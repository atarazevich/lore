import Foundation
import Observation

/// Shared cache for transcription backends. Both DictationCoordinator and
/// TranscriptionEngine draw from here so only one instance per model exists
/// in memory.
///
/// The cache stores a single prepared backend. DictationCoordinator uses it
/// directly. TranscriptionEngine can reuse it as its mic backend and creates
/// a second backend for system audio (Parakeet has mutable decoder state).
@MainActor
@Observable
final class SharedBackendCache {
    private(set) var backend: (any TranscriptionBackend)?
    private(set) var model: TranscriptionModel?

    var isReady: Bool { backend != nil }

    /// Ensure a backend is prepared for the given model.
    /// No-op if the cache already holds a matching backend.
    func prepare(
        model: TranscriptionModel,
        onStatus: @Sendable (String) -> Void = { _ in },
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard self.model != model || backend == nil else {
            diagLog("[BACKEND-CACHE] already cached \(model.rawValue)")
            return
        }

        diagLog("[BACKEND-CACHE] loading \(model.rawValue)...")
        let newBackend = model.makeBackend()
        try await newBackend.prepare(onStatus: onStatus, onProgress: onProgress)

        self.backend = newBackend
        self.model = model
        diagLog("[BACKEND-CACHE] \(model.rawValue) ready")
    }

    /// Discard the cached backend to free memory.
    func invalidate() {
        backend = nil
        model = nil
        diagLog("[BACKEND-CACHE] invalidated")
    }
}
