import Foundation
import Observation
import os

private let cacheLog = Logger(subsystem: "com.lore.app", category: "SharedBackendCache")

/// Shared cache for the transcription backend. Both DictationCoordinator and
/// TranscriptionEngine draw from here so only one instance exists in memory.
///
/// The cache stores a single prepared Parakeet backend and is the only place
/// the meeting's mic leg and dictation's model download may come from — asking
/// it is what keeps a meeting started during the launch warm-up from pulling a
/// second copy of the model into memory (#169).
///
/// It also owns the ASR `modelLoad` diagnostic for every load it serves, so a
/// cold load and a cache hit stay distinguishable in `events.json` and callers
/// never record a second event for the same load.
@MainActor
@Observable
final class SharedBackendCache {
    private(set) var backend: (any TranscriptionBackend)?

    /// In-flight load, if any. Concurrent `prepare()` callers await this same
    /// task instead of each building their own backend (which would double-load
    /// the model — e.g. the launch prewarm racing a real first transcription).
    @ObservationIgnored private var loadTask: Task<any TranscriptionBackend, Error>?

    /// Status/progress handlers of every caller waiting on the in-flight load.
    /// A caller that joins an existing load has to hear it too, or the meeting
    /// it started sits on a frozen "Loading…" line for the whole download (#169).
    /// Cleared when the load ends — they only ever describe the current one.
    @ObservationIgnored private var statusHandlers: [@Sendable (String) -> Void] = []
    @ObservationIgnored private var progressHandlers: [@Sendable (Double) -> Void] = []

    /// Backend factory — defaults to the production Parakeet backend; injectable
    /// so tests can exercise the dedup without loading a real CoreML model.
    @ObservationIgnored private let makeBackend: @Sendable () -> any TranscriptionBackend

    var isReady: Bool { backend != nil }

    init(makeBackend: @escaping @Sendable () -> any TranscriptionBackend = { ParakeetBackend() }) {
        self.makeBackend = makeBackend
    }

    /// The prepared backend, loading it once. A caller arriving during a load
    /// joins it instead of starting a second, and gets its status and progress
    /// while it waits.
    ///
    /// Records exactly one ASR `modelLoad` event per call: a cold load for the
    /// caller that performed it, a cache hit for everyone the cache served
    /// without loading.
    @discardableResult
    func prepare(
        onStatus: @escaping @Sendable (String) -> Void = { _ in },
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> any TranscriptionBackend {
        if let backend {
            DiagStore.record(.modelLoad(model: .asr, outcome: .ok, seconds: 0, fromCache: true))
            cacheLog.debug("already cached")
            return backend
        }
        if let loadTask {
            cacheLog.debug("awaiting in-flight load")
            statusHandlers.append(onStatus)
            progressHandlers.append(onProgress)
            let joined = try await loadTask.value
            // No loading was done by this caller — the same fact a hit reports,
            // and the health surface needs it to hear that ASR came up (#151).
            DiagStore.record(.modelLoad(model: .asr, outcome: .ok, seconds: 0, fromCache: true))
            return joined
        }

        cacheLog.debug("loading backend")
        let startedAt = Date()
        statusHandlers = [onStatus]
        progressHandlers = [onProgress]
        let make = makeBackend
        let task = Task { [weak self] () throws -> any TranscriptionBackend in
            let newBackend = make()
            try await newBackend.prepare(
                onStatus: { status in Task { @MainActor in self?.emit(status: status) } },
                onProgress: { fraction in Task { @MainActor in self?.emit(progress: fraction) } }
            )
            return newBackend
        }
        loadTask = task
        defer {
            loadTask = nil
            statusHandlers = []
            progressHandlers = []
        }
        let loaded: any TranscriptionBackend
        do {
            loaded = try await task.value
        } catch {
            DiagStore.record(.modelLoad(
                model: .asr,
                outcome: .failed,
                seconds: Date().timeIntervalSince(startedAt),
                fromCache: false
            ))
            cacheLog.error("backend load failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
        backend = loaded
        DiagStore.record(.modelLoad(
            model: .asr,
            outcome: .ok,
            seconds: Date().timeIntervalSince(startedAt),
            fromCache: false
        ))
        return loaded
    }

    private func emit(status: String) {
        for handler in statusHandlers { handler(status) }
    }

    private func emit(progress: Double) {
        for handler in progressHandlers { handler(progress) }
    }
}
