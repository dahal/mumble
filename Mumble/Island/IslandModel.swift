import Observation

/// What the notch island is currently showing.
enum IslandPhase: Equatable {
    case hidden
    case listening
    case finishing
    case done(String)
    case notice(String)
    /// Taking meeting notes: live speaker + text, red dot and timer.
    case meeting
    /// A meeting started: "Pricing page rollout · Take notes?" with Take Notes and ×.
    case suggest(title: String, appBundleID: String?)
    /// One minute before a calendar meeting.
    case headsUp(title: String)

    var isInteractive: Bool {
        switch self {
        case .suggest, .headsUp: true
        default: false
        }
    }
}

@MainActor @Observable
final class IslandModel {
    var phase: IslandPhase = .hidden
    var level: Float = 0
    var levels: [Float] = Array(repeating: 0, count: 14)
    var previewText = ""
    var isLatched = false
    var elapsed: Double = 0
    var showPreview = true
    /// Name shown before the live meeting line ("Sarah Chen", "You").
    var meetingSpeaker = ""
    /// Brief confirmation in the meeting island ("Bookmarked").
    var flash: String?
    /// The phase to return to when a dictation finishes during a meeting.
    var restingPhase: IslandPhase?
    @ObservationIgnored var onTakeNotes: () -> Void = {}
    @ObservationIgnored var onDismiss: () -> Void = {}

    func pushLevel(_ value: Float) {
        level = value
        levels.removeFirst()
        levels.append(value)
    }

    func reset() {
        level = 0
        levels = Array(repeating: 0, count: levels.count)
        previewText = ""
        isLatched = false
        elapsed = 0
    }
}
