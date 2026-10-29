import AppKit
import MumbleCore

/// Watches the push-to-talk key system-wide. Global key monitoring needs the
/// Accessibility permission; call `install()` again once it is granted.
@MainActor
final class HotkeyMonitor {
    var trigger: TriggerKey = .rightOption
    /// Called with the event's own timestamp (seconds since boot), so a busy main thread
    /// can't make a quick tap look like a long press.
    var onPress: (TimeInterval) -> Void = { _ in }
    var onRelease: (TimeInterval) -> Void = { _ in }
    var onEscape: () -> Void = {}
    /// Another key was typed while the trigger was held (e.g. ⌥+letter for a special character).
    var onOtherKey: () -> Void = {}

    private var monitors: [Any] = []
    private var isDown = false

    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK) distinguish left from right keys.
    private static let rightOptionMask: UInt = 0x40
    private static let rightCommandMask: UInt = 0x10
    private static let rightControlMask: UInt = 0x2000

    func install() {
        uninstall()
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    func uninstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 {
                onEscape()
            } else if isDown {
                onOtherKey()
            }
        case .flagsChanged:
            guard event.keyCode == trigger.keyCode else { return }
            let down = isPressed(event.modifierFlags)
            guard down != isDown else { return }
            isDown = down
            down ? onPress(event.timestamp) : onRelease(event.timestamp)
        default:
            break
        }
    }

    private func isPressed(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch trigger {
        case .function: flags.contains(.function)
        case .rightOption: flags.rawValue & Self.rightOptionMask != 0
        case .rightCommand: flags.rawValue & Self.rightCommandMask != 0
        case .rightControl: flags.rawValue & Self.rightControlMask != 0
        }
    }
}
