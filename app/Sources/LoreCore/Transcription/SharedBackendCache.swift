import Foundation
import Observation
import os

private let cacheLog = Logger(subsystem: "com.lore.app", category: "SharedBackendCache")

/// One prepared speech-model instance, loaded once and handed to every caller
/// that asks for it. Authority: `docs/decisions.md` 2026-08-15 (#169); swapped
/// for its successor only through `install` (#299), dropped only through
/// `evict` (#186).
@MainActor
@Observable
public final class SharedBackendCache {
    private var backend: (any TranscriptionBackend)?

    /// One load and the callers waiting on it. The handlers belong to the
    /// load, not the cache: a joining caller has to hear the download too, or
    /// its meeting sits on a frozen "Loading…" (#169), and it keeps hearing it
    /// after an eviction disowns the load (#186).
    @MainActor private final class Load {
        var task: Task<any TranscriptionBackend, Error>?
        var statusHandlers: [@MainActor @Sendable (String) -> Void] = []
        var progressHandlers: [@MainActor @Sendable (Double) -> Void] = []
    }

    /// The load later callers join instead of building a second backend.
    @ObservationIgnored private var load: Load?

    /// A load an eviction disowned, while it may still run. The next load
    /// waits for it: two loads never write into one model folder.
    @ObservationIgnored private var disowned: Task<any TranscriptionBackend, Error>?

    /// How many times this cache was evicted: an instance built before an
    /// eviction may come from deleted files, and `install` refuses it.
    @ObservationIgnored private(set) var evictions = 0

    /// Injectable so tests exercise the dedup without a real CoreML load.
    @ObservationIgnored private let makeBackend: @Sendable () -> any TranscriptionBackend

    public var isReady: Bool { backend != nil }

    /// Callers waiting on the current load, its owner included: lets a test
    /// act only once a caller has really joined.
    var loadWaiters: Int { load?.statusHandlers.count ?? 0 }

    public init(makeBackend: @escaping @Sendable () -> any TranscriptionBackend = { ParakeetBackend() }) {
        self.makeBackend = makeBackend
    }

    /// The prepared backend, loading it once.
    ///
    /// Records one ASR `modelLoad` event per call — a cold load for the caller
    /// that ran it, a hit for everyone served without loading. A load that
    /// fails is recorded once, by the caller that ran it: the callers that
    /// joined it inherit the error, not a second event for the same failure.
    @discardableResult
    public func prepare(
        onStatus: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onProgress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws -> any TranscriptionBackend {
        if let backend {
            DiagStore.record(.modelLoad(
                model: .asr, outcome: .ok, seconds: 0, fromCache: true, speechModel: backend.speechModel))
            cacheLog.debug("already cached")
            return backend
        }
        if let load, let task = load.task {
            cacheLog.debug("awaiting in-flight load")
            load.statusHandlers.append(onStatus)
            load.progressHandlers.append(onProgress)
            let joined = try await task.value
            DiagStore.record(.modelLoad(
                model: .asr, outcome: .ok, seconds: 0, fromCache: true, speechModel: joined.speechModel))
            return joined
        }

        cacheLog.debug("loading backend")
        let startedAt = Date()
        let current = Load()
        current.statusHandlers = [onStatus]
        current.progressHandlers = [onProgress]
        let newBackend = makeBackend()
        let predecessor = disowned
        let task = Task { [weak self] () throws -> any TranscriptionBackend in
            if let predecessor {
                cacheLog.debug("waiting for the evicted load to end")
                _ = try? await predecessor.value
                if self?.disowned == predecessor { self?.disowned = nil }
            }
            try await newBackend.prepare(
                onStatus: { status in Task { @MainActor in current.statusHandlers.forEach { $0(status) } } },
                onProgress: { fraction in Task { @MainActor in current.progressHandlers.forEach { $0(fraction) } } }
            )
            return newBackend
        }
        current.task = task
        load = current
        // Still this cache's load, not disowned by an eviction meanwhile.
        defer {
            if load === current { load = nil }
            if disowned == task { disowned = nil }
        }
        let loaded: any TranscriptionBackend
        do {
            loaded = try await task.value
        } catch {
            DiagStore.record(.modelLoad(
                model: .asr,
                outcome: .failed,
                seconds: Date().timeIntervalSince(startedAt),
                fromCache: false,
                speechModel: newBackend.speechModel
            ))
            cacheLog.error("backend load failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
        // Evicted while loading: the files it read may be gone. Its callers
        // use it for the work they asked it for; the cache does not keep it.
        if load === current { backend = loaded }
        DiagStore.record(.modelLoad(
            model: .asr,
            outcome: .ok,
            seconds: Date().timeIntervalSince(startedAt),
            fromCache: false,
            speechModel: loaded.speechModel
        ))
        return loaded
    }

    /// Each cache serves its successor from now on, all or none (#299): none
    /// while any of them has a load in flight, whose result would land on top,
    /// and none once any was evicted since `evictions` was read for it, before
    /// the successors were built — they may come from deleted files (#186).
    /// A caller already holding an old instance keeps it to the end of its work.
    static func install(
        _ successors: [(cache: SharedBackendCache, backend: any TranscriptionBackend)],
        evictions: [Int]
    ) -> Bool {
        guard successors.count == evictions.count,
              zip(successors, evictions).allSatisfy({ $0.cache.load == nil && $0.cache.evictions == $1 })
        else { return false }
        for successor in successors { successor.cache.backend = successor.backend }
        return true
    }

    /// Serves nothing from now on (#186): called when the model's files are
    /// deleted, so the next `prepare` loads again — one download, joined by
    /// every caller of this cache. A load in flight is disowned: its callers
    /// still get its instance and its progress, the cache does not keep it,
    /// and the next load starts only after it ends. Like `install`, a caller
    /// already holding an instance keeps it to the end of its work: a
    /// dictation mid-transcription finishes.
    public func evict() {
        evictions += 1
        backend = nil
        if let task = load?.task { disowned = task }
        load = nil
    }
}
