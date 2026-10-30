import Foundation

/// Decides when to remind the user to take notes (spec §4.1.1). Pure: the app feeds it events and
/// the current time, and performs the returned actions.
public struct ReminderScheduler: Sendable {
    public struct Options: Sendable, Equatable {
        public var remindOnDetect = true
        public var headsUp = true
        public var secondReminderAfter: Double = 120
        public var headsUpLead: Double = 60
        public init() {}
    }

    public struct CalendarMeeting: Sendable, Hashable {
        public var eventID: String
        public var seriesID: String?
        public var title: String
        public var start: Date
        public var url: String?
        public init(eventID: String, seriesID: String? = nil, title: String, start: Date, url: String?) {
            self.eventID = eventID
            self.seriesID = seriesID
            self.title = title
            self.start = start
            self.url = url
        }
    }

    public struct Detected: Sendable, Hashable {
        public var app: MeetingApp
        public var url: String?
        public var title: String
        public var seriesID: String?
        public init(app: MeetingApp, url: String?, title: String, seriesID: String? = nil) {
            self.app = app
            self.url = url
            self.title = title
            self.seriesID = seriesID
        }
    }

    public enum Action: Sendable, Equatable {
        case none
        case headsUp(title: String)
        /// Ask (island prompt + notification). `isRepeat` for the second reminder.
        case prompt(Detected, isRepeat: Bool)
        /// An "always take notes" rule matched: start without asking.
        case autoStart(Detected)
        /// The meeting ended unanswered: withdraw the prompt and drop any held audio.
        case withdraw
    }

    public var options: Options
    private var headsUpShown: Set<String> = []
    private var current: Detected?
    private var promptedAt: Date?
    private var repeated = false
    private var answered = false

    public init(options: Options = Options()) {
        self.options = options
    }

    public var pending: Detected? { answered ? nil : current }

    /// Called every few seconds with upcoming calendar meetings.
    public mutating func tick(now: Date, upcoming: [CalendarMeeting], isRecording: Bool) -> Action {
        if !isRecording, !answered, let current, let promptedAt, !repeated,
           now.timeIntervalSince(promptedAt) >= options.secondReminderAfter {
            repeated = true
            return options.remindOnDetect ? .prompt(current, isRepeat: true) : .none
        }
        guard options.headsUp, !isRecording, current == nil else { return .none }
        for meeting in upcoming where meeting.url != nil && !headsUpShown.contains(meeting.eventID) {
            let lead = meeting.start.timeIntervalSince(now)
            if lead <= options.headsUpLead, lead > 0 {
                headsUpShown.insert(meeting.eventID)
                return .headsUp(title: meeting.title)
            }
        }
        return .none
    }

    /// A meeting app started using the microphone.
    public mutating func meetingStarted(_ detected: Detected, rules: [MeetingRule], now: Date, isRecording: Bool) -> Action {
        guard !isRecording else { return .none }
        if let current, current.app == detected.app, current.url.map(MeetingLink.normalize) == detected.url.map(MeetingLink.normalize) {
            return .none
        }
        current = detected
        answered = false
        repeated = false
        if rules.contains(where: { $0.matches(seriesID: detected.seriesID, url: detected.url) }) {
            answered = true
            return .autoStart(detected)
        }
        guard options.remindOnDetect else { return .none }
        promptedAt = now
        return .prompt(detected, isRepeat: false)
    }

    /// The user chose Take Notes, Not Now or dismissed; no more reminders for this meeting.
    public mutating func answered(now: Date) {
        answered = true
    }

    /// The meeting app stopped using the microphone.
    public mutating func meetingEnded() -> Action {
        defer {
            current = nil
            promptedAt = nil
            repeated = false
            answered = false
        }
        return current != nil && !answered ? .withdraw : .none
    }
}

/// Fixed-capacity ring of recent samples ("catch the start", spec R4). Memory only; `wipe()` zeroes it.
public struct SampleRing: Sendable {
    public let capacity: Int
    private var storage: [Float]
    private var head = 0
    private var filled = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = [Float](repeating: 0, count: self.capacity)
    }

    public var count: Int { filled }

    public mutating func append<S: Sequence>(_ samples: S) where S.Element == Float {
        for sample in samples {
            storage[head] = sample
            head = (head + 1) % capacity
            filled = min(filled + 1, capacity)
        }
    }

    /// Oldest to newest.
    public func snapshot() -> [Float] {
        guard filled == capacity else { return Array(storage[0..<filled]) }
        return Array(storage[head...] + storage[..<head])
    }

    /// Zeroes the memory and forgets everything.
    public mutating func wipe() {
        for i in storage.indices { storage[i] = 0 }
        head = 0
        filled = 0
    }

    /// True when every stored sample is zero (used by tests to prove a wipe).
    public var isZeroed: Bool { storage.allSatisfy { $0 == 0 } }
}
