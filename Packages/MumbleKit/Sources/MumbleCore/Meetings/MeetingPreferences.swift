import Foundation

/// Meeting notes settings (spec §4.6). Stored inside `MumbleSettings`; every field decodes with a
/// default so settings saved by older builds keep loading.
public struct MeetingPreferences: Codable, Sendable, Equatable {
    public enum AudioRetention: String, Codable, Sendable, CaseIterable, Identifiable {
        case deleteAfterProcessing, keep7Days, keepUntilDeleted
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .deleteAfterProcessing: "Delete after processing"
            case .keep7Days: "Keep 7 days"
            case .keepUntilDeleted: "Keep until I delete"
            }
        }
    }

    public var enabled = true
    /// R1 + R3.
    public var remindOnDetect = true
    /// R2 (needs calendar access).
    public var headsUp = true
    /// R4: hold the last 2 minutes in memory until answered.
    public var catchTheStart = false
    public var showConsentSheet = true
    /// nil = not asked yet (asked the first time you name a speaker).
    public var rememberVoices: Bool?
    public var useCalendar = false
    public var readCaptions = true
    public var readMeetingWindow = false
    public var audioRetention: AudioRetention = .deleteAfterProcessing
    /// Raw value of MumbleSummary.SummaryProvider.
    public var summaryProvider = "automatic"
    public var markdownCopy = false
    public var markdownFolderBookmark: Data?
    public var privateNotesWhileMeeting = false
    public var myName: String?
    public var showLiveTranscript = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MeetingPreferences()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try c.decodeIfPresent(T.self, forKey: key) ?? fallback }
        enabled = try v(.enabled, d.enabled)
        remindOnDetect = try v(.remindOnDetect, d.remindOnDetect)
        headsUp = try v(.headsUp, d.headsUp)
        catchTheStart = try v(.catchTheStart, d.catchTheStart)
        showConsentSheet = try v(.showConsentSheet, d.showConsentSheet)
        rememberVoices = try c.decodeIfPresent(Bool.self, forKey: .rememberVoices)
        useCalendar = try v(.useCalendar, d.useCalendar)
        readCaptions = try v(.readCaptions, d.readCaptions)
        readMeetingWindow = try v(.readMeetingWindow, d.readMeetingWindow)
        audioRetention = try v(.audioRetention, d.audioRetention)
        summaryProvider = try v(.summaryProvider, d.summaryProvider)
        markdownCopy = try v(.markdownCopy, d.markdownCopy)
        markdownFolderBookmark = try c.decodeIfPresent(Data.self, forKey: .markdownFolderBookmark)
        privateNotesWhileMeeting = try v(.privateNotesWhileMeeting, d.privateNotesWhileMeeting)
        myName = try c.decodeIfPresent(String.self, forKey: .myName)
        showLiveTranscript = try v(.showLiveTranscript, d.showLiveTranscript)
    }

    public var reminderOptions: ReminderScheduler.Options {
        var o = ReminderScheduler.Options()
        o.remindOnDetect = remindOnDetect
        o.headsUp = headsUp && useCalendar
        return o
    }
}
