import Foundation

/// Status of a transcription backend's readiness.
enum BackendStatus: Equatable, Sendable {
    case ready
    case needsDownload
}

/// One piece of a transcript with the seconds of audio it came from. Parakeet's
/// tokens are sub-word pieces whose text carries the word boundary as a leading
/// space; the times are relative to the samples that were handed in.
struct TranscribedToken: Sendable, Equatable {
    let text: String
    let start: Double
    let end: Double
}

/// A transcription with the timings the model already produced (#192). The
/// text is identical to what `transcribe` returns; `tokens` is empty for a
/// backend that has no timings, and the caller falls back accordingly.
struct TranscriptionResult: Sendable, Equatable {
    let text: String
    let tokens: [TranscribedToken]

    init(text: String, tokens: [TranscribedToken] = []) {
        self.text = text
        self.tokens = tokens
    }
}

/// Interface for the transcription backend (ParakeetBackend in production,
/// mocks in tests). The backend handles its own model lifecycle and
/// transcription logic, and receives raw audio samples.
protocol TranscriptionBackend: Sendable {
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
}

extension TranscriptionBackend {
    func clearModelCache() {}

    func transcribeDetailed(
        _ samples: [Float], previousContext: String?
    ) async throws -> TranscriptionResult {
        TranscriptionResult(text: try await transcribe(samples, previousContext: previousContext))
    }

    /// Convenience overload without progress reporting.
    func prepare(onStatus: @Sendable (String) -> Void) async throws {
        try await prepare(onStatus: onStatus, onProgress: { _ in })
    }
}

enum TranscriptionBackendError: Error {
    case notPrepared
}
