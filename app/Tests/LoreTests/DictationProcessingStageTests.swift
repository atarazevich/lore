import XCTest
@testable import LoreKit

/// The bubble's working sentence names the stage that is actually running
/// (owner, 2026-08-31: "when it is being processed, you have transcription,
/// and if the translate modifier is on, then the word transcription keeps
/// hanging there all the time. But in fact this transcription is done
/// quickly, and then translating happens. Could it show an appropriate
/// state?"). It used to read "Transcribing" for the whole pipeline, including
/// the LLM call that runs after the ASR call is already done.
@MainActor
final class DictationProcessingStageTests: XCTestCase {

    // MARK: - The pure selection logic

    /// Recording and idle show nothing here regardless of stage — the working
    /// sentence exists only for the pipeline that runs after the key releases.
    func testRecordingAndIdleShowNoWorkingSentenceRegardlessOfStage() {
        for stage: UpgradeAction? in [nil, .cleanup, .translate] {
            XCTAssertNil(DictationIndicatorView.workingLabel(for: .recording, llmStage: stage))
            XCTAssertNil(DictationIndicatorView.workingLabel(for: .idle, llmStage: stage))
        }
    }

    /// The model download never reads a stage — nothing runs the LLM step
    /// before a model exists to transcribe with.
    func testDownloadingModelIgnoresStage() {
        for stage: UpgradeAction? in [nil, .cleanup, .translate] {
            XCTAssertEqual(
                DictationIndicatorView.workingLabel(for: .loadingModel, llmStage: stage),
                "Downloading model\u{2026}"
            )
        }
    }

    /// The bug this fix corrects: `.processing`/`.done` with no stage is the
    /// ASR call (or a raw dictation with no LLM step at all) and still reads
    /// "Transcribing" — but once `llmStage` names the LLM call, the sentence
    /// says which one, in the same ellipsis style `Downloading model…` set.
    func testProcessingNamesTheActualStage() {
        for state: DictationState in [.processing, .done] {
            XCTAssertEqual(DictationIndicatorView.workingLabel(for: state, llmStage: nil), "Transcribing")
            XCTAssertEqual(
                DictationIndicatorView.workingLabel(for: state, llmStage: .cleanup), "Cleaning up\u{2026}"
            )
            XCTAssertEqual(
                DictationIndicatorView.workingLabel(for: state, llmStage: .translate), "Translating\u{2026}"
            )
        }
    }

    // MARK: - The coordinator actually sets it

    private var storage: EphemeralDictation!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = EphemeralDictation("DictationProcessingStageTests")
        // The gesture starts behind the microphone-permission gate, and an
        // undetermined status would put a system prompt on the user's screen
        // (same gate `DictationDurabilityTests` uses for the live pipeline).
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

    /// Captures `coordinator.llmStage` at the instant the LLM call is made —
    /// the moment the bubble's sentence must already have moved off
    /// "Transcribing". The call runs on the coordinator's own MainActor turn
    /// (this stub does no real network hop), so the read is race-free: it
    /// observes exactly what `stopRecording`/`retryTranscription` set a
    /// statement earlier in the same synchronous chain.
    @MainActor
    private final class StageCapturingCleanupClient: CleanupProviding, @unchecked Sendable {
        weak var coordinator: DictationCoordinator?
        private(set) var called = false
        private(set) var stageSeen: UpgradeAction?

        func cleanup(rawText: String, prompt: String, apiKey: String) async throws -> String {
            called = true
            stageSeen = coordinator?.llmStage
            return "Cleaned: \(rawText)"
        }
    }

    private func makeSettings(apiKey: String) -> AppSettings {
        isolatedSettings("DictationProcessingStageTests", defaults: storage.defaults, apiKey: apiKey)
    }

    /// The live pipeline (#182/#211): translate-by-default runs after
    /// transcription, and the coordinator names it while it runs, then clears
    /// it once the call is over.
    func testLivePipelineNamesTranslateWhileItRuns() async throws {
        let client = StageCapturingCleanupClient()
        let coordinator = storage.coordinator(backend: StubTranscriptionBackend(transcript: "hello world"), cleanupClient: client)
        client.coordinator = coordinator
        let settings = makeSettings(apiKey: "sk-test")
        settings.translationByDefault = true
        coordinator.settings = settings

        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        speak(coordinator, samples: 20_000)
        coordinator.stopRecording()

        let ran = await waitUntil { client.called }
        XCTAssertTrue(ran, "the translate call never happened")
        XCTAssertEqual(client.stageSeen, .translate)

        let settled = await waitUntil { coordinator.state == .idle || coordinator.state == .done }
        XCTAssertTrue(settled)
        XCTAssertNil(coordinator.llmStage, "the stage clears once the call is over")
    }

    /// A history retry shows the bubble too (`transcribeEntry`'s
    /// `showsProgress` defaults true), so its cleanup call gets the same
    /// naming as the live pipeline's.
    func testHistoryRetryNamesCleanupWhileItRuns() async throws {
        let client = StageCapturingCleanupClient()
        let coordinator = storage.coordinator(backend: StubTranscriptionBackend(transcript: "hello world"), cleanupClient: client)
        client.coordinator = coordinator
        let settings = makeSettings(apiKey: "sk-test")
        settings.cleanupByDefault = true
        coordinator.settings = settings

        let samples = [Float](repeating: 0.05, count: 20_000)
        let entry = DictationHistoryEntry(
            durationSeconds: Double(samples.count) / 16000.0,
            audioFilename: coordinator.history.saveAudio(samples)
        )
        coordinator.history.add(entry)

        await coordinator.retryTranscription(entryID: entry.id)

        XCTAssertTrue(client.called, "the cleanup call never happened")
        XCTAssertEqual(client.stageSeen, .cleanup)
        XCTAssertNil(coordinator.llmStage, "the stage clears once the call is over")
    }
}
