import FluidAudio
import Foundation
import MumbleCore

/// Speaker diarization of the meeting app's audio, via FluidAudio's offline pipeline
/// (pyannote community-1 segmentation + embeddings, VBx clustering).
public actor MeetingDiarizer {
    /// Identifies the embedding space saved voices belong to; voices from another model are ignored.
    public static let embeddingModelID = "fluidaudio-offline-community-1"

    /// FluidAudio's manager isn't Sendable (its CoreML models are read-only after loading). It only
    /// ever runs inside this actor, which serializes every call.
    private final class Box: @unchecked Sendable {
        let manager = OfflineDiarizerManager(config: .default)
    }

    private var box: Box?

    public init() {}

    public var isReady: Bool { box != nil }

    public func prepare() async throws {
        guard box == nil else { return }
        let box = Box()
        try await box.manager.prepareModels()
        self.box = box
    }

    public struct Result: Sendable {
        /// Speech spans keyed "S1", "S2", … in order of first appearance.
        public var spans: [SpeakerSpan]
        /// One centroid embedding per speaker key.
        public var embeddings: [String: [Float]]
    }

    public func diarize(_ samples: [Float]) async throws -> Result {
        try await prepare()
        guard let box else { throw EngineError.notLoaded }
        guard samples.count > AudioAnalysis.sampleRate * 2 else { return Result(spans: [], embeddings: [:]) }
        let result = try await box.manager.process(audio: samples)
        return Self.normalize(result)
    }

    /// Renames diarizer IDs to stable keys by first appearance, and averages embeddings per speaker
    /// when the diarizer doesn't provide a speaker database.
    static func normalize(_ result: DiarizationResult) -> Result {
        let ordered = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var keys: [String: String] = [:]
        for segment in ordered where keys[segment.speakerId] == nil {
            keys[segment.speakerId] = "S\(keys.count + 1)"
        }
        let spans = ordered.map {
            SpeakerSpan(speakerKey: keys[$0.speakerId]!, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        var embeddings: [String: [Float]] = [:]
        for (id, key) in keys {
            if let centroid = result.speakerDatabase?[id], !centroid.isEmpty {
                embeddings[key] = centroid
                continue
            }
            let vectors = ordered.filter { $0.speakerId == id && !$0.embedding.isEmpty }.map(\.embedding)
            guard let first = vectors.first else { continue }
            var mean = [Float](repeating: 0, count: first.count)
            for v in vectors where v.count == mean.count { for i in mean.indices { mean[i] += v[i] } }
            embeddings[key] = mean.map { $0 / Float(vectors.count) }
        }
        return Result(spans: spans, embeddings: embeddings)
    }
}

/// Turns a meeting's two recordings into a speaker-labeled transcript (spec §8 steps 1–3).
public enum MeetingPipeline {
    public struct Output: Sendable {
        public var texts: [TimedText]
        /// Remote speech spans by speaker (for naming signals).
        public var spans: [SpeakerSpan]
        public var embeddings: [String: [Float]]
        public var talkSeconds: [String: Double]
        /// True when diarization failed and all remote speech was attributed to one "Others" speaker.
        public var diarizationFailed: Bool
        /// Seconds of microphone audio removed as speaker echo.
        public var echoSecondsRemoved: Double
    }

    public enum Stage: Sendable { case transcribing, diarizing }

    /// - Parameters:
    ///   - local: the microphone, 16 kHz mono.
    ///   - remote: the meeting app's audio on the same clock (may be empty when the tap was unavailable).
    public static func run(
        local: [Float], remote: [Float], engine: TranscriptionEngine, diarizer: MeetingDiarizer,
        boostVocabulary: Bool, stage: @Sendable (Stage) async -> Void = { _ in }
    ) async throws -> Output {
        await stage(.diarizing)
        let remoteHasSpeech = !remote.isEmpty && !SpeechRegions.detect(remote).isEmpty
        var spans: [SpeakerSpan] = []
        var embeddings: [String: [Float]] = [:]
        var failed = false
        if remoteHasSpeech {
            do {
                let result = try await diarizer.diarize(remote)
                spans = result.spans
                embeddings = result.embeddings
            } catch {
                failed = true
            }
            if spans.isEmpty {
                // Fallback: every remote speech region belongs to one "Others" speaker.
                failed = true
                spans = SpeechRegions.detect(remote).map {
                    SpeakerSpan(speakerKey: "S1", start: seconds($0.lowerBound), end: seconds($0.upperBound))
                }
            }
        }

        await stage(.transcribing)
        var texts: [TimedText] = []
        // Remote: one transcription per speaker turn, so every word carries its speaker.
        for turn in SpeakerTurns.build(spans) {
            try Task.checkCancellation()
            let range = sampleRange(turn.start, turn.end, count: remote.count)
            guard range.count > AudioAnalysis.sampleRate / 4 else { continue }
            let t = try await engine.transcribe(Array(remote[range]), boostVocabulary: boostVocabulary)
            if !t.text.isEmpty { texts.append(TimedText(speakerKey: turn.speakerKey, start: turn.start, end: turn.end, text: t.text)) }
        }

        // Local: your speech, after muting what is only the meeting leaking from the speakers.
        let (cleaned, echoSeconds) = EchoGate.suppress(local: local, remote: remote)
        var localSeconds = 0.0
        for region in SpeechRegions.detect(cleaned) {
            try Task.checkCancellation()
            let t = try await engine.transcribe(Array(cleaned[region]), boostVocabulary: boostVocabulary)
            guard !t.text.isEmpty else { continue }
            localSeconds += seconds(region.count)
            texts.append(TimedText(speakerKey: MeetingSpeaker.meKey, start: seconds(region.lowerBound),
                                   end: seconds(region.upperBound), text: t.text))
        }

        var talk = SpeakerTurns.talkSeconds(spans)
        if localSeconds > 0 { talk[MeetingSpeaker.meKey] = localSeconds }
        return Output(texts: TranscriptMerger.merge(texts), spans: spans, embeddings: embeddings, talkSeconds: talk,
                      diarizationFailed: failed && remoteHasSpeech, echoSecondsRemoved: echoSeconds)
    }

    static func seconds(_ samples: Int) -> Double { Double(samples) / Double(AudioAnalysis.sampleRate) }

    static func sampleRange(_ start: Double, _ end: Double, count: Int) -> Range<Int> {
        let a = max(0, min(count, Int(start * Double(AudioAnalysis.sampleRate))))
        let b = max(a, min(count, Int(end * Double(AudioAnalysis.sampleRate))))
        return a..<b
    }
}
