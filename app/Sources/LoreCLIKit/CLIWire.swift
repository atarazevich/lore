import Foundation
import LoreFormat

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

    /// A request is one path and a flag, so anything longer is not a request.
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
    /// directory, which the app does not share. `speakers` asks for the
    /// transcript as speaker turns (#276); it is optional so a command that
    /// predates it still decodes, and an app that predates it ignores it and
    /// answers `.transcript`.
    case transcribe(path: String, speakers: Bool? = nil)
    /// One agent's reply for lore to read aloud (#257), with the identity its
    /// own shell gathered.
    case say(CLISayRequest)
}

public enum CLIResponse: Codable, Sendable, Equatable {
    /// `complete` is false when the file stopped decoding part-way — truncated,
    /// or still being written — and `text` is what came before that point.
    case transcript(text: String, complete: Bool)
    /// The answer to a request with `speakers` (#276): one paragraph per
    /// turn, `[mm:ss] Speaker N: text` — or, with `found` false, the plain
    /// transcript, kept when the speakers could not be told apart. Only a
    /// request that asked for turns gets it, so a command that predates it
    /// never sees one.
    case speakerTurns(text: String, complete: Bool, found: Bool)
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
