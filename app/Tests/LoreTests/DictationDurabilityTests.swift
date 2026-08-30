import AVFoundation
import XCTest
@testable import LoreKit

/// #182: what the user said is on disk while they are still saying it, and a
/// gesture that never became a dictation leaves nothing at all.
///
/// The gestures below run with no audio bus wired, so no microphone is ever
/// opened; `appendCapturedSamples` is the seam the real capture loop goes
/// through, driven here with synthetic buffers.
@MainActor
final class DictationDurabilityTests: XCTestCase {

    private var storage: EphemeralDictation!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = EphemeralDictation("DictationDurabilityTests")
        // The gesture starts behind the microphone-permission gate, and an
        // undetermined status would put a system prompt on the user's screen.
        try XCTSkipUnless(
            MicrophonePermission.status == .authorized,
            "dictation gestures need microphone permission already granted"
        )
    }

    override func tearDown() {
        storage.tearDown()
        storage = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeCoordinator(backend: (any TranscriptionBackend)? = nil) -> DictationCoordinator {
        let coordinator = storage.coordinator(backend: backend)
        coordinator.settings = isolatedSettings("DictationDurabilityTests", defaults: storage.defaults)
        return coordinator
    }

    /// Transcribes to nothing, so the pipeline stops at its empty-result branch
    /// — before the paste, which would type into whatever the user has in front
    /// of them right now.
    private final class SilentBackend: TranscriptionBackend, @unchecked Sendable {
        func checkStatus() -> BackendStatus { .ready }
        func prepare(
            onStatus: @Sendable (String) -> Void,
            onProgress: @escaping @Sendable (Double) -> Void
        ) async throws {}
        func transcribe(_ samples: [Float], previousContext: String?) async throws -> String { "" }
    }

    // MARK: - The window this closes

    func testKillMidSpeechLeavesTheDictationRecoverable() async throws {
        let coordinator = makeCoordinator()
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        speak(coordinator, samples: 20_000) // 1.25s of a locked recording still running

        let onDisk = await storage.waitForSamplesOnDisk(20_000)
        XCTAssertTrue(onDisk)

        // The kill: nothing stops the recording, nothing finalizes it. What the
        // next launch finds is a fresh store over the same directories.
        let recovered = storage.history()

        XCTAssertEqual(recovered.entries.count, 1)
        let entry = try XCTUnwrap(recovered.entries.first)
        XCTAssertEqual(entry.status, .audioSaved, "the shape the retry button already knows")
        XCTAssertTrue(entry.hasAudio)
        // Duration is the one field the start could not know — read back from
        // the audio, so the row doesn't say 0:00 over a minute of speech.
        XCTAssertEqual(entry.durationSeconds, 1.25, accuracy: 0.001)
        let samples = recovered.loadAudio(filename: try XCTUnwrap(entry.audioFilename))
        XCTAssertEqual(samples?.count, 20_000)
        XCTAssertEqual(samples?.first, 0.05)
    }

    func testRecordingInProgressIsNeverOfferedForRetry() async {
        let coordinator = makeCoordinator()
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        speak(coordinator, samples: 20_000)

        let onDisk = await storage.waitForSamplesOnDisk(20_000)
        XCTAssertTrue(onDisk)

        // Both files are on disk from the first buffer — and the entry is
        // deliberately absent from the list the history UI (and its retry
        // button) reads: a file that is still growing has nothing to retry.
        XCTAssertEqual(storage.entryFiles.count, 1)
        XCTAssertTrue(coordinator.history.entries.isEmpty)
    }

    // MARK: - Nothing left behind

    func testTapNeverReachesDisk() {
        let coordinator = makeCoordinator()
        coordinator.startPreBuffer()
        speak(coordinator, samples: 20_000) // pre-buffer audio: not a dictation yet
        coordinator.cancelPreBuffer()

        XCTAssertEqual(storage.audioFiles, [])
        XCTAssertEqual(storage.entryFiles, [])
        XCTAssertTrue(storage.history().entries.isEmpty)
    }

    func testDiscardWhileRecordingLeavesNothingBehind() async {
        let coordinator = makeCoordinator()
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        speak(coordinator, samples: 20_000)
        let onDisk = await storage.waitForSamplesOnDisk(20_000)
        XCTAssertTrue(onDisk, "it really was on disk before Esc")

        coordinator.discardRecording()

        XCTAssertEqual(storage.audioFiles, [])
        XCTAssertEqual(storage.entryFiles, [])
        XCTAssertTrue(storage.history().entries.isEmpty)
    }

    func testSlipUnderHalfASecondLeavesNothingBehind() async {
        let coordinator = makeCoordinator()
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        speak(coordinator, samples: 4_000) // 0.25s — dropped, as it always was
        let onDisk = await storage.waitForSamplesOnDisk(4_000)
        XCTAssertTrue(onDisk)

        coordinator.stopRecording()
        let settled = await waitUntil { coordinator.state == .idle }
        XCTAssertTrue(settled)

        XCTAssertEqual(storage.audioFiles, [])
        XCTAssertEqual(storage.entryFiles, [])
        XCTAssertTrue(storage.history().entries.isEmpty)
    }

    // MARK: - The finished dictation

    func testFinishedRecordingAdoptsTheFileItWasWrittenTo() async throws {
        let coordinator = makeCoordinator(backend: SilentBackend())
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        speak(coordinator, samples: 20_000)

        coordinator.stopRecording()
        // The empty transcript is where the pipeline settles here, short of paste.
        let landed = await waitUntil { coordinator.history.entries.first?.status == .failed }
        XCTAssertTrue(landed)

        let entry = try XCTUnwrap(coordinator.history.entries.first)
        XCTAssertEqual(storage.audioFiles.count, 1, "release copies nothing — the audio is already there")
        XCTAssertEqual(entry.audioFilename, storage.audioFiles.first)
        XCTAssertEqual(storage.entryFiles, ["\(entry.id.uuidString).json"])
        XCTAssertEqual(entry.durationSeconds, 1.25, accuracy: 0.001)
        XCTAssertEqual(coordinator.history.loadAudio(filename: try XCTUnwrap(entry.audioFilename))?.count, 20_000)
    }

    /// The tail-cut hand-off (#104): a new press ends the previous recording
    /// mid-tail and its pipeline picks the recording up from there. Both
    /// dictations keep their own audio, and neither strands a file.
    func testNewPressMidTailKeepsBothRecordings() async throws {
        let coordinator = makeCoordinator(backend: SilentBackend())
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        speak(coordinator, samples: 20_000)
        coordinator.stopRecording()
        try await Task.sleep(for: .milliseconds(100)) // the pipeline reaches its 300ms tail

        coordinator.startPreBuffer() // cuts the tail, parking the recording
        coordinator.confirmRecording()
        speak(coordinator, samples: 24_000)
        coordinator.stopRecording()

        let bothLanded = await waitUntil { coordinator.history.entries.count == 2 }
        XCTAssertTrue(bothLanded)
        XCTAssertEqual(storage.audioFiles.count, 2)
        let durations = coordinator.history.entries.map(\.durationSeconds).sorted()
        XCTAssertEqual(durations, [1.25, 1.5])
        for entry in coordinator.history.entries {
            let name = try XCTUnwrap(entry.audioFilename)
            XCTAssertEqual(
                coordinator.history.loadAudio(filename: name)?.count,
                Int(entry.durationSeconds * 16000)
            )
        }
    }
}
