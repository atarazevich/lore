import Foundation

/// Why the app could not hand back a transcript. A closed set, so it doubles as
/// the diagnostic reason — no path and no text ever rides along.
public enum TranscribeFailure: String, Codable, Sendable, CaseIterable, Error {
    case fileNotFound
    /// The file exists and lore's own permissions do not reach it.
    case notPermitted
    /// Opening failed for another reason: an I/O error, a symlink loop, a name
    /// too long.
    case couldNotOpen
    case notAudio
    /// The speech model or the voice detector failed to load.
    case modelLoadFailed
    /// A meeting is recording, paused or finalizing, or started while the
    /// request ran: its microphone leg shares the model.
    case meetingInProgress
    case noSpeech
    /// The model or the voice detector threw part-way through.
    case transcriptionFailed

    /// The one line for stderr. `file` is the path as it was typed.
    public func message(file: String) -> String {
        switch self {
        case .fileNotFound:
            return "There's no file at \(file)."
        case .notPermitted:
            return "lore isn't allowed to read \(file) — give lore Full Disk Access in System Settings > Privacy & Security."
        case .couldNotOpen:
            return "lore couldn't open \(file)."
        case .notAudio:
            return "\(file) isn't an audio file lore can read."
        case .modelLoadFailed:
            return "lore couldn't load its speech model — try again."
        case .meetingInProgress:
            return "lore is in a meeting — try again when it ends."
        case .noSpeech:
            return "lore found no speech in \(file)."
        case .transcriptionFailed:
            return "lore couldn't transcribe \(file) — try again."
        }
    }
}
