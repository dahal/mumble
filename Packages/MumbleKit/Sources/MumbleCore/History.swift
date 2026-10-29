import Foundation

public struct HistoryItem: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    public var text: String
    public var rawText: String
    public var audioSeconds: Double
    public var latencyMs: Int
    public var appName: String?

    public init(
        id: UUID = UUID(), date: Date = Date(), text: String, rawText: String,
        audioSeconds: Double, latencyMs: Int, appName: String? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.rawText = rawText
        self.audioSeconds = audioSeconds
        self.latencyMs = latencyMs
        self.appName = appName
    }
}

/// Newest-first transcript history persisted as a small JSON file in Application Support.
public struct HistoryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Mumble/history.json")
    }

    public func load() -> [HistoryItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decoder.decode([HistoryItem].self, from: data)) ?? []
    }

    public func save(_ items: [HistoryItem]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(items)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    /// Prepends `item` and trims the list to `limit`, returning the new list.
    public static func inserting(_ item: HistoryItem, into items: [HistoryItem], limit: Int) -> [HistoryItem] {
        Array(([item] + items).prefix(max(0, limit)))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
