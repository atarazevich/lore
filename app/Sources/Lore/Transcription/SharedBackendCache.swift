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

    var isReady: Bool { backend != nil }

    /// Ensure a backend is prepared. No-op if the cache already holds one.
    func prepare(
        onStatus: @Sendable (String) -> Void = { _ in },
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard backend == nil else {
            diagLog("[BACKEND-CACHE] already cached")
            return
        }

        diagLog("[BACKEND-CACHE] loading backend...")
        let newBackend = ParakeetBackend()
        try await newBackend.prepare(onStatus: onStatus, onProgress: onProgress)

        self.backend = newBackend
        diagLog("[BACKEND-CACHE] backend ready")
    }
}
