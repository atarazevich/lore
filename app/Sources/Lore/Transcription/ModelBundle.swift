import FluidAudio
import Foundation

/// One model the app pins (#269): a fixed Hugging Face commit, the files that
/// make it whole, and the one way it is loaded — download only when incomplete,
/// one `modelLoad` event per attempt, removal only of a bundle that is visibly
/// incomplete. Silero VAD, Nemotron diarization and CAM++ all go through here.
struct ModelBundle: Sendable {
    let repo: Repo
    let revision: String
    /// The bundle's own folder, relative to the repo folder: what an incomplete
    /// download removes.
    let folder: String
    /// Every file the model needs, relative to the repo folder.
    let files: [String]

    /// FluidAudio's own folder for the repo (`…/FluidAudio/Models/<repo>`).
    var repoDirectory: URL { MLModelConfigurationUtils.defaultModelsDirectory(for: repo) }
    var directory: URL { repoDirectory.appendingPathComponent(folder, isDirectory: true) }

    /// `<repo>@<revision>`.
    var identity: String { "\(repo.folderName)@\(revision)" }

    /// Every file present. FluidAudio streams a file into `<file>.partial` and
    /// moves it to its name only once it is whole (`FileDownloader.ensure`,
    /// which also treats a file already at its name as done), so a file at its
    /// name is a whole file, and a missing one is what a cut-off download leaves.
    var isComplete: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: repoDirectory.appendingPathComponent($0).path) }
    }

    /// A download that did not finish (the network, most likely): the model is
    /// not there yet, which says nothing about whether it works.
    struct DownloadFailed: Error {
        let underlying: any Error
    }

    /// Once, at launch, before anything can download: FluidAudio's override
    /// table is a plain process-wide dictionary, so no background task writes it.
    @MainActor
    static func pinAll() {
        for bundle in [SileroVAD.bundle, SpeakerModels.diarizer, SpeakerModels.embedder] {
            ModelRegistry.revisionOverrides[bundle.repo.remotePath] = bundle.revision
        }
    }

    /// Downloads the bundle when it is incomplete, then loads it. Records one
    /// `modelLoad` event, `fromCache` meaning the bundle was already whole.
    func load<Model>(
        _ kind: DiagEvent.ModelKind,
        download: () async throws -> Void,
        load: () async throws -> sending Model
    ) async throws -> sending Model {
        let startedAt = Date()
        let wasComplete = isComplete
        var outcome = DiagEvent.Outcome.failed
        defer {
            DiagStore.record(.modelLoad(
                model: kind, outcome: outcome, seconds: Date().timeIntervalSince(startedAt), fromCache: wasComplete))
        }
        if !wasComplete {
            do {
                try await download()
            } catch {
                throw DownloadFailed(underlying: error)
            }
        }
        do {
            let model = try await load()
            outcome = .ok
            return model
        } catch {
            // A complete model that failed to load (memory pressure, a compile
            // failure) stays; only a visibly incomplete one goes.
            if !isComplete { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }
}
