import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MumbleCore

/// Acoustic end-to-end test against a real app:
///
///   Mumble --e2e <result-file> --file <path/to/test.md> [--mic <name substring>]
///
/// Opens the file in VS Code, then for each scenario: puts the cursor on a new last line, posts real
/// Right-⌥ key events (caught by the normal HotkeyMonitor), speaks through the MacBook speakers with
/// `say` so the real microphone hears it, saves with ⌘S and reads the file back from disk.
///
/// Safety: before every synthetic key event it checks that VS Code is frontmost with the test file
/// focused, and aborts otherwise; pastes are restricted to VS Code for the duration.
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
        Scenario(name: "third hold, back to back", sentence: "Book a table for four people on Saturday evening.", kind: .hold),
        Scenario(name: "double-tap latch", sentence: "Can you review my pull request when you get a chance?", kind: .latch),
        Scenario(name: "escape cancels", sentence: "This sentence should never appear anywhere.", kind: .cancel),
        Scenario(
            name: "long dictation (~30 s)",
            sentence: "Here is the plan for next week. On Monday we finish the onboarding flow and fix the login bug. "
                + "On Tuesday the design team reviews the new settings screen with the product managers. "
                + "On Wednesday we run the load tests and write up the results for the leadership meeting. "
                + "On Thursday we ship the release candidate to the beta testers and collect their feedback. "
                + "On Friday we decide whether it is ready to launch.",
            kind: .hold),
        Scenario(name: "cold start after standby", sentence: "The new design looks great, but the buttons feel a little small.", kind: .coldHold),
    ]

    struct Abort: Error { let reason: String }

    private static var lines: [String] = []
    private static var resultURL: URL!
    private static var fileURL: URL!
    private static var target: NSRunningApplication!

    private static func report(_ line: String) {
        lines.append(line)
        AppLog.info("E2E " + line)
        try? lines.joined(separator: "\n").appending("\n").write(to: resultURL, atomically: true, encoding: .utf8)
    }

    static func run(_ controller: DictationController, resultURL: URL, arguments: [String]) async {
        self.resultURL = resultURL
        guard let i = arguments.firstIndex(of: "--file"), i + 1 < arguments.count else {
            report("FAIL usage: --file <path> is required")
            exit(2)
        }
        fileURL = URL(fileURLWithPath: arguments[i + 1])

        if let j = arguments.firstIndex(of: "--mic"), j + 1 < arguments.count {
            let wanted = arguments[j + 1]
            guard let device = AudioDevices.inputDevices().first(where: { $0.name.localizedCaseInsensitiveContains(wanted) })
            else {
                report("FAIL no input device matching \(wanted)")
                exit(2)
            }
            controller.setTestInputDevice(device.uid)
        }

        report("speakers: \(speakerDevice ?? "system default"); mic: \(controller.testInputDeviceName); system output: \(AudioDevices.defaultOutput()?.name ?? "?")")
        report("permissions: accessibility \(Permissions.isAccessibilityTrusted), mic \(AudioRecorder.permission.rawValue)")
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

        var passed = 0
        do {
            try await openTarget()
            for scenario in scenarios {
                if try await run(scenario, controller) { passed += 1 }
                try? await Task.sleep(for: .milliseconds(700))
            }
        } catch let abort as Abort {
            report("ABORTED (safety): \(abort.reason)")
        } catch {
            report("ABORTED: \(error)")
        }
        TextInserter.restrictToProcess = nil
        report("done: \(passed)/\(scenarios.count) passed")
        try? await Task.sleep(for: .milliseconds(300))
        exit(passed == scenarios.count ? 0 : 1)
    }

    private static func run(_ scenario: Scenario, _ controller: DictationController) async throws -> Bool {
        if scenario.kind == .coldHold {
            // Let the recorder's standby expire so the microphone starts from cold.
            try? await Task.sleep(for: .seconds(AudioRecorder.standbySeconds + 2))
        }
        try await refocusTarget()
        // New last line for this scenario, saved, so the baseline is on disk.
        try await keystroke(CGKeyCode(kVK_DownArrow), flags: .maskCommand)
        try await keystroke(CGKeyCode(kVK_End), flags: [])
        try await keystroke(CGKeyCode(kVK_Return), flags: [])
        try await save()
        let before = try String(contentsOf: fileURL, encoding: .utf8)
        let output = AudioDevices.defaultOutput()
        let rateBefore = output.map { AudioDevices.nominalSampleRate($0.id) } ?? 0
        var rateDuring = rateBefore

        switch scenario.kind {
        case .hold, .coldHold:
            try await trigger(down: true)
            try? await Task.sleep(for: .milliseconds(300))
            await say(scenario.sentence)
            rateDuring = output.map { AudioDevices.nominalSampleRate($0.id) } ?? 0
            try? await Task.sleep(for: .milliseconds(400))
            try await trigger(down: false)
        case .latch:
            try await trigger(down: true); try? await Task.sleep(for: .milliseconds(80))
            try await trigger(down: false); try? await Task.sleep(for: .milliseconds(120))
            try await trigger(down: true); try? await Task.sleep(for: .milliseconds(80))
            try await trigger(down: false)
            try? await Task.sleep(for: .milliseconds(300))
            await say(scenario.sentence)
            rateDuring = output.map { AudioDevices.nominalSampleRate($0.id) } ?? 0
            try? await Task.sleep(for: .milliseconds(400))
            try await trigger(down: true); try? await Task.sleep(for: .milliseconds(80))
            try await trigger(down: false)
        case .cancel:
            try await trigger(down: true)
            try? await Task.sleep(for: .milliseconds(300))
            await say(scenario.sentence)
            try await keystroke(CGKeyCode(kVK_Escape), flags: [])
            try? await Task.sleep(for: .milliseconds(100))
            try await trigger(down: false)
        }

        // Give the final pass and paste time to land, then save and read back.
        try? await Task.sleep(for: .milliseconds(scenario.kind == .cancel ? 2_000 : 1_500))
        try await save()
        let after = try String(contentsOf: fileURL, encoding: .utf8)
        let inserted = Self.insertion(before: before, after: after).trimmingCharacters(in: .whitespacesAndNewlines)

        let audio = output.map { String(format: "%@ %.0f→%.0f Hz", $0.name, rateBefore, rateDuring) } ?? "?"
        let ok: Bool
        let detail: String
        if scenario.kind == .cancel {
            ok = inserted.isEmpty
            detail = ok ? "nothing inserted" : "unexpected text: \(inserted)"
        } else {
            // The model writes small numbers as digits ("4 people"); score that as correct.
            let wer = WordErrorRate.compute(reference: Self.digitsAsWords(scenario.sentence), hypothesis: Self.digitsAsWords(inserted))
            ok = !inserted.isEmpty && wer.rate <= 0.1
            detail = String(format: "WER %.0f%%, release→paste %@ ms: “%@”", wer.rate * 100,
                            controller.lastLatencyMs.map(String.init) ?? "?", inserted)
        }
        let degraded = rateDuring > 0 && rateDuring < rateBefore
        report("\(ok && !degraded ? "PASS" : "FAIL") \(scenario.name): \(detail) [output \(audio)\(degraded ? " DEGRADED" : "")]")
        return ok && !degraded
    }

    static func digitsAsWords(_ text: String) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        var out = text
        for (n, w) in words.enumerated().reversed() {
            out = out.replacingOccurrences(of: "\\b\(n)\\b", with: w, options: .regularExpression)
        }
        return out
    }

    static func insertion(before: String, after: String) -> String {
        let prefix = zip(before, after).prefix { $0 == $1 }.count
        let b = before.dropFirst(prefix), a = after.dropFirst(prefix)
        let suffix = zip(b.reversed(), a.reversed()).prefix { $0 == $1 }.count
        return String(a.dropLast(suffix))
    }

    // MARK: Target app

    private static func openTarget() async throws {
        guard let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
            throw Abort(reason: "VS Code is not installed")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        target = try await NSWorkspace.shared.open([fileURL], withApplicationAt: vscode, configuration: configuration)
        TextInserter.restrictToProcess = target.processIdentifier
        // Wait for VS Code to come forward with the file focused.
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            if isTargetFocused() { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        try requireTargetFocused()
        try? await Task.sleep(for: .milliseconds(500))
        if lines.allSatisfy({ !$0.hasPrefix("target:") }) {
            report("target: VS Code window “\(focusedWindowTitle() ?? "?")”")
        }
    }

    /// Brings VS Code and the test file back to the front (the user may have clicked elsewhere).
    private static func refocusTarget() async throws {
        guard !isTargetFocused() else { return }
        report("note: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") was in front; refocusing VS Code")
        try await openTarget()
    }

    private static func focusedWindowTitle() -> String? {
        guard let target else { return nil }
        let app = AXUIElementCreateApplication(target.processIdentifier)
        var window: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window
        else { return nil }
        var title: AnyObject?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }

    private static func isTargetFocused() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == target?.processIdentifier
            && (focusedWindowTitle()?.contains(fileURL.lastPathComponent) ?? false)
    }

    private static func requireTargetFocused() throws {
        guard isTargetFocused() else {
            throw Abort(reason: "frontmost is \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"), window “\(focusedWindowTitle() ?? "?")”; refusing to send keys")
        }
    }

    // MARK: Synthetic input (every event is gated on the target being focused)

    private static func trigger(down: Bool) async throws {
        try requireTargetFocused()
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_RightOption), keyDown: down)
        else { return }
        event.type = .flagsChanged
        // NX_DEVICERALTKEYMASK (0x40) marks the right-hand key; HotkeyMonitor checks it.
        event.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40) : []
        event.post(tap: .cghidEventTap)
    }

    private static func keystroke(_ key: CGKeyCode, flags: CGEventFlags) async throws {
        try requireTargetFocused()
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(120))
    }

    private static func save() async throws {
        try await keystroke(CGKeyCode(kVK_ANSI_S), flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(400))
    }

    // MARK: Speech

    /// The built-in speakers as named by `say -a ?`, so the test works with headphones connected.
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
        process.arguments = ["-r", "185"] + (speakerDevice.map { ["-a", $0] } ?? []) + [text]
        try? process.run()
        while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
    }
}
