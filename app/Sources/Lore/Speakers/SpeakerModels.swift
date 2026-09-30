import CoreML
import FluidAudio
import Foundation

/// The speaker pass's two models (#269), pinned through `ModelBundle`.
///
/// - Nemotron-3 diarization, `offline` preset, from the `monolithic/v2`
///   re-export FluidAudio 0.17.4 loads; on the GPU, the preset's documented
///   target and the configuration the ear test (experiments/diarization) ran.
///   FluidAudio's `loadFromHuggingFace` is not used: it treats the one
///   `coremldata.bin` as the whole bundle and deletes the cache when its own
///   weights marker is absent.
/// - CAM++ speaker embedding, FluidAudio's own loader and compute units.
enum SpeakerModels {
    private static let bundleFiles = [
        "coremldata.bin", "analytics/coremldata.bin", "model.mil", "weights/weight.bin",
    ]

    static let diarizerFolder = "monolithic/v2/Nemotron3Diarizer_offline.mlmodelc"
    /// What FluidAudio 0.17.1 loaded; superseded by `diarizerFolder`.
    static let supersededDiarizerFolder = "monolithic/Nemotron3Diarizer_offline.mlmodelc"

    /// `FluidInference/nemotron-3-diarization-coreml` at a commit that holds the
    /// `monolithic/v2` bundles (2026-09-25). The silence embedding sits at the
    /// repo root, next to the bundle folders.
    static let diarizer = ModelBundle(
        repo: .nemotron3Diarization,
        revision: "25a90f97f254428d4b30374b76af9c74fdee8327",
        folder: diarizerFolder,
        files: [ModelNames.Nemotron3.silenceEmbeddingFile] + bundleFiles.map { "\(diarizerFolder)/\($0)" }
    )

    /// `FluidInference/campplus-coreml` (2026-09-25).
    static let embedder = ModelBundle(
        repo: .campPlus,
        revision: "321b18e270a4e19e69ef4a13d179b4eac07cec6a",
        folder: "",
        files: [ModelNames.CampPlus.preprocessorFile, ModelNames.CampPlus.modelFile].flatMap { model in
            bundleFiles.map { "\(model)/\($0)" }
        }
    )

    static func loadDiarizer() async throws -> Nemotron3Diarizer {
        let bundle = diarizer
        return try await bundle.load(.diarizer) {
            let silence = ModelNames.Nemotron3.silenceEmbeddingFile
            // The root listing first: a download into the repo root starts by
            // clearing a folder without its revision marker, the bundle
            // download only its own folder.
            if !FileManager.default.fileExists(atPath: bundle.repoDirectory.appendingPathComponent(silence).path) {
                try await ModelHub.download(
                    bundle.repo, subdirectory: "", to: bundle.repoDirectory, shouldSkip: { $0 != silence })
            }
            try await ModelHub.download(bundle.repo, subdirectory: diarizerFolder, to: bundle.repoDirectory)
        } load: {
            // The preset, loaded from the pinned folder under the repo folder,
            // where the silence embedding is.
            var config = Nemotron3Config.offline
            config.modelFileName = diarizerFolder
            let models = try await Nemotron3Models.load(
                config: config, directory: bundle.repoDirectory, computeUnits: .cpuAndGPU)
            // Ours, 190 MB, and never read again once the v2 bundle is whole.
            try? FileManager.default.removeItem(at: bundle.repoDirectory.appendingPathComponent(supersededDiarizerFolder))
            return Nemotron3Diarizer(config: config, models: models)
        }
    }

    static func loadEmbedder() async throws -> CampPlusEmbedder {
        let bundle = embedder
        return try await bundle.load(.voiceprint) {
            try await ModelHub.download(bundle.repo, to: bundle.repoDirectory.deletingLastPathComponent())
        } load: {
            CampPlusEmbedder(models: try CampPlusModels.load(from: bundle.repoDirectory))
        }
    }
}
