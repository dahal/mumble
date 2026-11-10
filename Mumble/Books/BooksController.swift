import AppKit
import MumbleReader
import MumbleTTS
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The book library: importing PDFs, covers, and opening a book in its own reader window.
@MainActor @Observable
final class BooksController {
    static let shared = BooksController()

    private(set) var books: [Book] = []
    private(set) var libraryError: String?
    /// Book IDs whose reader window is open.
    private(set) var sessions: [UUID: ReadingSession] = [:]
    private(set) var covers: [UUID: NSImage] = [:]
    var importMessage: String?

    /// One narrator shared by every open book, so the model loads once.
    @ObservationIgnored let narrator = Narrator()
    @ObservationIgnored private(set) var library: Library?
    @ObservationIgnored private var coverTasks: Set<UUID> = []

    var voice: String {
        get { access(keyPath: \.voice); return UserDefaults.standard.string(forKey: "readerVoice") ?? Narrator.defaultVoice }
        set { withMutation(keyPath: \.voice) { UserDefaults.standard.set(newValue, forKey: "readerVoice") } }
    }

    var speed: Float {
        get {
            access(keyPath: \.speed)
            let value = UserDefaults.standard.float(forKey: "readerSpeed")
            return value == 0 ? 1 : value
        }
        set { withMutation(keyPath: \.speed) { UserDefaults.standard.set(newValue, forKey: "readerSpeed") } }
    }

    static var folderOverride: URL?

    init(folder: URL? = nil) {
        do {
            let library = try Library(folder: folder ?? Self.folderOverride ?? Library.defaultFolder)
            self.library = library
            books = library.books
        } catch {
            libraryError = error.localizedDescription
            AppLog.error("Book library failed to open: \(error)")
        }
    }

    // MARK: Windows

    func showLibrary() {
        WindowCenter.shared.show("books", title: "Books", size: NSSize(width: 1040, height: 700),
                                 minSize: NSSize(width: 640, height: 420), autosave: "MumbleBooks") {
            LibraryView(books: self)
        }
    }

    func open(_ id: UUID) {
        guard let library, let book = library.book(id) else { return }
        let session = sessions[id] ?? ReadingSession(book: book, url: library.fileURL(for: book), books: self)
        sessions[id] = session
        let key = "book-\(id.uuidString)"
        WindowCenter.shared.show(key, title: book.title, subtitle: book.author ?? "",
                                 size: NSSize(width: 820, height: 940), minSize: NSSize(width: 480, height: 480),
                                 autosave: "MumbleBook", make: { ReaderView(session: session, books: self) })
        WindowCenter.shared.onClose[key] = { [weak self] in
            session.close()
            self?.sessions[id] = nil
        }
        try? library.update(id) { $0.lastOpenedAt = Date() }
        refresh()
        // Warm the voice model while the page renders, so Play starts promptly.
        Task { try? await narrator.load() }
    }

    // MARK: Library

    /// Imports PDFs (from a drop, the open panel, or Finder). Opens the book when there's just one.
    func importFiles(_ urls: [URL], openSingle: Bool = false) {
        guard let library else { return }
        let pdfs = urls.filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) ?? ($0.pathExtension.lowercased() == "pdf") }
        var added = 0, skipped = urls.count - pdfs.count
        var last: Book?
        for url in pdfs {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let document = PDFDocument(url: url) else { skipped += 1; continue }
            if document.isLocked {
                skipped += 1
                importMessage = "“\(url.lastPathComponent)” is password protected."
                continue
            }
            let attributes = document.documentAttributes ?? [:]
            do {
                let result = try library.add(
                    fileAt: url, title: Self.usableTitle(attributes[PDFDocumentAttribute.titleAttribute] as? String),
                    author: attributes[PDFDocumentAttribute.authorAttribute] as? String,
                    pageCount: document.pageCount)
                if result.isNew { added += 1 }
                last = result.book
            } catch {
                skipped += 1
                AppLog.error("Import failed: \(error)")
            }
        }
        refresh()
        if skipped > 0, importMessage == nil {
            importMessage = skipped == 1 ? "One file isn't a PDF Mumble can read." : "\(skipped) files aren't PDFs Mumble can read."
        }
        AppLog.info("Imported \(added) book(s), skipped \(skipped)")
        if openSingle || pdfs.count == 1, let last { open(last.id) }
    }

    /// PDF metadata titles are often junk ("Microsoft Word - draft3.docx"); prefer the file name then.
    static func usableTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), title.count >= 2 else { return nil }
        let lower = title.lowercased()
        let junk = ["microsoft word", ".doc", ".pdf", ".indd", "untitled", ".tex"]
        return junk.contains { lower.contains($0) } ? nil : title
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs to add to your library"
        panel.prompt = "Add"
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func remove(_ id: UUID) {
        WindowCenter.shared.close("book-\(id.uuidString)")
        try? library?.remove(id)
        covers[id] = nil
        try? FileManager.default.removeItem(at: coverURL(id))
        refresh()
    }

    func setFinished(_ id: UUID, _ finished: Bool) {
        try? library?.update(id) {
            $0.finished = finished
            if !finished, $0.position >= $0.utteranceCount { $0.position = 0 }
        }
        refresh()
    }

    func update(_ id: UUID, _ change: (inout Book) -> Void) {
        try? library?.update(id, change)
        refresh()
    }

    func reveal(_ id: UUID) {
        guard let library, let book = library.book(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([library.fileURL(for: book)])
    }

    private func refresh() { books = library?.books ?? [] }

    // MARK: Covers

    private func coverURL(_ id: UUID) -> URL {
        (library?.folder ?? Library.defaultFolder).appending(path: "Covers/\(id.uuidString).png")
    }

    /// The first page, rendered once and cached as a PNG.
    func cover(for book: Book) -> NSImage? {
        if let image = covers[book.id] { return image }
        guard let library, !coverTasks.contains(book.id) else { return nil }
        coverTasks.insert(book.id)
        let pdf = library.fileURL(for: book), png = coverURL(book.id), id = book.id
        Task.detached(priority: .utility) {
            let image = NSImage(contentsOf: png) ?? Self.renderCover(pdf: pdf, to: png)
            await MainActor.run {
                if let image { self.covers[id] = image }
                self.coverTasks.remove(id)
            }
        }
        return nil
    }

    nonisolated private static func renderCover(pdf: URL, to png: URL) -> NSImage? {
        guard let page = PDFDocument(url: pdf)?.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let height: CGFloat = 520
        let size = NSSize(width: max(1, height * bounds.width / max(bounds.height, 1)), height: height)
        let image = page.thumbnail(of: size, for: .cropBox)
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: png.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: png)
        }
        return image
    }
}
