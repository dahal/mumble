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
        AppNavigation.shared.openMeetings = { Self.showMeetings() }
        if DevTools.runIfRequested(Self.controller) { return }
        Self.controller.start()
        Self.meetings.start()
        // First run, or a permission is missing: open settings so onboarding is visible.
        let onboarded = UserDefaults.standard.bool(forKey: "onboarded")
        if !onboarded || !Permissions.isAccessibilityTrusted || AudioRecorder.permission != .authorized {
            Self.showSettings()
        } else if HomeWindow.showsAtLaunch, !HomeWindow.launchedAtLogin {
            HomeWindow.show()
        }
        UserDefaults.standard.set(true, forKey: "onboarded")
    }

    static func showMeetings() {
        let meetings = meetingsOverride ?? meetings
        WindowCenter.shared.show("meetings", title: "Meetings", size: NSSize(width: 1100, height: 720),
                                 minSize: NSSize(width: 760, height: 460), autosave: "MumbleMeetings") {
            MeetingsWindow(meetings: meetings)
        }
    }

    static func showBooks() { BooksController.shared.showLibrary() }

    /// PDFs opened from Finder ("Open With", or dropped on the Dock icon) go to the book library.
    func application(_ application: NSApplication, open urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { return }
        BooksController.shared.importFiles(pdfs, openSingle: true)
        if pdfs.count > 1 { Self.showBooks() }
    }

    /// Opening Mumble again (Finder, Spotlight, the Dock) with no windows open shows Home.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { HomeWindow.show() }
        return true
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
            Button("Start Meeting Notes (Experimental)") { meetings.toggle() }
                .disabled(meetings.store == nil)
        }
        Button("Home…") { HomeWindow.show() }
        Button("Meetings…") { AppNavigation.shared.showMeeting(nil) }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        Button("Books…") { AppDelegate.showBooks() }
            .keyboardShortcut("b", modifiers: [.command, .shift])
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
