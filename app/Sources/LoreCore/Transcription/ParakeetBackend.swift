import FluidAudio
import Foundation
import os

/// The Parakeet transcription backend — Parakeet Ultra, or v3 on a Mac that
/// has not switched yet (#299, `SpeechModelFiles`). One model family since #53
/// (single-model decision, docs/decisions.md).
/// @unchecked Sendable: `speechModel` and `asrManager` are written in prepare(),
/// which completes before any transcribe() call or any read of the model.
public final class ParakeetBackend: TranscriptionBackend, @unchecked Sendable {
    /// What a meeting records as its `engine`: the model this process
    /// transcribes with. It changes only while no meeting is live (#299).
    public static var engineName: String { SpeechModelFiles.shared.working.rawValue }

    private let files: SpeechModelFiles
    /// Set at init when the caller names the model, otherwise when prepare()
    /// starts: the model in use when the load begins, never earlier.
    public private(set) var speechModel: SpeechModel?
    private var asrManager: AsrManager?

    public init(model: SpeechModel? = nil, files: SpeechModelFiles = .shared) {
        self.speechModel = model
        self.files = files
    }

    public func checkStatus() -> BackendStatus {
        files.isOnDisk(speechModel ?? files.working) ? .ready : .needsDownload
    }

    public func clearModelCache() {
        _ = files.clear(speechModel ?? files.working)
    }

    public func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        ModelBundle.pinAll()
        let model = speechModel ?? files.working
        speechModel = model
        onStatus("Downloading speech model...")
        let startedAt = Date()
        // A folder missing any file is fetched (the vocabulary alone comes by
        // a plain fetch); a whole one at another revision is downloaded anew,
        // which FluidAudio opens with `.listing`, never sent on a load from disk.
        let downloaded = OSAllocatedUnfairLock(initialState: !files.isOnDisk(model))
        let models = try await AsrModels.downloadAndLoad(to: files.folder(model), version: model.version) { progress in
            if case .listing = progress.phase { downloaded.withLock { $0 = true } }
            onProgress(progress.fractionCompleted)
        }
        if downloaded.withLock({ $0 }) {
            DiagStore.record(.speechModelDownloaded(model: model, seconds: Date().timeIntervalSince(startedAt)))
        }
        onStatus("Initializing speech model...")
        // Two of FluidAudio 0.15.7's long-form defaults, reverted (docs/decisions.md, #269).
        let asr = AsrManager(config: ASRConfig(melChunkContext: true, seamGapRepair: false))
        // FluidAudio 0.14 renamed `initialize(models:)` to `loadModels(_:)`.
        try await asr.loadModels(models)
        // Vocabulary boosting removed with FluidAudio v0.14 bump (#35); the vocabulary track was retired entirely in #53.
        self.asrManager = asr
    }

    public func transcribe(_ samples: [Float], previousContext: String? = nil) async throws -> String {
        try await transcribeDetailed(samples, previousContext: previousContext).text
    }

    /// The timings come back from the model on every TDT decode; until #192
    /// they were dropped one line before Lore saw them.
    public func transcribeDetailed(
        _ samples: [Float], previousContext: String? = nil
    ) async throws -> TranscriptionResult {
        guard let asrManager else {
            throw TranscriptionBackendError.notPrepared
        }
        // FluidAudio 0.14 requires an explicit decoder state. Each utterance is stateless,
        // so we make a fresh state per call (matches upstream CLI / benchmark idiom).
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(samples, decoderState: &decoderState)
        return TranscriptionResult(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            tokens: (result.tokenTimings ?? []).map {
                TranscribedToken(text: $0.token, start: $0.startTime, end: $0.endTime)
            }
        )
    }
}
