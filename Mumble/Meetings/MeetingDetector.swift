import AppKit
import ApplicationServices
import MumbleCore

/// Notices when a call starts (spec §7.1): a meeting app, or a browser showing a meeting page, is
/// using the microphone. Reads the page URL through Accessibility (no Automation prompt).
@MainActor
final class MeetingDetector {
    struct Call: Equatable, Sendable {
        var app: MeetingApp
        /// Bundle IDs to tap: the app (and its helpers) or the browser.
        var bundlePrefixes: [String]
        var url: String?
        var appName: String
        var pid: pid_t

        /// What to record: the app and its helpers, or this exact process.
        var tapTarget: SystemAudioTap.Target {
            bundlePrefixes.isEmpty ? .pids([pid]) : .bundlePrefixes(bundlePrefixes)
        }
    }

    var onStart: (Call) -> Void = { _ in }
    var onEnd: (Call) -> Void = { _ in }

    private(set) var current: Call?
    private var task: Task<Void, Never>?
    private var missedPolls = 0

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func poll() {
        let found = Self.detect()
        if let found {
            missedPolls = 0
            if found != current {
                if let current, current.url != found.url || current.app != found.app { onEnd(current) }
                current = found
                onStart(found)
            }
        } else if let current {
            // A muted call can briefly stop using the mic: wait ~2 minutes before calling it over.
            missedPolls += 1
            if missedPolls >= 40 {
                self.current = nil
                missedPolls = 0
                onEnd(current)
            }
        }
    }

    /// A call that is using the microphone right now, if any.
    static func detect() -> Call? {
        let inputProcesses = SystemAudioTap.processes().filter { $0.isRunningInput && $0.pid != getpid() }
        guard !inputProcesses.isEmpty else { return nil }
        for process in inputProcesses {
            guard let bundleID = process.bundleID else { continue }
            if let app = MeetingLink.app(forBundleID: bundleID) {
                let running = NSRunningApplication(processIdentifier: process.pid)
                let prefix = MeetingLink.appBundles.first { bundleID.hasPrefix($0.prefix) }?.prefix ?? bundleID
                return Call(app: app, bundlePrefixes: [prefix], url: nil,
                            appName: running?.localizedName ?? app.displayName, pid: process.pid)
            }
            if MeetingLink.isBrowser(bundleID) {
                // The input process may be a helper; find the browser app itself.
                let browserPrefix = MeetingLink.browserBundles.first { bundleID.hasPrefix($0) } ?? bundleID
                guard let browser = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == browserPrefix }),
                      let url = meetingURL(in: browser)
                else { continue }
                return Call(app: MeetingLink.app(forURL: url) ?? .other(browserPrefix), bundlePrefixes: [browserPrefix],
                            url: url, appName: browser.localizedName ?? "Browser", pid: browser.processIdentifier)
            }
        }
        return nil
    }

    /// Looks through the browser's windows for a meeting page: the address bar value or the window
    /// title ("Meet – abc-defg-hij").
    static func meetingURL(in app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for window in AXHelpers.children(element, attribute: kAXWindowsAttribute) {
            if let title = AXHelpers.string(window, kAXTitleAttribute),
               let range = title.range(of: #"[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) {
                return "https://meet.google.com/\(title[range])"
            }
            var found: String?
            AXHelpers.walk(window, depth: 8) { node in
                guard AXHelpers.string(node, kAXRoleAttribute) == kAXTextFieldRole as String,
                      let value = AXHelpers.string(node, kAXValueAttribute), MeetingLink.app(forURL: value) != nil
                else { return true }
                found = value.contains("://") ? value : "https://" + value
                return false
            }
            if let found { return found }
        }
        return nil
    }
}

/// Small Accessibility helpers.
enum AXHelpers {
    static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func children(_ element: AXUIElement, attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
        (value(element, attribute) as? [AXUIElement]) ?? []
    }

    /// Depth-first walk; `visit` returns false to stop.
    @discardableResult
    static func walk(_ element: AXUIElement, depth: Int, visit: (AXUIElement) -> Bool) -> Bool {
        guard visit(element) else { return false }
        guard depth > 0 else { return true }
        for child in children(element) where !walk(child, depth: depth - 1, visit: visit) { return false }
        return true
    }
}
