import MumbleReader
import MumbleTTS
import SwiftUI

/// A book's window: the page, with a floating audio player at the bottom.
struct ReaderView: View {
    let session: ReadingSession
    let books: BooksController
    @AppStorage("readerTheme") private var theme: ReaderTheme = .light
    @State private var scrub: Double?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let document = session.document {
                PDFReaderView(
                    document: document, highlight: session.currentUtterance, follow: session.followAlong,
                    revealRequest: session.revealRequest, theme: theme,
                    readFrom: { page, character in
                        if let index = session.utterance(page: page, character: character) {
                            session.seek(to: index)
                            if !session.isPlaying { session.play() }
                        }
                    },
                    togglePlay: { session.togglePlay() })
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("Can't open this PDF", systemImage: "doc.questionmark")
            }
            player
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
        .frame(minWidth: 480, minHeight: 480)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { session.followAlong }, set: { session.followAlong = $0 })) {
                    Label("Follow Along", systemImage: "text.viewfinder")
                }
                .help("Keep the sentence being read on screen")
                Menu {
                    Picker("Page Background", selection: $theme) {
                        ForEach(ReaderTheme.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Page Background", systemImage: "circle.lefthalf.filled")
                }
                .help("Page background")
            }
        }
    }

    // MARK: Player

    private var player: some View {
        VStack(spacing: 8) {
            if let message = session.problem ?? session.voiceStatus {
                HStack(spacing: 8) {
                    if session.voiceStatus != nil { ProgressView().controlSize(.small) }
                    else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 18) {
                transport
                scrubber
                trailingControls
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 760)
        .floatingPanel(cornerRadius: 22)
        .disabled(session.isLoadingText || session.utterances.isEmpty)
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button { session.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 15))
            }
            .help("Previous sentence (⌘←)")
            .keyboardShortcut(.leftArrow, modifiers: .command)
            Button { session.togglePlay() } label: {
                ZStack {
                    if session.isBuffering || session.isLoadingText {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 30, height: 30)
            }
            .help(session.isPlaying ? "Pause (Space)" : "Play (Space)")
            .keyboardShortcut(.space, modifiers: [])
            Button { session.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 15))
            }
            .help("Next sentence (⌘→)")
            .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        .buttonStyle(.plain)
    }

    private var scrubber: some View {
        let count = max(session.utterances.count - 1, 1)
        return VStack(spacing: 3) {
            Slider(
                value: Binding(get: { scrub ?? Double(session.current) }, set: { scrub = $0 }),
                in: 0...Double(count),
                onEditingChanged: { editing in
                    if !editing, let value = scrub {
                        session.seek(to: Int(value.rounded()))
                        scrub = nil
                    }
                })
                .controlSize(.small)
            HStack {
                Text(pageLabel)
                Spacer()
                Text(timeLeft)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 160)
    }

    private var pageLabel: String {
        if session.isLoadingText { return "Preparing text…" }
        let index = scrub.map { Int($0.rounded()) } ?? session.current
        let page = session.utterances.indices.contains(index) ? session.utterances[index].page : session.currentPage
        return "Page \(page + 1) of \(session.pageCount)"
    }

    private var timeLeft: String {
        let seconds = session.secondsLeft
        guard seconds > 0 else { return "" }
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return "\(minutes / 60) hr \(minutes % 60) min left" }
        return minutes < 1 ? "Under a minute left" : "\(minutes) min left"
    }

    private var trailingControls: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Speed", selection: Binding(get: { books.speed }, set: {
                    books.speed = $0
                    session.settingsChanged()
                })) {
                    ForEach([0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75] as [Float], id: \.self) { Text(Self.speedLabel($0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(Self.speedLabel(books.speed)).font(.callout.weight(.semibold)).monospacedDigit()
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Reading speed")
            Menu {
                Picker("Voice", selection: Binding(get: { books.voice }, set: {
                    books.voice = $0
                    session.settingsChanged()
                })) {
                    ForEach(["American", "British"], id: \.self) { accent in
                        Section(accent) {
                            ForEach(Narrator.voices.filter { $0.accent == accent }) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(Narrator.voices.first { $0.id == books.voice }?.name ?? "Voice", systemImage: "person.wave.2")
                    .font(.callout)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Narrator voice")
        }
    }

    static func speedLabel(_ speed: Float) -> String {
        let text = speed == speed.rounded() ? String(format: "%.0f", speed) : String(format: "%g", speed)
        return "\(text)×"
    }
}

extension View {
    /// Liquid Glass on macOS 26, a material panel before it.
    @ViewBuilder
    func floatingPanel(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *), !HomeView.renderForReview {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
    }
}
