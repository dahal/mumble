import Foundation

/// Apple Notes–style list sections: Today, Yesterday, Previous 7 Days, Previous 30 Days, then each
/// earlier month of this year by name, then earlier years.
public enum DateSections {
    public struct Section<Item>: Identifiable {
        public let title: String
        public var items: [Item]
        public var id: String { title }
    }

    public static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        let startOfToday = calendar.startOfDay(for: now)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if date > now { return "Upcoming" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
        if days <= 7 { return "Previous 7 Days" }
        if days <= 30 { return "Previous 30 Days" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale ?? .current
            formatter.setLocalizedDateFormatFromTemplate("MMMM")
            return formatter.string(from: date)
        }
        return String(calendar.component(.year, from: date))
    }

    /// Groups items (already sorted newest first) into sections, keeping their order.
    public static func group<Item>(
        _ items: [Item], date: (Item) -> Date, now: Date = Date(), calendar: Calendar = .current
    ) -> [Section<Item>] {
        var out: [Section<Item>] = []
        for item in items {
            let title = title(for: date(item), now: now, calendar: calendar)
            if out.last?.title == title {
                out[out.count - 1].items.append(item)
            } else if let i = out.firstIndex(where: { $0.title == title }) {
                out[i].items.append(item)
            } else {
                out.append(Section(title: title, items: [item]))
            }
        }
        return out
    }
}
