import FluidAudio
import Foundation

/// On-device text-to-speech for the book reader: Kokoro-82M (v3 pipeline) on the Neural Engine via FluidAudio.
/// The model downloads once (to FluidAudio's cache) on first use.
public actor Narrator {
    public struct Voice: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let accent: String

        public var label: String { "\(name) (\(accent))" }
    }

    /// English voices worth offering, best first. Kokoro ships more, but these read long-form text well.
    public static let voices: [Voice] = [
        Voice(id: "af_heart", name: "Heart", accent: "American"),
        Voice(id: "af_bella", name: "Bella", accent: "American"),
        Voice(id: "af_nicole", name: "Nicole", accent: "American"),
        Voice(id: "af_sarah", name: "Sarah", accent: "American"),
        Voice(id: "am_michael", name: "Michael", accent: "American"),
        Voice(id: "am_fenrir", name: "Fenrir", accent: "American"),
        Voice(id: "am_puck", name: "Puck", accent: "American"),
        Voice(id: "bf_emma", name: "Emma", accent: "British"),
        Voice(id: "bf_isabella", name: "Isabella", accent: "British"),
        Voice(id: "bm_george", name: "George", accent: "British"),
        Voice(id: "bm_fable", name: "Fable", accent: "British"),
    ]

    public static let defaultVoice = "af_heart"
    public static let sampleRate = Double(KokoroAneConstants.sampleRate)

    private let manager = KokoroAneManager(version: .v3)
    private var ready = false
    private var loading: Task<Void, Error>?

    public init() {}

    public var isReady: Bool { ready }

    /// Downloads (first time) and loads the model. Safe to call repeatedly or concurrently.
    public func load() async throws {
        if ready { return }
        if let loading { return try await loading.value }
        let manager = manager
        let task = Task { try await manager.initialize() }
        loading = task
        do {
            try await task.value
            ready = true
        } catch {
            loading = nil
            throw error
        }
    }

    /// 24 kHz mono samples. `speed` is Kokoro's native rate (0.5…2), which sounds better than time-stretching.
    public func speak(_ text: String, voice: String = defaultVoice, speed: Float = 1) async throws -> [Float] {
        try await load()
        let result = try await manager.synthesizeDetailed(text: text, voice: voice, speed: speed)
        return result.samples
    }
}
