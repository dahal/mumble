import AppKit
import SwiftUI

/// Owns Mumble's document-style windows (Books, a book, Meetings). Mumble is a menu bar app, so it
/// shows in the Dock and app switcher only while one of these is open.
@MainActor
final class WindowCenter: NSObject, NSWindowDelegate {
    static let shared = WindowCenter()
    private var windows: [String: NSWindow] = [:]

    /// Shows the window for `key`, creating it with `make` the first time.
    @discardableResult
    func show(_ key: String, title: String, subtitle: String = "", size: NSSize, minSize: NSSize,
              autosave: String? = nil, toolbarStyle: NSWindow.ToolbarStyle = .unified,
              make: () -> some View) -> NSWindow {
        let window: NSWindow
        if let existing = windows[key] {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = title
            window.subtitle = subtitle
            window.isReleasedWhenClosed = false
            window.toolbarStyle = toolbarStyle
            window.contentMinSize = minSize
            window.contentViewController = NSHostingController(rootView: make())
            window.setContentSize(size)
            window.delegate = self
            if let autosave, window.setFrameUsingName(autosave) {
                window.setFrameAutosaveName(autosave)
            } else {
                window.center()
                if let autosave { window.setFrameAutosaveName(autosave) }
            }
            windows[key] = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func window(_ key: String) -> NSWindow? { windows[key] }

    func close(_ key: String) { windows[key]?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = windows.first(where: { $0.value === window })?.key else { return }
        windows[key] = nil
        onClose[key]?()
        onClose[key] = nil
        if windows.isEmpty {
            // Back to a menu bar–only app, after the window finishes closing.
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// Called once when the window for `key` closes.
    var onClose: [String: () -> Void] = [:]
}
