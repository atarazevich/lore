import Foundation
import os

private let upgradeLog = Logger(subsystem: "com.lore.app", category: "SpeechModelUpgrade")

/// The way from Parakeet v3 to Parakeet Ultra on a Mac that updated (#299),
/// run once per launch after the warm-up.
///
/// v3 keeps transcribing throughout. Ultra is downloaded and compiled here
/// and nowhere else — every other load asks `SpeechModelFiles`, which answers
/// v3 until the swap — by one load whose instance is released at once: what
/// stays is the compiled cache. At a moment nothing records or transcribes,
/// one instance per cache is built from that cache, quickly, and if it is
/// still quiet once they are ready, every cache serves Ultra; otherwise they
/// are dropped and a later quiet stretch tries again. A quiet moment is a
/// stretch of `quietStretch` with nothing found running at any poll, and at
/// most `buildAttempts` builds are made per launch, so a Mac in steady use
/// does not load Ultra over and over: it switches on a later launch. No Ultra instance is
/// held through a meeting or a take. A take or a meeting already under way
/// holds its v3 instance and finishes on it. v3's folders go at the next
/// launch (`SpeechModelFiles.removeSuperseded`), before anything can read them.
///
/// Ultra that cannot download or load (offline, say) changes nothing: v3
/// stays, the attempt is traced, and the next launch tries again, resuming the
/// download where it stopped. Nothing is shown — dictation works.
@MainActor
public struct SpeechModelUpgrade {
    let files: SpeechModelFiles
    /// Every cache that serves the speech model. Each gets its own successor,
    /// as each holds its own instance today.
    let caches: [SharedBackendCache]
    /// Nothing is recording or transcribing anywhere.
    let isQuiet: @MainActor () -> Bool
    /// Right after the swap: whatever else holds the old model lets it go.
    let didSwap: @MainActor () -> Void
    var makeBackend: @Sendable (SpeechModel) -> any TranscriptionBackend = { ParakeetBackend(model: $0) }
    var pollInterval: Duration = .seconds(2)
    var quietStretch: Duration = .seconds(60)
    var buildAttempts = 3

    public func run() async {
        guard files.working == .parakeetV3, await prepare(count: 1) != nil else { return }
        for _ in 0..<buildAttempts {
            guard await quietMoment() else { return }
            let evictions = caches.map(\.evictions)
            guard let successors = await prepare(count: caches.count) else { return }
            if isQuiet(), SharedBackendCache.install(Array(zip(caches, successors)), evictions: evictions) {
                let remembered = files.adoptUltra()
                didSwap()
                DiagStore.record(.speechModelSwapped(remembered: remembered))
                return
            }
        }
    }

    /// `count` Ultra instances, or nil when one could not be built. Traced:
    /// the first call downloads and compiles, a later one loads compiled.
    private func prepare(count: Int) async -> [any TranscriptionBackend]? {
        let startedAt = Date()
        var built: [any TranscriptionBackend] = []
        do {
            for _ in 0..<count {
                let backend = makeBackend(.parakeetUltra)
                try await backend.prepare(onStatus: { _ in })
                built.append(backend)
            }
        } catch {
            upgradeLog.error("next speech model not ready: \(error.localizedDescription, privacy: .private)")
        }
        let ready = built.count == count
        DiagStore.record(.speechModelPrepared(
            model: .parakeetUltra, outcome: ready ? .ok : .failed, seconds: Date().timeIntervalSince(startedAt)))
        return ready ? built : nil
    }

    /// The end of a `quietStretch` in which every poll found nothing
    /// recording or transcribing; false when cancelled.
    private func quietMoment() async -> Bool {
        let clock = ContinuousClock()
        var quietSince = clock.now
        while clock.now - quietSince < quietStretch {
            do { try await Task.sleep(for: pollInterval) } catch { return false }
            if !isQuiet() { quietSince = clock.now }
        }
        return true
    }
}

extension SpeechModelUpgrade {
    /// The app's upgrade: every other field keeps its default.
    public init(
        files: SpeechModelFiles,
        caches: [SharedBackendCache],
        isQuiet: @escaping @MainActor () -> Bool,
        didSwap: @escaping @MainActor () -> Void
    ) {
        self.init(files: files, caches: caches, isQuiet: isQuiet, didSwap: didSwap, buildAttempts: 3)
    }
}
