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
    /// Community-1's folder, `FluidAudio/Models/speaker-diarization` (the
    /// `speaker-diarization-coreml` repo, about 21 MB). It led the Mac's
    /// speaker passes in 3.8.26–3.8.29 and was reverted (#328); nothing loads
    /// it any more, and the phone never had it.
    static let supersededCommunityFolder = MLModelConfigurationUtils.defaultModelsDirectory(for: .diarizer)

    /// `FluidInference/nemotron-3-diarization-coreml` at a commit that holds the
    /// `monolithic/v2` bundles (2026-09-25). The silence embedding sits at the
    /// repo root, next to the bundle folders.
    static let diarizer = ModelBundle(
        repo: .nemotron3Diarization,
        revision: "25a90f97f254428d4b30374b76af9c74fdee8327",
        folder: diarizerFolder,
        files: [ModelNames.Nemotron3.silenceEmbeddingFile] + bundleFiles.map { "\(diarizerFolder)/\($0)" }
    )

    /// The phone's diarizer (#308): the same model as the `c128-split-w8a8`
    /// graph, which runs on the Neural Engine alone (the GPU is not the
    /// phone's in the background), with the projection it needs at the repo
    /// root. FluidAudio pins one revision per repo, so this bundle takes the
    /// Mac diarizer's: `pinAll`'s one entry serves both, and the phone's can
    /// never move the Mac's.
    static let phoneDiarizer = ModelBundle(
        repo: diarizer.repo,
        revision: diarizer.revision,
        folder: "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc",
        files: [ModelNames.Nemotron3.silenceEmbeddingFile, ModelNames.Nemotron3.preEncodeProjectionFile]
            + bundleFiles.map { "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc/\($0)" }
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

    /// The Mac's diarizer, for the meeting pass and `lore transcribe
    /// --speakers`; once it has loaded, Community-1's folder goes (#328).
    static func loadMacDiarizer() async throws -> Nemotron3Diarizer {
        let diarizer = try await loadDiarizer()
        try? FileManager.default.removeItem(at: supersededCommunityFolder)
        return diarizer
    }

    /// The Mac's diarizer by default; the phone's with its bundle, preset and
    /// compute units (#308).
    static func loadDiarizer(
        _ bundle: ModelBundle = diarizer, preset: Nemotron3Config = .offline, computeUnits: MLComputeUnits = .cpuAndGPU
    ) async throws -> Nemotron3Diarizer {
        try await bundle.load(.diarizer) {
            let fm = FileManager.default
            let root = bundle.files.filter { !$0.contains("/") }
                .filter { !fm.fileExists(atPath: bundle.repoDirectory.appendingPathComponent($0).path) }
            if bundle.folder == diarizerFolder {
                // The root listing first: a download into the repo root starts by
                // clearing a folder without its revision marker, the bundle
                // download only its own folder.
                if !root.isEmpty {
                    try await ModelHub.download(
                        bundle.repo, subdirectory: "", to: bundle.repoDirectory, shouldSkip: { !root.contains($0) })
                }
            } else {
                // One by one at the pinned commit: that clearing would take the
                // Mac's bundle beside this one.
                try fm.createDirectory(at: bundle.repoDirectory, withIntermediateDirectories: true)
                for file in root {
                    let url = try ModelRegistry.resolveModel(bundle.repo.remotePath, file, revision: bundle.revision)
                    try await ModelHub.fetchFile(from: url, description: file)
                        .write(to: bundle.repoDirectory.appendingPathComponent(file), options: .atomic)
                }
            }
            try await ModelHub.download(bundle.repo, subdirectory: bundle.folder, to: bundle.repoDirectory)
        } load: {
            // The preset, loaded from the pinned folder under the repo folder,
            // where the root files are.
            var config = preset
            config.modelFileName = bundle.folder
            let models = try await Nemotron3Models.load(
                config: config, directory: bundle.repoDirectory, computeUnits: computeUnits)
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
