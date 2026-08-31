import AppKit
import Foundation
import XCTest
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
    /// What the settings suite a recording gets is named after.
    private let label: String

    var entriesDirectory: URL { root.appendingPathComponent("entries") }
    var audioDirectory: URL { root.appendingPathComponent("audio") }

    init(_ label: String) {
        self.label = label
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

    /// A confirmed recording on this storage: a coordinator with settings of
    /// its own — `startPreBuffer` refuses without them — taken through the
    /// pre-buffer and the hold-confirm. Nothing has been spoken yet; `speak` is
    /// the seam for that, and with no bus wired no microphone is ever opened.
    ///
    /// Callers cross `skipWithoutMicrophone()` first: without the grant the
    /// pre-buffer aborts and the confirm is a no-op.
    func recording(
        backend: (any TranscriptionBackend)? = nil,
        cleanupClient: any CleanupProviding = CleanupClient(),
        clipboard: ClipboardWatcher = ClipboardWatcher(),
        deliver: @escaping DictationDelivery = { _ in Task { true } }
    ) -> DictationCoordinator {
        let coordinator = coordinator(
            backend: backend, cleanupClient: cleanupClient,
            clipboard: clipboard, deliver: deliver
        )
        coordinator.settings = isolatedSettings(label, defaults: defaults)
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        return coordinator
    }

    /// The gesture fixture: a coordinator on this storage that hears nothing,
    /// its own settings, and a `HotkeyManager` installed on the pair. Three
    /// suites had hand-rolled these five lines — `LockedFnHoldTests`,
    /// `DictationPauseTests` and `RecordedHotkeyTests` — and the differences
    /// between the copies were accidental.
    ///
    /// Both halves come back because `HotkeyManager.coordinator` is weak: a
    /// caller holding only the manager would put every gesture through a nil.
    func gestures(
        _ label: String, talkKey: HotkeyKey = .fn, transcript: String = ""
    ) -> (coordinator: DictationCoordinator, settings: AppSettings, hotkeys: HotkeyManager) {
        let settings = isolatedSettings(label, defaults: defaults)
        settings.hotkeyKey = talkKey
        let coordinator = coordinator(backend: StubTranscriptionBackend(transcript: transcript))
        coordinator.settings = settings
        let hotkeys = HotkeyManager()
        hotkeys.install(coordinator: coordinator, settings: settings)
        return (coordinator, settings, hotkeys)
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

/// One copy during a recording, through the door the app uses: the watcher's
/// own poll notices the pasteboard moved and the item lands on the coordinator.
/// Answers whether it arrived, so each caller says what its absence would mean.
@MainActor
func copied(
    _ text: String, onto board: NSPasteboard, into coordinator: DictationCoordinator
) async -> Bool {
    let before = coordinator.items.count
    board.clearContents()
    board.setString(text, forType: .string)
    return await waitUntil { coordinator.items.count == before + 1 }
}

/// A dictation gesture starts behind the microphone-permission gate, and an
/// undetermined status would put a system prompt on the user's screen.
func skipWithoutMicrophone() throws {
    try XCTSkipUnless(
        MicrophonePermission.status == .authorized,
        "a dictation gesture starts behind the microphone-permission gate"
    )
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
