import AppKit
import SwiftUI
import MumbleASR
import MumbleCore

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
        if let i = args.firstIndex(of: "--e2e"), i + 1 < args.count {
            Task { await E2ETest.run(controller, resultURL: URL(fileURLWithPath: args[i + 1]), arguments: args) }
            return true
        }
        if args.contains("--record-test") {
            Task { await recordTest() }
            return true
        }
        if let i = args.firstIndex(of: "--render-island"), i + 1 < args.count {
            renderIsland(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        return false
    }

    /// Renders each island state to a PNG, for checking the design without screen recording.
    private static func renderIsland(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let states: [(String, IslandPhase, String, Bool)] = [
            ("listening", .listening, "", false),
            ("listening-preview", .listening, "Let's grab coffee at nine thirty and go over the", false),
            ("latched", .listening, "", true),
            ("finishing", .finishing, "Let's grab coffee at nine thirty and go over the roadmap", false),
            ("done", .done("Let's grab coffee at nine thirty and go over the roadmap."), "", false),
            ("notice", .notice("Secure field — copied to clipboard instead"), "", false),
        ]
        // Menu bar icons at 4×, on light and dark menu bar backgrounds.
        for (name, icon) in [("menubar-idle", MenuBarIcon.idle), ("menubar-recording", MenuBarIcon.recording)] {
            for (bg, color) in [("light", NSColor(white: 0.93, alpha: 1)), ("dark", NSColor(white: 0.12, alpha: 1))] {
                let scale: CGFloat = 4
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(40 * scale), pixelsHigh: Int(24 * scale), bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                    bitsPerPixel: 0)!
                rep.size = NSSize(width: 40, height: 24)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                color.setFill()
                NSRect(x: 0, y: 0, width: 40, height: 24).fill()
                icon.draw(in: NSRect(x: 10, y: 3, width: 20, height: 18))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name)-\(bg).png"))
            }
        }
        for hasNotch in [true, false] {
            for (name, phase, preview, latched) in states {
                let model = IslandModel()
                model.phase = phase
                model.previewText = preview
                model.isLatched = latched
                model.elapsed = 4.2
                model.levels = (0..<14).map { Float(0.25 + 0.6 * abs(sin(Double($0) * 0.7))) }
                let view = IslandView(model: model, notch: CGSize(width: 185, height: 32), hasNotch: hasNotch)
                    .frame(width: 520, height: 180)
                    .background(Color(white: 0.85))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appending(path: "\(hasNotch ? "notch" : "floating")-\(name).png"))
                }
            }
        }
    }

    /// Records from the real microphone twice in a row (the pattern that used to crash on the
    /// audio thread) and prints what was captured. Never prompts for permission.
    private static func recordTest() async {
        guard AudioRecorder.permission == .authorized else {
            print("RECORDTEST microphone not authorized for this process (status \(AudioRecorder.permission.rawValue))")
            exit(2)
        }
        let recorder = AudioRecorder()
        for round in 1...3 {
            do {
                try recorder.start()
                try? await Task.sleep(for: .seconds(1.5))
                let samples = recorder.buffer.snapshot()
                recorder.stop()
                print(String(format: "RECORDTEST round %d: %.2f s captured, rms %.5f, level %.2f",
                             round, Double(samples.count) / 16_000, AudioAnalysis.rms(samples), recorder.level))
                try? await Task.sleep(for: .milliseconds(round == 2 ? 9_000 : 300))  // round 3 starts cold
            } catch {
                print("RECORDTEST round \(round) failed: \(error)")
                exit(1)
            }
        }
        print("RECORDTEST ok")
        exit(0)
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
