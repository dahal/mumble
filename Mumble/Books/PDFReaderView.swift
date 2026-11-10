import AppKit
import MumbleReader
import PDFKit
import SwiftUI

/// The book's pages (PDFKit), with the sentence being read highlighted and kept in view.
struct PDFReaderView: NSViewRepresentable {
    let document: PDFDocument
    let highlight: Utterance?
    let follow: Bool
    let revealRequest: Int
    let theme: ReaderTheme
    var readFrom: (_ page: Int, _ character: Int) -> Void
    var togglePlay: () -> Void

    func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.autoScales = true
        view.pageShadowsEnabled = true
        return view
    }

    func updateNSView(_ view: ReaderPDFView, context: Context) {
        view.readFrom = readFrom
        view.togglePlay = togglePlay
        view.backgroundColor = theme.background
        let changed = context.coordinator.highlighted != highlight?.index
        let revealed = context.coordinator.revealRequest != revealRequest
        context.coordinator.highlighted = highlight?.index
        context.coordinator.revealRequest = revealRequest
        guard changed || revealed else { return }

        let selections = (highlight?.spans ?? []).compactMap { span -> PDFSelection? in
            guard let page = document.page(at: span.page), let selection = page.selection(for: span.range) else { return nil }
            selection.color = theme.highlight
            return selection
        }
        view.highlightedSelections = selections.isEmpty ? nil : selections
        guard let first = selections.first, follow || revealed else { return }
        // Only scroll when the sentence isn't comfortably on screen, so the page doesn't jitter.
        if revealed || !view.isComfortablyVisible(first) {
            view.scroll(toCenter: first)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var highlighted: Int?
        var revealRequest = -1
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case light = "Light", sepia = "Sepia", dark = "Dark"
    var id: String { rawValue }

    var background: NSColor {
        switch self {
        case .light: NSColor(white: 0.93, alpha: 1)
        case .sepia: NSColor(red: 0.91, green: 0.86, blue: 0.76, alpha: 1)
        case .dark: NSColor(white: 0.12, alpha: 1)
        }
    }

    var highlight: NSColor {
        switch self {
        case .light, .sepia: NSColor.systemYellow.withAlphaComponent(0.38)
        case .dark: NSColor.systemOrange.withAlphaComponent(0.45)
        }
    }
}

final class ReaderPDFView: PDFView {
    var readFrom: ((Int, Int) -> Void)?
    var togglePlay: (() -> Void)?

    /// Space plays/pauses (instead of paging), matching audio players.
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            togglePlay?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Double-click a sentence to read from there.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let (page, character) = location(of: event) {
            readFrom?(page, character)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let (page, character) = location(of: event) {
            let item = NSMenuItem(title: "Read from Here", action: #selector(readFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [page, character]
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func readFromMenu(_ item: NSMenuItem) {
        guard let pair = item.representedObject as? [Int], pair.count == 2 else { return }
        readFrom?(pair[0], pair[1])
    }

    private func location(of event: NSEvent) -> (Int, Int)? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: true), let document, let pageIndex = Optional(document.index(for: page)) else { return nil }
        let pagePoint = convert(point, to: page)
        let character = page.characterIndex(at: pagePoint)
        return (pageIndex, max(0, character))
    }

    func isComfortablyVisible(_ selection: PDFSelection) -> Bool {
        guard let page = selection.pages.first else { return false }
        let rect = convert(selection.bounds(for: page), from: page)
        let visible = bounds.insetBy(dx: 0, dy: bounds.height * 0.18)
        return visible.contains(rect) || (rect.height > visible.height && rect.intersects(visible))
    }

    /// Scrolls so the selection sits about a third of the way down the window.
    func scroll(toCenter selection: PDFSelection) {
        guard let page = selection.pages.first else { return }
        let bounds = selection.bounds(for: page)
        let pageHeight = page.bounds(for: displayBox).height
        let visibleHeight = self.bounds.height / max(scaleFactor, 0.01)
        let target = NSPoint(x: 0, y: min(pageHeight, bounds.maxY + visibleHeight * 0.33))
        go(to: PDFDestination(page: page, at: target))
    }
}
