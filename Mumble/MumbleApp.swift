import AppKit
import SwiftUI

@main
struct MumbleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: AppDelegate.controller, openSettings: AppDelegate.showSettings)
        } label: {
            Image(systemName: AppDelegate.controller.isRecording ? "waveform.circle.fill" : "waveform")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let controller = DictationController()
    private static var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if DevTools.runIfRequested(Self.controller) { return }
        Self.controller.start()
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
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Mumble"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(controller: controller))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct MenuContent: View {
    let controller: DictationController
    let openSettings: () -> Void

    var body: some View {
        Text(statusLine)
        if !controller.accessibilityTrusted {
            Button("⚠︎ Grant Accessibility access…") { Permissions.requestAccessibility() }
        }
        Divider()
        if let last = controller.history.first {
            Button("Copy last: \(last.text.prefix(40))\(last.text.count > 40 ? "…" : "")") {
                TextInserter.copy(last.text)
            }
            Button("Paste last again") { controller.reinsertLast() }
            Divider()
        }
        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")
        Button("Quit Mumble") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch controller.modelStatus {
        case .idle: "Starting…"
        case let .loading(progress, label): "\(label) \(Int(progress * 100))%"
        case .ready: "Hold \(controller.settings.triggerKey.displayName) to dictate"
        case let .failed(message): "Model error: \(message)"
        }
    }
}
