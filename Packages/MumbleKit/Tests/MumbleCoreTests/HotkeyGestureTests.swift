import Testing
@testable import MumbleCore

@Suite struct HotkeyGestureTests {
    @Test func holdStartsAndReleaseCommits() {
        var g = HotkeyGesture()
        #expect(g.press(at: 0) == .start)
        #expect(g.isRecording)
        #expect(g.release(at: 1.2) == .commit)
        #expect(!g.isRecording)
    }

    @Test func quickTapIsDiscarded() {
        var g = HotkeyGesture()
        #expect(g.press(at: 0) == .start)
        #expect(g.release(at: 0.1) == .discard)
        #expect(!g.isRecording)
    }

    @Test func doubleTapLatchesAndNextPressCommits() {
        var g = HotkeyGesture()
        _ = g.press(at: 0)
        #expect(g.release(at: 0.1) == .discard)
        #expect(g.press(at: 0.3) == .start)
        #expect(g.release(at: 0.4) == .latch)
        #expect(g.isLatched)
        #expect(g.press(at: 5) == .none)
        #expect(g.release(at: 5.1) == .commit)
        #expect(!g.isRecording)
    }

    @Test func slowSecondTapIsJustAnotherTap() {
        var g = HotkeyGesture()
        _ = g.press(at: 0)
        _ = g.release(at: 0.1)
        #expect(g.press(at: 1.0) == .start)
        #expect(g.release(at: 1.1) == .discard)
        #expect(!g.isLatched)
    }

    @Test func secondPressHeldLongIsNormalDictation() {
        var g = HotkeyGesture()
        _ = g.press(at: 0)
        _ = g.release(at: 0.1)
        _ = g.press(at: 0.3)
        #expect(g.release(at: 2.0) == .commit)
    }

    @Test func keyRepeatIsIgnored() {
        var g = HotkeyGesture()
        #expect(g.press(at: 0) == .start)
        #expect(g.press(at: 0.05) == .none)
        #expect(g.release(at: 1) == .commit)
    }

    @Test func escapeDiscardsWhileHoldingOrLatched() {
        var g = HotkeyGesture()
        _ = g.press(at: 0)
        #expect(g.cancel() == .discard)
        #expect(!g.isRecording)
        #expect(g.release(at: 1) == .none)

        _ = g.press(at: 2); _ = g.release(at: 2.1)
        _ = g.press(at: 2.2); _ = g.release(at: 2.3)
        #expect(g.isLatched)
        #expect(g.cancel() == .discard)
        #expect(g.cancel() == .none)
    }

    @Test func tripleTapAfterLatchDoesNotRelatch() {
        var g = HotkeyGesture()
        _ = g.press(at: 0); _ = g.release(at: 0.1)
        _ = g.press(at: 0.2); _ = g.release(at: 0.3)  // latched
        _ = g.press(at: 0.4)
        #expect(g.release(at: 0.45) == .commit)
        #expect(g.press(at: 0.6) == .start)  // fresh, not a double-tap
        #expect(g.release(at: 0.65) == .discard)
    }
}
