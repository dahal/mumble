import AppKit
import CoreText
import MumbleReader
import PDFKit
import ScreenCaptureKit
import SwiftUI

/// Developer entry points for the book reader:
///
///   Mumble --render-books <dir>        library + reader windows (and Meetings) as PNGs, then quit
///   Mumble --read-test [<pdf>]         open a PDF, press Play, wait for real narration to advance, quit
@MainActor
enum BooksDevTools {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-books"), i + 1 < args.count {
            Task { await render(to: URL(fileURLWithPath: args[i + 1])) }
            return true
        }
        if let i = args.firstIndex(of: "--read-test") {
            ReadingSession.muted = !args.contains("--audible")
            let path = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil
            Task { await readTest(pdf: path.map { URL(fileURLWithPath: $0) }) }
            return true
        }
        return false
    }

    /// A temporary library, so the real one is never touched.
    private static func temporaryController() throws -> (BooksController, URL) {
        let work = FileManager.default.temporaryDirectory.appending(path: "mumble-books-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (BooksController(folder: work.appending(path: "Library")), work)
    }

    private static func readTest(pdf: URL?) async {
        do {
            let (books, work) = try temporaryController()
            let source = try pdf ?? samplePDF(in: work, title: "Read Test", chapters: 1)
            books.importFiles([source])
            guard let book = books.books.first, let session = books.sessions[book.id] else {
                print("READTEST import failed"); exit(1)
            }
            let clock = ContinuousClock()
            let opened = clock.now
            while session.isLoadingText { try await Task.sleep(for: .milliseconds(50)) }
            print("READTEST text: \(session.utterances.count) sentences, \(session.pageCount) pages in \(opened.duration(to: clock.now))")
            let sample = Array(session.utterances.prefix(3)) + Array(session.utterances.dropFirst(60).prefix(8))
            for u in sample { print("READTEST  [\(u.index)] p\(u.page + 1): \(u.text)") }
            let start = clock.now
            session.play()
            var firstAudio: Duration?
            while session.current < 2 {
                if firstAudio == nil, !session.isBuffering, session.voiceStatus == nil { firstAudio = start.duration(to: clock.now) }
                if let problem = session.problem { print("READTEST problem: \(problem)"); exit(1) }
                if start.duration(to: clock.now) > .seconds(600) { print("READTEST timed out"); exit(1) }
                try await Task.sleep(for: .milliseconds(20))
            }
            print("READTEST first audio after \(firstAudio ?? .zero); two sentences played in \(start.duration(to: clock.now))")
            session.pause()
            let saved = books.books.first?.position ?? -1
            print("READTEST saved position \(saved)")
            session.seek(to: 0)
            session.play()
            try await Task.sleep(for: .seconds(1))
            print("READTEST replay current=\(session.current) playing=\(session.isPlaying)")
            print(saved == 2 ? "READTEST ok" : "READTEST position mismatch")
            exit(saved == 2 ? 0 : 1)
        } catch {
            print("READTEST error: \(error)")
            exit(1)
        }
    }

    private static func render(to dir: URL) async {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let (books, work) = try temporaryController()
            NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
            books.showLibrary()
            try await Task.sleep(for: .seconds(1))
            try await snapshot("books", to: dir.appending(path: "books-empty.png"))
            try await RenderMeetings.dump(to: dir.appending(path: "books-empty.txt"))
            let titles = ["The Quiet Harbor", "Field Notes on Rivers", "A Short History of Lanterns", "Meadow Light", "Kitchen Science"]
            let urls = try titles.enumerated().map { try samplePDF(in: work, title: $1, chapters: 2 + $0) }
            books.importFiles(urls)
            if let first = books.books.last { books.open(first.id); books.update(first.id) { $0.position = 30 } }
            if let second = books.books.dropLast().last { books.update(second.id) { $0.lastOpenedAt = Date(); $0.utteranceCount = 100; $0.position = 64 } }
            if let third = books.books.first { books.setFinished(third.id, true) }
            try await Task.sleep(for: .seconds(3))
            if let session = books.sessions.values.first { session.seek(to: 5) }
            try await Task.sleep(for: .seconds(1.5))
            if let id = books.sessions.keys.first {
                try await snapshot("book-\(id.uuidString)", to: dir.appending(path: "reader.png"))
                WindowCenter.shared.window("books")?.orderOut(nil)
                try await RenderMeetings.dump(to: dir.appending(path: "reader.txt"))
                if let session = books.sessions[id] {
                    print("RENDER reader: current=\(session.current) page=\(session.currentPage + 1) highlight=\(session.currentUtterance?.text ?? "-")")
                }
            }
            WindowCenter.shared.window("books")?.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(1))
            try await snapshot("books", to: dir.appending(path: "books-home.png"))
            WindowCenter.shared.close("book-\(books.sessions.keys.first?.uuidString ?? "")")
            try await RenderMeetings.dump(to: dir.appending(path: "books-home.txt"))
            WindowCenter.shared.close("books")
            HomeWindow.show()
            try await Task.sleep(for: .seconds(1.5))
            // Offscreen SwiftUI render (draws images, shapes and text; native controls and glass come out plain).
            HomeView.renderForReview = true
            let renderer = ImageRenderer(content: HomeView(dictation: AppDelegate.controller, meetings: AppDelegate.meetings, books: books)
                .frame(width: 1040, height: 680))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: dir.appending(path: "home-render.png"))
            }
            HomeView.renderForReview = false
            try await snapshot("home", to: dir.appending(path: "home.png"))
            try await RenderMeetings.dump(to: dir.appending(path: "home.txt"))
            print("RENDERED \(dir.path)")
            exit(0)
        } catch {
            print("RENDER failed: \(error)")
            exit(1)
        }
    }

    /// Captures a window to a PNG: real pixels via ScreenCaptureKit when Mumble has Screen Recording
    /// permission, otherwise a flat AppKit drawing (which misses layer-backed content).
    static func snapshot(_ key: String, to url: URL) async throws {
        guard let window = WindowCenter.shared.window(key), let view = window.contentView?.superview else {
            throw CocoaError(.fileNoSuchFile)
        }
        if CGPreflightScreenCaptureAccess() {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * 2)
                config.height = Int(window.frame.height * 2)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: config)
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: url)
                return
            }
        }
        print("SNAPSHOT \(key): flat drawing only")
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A small book PDF with a title page, running heads, page numbers and wrapped prose.
    static func samplePDF(in dir: URL, title: String, chapters: Int) throws -> URL {
        let paragraphs = [
            "The harbor was quiet in the early morning, and the fishing boats rocked gently against the old stone pier. A gull called once and then fell silent, as if it, too, had decided the day could wait.",
            "Mara walked the length of the pier twice before she noticed the letter tucked under the coil of rope. It was addressed to her grandmother, who had been gone for eleven years, and the postmark was from last Tuesday.",
            "She did not open it right away. Instead she sat on the bench by the ticket office, turned the envelope over in her hands, and watched the light climb slowly up the hulls of the boats.",
            "By nine o'clock the cafés had opened their shutters and the smell of coffee drifted down to the water. Somewhere a radio was playing an old song about a lighthouse keeper who never learned to swim.",
        ]
        let url = dir.appending(path: "\(title.replacingOccurrences(of: " ", with: "_")).pdf")
        var box = CGRect(x: 0, y: 0, width: 432, height: 648)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: title, kCGPDFContextAuthor: "Sample Author"] as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        func draw(_ text: String, font: NSFont, in rect: CGRect, align: NSTextAlignment = .natural, color: NSColor = .black) {
            let style = NSMutableParagraphStyle()
            style.alignment = align
            style.lineSpacing = 3
            style.paragraphSpacing = 9
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
            CTFrameDraw(frame, context)
        }
        // Cover
        context.beginPDFPage(nil)
        context.setFillColor(NSColor(calibratedHue: CGFloat(title.count % 10) / 10, saturation: 0.45, brightness: 0.45, alpha: 1).cgColor)
        context.fill(box)
        draw(title, font: .systemFont(ofSize: 34, weight: .bold), in: CGRect(x: 40, y: 260, width: 352, height: 220), align: .center, color: .white)
        draw("Sample Author", font: .systemFont(ofSize: 16), in: CGRect(x: 40, y: 120, width: 352, height: 40), align: .center, color: .white)
        context.endPDFPage()
        var pageNumber = 1
        for chapter in 1...chapters {
            for page in 0..<2 {
                context.beginPDFPage(nil)
                draw("\(title.uppercased()) · CHAPTER \(chapter)", font: .systemFont(ofSize: 8), in: CGRect(x: 48, y: 608, width: 336, height: 16), align: .center, color: .gray)
                var body = paragraphs.shuffled().joined(separator: "\n")
                if page == 0 { body = "Chapter \(chapter)\n" + body }
                draw(body, font: NSFont(name: "Georgia", size: 12) ?? .systemFont(ofSize: 12), in: CGRect(x: 48, y: 60, width: 336, height: 536))
                draw("\(pageNumber)", font: .systemFont(ofSize: 9), in: CGRect(x: 48, y: 30, width: 336, height: 16), align: .center, color: .gray)
                pageNumber += 1
                context.endPDFPage()
            }
        }
        context.closePDF()
        return url
    }
}
