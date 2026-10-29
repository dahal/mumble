import AppKit
import FluidAudio
import Foundation
import MumbleCore

public struct Transcript: Sendable, Equatable {
    public let text: String
    public let audioSeconds: Double
    public let processingMs: Int
    /// Vocabulary terms the CTC rescorer swapped into the text.
    public let vocabularyApplied: [String]
}

public enum EngineError: LocalizedError {
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "The speech model isn't loaded yet."
        }
    }
}

/// Owns the Parakeet models and runs every inference. Being an actor serializes all
/// Neural Engine work, so a live preview can never overlap the final pass (FluidVoice
/// saw crashes from concurrent CoreML models contending for the ANE).
public actor TranscriptionEngine {
    private var manager: AsrManager?
    public private(set) var loadedModel: SpeechModel?

    private var ctcModels: CtcModels?
    private var vocabularySession: VocabularyBoostingSession?
    private var vocabularyEntries: [VocabularyEntry] = []

    /// Silence prepended to every clip: gives the encoder left context so the first
    /// word of a short utterance isn't dropped.
    static let leadInSamples = 4_000
    /// Clips are padded to at least this length; FluidAudio rejects anything under 0.3 s.
    static let minimumSamples = 16_000

    public init() {}

    public static func modelVersion(for model: SpeechModel) -> AsrModelVersion {
        switch model {
        case .phonon2: .phonon2
        case .ultra: .ultra
        case .v3: .v3
        case .v2: .v2
        case .small: .tdtCtc110m
        }
    }

    public static func isDownloaded(_ model: SpeechModel) -> Bool {
        let version = modelVersion(for: model)
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    public var isReady: Bool { manager != nil }

    /// Downloads (if needed), compiles and loads `model`, then warms it up so the first real
    /// dictation doesn't pay the one-off Neural Engine setup cost.
    public func load(_ model: SpeechModel, progress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        if loadedModel == model, manager != nil { return }
        unload()

        let models = try await AsrModels.downloadAndLoad(
            version: Self.modelVersion(for: model),
            progressHandler: { update in
                let label: String
                switch update.phase {
                case .listing: label = "Preparing download"
                case let .downloading(done, total): label = "Downloading model (\(done)/\(total) files)"
                case .compiling: label = "Optimizing for your Mac"
                }
                progress?(update.fractionCompleted, label)
            }
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        self.loadedModel = model

        progress?(1, "Warming up")
        _ = try? await transcribe([Float](repeating: 0, count: 16_000), boostVocabulary: false)
    }

    public func unload() {
        manager = nil
        loadedModel = nil
    }

    /// Prepares CTC vocabulary boosting. Loads the extra ~100 MB CTC model only when there are terms.
    public func setVocabulary(_ entries: [VocabularyEntry]) async throws {
        let usable = entries.filter { !$0.term.trimmingCharacters(in: .whitespaces).isEmpty }
        guard usable != vocabularyEntries else { return }
        vocabularyEntries = usable
        guard !usable.isEmpty else {
            vocabularySession = nil
            ctcModels = nil
            return
        }
        let ctc: CtcModels
        if let ctcModels {
            ctc = ctcModels
        } else {
            ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            ctcModels = ctc
        }
        let terms = usable.map {
            CustomVocabularyTerm(text: $0.term, aliases: $0.aliases.isEmpty ? nil : $0.aliases)
        }
        // Spotter rescue off: with it on, short and brand-like terms over-fire badly
        // (in our eval it replaced "pods"/"cluster" with vocabulary terms). FluidAudio
        // recommends this for short vocabularies.
        vocabularySession = try await VocabularyBoostingSession(
            vocabulary: CustomVocabularyContext(terms: terms), ctcModels: ctc,
            config: VocabularyRescorer.Config(spotterRescueEnabled: false))
    }

    /// Transcribes 16 kHz mono samples.
    /// - Parameter boostVocabulary: run CTC vocabulary rescoring. Only worth it on the final pass;
    ///   FluidAudio documents that boosting degrades on partial audio.
    public func transcribe(_ samples: [Float], boostVocabulary: Bool) async throws -> Transcript {
        guard let manager else { throw EngineError.notLoaded }
        let start = ContinuousClock.now

        var padded = [Float](repeating: 0, count: Self.leadInSamples)
        padded.append(contentsOf: samples)
        if padded.count < Self.minimumSamples {
            padded.append(contentsOf: [Float](repeating: 0, count: Self.minimumSamples - padded.count))
        }

        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(padded, decoderState: &state)

        var text = result.text
        var applied: [String] = []
        if boostVocabulary, let session = vocabularySession, let timings = result.tokenTimings, !timings.isEmpty,
           session.hasCTCRescoringCandidates(text: text, tokenTimings: timings),
           let output = await session.rescore(text: text, tokenTimings: timings, audioSamples: padded) {
            let original = text
            let terms = vocabularyEntries.map(\.term)
            let guarded = await MainActor.run {
                Vocabulary.guardRescore(
                    original: original, rescored: output.text, terms: terms, isDictionaryWord: Self.isDictionaryWord)
            }
            if guarded != text {
                applied = output.replacements.filter(\.shouldReplace).compactMap(\.replacementWord)
            }
            text = guarded
        }

        let elapsed = start.duration(to: .now)
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return Transcript(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            audioSeconds: Double(samples.count) / Double(AudioAnalysis.sampleRate),
            processingMs: ms,
            vocabularyApplied: applied
        )
    }

    @MainActor static func isDictionaryWord(_ word: String) -> Bool {
        guard word.count > 1 else { return true }
        let checker = NSSpellChecker.shared
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return miss.location == NSNotFound
    }

    /// Inverse text normalization: "twenty five dollars" → "$25", "test at gmail dot com" → "test@gmail.com".
    public nonisolated static func normalize(_ text: String) -> String {
        TextNormalizer.shared.normalizeSentence(text)
    }
}
