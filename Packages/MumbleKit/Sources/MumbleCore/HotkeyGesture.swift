import Foundation

/// Turns raw press/release events of the trigger key into dictation commands.
///
/// - Hold the key: recording starts on press, text is inserted on release.
/// - Quick tap: discarded (recording started optimistically, so a stray tap costs nothing).
/// - Double-tap: the second tap latches recording hands-free; the next press finishes it.
/// - Escape: discards whatever is recording.
public struct HotkeyGesture: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case start
        case latch
        case commit
        case discard
    }

    enum State: Equatable {
        case idle
        case holding(since: TimeInterval, isSecondTap: Bool)
        case latched
        case latchedPressed
    }

    /// Presses shorter than this count as taps, not dictation.
    public var tapThreshold: TimeInterval
    /// Maximum gap between two taps to count as a double-tap.
    public var doubleTapWindow: TimeInterval

    private(set) var state: State = .idle
    private var lastTapAt: TimeInterval?

    public init(tapThreshold: TimeInterval = 0.25, doubleTapWindow: TimeInterval = 0.4) {
        self.tapThreshold = tapThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    public var isRecording: Bool { state != .idle }
    public var isLatched: Bool { state == .latched || state == .latchedPressed }

    public mutating func press(at time: TimeInterval) -> Action {
        switch state {
        case .idle:
            let isSecondTap = lastTapAt.map { time - $0 <= doubleTapWindow } ?? false
            state = .holding(since: time, isSecondTap: isSecondTap)
            return .start
        case .latched:
            state = .latchedPressed
            return .none
        case .holding, .latchedPressed:
            return .none  // key repeat
        }
    }

    public mutating func release(at time: TimeInterval) -> Action {
        switch state {
        case let .holding(since, isSecondTap):
            let isTap = time - since < tapThreshold
            if isTap && isSecondTap {
                lastTapAt = nil
                state = .latched
                return .latch
            }
            state = .idle
            if isTap {
                lastTapAt = time
                return .discard
            }
            lastTapAt = nil
            return .commit
        case .latchedPressed:
            state = .idle
            return .commit
        case .idle, .latched:
            return .none
        }
    }

    public mutating func cancel() -> Action {
        guard state != .idle else { return .none }
        state = .idle
        lastTapAt = nil
        return .discard
    }

    /// Resets after an external stop (e.g. an error) so the next press starts fresh.
    public mutating func reset() {
        state = .idle
        lastTapAt = nil
    }
}
