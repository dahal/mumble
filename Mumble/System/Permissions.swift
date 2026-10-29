import AppKit
import ApplicationServices
import ServiceManagement

@MainActor
enum Permissions {
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to Privacy & Security → Accessibility.
    static func requestAccessibility() {
        // The literal value of kAXTrustedCheckOptionPrompt, which Swift 6 flags as shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    /// What the 🌐/fn key does on its own: 0 = do nothing, 1 = change input source,
    /// 2 = emoji picker, 3 = dictation. Unset means the system default, which is not "nothing".
    static var fnKeyDoesNothing: Bool {
        UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int == 0
    }

    static var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
