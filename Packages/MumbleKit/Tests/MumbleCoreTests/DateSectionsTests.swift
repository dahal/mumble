import Foundation
import Testing
@testable import MumbleCore

@Suite struct DateSectionsTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func titles() {
        let now = date(2026, 11, 9, 15)
        #expect(DateSections.title(for: date(2026, 11, 9, 1), now: now, calendar: calendar) == "Today")
        #expect(DateSections.title(for: date(2026, 11, 8, 23), now: now, calendar: calendar) == "Yesterday")
        #expect(DateSections.title(for: date(2026, 11, 3), now: now, calendar: calendar) == "Previous 7 Days")
        #expect(DateSections.title(for: date(2026, 10, 20), now: now, calendar: calendar) == "Previous 30 Days")
        #expect(DateSections.title(for: date(2026, 3, 2), now: now, calendar: calendar) == "March")
        #expect(DateSections.title(for: date(2025, 12, 30), now: now, calendar: calendar) == "2025")
        #expect(DateSections.title(for: date(2026, 11, 12), now: now, calendar: calendar) == "Upcoming")
    }

    @Test func groupsInOrder() {
        let now = date(2026, 11, 9, 15)
        let dates = [date(2026, 11, 9, 10), date(2026, 11, 9, 9), date(2026, 11, 8), date(2026, 5, 1), date(2024, 1, 1)]
        let sections = DateSections.group(dates, date: { $0 }, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["Today", "Yesterday", "May", "2024"])
        #expect(sections.first?.items.count == 2)
    }
}
