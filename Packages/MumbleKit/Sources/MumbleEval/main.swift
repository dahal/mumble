import Foundation
import MumbleASR
import MumbleCore

// mumble-eval: transcribes every audio file in a directory and reports WER against
// a sibling .txt reference with the same name.
//
//   swift run -c release mumble-eval <dir> [--model phonon2|ultra|v3|v2|small] [--raw] [--itn]
//
// By default the app's text pipeline runs without number normalization (its default); --itn adds it,
// --raw skips post-processing entirely.

let args = CommandLine.arguments.dropFirst()
guard let dir = args.first else {
    print("usage: mumble-eval <dir> [--model phonon2|ultra|v3|v2|small] [--raw] [--itn]")
    exit(2)
}
let model = args.firstIndex(of: "--model").flatMap { args.index(after: $0) < args.endIndex ? args[args.index(after: $0)] : nil }
    .flatMap(SpeechModel.init(rawValue:)) ?? .phonon2
let raw = args.contains("--raw")
let itn = args.contains("--itn")

let engine = TranscriptionEngine()
print("Loading \(model.displayName)…")
try await engine.load(model)

let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
    .filter { ["wav", "m4a", "aiff", "aif", "caf", "mp3", "flac"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

var totalErrors = 0, totalWords = 0, totalAudio = 0.0, totalMs = 0
for file in files {
    let samples = try AudioFileLoader.samples(from: file)
    let transcript = try await engine.transcribe(samples, boostVocabulary: false)
    let normalizer: ((String) -> String)? = itn ? { TranscriptionEngine.normalize($0) } : nil
    let text = raw ? transcript.text : TextPipeline.process(
        transcript.text, options: TextPipelineOptions(), normalizer: normalizer)
    totalAudio += transcript.audioSeconds
    totalMs += transcript.processingMs

    let refURL = file.deletingPathExtension().appendingPathExtension("txt")
    var line = "\(file.lastPathComponent)  \(transcript.processingMs) ms"
    if let reference = try? String(contentsOf: refURL, encoding: .utf8) {
        let wer = WordErrorRate.compute(reference: reference, hypothesis: text)
        totalErrors += wer.errors
        totalWords += wer.referenceWords
        line += String(format: "  WER %.1f%%", wer.rate * 100)
    }
    print(line)
    print("   → \(text)")
}

if totalWords > 0 {
    print(String(format: "\nOverall WER: %.2f%% (%d errors / %d words)", Double(totalErrors) / Double(totalWords) * 100, totalErrors, totalWords))
}
if totalMs > 0 {
    print(String(format: "Speed: %.1fx real-time over %.1f s of audio", totalAudio / (Double(totalMs) / 1000), totalAudio))
}
