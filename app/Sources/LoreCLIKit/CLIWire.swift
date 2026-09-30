import Foundation

/// What the `lore` command and the running app say to each other (#254).
///
/// One connection carries one exchange: the command writes a `CLIRequest` as one
/// line of JSON and keeps the connection open while it waits; the app answers
/// with a `CLIResponse` as one line of JSON and closes. The command closing
/// first (Ctrl-C) is how the app learns to stop. System frameworks only,
/// because the command links this module and has to run on a bare macOS.
public enum CLIWire {
    /// Beside the app's other state and never in /tmp: a socket in a
    /// world-writable directory is a door anyone can stand behind.
    public static var socketPath: String {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lore/cli.sock")
            .path
    }

    /// The app's setup flag (#150). The command reads it from the app's
    /// defaults to tell an unfinished setup from an app that did not start.
    public static let setupCompletedKey = "didCompleteSetup"

    /// A request is one path, so anything longer is not a request.
    public static let maxRequestBytes = 64 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Decodes the first line. JSON escapes newlines inside strings, so the
    /// first raw newline is always the end of the message.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let line = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first ?? data[...]
        return try JSONDecoder().decode(type, from: Data(line))
    }
}

public enum CLIRequest: Codable, Sendable, Equatable {
    /// `path` is absolute: the command resolves it against its own working
    /// directory, which the app does not share.
    case transcribe(path: String)
    /// One agent's reply for lore to read aloud (#257), with the identity its
    /// own shell gathered.
    case say(CLISayRequest)
}

public enum CLIResponse: Codable, Sendable, Equatable {
    /// `complete` is false when the file stopped decoding part-way — truncated,
    /// or still being written — and `text` is what came before that point.
    case transcript(text: String, complete: Bool)
    /// `complete` is false only for `.noSpeech` in a file that stopped decoding
    /// part-way.
    case failed(reason: TranscribeFailure, complete: Bool)
    /// The reply is in lore's queue and will be read aloud there (#257).
    case queued
    /// lore is running, and not taking replies: the feature's switch is off.
    /// The command speaks the text itself, so the terminal behaves as it did
    /// before the feature existed (#257).
    case notAccepted

    /// Every failure but a no-speech one in a partly readable file.
    public static func failed(_ reason: TranscribeFailure) -> CLIResponse {
        .failed(reason: reason, complete: true)
    }

    /// The line the command adds on stderr when the file stopped decoding early.
    public static func incompleteMessage(file: String) -> String {
        "lore couldn't read the rest of \(file); the transcript stops there."
    }
}

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
