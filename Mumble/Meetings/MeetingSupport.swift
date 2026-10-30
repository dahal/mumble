import AppKit
import Carbon.HIToolbox
import Security
@preconcurrency import UserNotifications

/// System-wide shortcuts that don't type a character into the frontmost app (Carbon hot keys).
@MainActor
final class GlobalShortcuts {
    struct Shortcut: Hashable {
        var keyCode: UInt32
        var modifiers: UInt32
        var display: String
        static let toggleMeeting = Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(optionKey | shiftKey), display: "⌥⇧M")
        static let bookmark = Shortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey | shiftKey), display: "⌥⇧B")
    }

    private var refs: [EventHotKeyRef] = []
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    func register(_ shortcut: Shortcut, id: UInt32, action: @escaping () -> Void) {
        Self.installHandler()
        Self.handlers[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D_55_4D_42), id: id)  // "MUMB"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) } else { AppLog.error("Couldn't register \(shortcut.display): \(status)") }
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalShortcuts.handlers[key]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Local notifications with actions (spec §4.1.1).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    enum Action: String { case takeNotes = "TAKE_NOTES", always = "ALWAYS", notNow = "NOT_NOW", open = "OPEN" }

    var onAction: (Action, [AnyHashable: Any]) -> Void = { _, _ in }
    private var configured = false

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter needs a real app bundle (not available to `swift test` or raw binaries).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func configure() {
        guard !configured, let center else { return }
        configured = true
        center.delegate = self
        let take = UNNotificationAction(identifier: Action.takeNotes.rawValue, title: "Take Notes", options: [])
        let always = UNNotificationAction(identifier: Action.always.rawValue, title: "Always for This Meeting", options: [])
        let notNow = UNNotificationAction(identifier: Action.notNow.rawValue, title: "Not Now", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "MEETING", actions: [take, always, notNow], intentIdentifiers: []),
            UNNotificationCategory(identifier: "MEETING_ONCE", actions: [take, notNow], intentIdentifiers: []),
            UNNotificationCategory(identifier: "NOTES_READY", actions: [], intentIdentifiers: []),
        ])
    }

    func post(id: String, title: String, body: String, category: String, userInfo: [String: String] = [:]) {
        configure()
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            content.userInfo = userInfo
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    func remove(id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [id])
        center?.removePendingNotificationRequests(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let sendable = info.reduce(into: [String: String]()) { if let k = $1.key as? String, let v = $1.value as? String { $0[k] = v } }
        await MainActor.run {
            let action: Action = identifier == UNNotificationDefaultActionIdentifier ? .open : Action(rawValue: identifier) ?? .open
            onAction(action, sendable)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// The Claude API key, kept in the login keychain.
enum Keychain {
    static let service = "dev.mumble.Mumble.claude"

    static func load() -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
