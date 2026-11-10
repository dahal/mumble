import Foundation
import Testing

@testable import MumbleReader

@Suite struct LibraryTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "mumble-library-\(UUID().uuidString)")

    func pdf(named name: String, bytes: Int = 100) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mumble-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try Data(repeating: 0x25, count: bytes).write(to: url)
        return url
    }

    @Test func addCopiesFileAndPersists() throws {
        let library = try Library(folder: folder)
        let source = try pdf(named: "the_great-gatsby.pdf")
        let (book, isNew) = try library.add(fileAt: source, title: nil, author: " F. Scott ", pageCount: 180)
        #expect(isNew)
        #expect(book.title == "The Great Gatsby")
        #expect(book.author == "F. Scott")
        try FileManager.default.removeItem(at: source)
        #expect(FileManager.default.fileExists(atPath: library.fileURL(for: book).path))

        let reopened = try Library(folder: folder)
        #expect(reopened.books == [book])
    }

    @Test func reimportReturnsExistingBook() throws {
        let library = try Library(folder: folder)
        let a = try library.add(fileAt: try pdf(named: "book.pdf"), title: "Book", author: nil, pageCount: 1)
        let b = try library.add(fileAt: try pdf(named: "book.pdf"), title: "Book", author: nil, pageCount: 1)
        #expect(!b.isNew)
        #expect(a.book.id == b.book.id)
        let c = try library.add(fileAt: try pdf(named: "book.pdf", bytes: 200), title: "Book", author: nil, pageCount: 1)
        #expect(c.isNew)
        #expect(library.books.count == 2)
    }

    @Test func progressAndShelves() throws {
        let library = try Library(folder: folder)
        let a = try library.add(fileAt: try pdf(named: "a.pdf"), title: "A", author: nil, pageCount: 10).book
        let b = try library.add(fileAt: try pdf(named: "b.pdf"), title: "B", author: nil, pageCount: 10).book
        #expect(library.book(a.id)?.isNew == true)
        try library.update(a.id) {
            $0.lastOpenedAt = Date()
            $0.utteranceCount = 200
            $0.position = 50
        }
        #expect(library.book(a.id)?.progress == 0.25)
        #expect(library.readingNow.map(\.id) == [a.id])
        try library.update(b.id) { $0.finished = true }
        #expect(library.finished.map(\.id) == [b.id])
        #expect(library.book(b.id)?.progress == 1)

        let reopened = try Library(folder: folder)
        #expect(reopened.book(a.id)?.position == 50)
    }

    @Test func removeDeletesFile() throws {
        let library = try Library(folder: folder)
        let book = try library.add(fileAt: try pdf(named: "a.pdf"), title: "A", author: nil, pageCount: 1).book
        try library.remove(book.id)
        #expect(library.books.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.fileURL(for: book).path))
    }

    @Test func dropsEntriesWhoseFileWasDeleted() throws {
        let library = try Library(folder: folder)
        let book = try library.add(fileAt: try pdf(named: "a.pdf"), title: "A", author: nil, pageCount: 1).book
        try FileManager.default.removeItem(at: library.fileURL(for: book))
        #expect(try Library(folder: folder).books.isEmpty)
    }

    @Test func titlesFromFileNames() {
        #expect(Library.title(fromFileName: "war_and_peace.pdf") == "War And Peace")
        #expect(Library.title(fromFileName: "SICP-2nd ed.pdf") == "SICP 2nd ed")
        #expect(Library.title(fromFileName: ".pdf") == "Untitled")
    }
}
