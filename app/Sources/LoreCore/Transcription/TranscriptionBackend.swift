import Foundation

/// Status of a transcription backend's readiness.
public enum BackendStatus: Equatable, Sendable {
    case ready
    case needsDownload
}

/// One piece of a transcript with the seconds of audio it came from. Parakeet's
/// tokens are sub-word pieces whose text carries the word boundary as a leading
/// space; the times are relative to the samples that were handed in.
public struct TranscribedToken: Sendable, Equatable {
    let text: String
    let start: Double
    let end: Double
}

/// One spoken word and the seconds it took, from the tokens that spelled it.
public struct TimedWord: Sendable, Equatable {
    public var text: String
    public let start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A stretch between two points on one axis — a file's frames, or seconds.
struct Span: Codable, Sendable, Equatable {
    let start: Double
    let end: Double
}

extension TranscribedToken {
    /// The words `tokens` spell, in order. A word runs from the first token
    /// that contributed a non-space character to it to the last: Parakeet's
    /// tokens are sub-word pieces whose text carries the boundary as a
    /// leading space.
    public static func words(_ tokens: [TranscribedToken]) -> [TimedWord] {
        var words: [TimedWord] = []
        var pending: TimedWord?
        for token in tokens {
            for character in token.text {
                if character.isWhitespace {
                    if let word = pending { words.append(word) }
                    pending = nil
                } else if pending == nil {
                    pending = TimedWord(text: String(character), start: token.start, end: token.end)
                } else {
                    pending?.text.append(character)
                    pending?.end = token.end
                }
            }
        }
        if let word = pending { words.append(word) }
        return words
    }
}

/// A transcription with the timings the model already produced (#192). The
/// text is identical to what `transcribe` returns; `tokens` is empty for a
/// backend that has no timings, and the caller falls back accordingly.
public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let tokens: [TranscribedToken]

    init(text: String, tokens: [TranscribedToken] = []) {
        self.text = text
        self.tokens = tokens
    }
}

/// Interface for the transcription backend (ParakeetBackend in production,
/// mocks in tests). The backend handles its own model lifecycle and
/// transcription logic, and receives raw audio samples.
public protocol TranscriptionBackend: Sendable {
    /// Check whether this backend is ready to transcribe.
    func checkStatus() -> BackendStatus

    /// Prepare the backend for use (download models, validate API keys, etc.).
    /// Must be called exactly once, and must complete before any call to transcribe().
    /// - Parameters:
    ///   - onStatus: Reports human-readable status messages (e.g. "Downloading…").
    ///   - onProgress: Reports download progress as a fraction in 0…1 (called only during download).
    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws

    /// Transcribe a segment of Float32 audio samples at 16kHz mono.
    /// Returns the transcribed text, or empty string if no speech detected.
    /// - Parameters:
    ///   - samples: Float32 audio at 16kHz mono.
    ///   - previousContext: Trailing words from the prior segment, used to prime the decoder
    ///     for cross-segment continuity. Backends that don't support prompting ignore this.
    func transcribe(_ samples: [Float], previousContext: String?) async throws -> String

    /// Same transcription, with the word timings the model produced — what
    /// puts a copied item at the second of the speech it belongs to (#192).
    /// Backends that have no timings inherit the default below and answer with
    /// the text alone.
    func transcribeDetailed(_ samples: [Float], previousContext: String?) async throws -> TranscriptionResult

    /// Remove cached model files so the next prepare() triggers a fresh download.
    func clearModelCache()

    /// Which speech model this backend runs, once known — what its `modelLoad`
    /// event names (#299). Nil for a backend that is not a speech model.
    var speechModel: SpeechModel? { get }
}

extension TranscriptionBackend {
    public func clearModelCache() {}

    public var speechModel: SpeechModel? { nil }

    public func transcribeDetailed(
        _ samples: [Float], previousContext: String?
    ) async throws -> TranscriptionResult {
        TranscriptionResult(text: try await transcribe(samples, previousContext: previousContext))
    }

    /// Convenience overload without progress reporting.
    public func prepare(onStatus: @Sendable (String) -> Void) async throws {
        try await prepare(onStatus: onStatus, onProgress: { _ in })
    }
}

enum TranscriptionBackendError: Error {
    case notPrepared
}
