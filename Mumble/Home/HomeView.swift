import MumbleCore
import MumbleReader
import MumbleStore
import SwiftUI

/// The window Mumble opens to: a photo, a greeting, and a card for each thing Mumble does.
/// Background: "Mountain range at dusk with soft pastel sky" by Renaud Confavreux (Unsplash License).
/// Icons: IconMCP (MIT), in Assets.xcassets/Home.
struct HomeView: View {
    let dictation: DictationController
    let meetings: MeetingController
    let books: BooksController
    @AppStorage(HomeWindow.showAtLaunchKey) private var showAtLaunch = true
    /// Offscreen renders can't draw Liquid Glass; use the material look instead.
    nonisolated(unsafe) static var renderForReview = false
    @State private var meetingItems: [MeetingListItem] = []

    var body: some View {
        ZStack {
            background
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    privacyPill
                }
                .padding(.top, 14)
                Spacer(minLength: 24)
                header
                cards.padding(.top, 30)
                footer.padding(.top, 22)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 26)
        }
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 880, minHeight: 600)
        .ignoresSafeArea()
        .task { await observeMeetings() }
    }

    // MARK: Background

    private var background: some View {
        GeometryReader { proxy in
            Image("HomeBackground")
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .clipped()
                .overlay {
                    // Keep the sky, darken toward the cards so text and glass stay legible.
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.10), location: 0),
                        .init(color: .black.opacity(0.0), location: 0.25),
                        .init(color: .black.opacity(0.35), location: 0.6),
                        .init(color: .black.opacity(0.72), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
        }
        .ignoresSafeArea()
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(greeting)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("What would you like to do?")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
            Text("Talk instead of typing, keep notes on every call, and listen to your books. All of it runs on this Mac.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.78))
                .frame(maxWidth: 560, alignment: .leading)
        }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? part : "\(part), \(first)"
    }

    private var privacyPill: some View {
        HStack(spacing: 6) {
            Image("icon-private").resizable().frame(width: 14, height: 14)
            Text("On-device · nothing leaves your Mac")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .floatingPanel(cornerRadius: 14)
    }

    // MARK: Cards

    private var cards: some View {
        HStack(alignment: .top, spacing: 18) {
            FeatureCard(
                icon: "icon-dictation", title: "Dictation",
                blurb: "Hold a key, speak, let go. Your words appear wherever the cursor is, in any app.",
                tint: [Color(red: 0.36, green: 0.42, blue: 1.0), Color(red: 0.22, green: 0.68, blue: 1.0)],
                cta: "Dictation Settings", action: { AppDelegate.showSettings() }
            ) {
                HStack(spacing: 6) {
                    Text("Hold")
                    Keycap(dictation.settings.triggerKey.displayName)
                    Text(dictationStatus)
                }
            }
            FeatureCard(
                icon: "icon-meetings", title: "Meeting Notes",
                blurb: "Who said what, by name, with a summary and action items. No bot joins the call.",
                tint: [Color(red: 1.0, green: 0.78, blue: 0.16), Color(red: 1.0, green: 0.55, blue: 0.10)],
                cta: "Open Meetings", action: { AppNavigation.shared.showMeeting(nil) },
                secondary: (meetings.isRecording ? "Stop Notes" : "Start Notes", { meetings.toggle() })
            ) {
                if meetings.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text("Recording · \(MarkdownExporter.timestamp(meetings.elapsed))")
                    }
                } else {
                    Text(meetingStatus)
                }
            }
            FeatureCard(
                icon: "icon-books", title: "Books",
                blurb: "Drop in a PDF and listen in a natural voice, with the sentence highlighted as it's read.",
                tint: [Color(red: 1.0, green: 0.50, blue: 0.30), Color(red: 0.96, green: 0.30, blue: 0.45)],
                cta: resumeBook.map { _ in "Resume Reading" } ?? "Open Library",
                action: {
                    if let book = resumeBook { books.open(book.id) } else { books.showLibrary() }
                },
                secondary: resumeBook == nil ? nil : ("Library", { books.showLibrary() })
            ) {
                Text(booksStatus).lineLimit(1)
            }
        }
    }

    private var dictationStatus: String {
        switch dictation.modelStatus {
        case let .loading(progress, _): return "· loading \(Int(progress * 100))%"
        case .failed: return "· model error"
        default:
            let today = dictation.history.filter { Calendar.current.isDateInToday($0.date) }
            guard !today.isEmpty else { return "to talk" }
            let words = today.reduce(0) { $0 + $1.text.split(separator: " ").count }
            return "· \(words) word\(words == 1 ? "" : "s") today"
        }
    }

    private var meetingStatus: String {
        guard !meetingItems.isEmpty else { return "Press ⌥⇧M during a call" }
        let todos = meetingItems.reduce(0) { $0 + $1.openActionCount }
        let count = "\(meetingItems.count) meeting\(meetingItems.count == 1 ? "" : "s")"
        return todos > 0 ? "\(count) · \(todos) to-do\(todos == 1 ? "" : "s") open" : count
    }

    private var resumeBook: Book? {
        books.books.filter(\.isStarted).max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    private var booksStatus: String {
        if let book = resumeBook { return "“\(book.title)” · \(Int((book.progress * 100).rounded()))%" }
        let count = books.books.count
        return count == 0 ? "Drag a PDF in to start" : "\(count) book\(count == 1 ? "" : "s") in your library"
    }

    private func observeMeetings() async {
        guard let store = meetings.store else { return }
        do {
            for try await value in store.observeListItems() { meetingItems = value }
        } catch {
            AppLog.error("Home meetings observation failed: \(error)")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button { AppDelegate.showSettings() } label: {
                HStack(spacing: 6) {
                    Image("icon-settings").resizable().frame(width: 14, height: 14)
                    Text("Settings")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .floatingPanel(cornerRadius: 14)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            Toggle("Show when Mumble opens", isOn: $showAtLaunch)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Link(destination: URL(string: "https://unsplash.com/photos/mountain-range-at-dusk-with-soft-pastel-sky-1cU3fPmVbXQ")!) {
                Text("Photo: Renaud Confavreux / Unsplash")
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.55))
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
    }
}

/// One feature: gradient icon tile, title, a line about what it does, live status, and buttons.
private struct FeatureCard<Status: View>: View {
    let icon: String
    let title: String
    let blurb: String
    let tint: [Color]
    let cta: String
    let action: () -> Void
    var secondary: (String, () -> Void)?
    @ViewBuilder var status: Status
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                Image(icon)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.white)
            }
            .frame(width: 54, height: 54)
            .shadow(color: tint.last!.opacity(0.45), radius: 12, y: 6)

            Text(title)
                .font(.system(size: 21, weight: .bold))
                .padding(.top, 18)
            Text(blurb)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.72))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Spacer(minLength: 14)
            status
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(height: 22, alignment: .leading)
            HStack(spacing: 8) {
                Button(action: action) {
                    HStack {
                        Text(cta)
                        Spacer(minLength: 4)
                        Image("icon-arrow").resizable().frame(width: 14, height: 14)
                            .offset(x: hovering ? 3 : 0)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .frame(maxWidth: .infinity)
                    .background(.white.opacity(hovering ? 0.95 : 0.85), in: Capsule())
                }
                .buttonStyle(.plain)
                if let secondary {
                    Button(action: secondary.1) {
                        Text(secondary.0)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(.white.opacity(0.14), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.22)))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .padding(.top, 10)
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 262, maxHeight: 280, alignment: .topLeading)
        .floatingPanel(cornerRadius: 26)
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(hovering ? 0.45 : 0.22), .white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .scaleEffect(hovering ? 1.015 : 1)
        .shadow(color: .black.opacity(hovering ? 0.35 : 0.2), radius: hovering ? 24 : 14, y: hovering ? 12 : 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture(perform: action)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A keyboard key, for "Hold ⌥ to talk".
private struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.3)))
    }
}

/// Opening and remembering the Home window.
@MainActor
enum HomeWindow {
    static let showAtLaunchKey = "showHomeAtLaunch"

    static var showsAtLaunch: Bool {
        UserDefaults.standard.object(forKey: showAtLaunchKey) as? Bool ?? true
    }

    static func show() {
        let window = WindowCenter.shared.show(
            "home", title: "Mumble", size: NSSize(width: 1040, height: 680), minSize: NSSize(width: 880, height: 600),
            autosave: "MumbleHome"
        ) {
            HomeView(dictation: AppDelegate.controller, meetings: AppDelegate.meetingsOverride ?? AppDelegate.meetings,
                     books: BooksController.shared)
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
    }

    /// Launched by macOS at login (not by the user): stay in the menu bar.
    static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
