import CoreML
import FluidAudio
import Foundation

/// The voice detector, pinned to Silero v6.0.0 — the artifact meetings were
/// segmented with up to FluidAudio 0.15.2. FluidAudio 0.15.5 moved its default
/// to v6.2.1; the v6.0.0 folder stays in the same Hugging Face repo, fetched from
/// a fixed commit, and an existing machine keeps the file it has
/// (docs/decisions.md, #269). Every VAD load and the health probe go through here.
enum SileroVAD {
    /// What the detector reads at a time: 4096 samples, 256 ms at 16 kHz.
    static let windowSize = VadManager.chunkSize
    /// Windows kept before a detected start, live and in the file pass (512 ms):
    /// the detector fires after the first syllable has begun.
    static let leadInWindows = 2
    /// The one call configuration, live and in the file pass.
    static let segmentation = VadSegmentationConfig.default
    /// Below this the detector counts a window as silence (its hysteresis floor).
    static let negativeThreshold = segmentation.effectiveNegativeThreshold(baseThreshold: VadConfig.default.defaultThreshold)

    static let fileName = "silero-vad-unified-256ms-v6.0.0.mlmodelc"

    /// `FluidInference/silero-vad-coreml` at a commit that holds v6.0.0 — `main`
    /// is mutable, and the folder was deleted and re-uploaded once (2025-09-16).
    /// Every file of the v6.0.0 bundle: the download fetches them several at a
    /// time, so only the whole set says the model is there.
    static let bundle = ModelBundle(
        repo: .vad,
        revision: "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
        folder: fileName,
        files: ["coremldata.bin", "analytics/coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"]
            .map { "\(fileName)/\($0)" }
    )

    /// Complete on disk. A bare folder is not a model.
    static var isPresent: Bool { bundle.isComplete }

    /// Downloads the model when it is missing or incomplete, then loads it with
    /// the settings FluidAudio's own loader uses. Records the `modelLoad` event,
    /// so every caller's success or failure reaches the health panel. The
    /// revision is pinned at launch (`ModelBundle.pinAll`).
    static func load() async throws -> VadManager {
        try await bundle.load(.vad) {
            try await ModelHub.download(.vad, subdirectory: fileName, to: bundle.repoDirectory)
        } load: {
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = VadConfig.default.computeUnits
            mlConfig.allowLowPrecisionAccumulationOnGPU = true
            return VadManager(config: .default, vadModel: try MLModel(contentsOf: bundle.directory, configuration: mlConfig))
        }
    }
}
