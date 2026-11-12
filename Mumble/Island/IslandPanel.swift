import AppKit
import SwiftUI

/// A borderless, click-through panel pinned to the bottom middle of the active screen,
/// just above the Dock. It never
/// becomes key, so the app you're dictating into keeps focus.
@MainActor
final class IslandPanel {
    private let model: IslandModel
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private static let panelSize = CGSize(width: 520, height: 180)
    private static let bottomMargin: CGFloat = 0

    init(model: IslandModel) {
        self.model = model
    }

    func show() {
        hideTask?.cancel()
        let screen = Self.activeScreen()
        let panel = panel ?? makePanel()
        self.panel = panel

        panel.contentView = NSHostingView(rootView: IslandView(model: model))
        panel.ignoresMouseEvents = !model.phase.isInteractive
        // visibleFrame excludes the Dock, so the pill never sits on top of it.
        let frame = screen.visibleFrame
        panel.setFrame(
            NSRect(
                x: frame.midX - Self.panelSize.width / 2,
                y: frame.minY + Self.bottomMargin,
                width: Self.panelSize.width,
                height: Self.panelSize.height),
            display: true)
        panel.orderFrontRegardless()
    }

    /// Collapses the island, then removes the panel once the animation has finished.
    func hide(after delay: Duration = .zero) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            // During a meeting the island returns to the meeting state instead of hiding.
            if let resting = self.model.restingPhase {
                self.model.phase = resting
                self.panel?.ignoresMouseEvents = !resting.isInteractive
                return
            }
            self.model.phase = .hidden
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self.panel?.orderOut(nil)
            self.model.reset()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    /// The screen the user is working on: the one under the mouse pointer.
    static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
