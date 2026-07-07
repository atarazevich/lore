import Foundation
import Observation

/// Shared cache for the transcription backend. Both DictationCoordinator and
/// TranscriptionEngine draw from here so only one instance exists in memory.
///
/// The cache stores a single prepared Parakeet backend. DictationCoordinator
/// uses it directly. TranscriptionEngine can reuse it as its mic backend and
/// creates a second backend for system audio (Parakeet has mutable decoder state).
@MainActor
@Observable
final class SharedBackendCache {
    private(set) var backend: (any TranscriptionBackend)?

    /// In-flight load, if any. Concurrent `prepare()` callers await this same
    /// task instead of each building their own backend (which would double-load
    /// the model — e.g. the launch prewarm racing a real first transcription).
    @ObservationIgnored private var loadTask: Task<any TranscriptionBackend, Error>?

    /// Backend factory — defaults to the production Parakeet backend; injectable
    /// so tests can exercise the dedup without loading a real CoreML model.
    @ObservationIgnored private let makeBackend: @Sendable () -> any TranscriptionBackend

    var isReady: Bool { backend != nil }

    init(makeBackend: @escaping @Sendable () -> any TranscriptionBackend = { ParakeetBackend() }) {
        self.makeBackend = makeBackend
    }

    /// Ensure a backend is prepared. No-op if the cache already holds one;
    /// if a load is already in flight, awaits it rather than starting a second.
    func prepare(
        onStatus: @escaping @Sendable (String) -> Void = { _ in },
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        if backend != nil {
            diagLog("[BACKEND-CACHE] already cached")
            return
        }
        if let loadTask {
            diagLog("[BACKEND-CACHE] awaiting in-flight load")
            _ = try await loadTask.value
            return
        }

        diagLog("[BACKEND-CACHE] loading backend...")
        let make = makeBackend
        let task = Task { () throws -> any TranscriptionBackend in
            let newBackend = make()
            try await newBackend.prepare(onStatus: onStatus, onProgress: onProgress)
            return newBackend
        }
        loadTask = task
        defer { loadTask = nil }
        backend = try await task.value
        diagLog("[BACKEND-CACHE] backend ready")
    }
}
