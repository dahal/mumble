import AppKit
import SwiftUI

/// "Let everyone know Mumble is taking notes" (spec §4.2). Recording has already started; this
/// only helps the user tell the others.
@MainActor
final class ConsentPanel {
    static let message = "Heads up: I'm taking notes with Mumble. Audio stays on my Mac and is deleted after processing."

    private var window: NSPanel?
    private let onClose: (Bool) -> Void

    init(onClose: @escaping (_ dontShowAgain: Bool) -> Void) {
        self.onClose = onClose
    }

    func show() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Meeting notes"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ConsentView { [weak self] dontShow in
            self?.onClose(dontShow)
            self?.close()
        })
        if let screen = IslandPanel.activeScreen() as NSScreen? {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 400, y: f.maxY - 200))
        }
        panel.orderFrontRegardless()
        window = panel
    }

    func close() {
        window?.close()
        window = nil
    }
}

struct ConsentView: View {
    let done: (Bool) -> Void
    @State private var dontShowAgain = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Let everyone know Mumble is taking notes", systemImage: "record.circle")
                .font(.headline)
            Text(ConsentPanel.message).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("Don't show again", isOn: $dontShowAgain).toggleStyle(.checkbox).font(.callout)
                Spacer()
                Button(copied ? "Copied" : "Copy Message") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ConsentPanel.message, forType: .string)
                    copied = true
                }
                Button("Done") { done(dontShowAgain) }.keyboardShortcut(.defaultAction)
            }
            Text("You're responsible for recording-consent laws where you and others are.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .padding(.top, 8)
        .frame(width: 380)
    }
}

/// Which sidebar tab and meeting the Mumble window shows; lets notifications deep-link.
@MainActor @Observable
final class AppNavigation {
    static let shared = AppNavigation()
    var tab: SettingsView.Tab = .general
    var selectedMeetingID: UUID?
    var openWindow: () -> Void = {}

    func showMeeting(_ id: UUID?) {
        tab = .meetings
        selectedMeetingID = id
        openWindow()
    }
}
