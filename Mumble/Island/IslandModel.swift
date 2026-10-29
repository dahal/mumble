import Observation

/// What the notch island is currently showing.
enum IslandPhase: Equatable {
    case hidden
    case listening
    case finishing
    case done(String)
    case notice(String)
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
