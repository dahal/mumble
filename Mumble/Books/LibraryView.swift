import MumbleReader
import SwiftUI
import UniformTypeIdentifiers

/// The Books window: a sidebar of shelves and a grid of covers, in the spirit of Apple Books.
struct LibraryView: View {
    let books: BooksController

    enum Shelf: String, CaseIterable, Identifiable {
        case home = "Home", all = "All", finished = "Finished"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .home: "house"
            case .all: "books.vertical"
            case .finished: "checkmark.circle"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recent", title = "Title", author = "Author"
        var id: String { rawValue }
    }

    @State private var shelf: Shelf = .home
    @State private var query = ""
    @State private var dropTargeted = false
    @State private var confirmRemove: Book?
    @AppStorage("librarySort") private var sort: Sort = .recent

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { shelf }, set: { if let s = $0 { shelf = s } })) {
                Section("Library") {
                    ForEach(Shelf.allCases) { shelf in
                        Label(shelf.rawValue, systemImage: shelf.icon).tag(shelf)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            content
                .navigationTitle(shelf == .home ? "Home" : shelf.rawValue)
                .toolbar {
                    ToolbarItem {
                        Menu {
                            Picker("Sort By", selection: $sort) {
                                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                        .help("Sort books")
                    }
                    ToolbarItem {
                        Button { books.chooseFiles() } label: { Label("Add PDFs", systemImage: "plus") }
                            .help("Add PDFs to your library")
                    }
                }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .dropDestination(for: URL.self) { urls, _ in
            books.importFiles(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { dropOverlay } }
        .alert("Couldn't add everything", isPresented: Binding(
            get: { books.importMessage != nil }, set: { if !$0 { books.importMessage = nil } })) {
            Button("OK") { books.importMessage = nil }
        } message: {
            Text(books.importMessage ?? "")
        }
        .confirmationDialog("Remove “\(confirmRemove?.title ?? "")” from your library?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let book = confirmRemove { books.remove(book.id) }
            }
        } message: {
            Text("Mumble's copy of the PDF and your reading position are deleted. The original file isn't touched.")
        }
    }

    // MARK: Content

    private var filtered: [Book] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? books.books : books.books.filter {
            $0.title.localizedCaseInsensitiveContains(q) || ($0.author?.localizedCaseInsensitiveContains(q) ?? false)
        }
        switch sort {
        case .recent: return base.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
        case .title: return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: return base.sorted { ($0.author ?? "~").localizedStandardCompare($1.author ?? "~") == .orderedAscending }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = books.libraryError {
            ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if books.books.isEmpty {
            emptyLibrary
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    switch shelf {
                    case .home: home
                    case .all: grid(filtered)
                    case .finished:
                        let done = filtered.filter(\.finished)
                        if done.isEmpty {
                            ContentUnavailableView("No finished books", systemImage: "checkmark.circle",
                                                   description: Text("Books you finish appear here."))
                                .padding(.top, 80)
                        } else {
                            grid(done)
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Add PDFs to Your Library", systemImage: "books.vertical")
        } description: {
            Text("Drag PDFs into this window, or choose them. Mumble reads them aloud in a natural voice, right on this Mac.")
        } actions: {
            Button("Choose PDFs…") { books.chooseFiles() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var home: some View {
        let reading = filtered.filter(\.isStarted)
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        if !reading.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Continue")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(reading.prefix(8)) { book in
                            ContinueCard(book: book, books: books, remove: { confirmRemove = book })
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        let added = filtered.filter(\.isNew).sorted { $0.addedAt > $1.addedAt }
        if !added.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: reading.isEmpty ? "Your Books" : "Up Next")
                grid(added)
            }
        }
        if reading.isEmpty && added.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private func grid(_ items: [Book]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 28, alignment: .bottom)],
                  alignment: .leading, spacing: 34) {
            ForEach(items) { book in
                BookTile(book: book, books: books, remove: { confirmRemove = book })
            }
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                Label("Drop PDFs to add them", systemImage: "plus.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(10)
            .allowsHitTesting(false)
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.title2.weight(.bold))
    }
}

/// A cover with the title under it and a NEW badge or percent read, like a Books library tile.
struct BookTile: View {
    let book: Book
    let books: BooksController
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BookCover(book: book, books: books)
                .frame(height: 220, alignment: .bottom)
                .onTapGesture { books.open(book.id) }
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.callout.weight(.medium)).lineLimit(2)
                if let author = book.author { Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            HStack {
                status
                Spacer()
                BookMenu(book: book, books: books, remove: remove)
            }
        }
        .contextMenu { BookMenuItems(book: book, books: books, remove: remove) }
        .help(book.title)
    }

    @ViewBuilder
    private var status: some View {
        if book.finished {
            Label("Finished", systemImage: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        } else if book.isNew {
            Text("NEW")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor, in: Capsule())
        } else {
            Text("\(Int((book.progress * 100).rounded()))%").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// Wide "Continue" card on Home: cover, title, progress bar and a Resume button.
struct ContinueCard: View {
    let book: Book
    let books: BooksController
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            BookCover(book: book, books: books)
                .frame(width: 110, height: 160, alignment: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Spacer(minLength: 0)
                Text(book.title).font(.headline).lineLimit(3)
                if let author = book.author { Text(author).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                ProgressView(value: book.progress).controlSize(.small).tint(.accentColor)
                HStack {
                    Text("\(Int((book.progress * 100).rounded()))% · Page \(pageEstimate) of \(book.pageCount)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    BookMenu(book: book, books: books, remove: remove)
                }
                Button { books.open(book.id) } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
            .frame(width: 210, alignment: .leading)
        }
        .padding(16)
        .frame(height: 192)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { books.open(book.id) }
        .contextMenu { BookMenuItems(book: book, books: books, remove: remove) }
    }

    private var pageEstimate: Int { max(1, min(book.pageCount, Int((book.progress * Double(book.pageCount)).rounded(.up)))) }
}

/// The first page of the PDF as a cover, with a thin page edge and shadow.
struct BookCover: View {
    let book: Book
    let books: BooksController

    var body: some View {
        Group {
            if let image = books.cover(for: book) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .contentShape(Rectangle())
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.75), Color(hue: hue, saturation: 0.45, brightness: 0.55)],
                           startPoint: .top, endPoint: .bottom)
            Text(book.title)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(12)
        }
        .aspectRatio(0.7, contentMode: .fit)
    }

    private var hue: Double { Double(abs(book.id.hashValue) % 360) / 360 }
}

struct BookMenu: View {
    let book: Book
    let books: BooksController
    let remove: () -> Void

    var body: some View {
        Menu {
            BookMenuItems(book: book, books: books, remove: remove)
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

struct BookMenuItems: View {
    let book: Book
    let books: BooksController
    let remove: () -> Void

    var body: some View {
        Button(book.isStarted ? "Resume Reading" : "Start Reading") { books.open(book.id) }
        Divider()
        if book.finished {
            Button("Mark as Still Reading") { books.setFinished(book.id, false) }
        } else {
            Button("Mark as Finished") { books.setFinished(book.id, true) }
        }
        if book.isStarted || book.finished {
            Button("Start Over") {
                books.update(book.id) {
                    $0.position = 0
                    $0.finished = false
                }
            }
        }
        Button("Show in Finder") { books.reveal(book.id) }
        Divider()
        Button("Remove…", role: .destructive, action: remove)
    }
}
