import FluidAudio
import Foundation

/// Transcription backend for Parakeet TDT v3 (multilingual) — the app's only
/// transcription model since #53 (single-model decision, docs/decisions.md).
/// @unchecked Sendable: asrManager is written once in prepare() before any transcribe() calls.
final class ParakeetBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "Parakeet TDT v3"
    /// Engine identifier persisted in session metadata and markdown frontmatter.
    static let engineName = "parakeetV3"
    private let version: AsrModelVersion = .v3
    private var asrManager: AsrManager?

    func checkStatus() -> BackendStatus {
        let exists = AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: version),
            version: version
        )
        return exists ? .ready : .needsDownload
    }

    func clearModelCache() {
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        try? FileManager.default.removeItem(at: cacheDir)
    }

    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        onStatus("Downloading \(displayName)...")
        let models = try await AsrModels.downloadAndLoad(version: version) { progress in
            onProgress(progress.fractionCompleted)
        }
        onStatus("Initializing \(displayName)...")
        let asr = AsrManager(config: .default)
        // FluidAudio 0.14 renamed `initialize(models:)` to `loadModels(_:)`.
        try await asr.loadModels(models)
        // Vocabulary boosting removed with FluidAudio v0.14 bump (#35); the vocabulary track was retired entirely in #53.
        self.asrManager = asr
    }

    func transcribe(_ samples: [Float], previousContext: String? = nil) async throws -> String {
        guard let asrManager else {
            throw TranscriptionBackendError.notPrepared
        }
        // FluidAudio 0.14 requires an explicit decoder state. Each utterance is stateless,
        // so we make a fresh state per call (matches upstream CLI / benchmark idiom).
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(samples, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
