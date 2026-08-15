import Foundation
import Observation
import os

private let cacheLog = Logger(subsystem: "com.lore.app", category: "SharedBackendCache")

/// One prepared Parakeet instance, loaded once and handed to every caller that
/// asks for it. Authority: `docs/decisions.md` 2026-08-15 (#169).
@MainActor
@Observable
final class SharedBackendCache {
    private var backend: (any TranscriptionBackend)?

    /// In-flight load, if any — later callers await this task instead of
    /// building a second backend.
    @ObservationIgnored private var loadTask: Task<any TranscriptionBackend, Error>?

    /// Status/progress handlers of every caller waiting on the current load,
    /// cleared when it ends — a joining caller has to hear the download too,
    /// or its meeting sits on a frozen "Loading…" (#169).
    @ObservationIgnored private var statusHandlers: [@MainActor @Sendable (String) -> Void] = []
    @ObservationIgnored private var progressHandlers: [@MainActor @Sendable (Double) -> Void] = []

    /// Injectable so tests exercise the dedup without a real CoreML load.
    @ObservationIgnored private let makeBackend: @Sendable () -> any TranscriptionBackend

    var isReady: Bool { backend != nil }

    init(makeBackend: @escaping @Sendable () -> any TranscriptionBackend = { ParakeetBackend() }) {
        self.makeBackend = makeBackend
    }

    /// The prepared backend, loading it once.
    ///
    /// Records one ASR `modelLoad` event per call — a cold load for the caller
    /// that ran it, a hit for everyone served without loading. A load that
    /// fails is recorded once, by the caller that ran it: the callers that
    /// joined it inherit the error, not a second event for the same failure.
    @discardableResult
    func prepare(
        onStatus: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onProgress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
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
