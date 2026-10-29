import Foundation

/// Modifier-style keys that can be held for push-to-talk. Raw values are macOS virtual key codes.
public enum TriggerKey: Int, Codable, CaseIterable, Sendable, Identifiable {
    case function = 63
    case rightOption = 61
    case rightCommand = 54
    case rightControl = 62

    public var id: Int { rawValue }
    public var keyCode: UInt16 { UInt16(rawValue) }

    public var displayName: String {
        switch self {
        case .function: "fn (Globe)"
        case .rightOption: "Right ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .rightControl: "Right ⌃ Control"
        }
    }
}

/// The speech models Mumble offers, mapped to FluidAudio model versions in MumbleASR.
public enum SpeechModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case phonon2
    case ultra
    case v3
    case v2
    case small

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .phonon2: "Phonon-2 · English"
        case .ultra: "Parakeet Ultra · 25 languages"
        case .v3: "Parakeet TDT v3 · 25 languages"
        case .v2: "Parakeet TDT v2 · English"
        case .small: "Parakeet 110M · English (light)"
        }
    }

    public var tier: String {
        switch self {
        case .phonon2: "Balanced"
        case .ultra: "Max"
        case .v3, .v2: "Classic"
        case .small: "Light"
        }
    }

    public var approximateDownload: String {
        switch self {
        case .phonon2: "~330 MB"
        case .ultra: "~620 MB"
        case .v3, .v2: "~480 MB"
        case .small: "~230 MB"
        }
    }

    public var summary: String {
        switch self {
        case .phonon2: "Recommended. Small, fast and very accurate for English."
        case .ultra: "Most accurate. Multilingual. Larger download."
        case .v3: "Original multilingual Parakeet."
        case .v2: "Original English Parakeet, strong recall."
        case .small: "Lightest and fastest, slightly less accurate."
        }
    }
}

public struct VocabularyEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var term: String
    /// Other ways people say it, e.g. "cube control" for "kubectl".
    public var aliases: [String]

    public init(id: UUID = UUID(), term: String, aliases: [String] = []) {
        self.id = id
        self.term = term
        self.aliases = aliases
    }
}

public struct MumbleSettings: Codable, Sendable, Equatable {
    public var triggerKey: TriggerKey = .function
    public var model: SpeechModel = .phonon2
    public var removeFillers = true
    public var spokenCommands = true
    public var inverseTextNormalization = true
    public var smartSpacing = true
    public var playSounds = true
    public var showLivePreview = true
    public var keepHistory = true
    public var historyLimit = 200
    public var vocabulary: [VocabularyEntry] = []
    public var replacements: [Replacement] = []

    public init() {}

    public var pipelineOptions: TextPipelineOptions {
        TextPipelineOptions(removeFillers: removeFillers, spokenCommands: spokenCommands, replacements: replacements)
    }

    // Decode field by field so settings saved by an older build (missing keys) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MumbleSettings()
        triggerKey = try c.decodeIfPresent(TriggerKey.self, forKey: .triggerKey) ?? d.triggerKey
        model = try c.decodeIfPresent(SpeechModel.self, forKey: .model) ?? d.model
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? d.removeFillers
        spokenCommands = try c.decodeIfPresent(Bool.self, forKey: .spokenCommands) ?? d.spokenCommands
        inverseTextNormalization =
            try c.decodeIfPresent(Bool.self, forKey: .inverseTextNormalization) ?? d.inverseTextNormalization
        smartSpacing = try c.decodeIfPresent(Bool.self, forKey: .smartSpacing) ?? d.smartSpacing
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        showLivePreview = try c.decodeIfPresent(Bool.self, forKey: .showLivePreview) ?? d.showLivePreview
        keepHistory = try c.decodeIfPresent(Bool.self, forKey: .keepHistory) ?? d.keepHistory
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? d.historyLimit
        vocabulary = try c.decodeIfPresent([VocabularyEntry].self, forKey: .vocabulary) ?? d.vocabulary
        replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements) ?? d.replacements
    }
}
