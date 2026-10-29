import AppKit
import SwiftUI

/// A borderless, click-through panel pinned to the top of the active screen. It never
/// becomes key, so the app you're dictating into keeps focus.
@MainActor
final class IslandPanel {
    private let model: IslandModel
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private static let panelSize = CGSize(width: 520, height: 180)

    init(model: IslandModel) {
        self.model = model
    }

    func show() {
        hideTask?.cancel()
        let screen = Self.activeScreen()
        let panel = panel ?? makePanel()
        self.panel = panel

        let notch = Self.notchSize(of: screen)
        panel.contentView = NSHostingView(
            rootView: IslandView(model: model, notch: notch ?? CGSize(width: 180, height: 32), hasNotch: notch != nil))
        let frame = screen.frame
        panel.setFrame(
            NSRect(
                x: frame.midX - Self.panelSize.width / 2,
                y: frame.maxY - Self.panelSize.height - (notch == nil ? Self.menuBarHeight(screen) : 0),
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

    static func notchSize(of screen: NSScreen) -> CGSize? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else { return nil }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }

    static func menuBarHeight(_ screen: NSScreen) -> CGFloat {
        max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }
}
