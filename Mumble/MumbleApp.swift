import AppKit
import MumbleCore
import SwiftUI

@main
struct MumbleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: AppDelegate.controller, meetings: AppDelegate.meetings, openSettings: AppDelegate.showSettings)
        } label: {
            Image(nsImage: AppDelegate.controller.isRecording || AppDelegate.meetings.isRecording ? MenuBarIcon.recording : MenuBarIcon.idle)
                .renderingMode(.original)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let controller = DictationController()
    static let meetings = MeetingController(dictation: controller)
    /// Dev tools show the window with a different (temporary) store.
    static var meetingsOverride: MeetingController?
    private static var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppNavigation.shared.openWindow = { Self.showSettings() }
        if DevTools.runIfRequested(Self.controller) { return }
        Self.controller.start()
        Self.meetings.start()
        // First run, or a permission is missing: open settings so onboarding is visible.
        let onboarded = UserDefaults.standard.bool(forKey: "onboarded")
        if !onboarded || !Permissions.isAccessibilityTrusted || AudioRecorder.permission != .authorized {
            Self.showSettings()
        }
        UserDefaults.standard.set(true, forKey: "onboarded")
    }

    static func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Mumble"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(controller: controller, meetings: meetingsOverride ?? meetings))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct MenuContent: View {
    let controller: DictationController
    let meetings: MeetingController
    let openSettings: () -> Void

    var body: some View {
        Text(statusLine)
        if !controller.accessibilityTrusted {
            Button("⚠︎ Grant Accessibility access…") { Permissions.requestAccessibility() }
        }
        Divider()
        if let title = meetings.askingTitle {
            Button("Take Notes for \(title)") { meetings.takeNotes() }
        }
        if meetings.isRecording {
            Button("Stop Meeting Notes") { meetings.stop() }
            Button("Bookmark This Moment") { meetings.bookmark() }
            if meetings.prefs.privateNotesWhileMeeting {
                Text("Hold \(controller.settings.triggerKey.displayName) to add a private note")
            }
        } else if meetings.askingTitle == nil {
            Button("Start Meeting Notes") { meetings.toggle() }
                .disabled(meetings.store == nil)
        }
        Button("Meetings…") { AppNavigation.shared.showMeeting(nil) }
        Divider()
        if let last = controller.history.first {
            Button("Copy last: \(last.text.prefix(40))\(last.text.count > 40 ? "…" : "")") {
                TextInserter.copy(last.text)
            }
            Button("Paste last again") { controller.reinsertLast() }
            Divider()
        }
        Button("Show Log") { AppLog.reveal() }
        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")
        Button("Quit Mumble") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        if meetings.isRecording { return "Taking meeting notes · \(MarkdownExporter.timestamp(meetings.elapsed))" }
        return switch controller.modelStatus {
        case .idle: "Starting…"
        case let .loading(progress, label): "\(label) \(Int(progress * 100))%"
        case .ready: "Hold \(controller.settings.triggerKey.displayName) to dictate"
        case let .failed(message): "Model error: \(message)"
        }
    }
}
