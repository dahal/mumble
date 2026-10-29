import AppKit
import MumbleASR

/// Developer entry points, triggered by launch arguments:
///
///   Mumble.app/Contents/MacOS/Mumble --self-test <audio-file>   transcribe through the real pipeline, print, quit
///   Mumble.app/Contents/MacOS/Mumble --demo-island              cycle the notch island through its states
@MainActor
enum DevTools {
    /// Returns true if a developer mode took over this launch.
    static func runIfRequested(_ controller: DictationController) -> Bool {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--self-test"), i + 1 < args.count {
            Task { await selfTest(controller, path: args[i + 1]) }
            return true
        }
        if args.contains("--demo-island") {
            Task { await demoIsland(controller) }
            return true
        }
        return false
    }

    private static func selfTest(_ controller: DictationController, path: String) async {
        controller.loadModel()
        await controller.waitUntilModelSettles()
        guard controller.modelStatus.isReady else {
            print("SELFTEST model failed: \(controller.modelStatus)")
            exit(1)
        }
        do {
            let samples = try AudioFileLoader.samples(from: URL(fileURLWithPath: path))
            let clock = ContinuousClock()
            var result: (text: String, transcript: Transcript)!
            let elapsed = try await clock.measure { result = try await controller.transcribeForInsertion(samples) }
            print("SELFTEST text: \(result.text)")
            print("SELFTEST raw: \(result.transcript.text)")
            print("SELFTEST vocabulary: \(result.transcript.vocabularyApplied)")
            print("SELFTEST asr_ms: \(result.transcript.processingMs) total_ms: \(elapsed.components.attoseconds / 1_000_000_000_000_000 + elapsed.components.seconds * 1000)")
            exit(0)
        } catch {
            print("SELFTEST error: \(error)")
            exit(1)
        }
    }

    private static func demoIsland(_ controller: DictationController) async {
        let island = controller.island
        let panel = IslandPanel(model: island)
        island.reset()
        island.phase = .listening
        panel.show()
        let words = "Let's grab coffee at nine thirty and go over the roadmap for next quarter".split(separator: " ")
        for step in 0..<60 {
            island.pushLevel(Float.random(in: 0.2...0.9))
            island.elapsed = Double(step) * 0.08
            if step % 4 == 0 { island.previewText = words.prefix(step / 4 + 1).joined(separator: " ") }
            try? await Task.sleep(for: .milliseconds(80))
        }
        island.phase = .finishing
        try? await Task.sleep(for: .milliseconds(600))
        island.phase = .done("Let's grab coffee at nine thirty and go over the roadmap for next quarter.")
        try? await Task.sleep(for: .seconds(2))
        island.phase = .notice("Secure field — copied to clipboard instead")
        try? await Task.sleep(for: .seconds(2))
        panel.hide()
        try? await Task.sleep(for: .seconds(1))
        exit(0)
    }
}
