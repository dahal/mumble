import EventKit
import MumbleCore

/// Reads meetings from the calendars on this Mac (Google, Exchange and iCloud accounts added in
/// System Settings sync here), so no Google sign-in or email access is needed (spec §10.2).
@MainActor
final class CalendarService {
    struct Event: Sendable, Hashable {
        struct Attendee: Sendable, Hashable {
            var name: String
            var email: String?
            var isMe: Bool
        }

        var id: String
        var seriesID: String?
        var title: String
        var start: Date
        var end: Date
        var url: String?
        var attendees: [Attendee]
    }

    private let store = EKEventStore()

    static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    static var isAuthorized: Bool { status == .fullAccess }

    /// Asks for calendar access (once; macOS remembers the answer).
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            AppLog.error("Calendar access request failed: \(error)")
            return false
        }
    }

    /// Events overlapping [from, to], skipping all-day events.
    func events(from: Date, to: Date) -> [Event] {
        guard Self.isAuthorized else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).filter { !$0.isAllDay }.map(Self.convert)
    }

    /// The event this meeting most likely is: same meeting link first, else the one that overlaps
    /// now and started closest to now.
    func currentEvent(url: String?, now: Date = Date()) -> Event? {
        let candidates = events(from: now.addingTimeInterval(-3 * 3600), to: now.addingTimeInterval(15 * 60))
            .filter { $0.start <= now.addingTimeInterval(10 * 60) && $0.end >= now.addingTimeInterval(-5 * 60) }
        if let url, let byLink = candidates.first(where: { $0.url.map(MeetingLink.normalize) == MeetingLink.normalize(url) }) {
            return byLink
        }
        return candidates.filter { $0.url != nil || $0.attendees.count > 1 }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    /// Upcoming meetings for the 1-minute heads-up.
    func upcoming(now: Date = Date()) -> [ReminderScheduler.CalendarMeeting] {
        events(from: now, to: now.addingTimeInterval(5 * 60)).filter { $0.start > now }.map {
            ReminderScheduler.CalendarMeeting(eventID: $0.id, seriesID: $0.seriesID, title: $0.title, start: $0.start, url: $0.url)
        }
    }

    private static func convert(_ event: EKEvent) -> Event {
        let text = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }.joined(separator: "\n")
        let attendees: [Event.Attendee] = (event.attendees ?? []).compactMap { participant in
            guard participant.participantType != .room, participant.participantType != .resource else { return nil }
            let email = participant.url.absoluteString.hasPrefix("mailto:")
                ? String(participant.url.absoluteString.dropFirst("mailto:".count)) : nil
            let name = participant.name?.trimmingCharacters(in: .whitespaces)
            guard let display = (name?.isEmpty == false ? name : email.map(NameMatcher.displayName(fromEmail:))) else { return nil }
            return .init(name: display, email: email, isMe: participant.isCurrentUser)
        }
        let start = event.startDate ?? Date()
        return Event(
            id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)@\(Int(start.timeIntervalSince1970))",
            seriesID: event.hasRecurrenceRules ? event.calendarItemExternalIdentifier : nil,
            title: event.title?.isEmpty == false ? event.title! : "Meeting",
            start: start, end: event.endDate ?? start, url: MeetingLink.firstLink(in: text), attendees: attendees)
    }
}
