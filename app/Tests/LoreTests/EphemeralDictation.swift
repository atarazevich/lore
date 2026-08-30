import Foundation
@testable import LoreKit

/// Dictation storage nobody else can see: a temp directory holding the
/// per-entry JSON and the audio beside it, and its own `UserDefaults` suite.
///
/// Three test classes had grown near-verbatim copies of this —
/// `DictationDurabilityTests`, `DictationPauseTests` and `DictationRetryTests`
/// — and the fourth would have been another. Nothing here is new behaviour;
/// each helper is one of those copies, kept in the form the majority already
/// used.
///
/// It owns its own cleanup, which the copy in `DictationRetryTests` did not: it
/// built a temp directory per coordinator and never removed one.
@MainActor
final class EphemeralDictation {
    /// The directory the two below live in — held so `tearDown` can take the
    /// whole thing, and because a test that wants a third path wants it here.
    let root: URL
    /// The suite the history writes its migration state to, and the one a
    /// test's `isolatedSettings` should share so both read one machine.
    let defaults: UserDefaults

    private let suiteName: String

    var entriesDirectory: URL { root.appendingPathComponent("entries") }
    var audioDirectory: URL { root.appendingPathComponent("audio") }

    init(_ label: String) {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        suiteName = "com.lore.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// A store over these directories. Built a second time it is the store the
    /// *next launch* would build over the same files, which is how the #182
    /// durability tests read back what a kill left behind.
    func history() -> DictationHistory {
        DictationHistory(
            defaults: defaults, entriesDirectory: entriesDirectory, audioDirectory: audioDirectory
        )
    }

    /// A coordinator on that storage with no audio bus wired: every gesture path
    /// runs and no microphone is ever opened. `appendCapturedSamples` is the seam
    /// the real capture loop goes through — `speak` drives it.
    ///
    /// Settings are deliberately not wired here: a coordinator with none behaves
    /// differently from one with an empty key, and which of the two a test wants
    /// is the test's business.
    ///
    /// `deliver` answers "posted" and touches nothing: the real one presses
    /// Cmd+V into whatever the developer has in front of them, so a test that
    /// runs the pipeline past transcription has to hand its own in (#211).
    func coordinator(
        backend: (any TranscriptionBackend)? = nil,
        cleanupClient: any CleanupProviding = CleanupClient(),
        clipboard: ClipboardWatcher = ClipboardWatcher(),
        deliver: @escaping DictationDelivery = { _ in Task { true } }
    ) -> DictationCoordinator {
        DictationCoordinator(
            history: history(), cleanupClient: cleanupClient,
            backend: backend, clipboard: clipboard, deliver: deliver
        )
    }

    func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    var audioFiles: [String] { files(in: audioDirectory) }
    var entryFiles: [String] { files(in: entriesDirectory) }

    /// The size of the first audio file on disk, which is the only one these
    /// tests ever have while they are watching it grow.
    var audioBytes: Int? {
        guard let name = audioFiles.first,
              let attributes = try? FileManager.default.attributesOfItem(
                  atPath: audioDirectory.appendingPathComponent(name).path
              ) else { return nil }
        return attributes[.size] as? Int
    }

    /// The capture queue writes off the main actor — wait for the samples to
    /// land rather than assuming they have.
    func waitForSamplesOnDisk(_ count: Int) async -> Bool {
        await waitUntil { self.audioBytes == count * MemoryLayout<Float>.size }
    }
}

/// One buffer of speech, through the seam the real capture loop goes through.
@MainActor
func speak(_ coordinator: DictationCoordinator, samples: Int) {
    guard samples > 0 else { return }
    coordinator.appendCapturedSamples([Float](repeating: 0.05, count: samples))
}

/// Reading the shared diagnostic store as a delta: what a test's own actions put
/// into it, and nothing the test before it left there.
@MainActor
enum DiagStream {
    /// Distinct build numbers for the fences below, so no two can collide —
    /// deterministically, so a rerun repeats exactly.
    private static var nextFenceBuild = 0

    /// Fence, then mark. Identical consecutive events share one record (#149),
    /// so without the fence a test's first event could fold into the previous
    /// test's last one and become invisible behind the mark.
    static func mark() -> Int {
        nextFenceBuild += 1
        DiagStore.record(.appLaunched(build: nextFenceBuild))
        return DiagStore.shared.recent(DiagStore.capacity).count
    }

    static func events(since mark: Int) -> [DiagEvent] {
        Array(DiagStore.shared.recent(DiagStore.capacity).dropFirst(mark)).occurrenceEvents
    }
}
