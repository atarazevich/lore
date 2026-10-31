import FluidAudio
import Foundation

/// One model the app pins (#269): a fixed Hugging Face commit, the files that
/// make it whole, and the one way it is loaded — download only when incomplete,
/// one `modelLoad` event per attempt, removal only of a bundle that is visibly
/// incomplete. Silero VAD, Nemotron diarization and CAM++ all go through here.
public struct ModelBundle: Sendable {
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
    public static func pinAll() {
        for (repo, revision) in pins {
            ModelRegistry.revisionOverrides[repo.remotePath] = revision
        }
    }

    /// Every repo the app pins, with its commit.
    static var pins: [Repo: String] {
        var pins: [Repo: String] = [:]
        for bundle in [SileroVAD.bundle, SpeakerModels.diarizer, SpeakerModels.embedder] {
            pins[bundle.repo] = bundle.revision
        }
        pins[.parakeetUltra] = SpeechModel.ultraRevision
        return pins
    }

    /// For the iPhone (#315; the Mac does not read it): the folder holding the
    /// `.fluidaudio-revision` marker of each model the phone downloads, by its
    /// repo's folder name. FluidAudio writes the marker in the subdirectory a
    /// download asks for: Silero VAD's bundle folder, the phone diarizer's
    /// bundle folder, CAM++'s and Parakeet Ultra's repo folder.
    public static var pinnedFolders: [String: URL] {
        var folders: [String: URL] = [:]
        for bundle in [SileroVAD.bundle, SpeakerModels.phoneDiarizer, SpeakerModels.embedder] {
            folders[bundle.repo.folderName] = bundle.directory
        }
        folders[Repo.parakeetUltra.folderName] = MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetUltra)
        return folders
    }

    /// One load per repo folder at a time, across every caller (#276: a
    /// `lore transcribe --speakers` and a meeting's speaker pass both load the
    /// diarizer): two downloads into one folder, or a failed one's removal
    /// under another's download, would leave neither whole. The second caller
    /// waits, then finds the bundle whole and loads it from the cache.
    static let line = LoadLine()

    /// Downloads the bundle when it is incomplete, then loads it. Records one
    /// `modelLoad` event, `fromCache` meaning the bundle was already whole.
    func load<Model>(
        _ kind: DiagEvent.ModelKind,
        download: () async throws -> Void,
        load: () async throws -> sending Model
    ) async throws -> sending Model {
        try await Self.line.enter(repo.folderName)
        defer { Self.line.leave(repo.folderName) }
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

/// Callers of one key go one at a time, in the order they came; others run
/// beside them. `leave` hands the key straight to the next caller waiting. A
/// caller cancelled while it waits leaves the queue and throws, so it never
/// holds the key; one already handed the key keeps it and must `leave`.
final class LoadLine: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let turn: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    /// The keys in use, each with the callers waiting for it.
    private var waiting: [String: [Waiter]] = [:]

    func enter(_ key: String) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (turn: CheckedContinuation<Void, any Error>) in
                // Under the lock, so a cancellation either sees this waiter
                // queued or was already flagged here.
                let now: Bool? = lock.withLock {
                    if Task.isCancelled { return nil }
                    guard waiting[key] != nil else {
                        waiting[key] = []
                        return true
                    }
                    waiting[key]!.append(Waiter(id: id, turn: turn))
                    return false
                }
                switch now {
                case true?: turn.resume()
                case nil: turn.resume(throwing: CancellationError())
                case false?: break
                }
            }
        } onCancel: {
            // Only a waiter still queued: one `leave` took out already has the key.
            let removed = lock.withLock { () -> Waiter? in
                guard let index = waiting[key]?.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting[key]!.remove(at: index)
            }
            removed?.turn.resume(throwing: CancellationError())
        }
    }

    func leave(_ key: String) {
        let next = lock.withLock { () -> Waiter? in
            guard var queue = waiting[key], !queue.isEmpty else {
                waiting[key] = nil
                return nil
            }
            let next = queue.removeFirst()
            waiting[key] = queue
            return next
        }
        next?.turn.resume()
    }
}
