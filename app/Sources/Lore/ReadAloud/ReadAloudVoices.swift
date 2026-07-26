import AVFoundation
import Foundation

/// Which synthesis engine renders a voice (#105): Speechify's API (paid) or
/// the local `AVSpeechSynthesizer` (free, offline, the default).
enum ReadAloudEngine: String, Codable, Sendable {
    case speechify
    case system
}

/// How the voice for a text is chosen: one voice per detected language
/// (default), or a single multilingual Speechify voice for everything
/// (offered only while a key is present).
enum ReadAloudVoiceMode: String, Codable, Sendable, CaseIterable {
    case perLanguage
    case singleVoice

    var displayName: String {
        switch self {
        case .perLanguage: "Per language"
        case .singleVoice: "Single voice"
        }
    }
}

/// A selected voice: engine-qualified id plus a cached display name, so the
/// setting renders without a network round-trip. Persisted in UserDefaults
/// as its `rawValue` ("engine|id|name").
struct ReadAloudVoiceChoice: Equatable, Sendable, RawRepresentable {
    let engine: ReadAloudEngine
    /// Speechify `voice_id`, or an `AVSpeechSynthesisVoice` identifier, or
    /// `systemAutoID` for "let macOS pick per detected language".
    let id: String
    let name: String

    init(engine: ReadAloudEngine, id: String, name: String) {
        self.engine = engine
        self.id = id
        self.name = name
    }

    var rawValue: String { [engine.rawValue, id, name].joined(separator: "|") }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3, let engine = ReadAloudEngine(rawValue: parts[0]) else { return nil }
        self.init(engine: engine, id: parts[1], name: parts[2])
    }

    static let systemAutoID = "auto"
    /// "System voice" — macOS auto-picks a voice for the detected language.
    /// The fresh-install default for every language row (free-first).
    static let systemAuto = ReadAloudVoiceChoice(
        engine: .system, id: systemAutoID, name: "System voice"
    )
}

/// System-voice enumeration and display helpers (#105). The Speechify side
/// of the pickers comes from `SpeechifyVoiceCatalog`.
enum ReadAloudVoices {
    /// Single-voice mode default — leonid, the auditioned multilingual voice.
    /// Only reachable while a key is present, so a Speechify default is safe.
    static let defaultSingle = ReadAloudVoiceChoice(
        engine: .speechify, id: "leonid", name: "Leonid"
    )

    /// Installed system voices for a language prefix ("ru", "en") — the free
    /// tier of the voice pickers. Compact/premium duplicates collapse by name.
    static func systemVoices(languagePrefix: String) -> [ReadAloudVoiceChoice] {
        var seen = Set<String>()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languagePrefix) }
            .compactMap { voice in
                guard seen.insert(voice.name).inserted else { return nil }
                return ReadAloudVoiceChoice(
                    engine: .system, id: voice.identifier, name: voice.name
                )
            }
            .sorted { $0.name < $1.name }
    }

    /// Panel avatar letter — the voice name's first letter.
    static func avatarInitial(for choice: ReadAloudVoiceChoice) -> String {
        choice.name.prefix(1).uppercased()
    }
}
