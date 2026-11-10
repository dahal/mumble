import Foundation

/// A PDF in the library. The file is copied into the library folder, so moving or deleting the
/// original doesn't lose the book or your place in it.
public struct Book: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var author: String?
    /// File name inside the library folder.
    public var fileName: String
    /// The imported file's name and size, to recognize the same PDF imported twice.
    public var sourceName: String
    public var byteCount: Int
    public var pageCount: Int
    public var addedAt: Date
    public var lastOpenedAt: Date?
    /// Index of the utterance to read next, and how many the book has (0 until first opened).
    public var position: Int
    public var utteranceCount: Int
    public var finished: Bool

    public init(
        id: UUID = UUID(), title: String, author: String? = nil, fileName: String, sourceName: String,
        byteCount: Int, pageCount: Int, addedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.fileName = fileName
        self.sourceName = sourceName
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.addedAt = addedAt
        self.position = 0
        self.utteranceCount = 0
        self.finished = false
    }

    /// 0…1 through the book.
    public var progress: Double {
        if finished { return 1 }
        guard utteranceCount > 0 else { return 0 }
        return min(1, Double(position) / Double(utteranceCount))
    }

    public var isNew: Bool { lastOpenedAt == nil && !finished }
    public var isStarted: Bool { lastOpenedAt != nil && !finished }
}

/// The book list, saved as JSON next to the PDFs.
public final class Library {
    public let folder: URL
    public private(set) var books: [Book] = []

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mumble/Books")
    }

    private var indexURL: URL { folder.appending(path: "library.json") }

    public init(folder: URL = Library.defaultFolder) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL) {
            books = try Self.decoder.decode([Book].self, from: data)
            // Drop entries whose file is gone (deleted by hand).
            books.removeAll { !FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
        }
    }

    public func fileURL(for book: Book) -> URL { folder.appending(path: book.fileName) }

    public func book(_ id: UUID) -> Book? { books.first { $0.id == id } }

    /// Copies the PDF into the library. Importing the same file again returns the existing book.
    @discardableResult
    public func add(
        fileAt source: URL, title: String?, author: String?, pageCount: Int
    ) throws -> (book: Book, isNew: Bool) {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let name = source.lastPathComponent
        if let existing = books.first(where: { $0.sourceName == name && $0.byteCount == size }) {
            return (existing, false)
        }
        let id = UUID()
        let fileName = "\(id.uuidString).pdf"
        try FileManager.default.copyItem(at: source, to: folder.appending(path: fileName))
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let book = Book(
            id: id,
            title: (cleanTitle?.isEmpty == false ? cleanTitle : nil) ?? Self.title(fromFileName: name),
            author: author?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            fileName: fileName, sourceName: name, byteCount: size, pageCount: pageCount)
        books.insert(book, at: 0)
        try save()
        return (book, true)
    }

    public func update(_ id: UUID, _ change: (inout Book) -> Void) throws {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[i])
        try save()
    }

    public func remove(_ id: UUID) throws {
        guard let book = book(id) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: book))
        books.removeAll { $0.id == id }
        try save()
    }

    /// Recently read first, then recently added.
    public var readingNow: [Book] {
        books.filter(\.isStarted).sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
    }

    public var finished: [Book] { books.filter(\.finished) }

    private func save() throws {
        let data = try Self.encoder.encode(books)
        try data.write(to: indexURL, options: .atomic)
    }

    /// "the_great-gatsby_v2.pdf" → "The Great Gatsby V2"
    static func title(fromFileName name: String) -> String {
        let base = (name.lowercased().hasSuffix(".pdf") ? String(name.dropLast(4)) : name)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !base.isEmpty else { return "Untitled" }
        return base == base.lowercased() ? base.capitalized : base
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
                e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
                return d
    }()
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
