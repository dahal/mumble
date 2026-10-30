import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit
import Vision
import MumbleCore

/// Reads live captions ("Sarah Chen: so the annual plan…") from the meeting window through
/// Accessibility (spec §10.2). Experimental: works where the app exposes its captions to
/// Accessibility; it fails closed (no signals) otherwise.
@MainActor
final class CaptionReader {
    struct Line: Hashable { var name: String; var text: String }

    private let app: AXUIElement
    private var lastSeen: [Line] = []
    private var emitted = Set<String>()

    init(pid: pid_t) {
        app = AXUIElementCreateApplication(pid)
        // Chromium and Electron build their web accessibility tree only when asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// New, settled caption lines since the last poll.
    func poll() -> [Line] {
        guard AXIsProcessTrusted() else { return [] }
        var lines: [Line] = []
        for window in AXHelpers.children(app, attribute: kAXWindowsAttribute) {
            AXHelpers.walk(window, depth: 30) { node in
                if Self.isCaptionRegion(node) {
                    lines += Self.parse(Self.texts(in: node))
                    return false
                }
                return true
            }
        }
        // A line is settled once it is unchanged between two polls.
        let settled = lines.filter { lastSeen.contains($0) }
        lastSeen = lines
        return settled.filter { emitted.insert("\($0.name)|\($0.text)").inserted }
    }

    static func isCaptionRegion(_ node: AXUIElement) -> Bool {
        let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute, "AXDOMIdentifier"]
            .compactMap { AXHelpers.string(node, $0)?.lowercased() }
        return labels.contains { $0 == "captions" || $0.hasPrefix("captions") || $0.contains("live caption") }
    }

    static func texts(in node: AXUIElement) -> [String] {
        var out: [String] = []
        AXHelpers.walk(node, depth: 12) { child in
            if AXHelpers.string(child, kAXRoleAttribute) == kAXStaticTextRole as String,
               let value = AXHelpers.string(child, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                out.append(value)
            }
            return true
        }
        return out
    }

    /// Captions alternate a short name and the words they said; "Name: text" in one string also works.
    static func parse(_ texts: [String]) -> [Line] {
        var lines: [Line] = []
        var i = 0
        while i < texts.count {
            let t = texts[i]
            if let colon = t.firstIndex(of: ":"), isName(String(t[..<colon])) {
                lines.append(Line(name: String(t[..<colon]), text: String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
                i += 1
            } else if isName(t), i + 1 < texts.count, !isName(texts[i + 1]) {
                lines.append(Line(name: t, text: texts[i + 1]))
                i += 2
            } else {
                i += 1
            }
        }
        return lines.filter { WordErrorRate.normalizedWords($0.text).count >= 2 }
    }

    nonisolated static func isName(_ s: String) -> Bool {
        let words = s.split(separator: " ")
        guard (1...4).contains(words.count), s.count <= 40 else { return false }
        return words.allSatisfy { w in w.first?.isUppercase == true && w.allSatisfy { $0.isLetter || $0 == "." || $0 == "-" || $0 == "'" } }
    }
}

/// Reads participant names off the meeting window (spec §10.2 "participant list"), with Apple's
/// on-device text recognition. Opt-in, needs Screen Recording; only the meeting window is
/// captured, every few seconds, and frames are discarded immediately. The names are offered as
/// suggestions in the Choose name… picker; they never decide who is talking.
@MainActor
final class ScreenSpeaker {
    static let shared = ScreenSpeaker()

    private var task: Task<Void, Never>?
    private(set) var names: Set<String> = []

    nonisolated static let uiWords: Set<String> = [
        "meet", "zoom", "teams", "slack", "present now", "turn on captions", "more options", "leave call", "you",
        "chat", "people", "activities", "host controls", "raise hand", "mute", "unmute", "share screen", "participants",
        "reactions", "record", "apps", "view", "camera", "microphone", "settings", "join", "end", "leave", "gallery",
        "speaker", "pin", "unpin", "remove", "more", "details", "everyone", "meeting", "call", "huddle", "captions",
    ]

    func start(pid: pid_t, onNames: @escaping (Set<String>) -> Void) {
        stop()
        names = []
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let found = await Self.readNames(pid: pid), let self {
                    let new = found.subtracting(self.names)
                    if !new.isEmpty {
                        self.names.formUnion(new)
                        onNames(self.names)
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    static func readNames(pid: pid_t) async -> Set<String>? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.filter({ $0.owningApplication?.processID == pid && $0.frame.width > 300 })
                  .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        else { return nil }
        return await Task.detached { recognizeNames(in: image) }.value
    }

    nonisolated static func recognizeNames(in image: CGImage) -> Set<String> {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        var names = Set<String>()
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                  observation.confidence > 0.5, CaptionReader.isName(text), !uiWords.contains(text.lowercased()),
                  text.split(separator: " ").count >= 2 || text.count >= 3
            else { continue }
            names.insert(text)
        }
        return names
    }
}
