import AppKit
import Carbon.HIToolbox
import MumbleCore

/// Acoustic end-to-end test, run with `Mumble --e2e <result-file>`.
///
/// Drives the real app: posts real Right-⌥ key events (caught by the same HotkeyMonitor),
/// speaks with `say` through the speakers so the real microphone hears it, and checks what the
/// real paste put into a text field. Needs Accessibility + Microphone for Mumble, speakers on,
/// and no headphones.
@MainActor
enum E2ETest {
    struct Scenario {
        let name: String
        let sentence: String
        let kind: Kind
        enum Kind { case hold, latch, cancel, coldHold }
    }

    static let scenarios = [
        Scenario(name: "hold", sentence: "Please send the quarterly report to the whole team before Friday.", kind: .hold),
        Scenario(name: "second hold (previous crash)", sentence: "I think we should move the meeting to Tuesday afternoon.", kind: .hold),
        Scenario(name: "double-tap latch", sentence: "Can you review my pull request when you get a chance?", kind: .latch),
        Scenario(name: "escape cancels", sentence: "This sentence should never appear anywhere.", kind: .cancel),
        Scenario(name: "cold start after standby", sentence: "The new design looks great, but the buttons feel a little small.", kind: .coldHold),
    ]

    private static var lines: [String] = []

    static func run(_ controller: DictationController, resultURL: URL) async {
        func report(_ line: String) {
            lines.append(line)
            AppLog.info("E2E " + line)
            try? lines.joined(separator: "\n").appending("\n").write(to: resultURL, atomically: true, encoding: .utf8)
        }

        report("speakers: \(speakerDevice ?? "system default"), mic: \(AudioDevices.resolveInput(preferredUID: controller.settings.inputDeviceUID)?.name ?? "?")")
        report("start: accessibility \(Permissions.isAccessibilityTrusted), mic \(AudioRecorder.permission.rawValue)")
        guard Permissions.isAccessibilityTrusted, AudioRecorder.permission == .authorized else {
            report("FAIL permissions missing")
            exit(2)
        }
        controller.start()
        await controller.waitUntilModelSettles()
        guard controller.modelStatus.isReady else {
            report("FAIL model: \(controller.modelStatus)")
            exit(2)
        }

        let (window, textView) = makeWindow()
        _ = window
        try? await Task.sleep(for: .milliseconds(800))

        var passed = 0
        for scenario in scenarios {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
            if scenario.kind == .coldHold {
                // Let the recorder's standby expire so the mic engine starts from cold.
                try? await Task.sleep(for: .seconds(AudioRecorder.standbySeconds + 2))
            }
            let before = textView.string
            let started = ContinuousClock.now

            switch scenario.kind {
            case .hold, .coldHold:
                postTrigger(down: true)
                try? await Task.sleep(for: .milliseconds(300))
                await say(scenario.sentence)
                try? await Task.sleep(for: .milliseconds(400))
                postTrigger(down: false)
            case .latch:
                postTrigger(down: true); try? await Task.sleep(for: .milliseconds(80))
                postTrigger(down: false); try? await Task.sleep(for: .milliseconds(120))
                postTrigger(down: true); try? await Task.sleep(for: .milliseconds(80))
                postTrigger(down: false)
                try? await Task.sleep(for: .milliseconds(300))
                await say(scenario.sentence)
                try? await Task.sleep(for: .milliseconds(400))
                postTrigger(down: true); try? await Task.sleep(for: .milliseconds(80))
                postTrigger(down: false)
            case .cancel:
                postTrigger(down: true)
                try? await Task.sleep(for: .milliseconds(300))
                await say(scenario.sentence)
                postEscape()
                try? await Task.sleep(for: .milliseconds(100))
                postTrigger(down: false)
            }

            // Wait for the paste to land.
            let deadline = ContinuousClock.now + .seconds(4)
            while textView.string == before, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let inserted = String(textView.string.dropFirst(before.count))
            let ms = Int(started.duration(to: .now).components.seconds * 1000)

            let ok: Bool
            var detail: String
            if scenario.kind == .cancel {
                try? await Task.sleep(for: .seconds(1.5))
                let leaked = String(textView.string.dropFirst(before.count))
                ok = leaked.isEmpty
                detail = ok ? "nothing inserted" : "unexpected text: \(leaked)"
            } else {
                let wer = WordErrorRate.compute(reference: scenario.sentence, hypothesis: inserted)
                ok = !inserted.isEmpty && wer.rate <= 0.15
                detail = String(format: "WER %.0f%%, latency release→text %@ ms: “%@”",
                                wer.rate * 100, controller.lastLatencyMs.map(String.init) ?? "?",
                                inserted.trimmingCharacters(in: .whitespaces))
            }
            if ok { passed += 1 }
            report("\(ok ? "PASS" : "FAIL") \(scenario.name) (\(ms / 1000) s): \(detail)")
            try? await Task.sleep(for: .milliseconds(700))
        }

        report("done: \(passed)/\(scenarios.count) passed")
        try? await Task.sleep(for: .milliseconds(300))
        exit(passed == scenarios.count ? 0 : 1)
    }

    // MARK: Helpers

    private static func makeWindow() -> (NSWindow, NSTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Mumble end-to-end test"
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        let textView = PastingTextView(frame: scroll.bounds)
        textView.font = .systemFont(ofSize: 15)
        textView.isRichText = false
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        window.contentView = scroll
        window.center()
        window.isReleasedWhenClosed = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        return (window, textView)
    }

    /// Posts a Right-⌥ press or release as a real modifier event.
    private static func postTrigger(down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_RightOption), keyDown: down)
        else { return }
        event.type = .flagsChanged
        // NX_DEVICERALTKEYMASK (0x40) marks the right-hand key; HotkeyMonitor checks it.
        event.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40) : []
        event.post(tap: .cghidEventTap)
    }

    private static func postEscape() {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: false)?.post(tap: .cghidEventTap)
    }

    /// The built-in speakers as named by `say -a ?`, if present.
    static let speakerDevice: String? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-a", "?"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(separator: "\n").first { $0.localizedCaseInsensitiveContains("Speakers") }
            .map { String($0.drop { $0 == " " || $0.isNumber }).trimmingCharacters(in: .whitespaces) }
    }()

    private static func say(_ text: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        // Through the MacBook speakers explicitly, so the test works with headphones connected.
        process.arguments = ["-r", "185"] + (speakerDevice.map { ["-a", $0] } ?? []) + [text]
        try? process.run()
        while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
    }
}

/// Mumble has no Edit menu (it's a menu bar app), so ⌘V isn't routed to text views by default.
/// Real target apps all have one; this view handles it directly for the test window.
private final class PastingTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
