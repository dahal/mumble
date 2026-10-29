import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts text into whatever app has focus by pasting it, then restores the user's clipboard.
@MainActor
enum TextInserter {
    enum Outcome: Equatable {
        case inserted
        /// A password field is focused; the text was only copied.
        case copiedSecureField
        /// Without Accessibility, synthetic ⌘V is silently dropped; the text was only copied.
        case copiedNoAccessibility
        /// The end-to-end test's window wasn't frontmost; nothing was pasted anywhere.
        case blockedOutsideTest
    }

    /// Set by the end-to-end test: pastes are only allowed into this process.
    static var restrictToProcess: pid_t?

    /// - Parameter onPasted: called the moment ⌘V is posted (before the clipboard is restored).
    static func insert(_ text: String, onPasted: () -> Void = {}) async -> Outcome {
        let pasteboard = NSPasteboard.general

        if let pid = restrictToProcess, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            return .blockedOutsideTest
        }

        if IsSecureEventInputEnabled() {
            copy(text)
            return .copiedSecureField
        }
        if !AXIsProcessTrusted() {
            copy(text)
            return .copiedNoAccessibility
        }

        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Tells clipboard managers to ignore this short-lived entry (nspasteboard.org convention).
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pasteboard.changeCount

        postCommandV()
        onPasted()

        // Give the target app time to read the pasteboard before restoring it.
        try? await Task.sleep(for: .milliseconds(350))
        if pasteboard.changeCount == ourChange {
            restore(saved, to: pasteboard)
        }
        return .inserted
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    /// The few characters before the cursor in the focused text field, via Accessibility.
    /// Returns nil when the app doesn't expose it (many Electron and web apps don't).
    static func precedingText(maxLength: Int = 4) -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement

        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return nil }
        guard selection.location > 0 else { return "" }

        var before = CFRange(location: max(0, selection.location - maxLength), length: 0)
        before.length = selection.location - before.location
        guard let beforeValue = AXValueCreate(.cfRange, &before) else { return nil }
        var text: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, beforeValue, &text) == .success
        else { return nil }
        return text as? String
    }
}
