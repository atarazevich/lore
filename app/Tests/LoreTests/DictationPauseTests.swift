import AppKit
import XCTest
@testable import LoreKit

/// #206: Esc never destroys a recording. It pauses capture in place, and the
/// same key — or the bubble's `Continue` — brings it back into the same entry
/// and the same audio file.
///
/// The gestures below run with no audio bus wired, so no microphone is ever
/// opened; `appendCapturedSamples` is the seam the real capture loop goes
/// through, driven here with synthetic buffers. What a pause must not do to the
/// capture (unsubscribe and stay unsubscribed, cancel the watchdog, shut the
/// clipboard door) is asserted through what the coordinator reports, since the
/// bus itself is absent.
@MainActor
final class DictationPauseTests: XCTestCase {

    private var storage: EphemeralDictation!
    private var hotkeys: HotkeyManager!
    /// Held strongly for the test's length: `HotkeyManager.coordinator` is weak.
    private var coordinator: DictationCoordinator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = EphemeralDictation("DictationPauseTests")
        // The gesture starts behind the microphone-permission gate, and an
        // undetermined status would put a system prompt on the user's screen.
        try XCTSkipUnless(
            MicrophonePermission.status == .authorized,
            "dictation gestures need microphone permission already granted"
        )
    }

    override func tearDown() {
        hotkeys?.uninstall()
        hotkeys = nil
        coordinator = nil
        storage.tearDown()
        storage = nil
        super.tearDown()
    }

    // MARK: - Whose key it is

    /// The board's logic rows, taken as the pure decision they are — every input
    /// the function has, both ways, with no crosshair on the screen. What
    /// happens outside a recording is the caller's guard, not this table's, and
    /// `testEscDuringThePreBufferIsNotOurs` is where that is checked.
    func testWhoseEscapeItIs() {
        XCTAssertEqual(
            DictationEscape.decide(paused: false, screenshotUIIsUp: false),
            .pause, "Esc in a recording pauses it"
        )
        XCTAssertEqual(
            DictationEscape.decide(paused: true, screenshotUIIsUp: false),
            .resume, "Esc again continues"
        )
        // The incident this issue is named for: a screenshot crosshair is up and
        // the Esc cancelling it took the dictation with it.
        XCTAssertEqual(
            DictationEscape.decide(paused: false, screenshotUIIsUp: true),
            .passThrough, "the crosshair's Esc is the crosshair's"
        )
        XCTAssertEqual(
            DictationEscape.decide(paused: true, screenshotUIIsUp: true),
            .passThrough, "and it stays the crosshair's while paused"
        )
    }

    /// The bundle id is what the live reading finds the process by, so it is
    /// pinned: a typo would silently give every Esc back to lore.
    func testTheScreenshotUIIsNamedByItsBundleID() {
        XCTAssertEqual(DictationEscape.screenshotUIBundleID, "com.apple.screencaptureui")
        XCTAssertEqual(DictationEscape.keyCode, 53)
    }

    /// And the reading itself says no on a machine with no crosshair on it —
    /// which is the case the naive "is the process running" test got wrong.
    /// `screencaptureui` stays resident for hours after a screenshot, with a
    /// prewarmed full-screen window on screen, so a test that answered yes to
    /// either would leave Esc unable to pause anything ever again.
    func testNoCrosshairMeansTheKeyIsOurs() {
        XCTAssertFalse(
            DictationEscape.screenshotUIIsUp,
            "no crosshair is up in a test run — if this fails, the reading is latched on"
        )
    }

    // MARK: - The pause itself

    func testEscKeepsBothFilesAndTheEntry() async {
        let coordinator = makeRecording()
        speak(coordinator, samples: 20_000)
        let landed = await storage.waitForSamplesOnDisk(20_000)
        XCTAssertTrue(landed)
        let mark = DiagStream.mark()

        coordinator.pauseRecording()

        XCTAssertTrue(coordinator.isPaused)
        XCTAssertEqual(coordinator.state, .recording, "a paused dictation is still a recording")
        XCTAssertEqual(storage.audioFiles.count, 1, "the audio is where it was")
        XCTAssertEqual(storage.entryFiles.count, 1, "and so is its entry")
        let seen = DiagStream.events(since: mark)
        XCTAssertTrue(seen.contains(.dictationPaused), "the pause left a trace")
        XCTAssertFalse(
            seen.contains { if case .dictationDiscarded = $0 { true } else { false } },
            "Esc discarded something"
        )
    }

    /// The meter and the no-signal row belong to a running capture. With the
    /// capture down they must read as nothing rather than as a dead microphone —
    /// no watchdog may accuse a mic of withholding frames nobody asked it for.
    func testPauseLeavesNoFailureBehindIt() {
        let coordinator = makeRecording()
        speak(coordinator, samples: 20_000)

        coordinator.pauseRecording()

        XCTAssertEqual(coordinator.audioLevel, 0)
        XCTAssertFalse(coordinator.noSignal)
        XCTAssertNil(coordinator.lastError, "a pause is not a failure")
    }

    /// Two legs of speech with a pause between them: one entry, one audio file,
    /// and the samples of both legs end to end with nothing spliced in.
    func testContinueKeepsOneEntryAndOneContiguousStream() async throws {
        let coordinator = makeRecording()
        coordinator.appendCapturedSamples([Float](repeating: 0.25, count: 16_000))
        let firstLeg = await storage.waitForSamplesOnDisk(16_000)
        XCTAssertTrue(firstLeg)

        let mark = DiagStream.mark()
        coordinator.pauseRecording()
        coordinator.resumeRecording()
        XCTAssertFalse(coordinator.isPaused)
        XCTAssertTrue(DiagStream.events(since: mark).contains(.dictationResumed))

        coordinator.appendCapturedSamples([Float](repeating: -0.5, count: 8_000))
        let bothLegs = await storage.waitForSamplesOnDisk(24_000)
        XCTAssertTrue(bothLegs)

        XCTAssertEqual(storage.audioFiles.count, 1, "the resume opened a second file")
        XCTAssertEqual(storage.entryFiles.count, 1, "the resume started a second entry")

        // Read back through the store the next launch would use: one stream, the
        // second leg beginning exactly where the first ended.
        let recovered = storage.history()
        let entry = try XCTUnwrap(recovered.entries.first)
        let samples = try XCTUnwrap(recovered.loadAudio(filename: try XCTUnwrap(entry.audioFilename)))
        XCTAssertEqual(samples.count, 24_000)
        XCTAssertEqual(samples[15_999], 0.25, "the first leg's last sample")
        XCTAssertEqual(samples[16_000], -0.5, "the second leg's first, with no gap between them")
        XCTAssertEqual(entry.durationSeconds, 1.5, accuracy: 0.001, "1.0 s + 0.5 s, and no pause")
    }

    /// A Fn tap while paused is the dictation's ending — the same one a release
    /// takes. Which is why `Finish` never needed to be a second button.
    func testFnTapWhilePausedEndsTheDictationTheSameWay() async throws {
        let coordinator = makeRecording(backend: StubTranscriptionBackend(transcript: ""))
        speak(coordinator, samples: 20_000)
        coordinator.pauseRecording()
        speak(coordinator, samples: 0) // nothing arrives while paused
        let mark = DiagStream.mark()

        coordinator.stopRecording()
        let finished = await waitUntil { coordinator.state != .recording }
        XCTAssertTrue(finished)

        XCTAssertFalse(coordinator.isPaused, "the pause left with the recording")
        // The whole stream reached the pipeline, not the leg before the pause.
        XCTAssertTrue(DiagStream.events(since: mark).contains { event in
            if case .dictationRecorded(let samples, _) = event { samples == 20_000 } else { false }
        }, "the pipeline was handed the dictation's own audio")
        XCTAssertEqual(storage.audioFiles.count, 1)
        let recovered = storage.history()
        XCTAssertEqual(recovered.entries.count, 1, "one entry, finished")
        XCTAssertEqual(try XCTUnwrap(recovered.entries.first).durationSeconds, 1.25, accuracy: 0.001)
    }

    /// `state` stays `.recording` through the pipeline's 300 ms audio tail, so a
    /// paused dictation that has just been finished is still, for that long,
    /// `.recording` and `isPaused`. An Esc landing there must not open a
    /// microphone the pipeline is about to close again.
    func testAnEscAfterTheEndingDoesNotReopenTheCapture() async throws {
        let coordinator = makeRecording(backend: StubTranscriptionBackend(transcript: ""))
        speak(coordinator, samples: 20_000)
        coordinator.pauseRecording()

        coordinator.stopRecording()
        XCTAssertTrue(coordinator.isPaused, "the tail has not reached the capture yet")

        coordinator.resumeRecording()
        XCTAssertTrue(coordinator.isPaused, "the ending was already under way")

        let finished = await waitUntil { coordinator.state != .recording }
        XCTAssertTrue(finished, "and it still finished")
        XCTAssertFalse(coordinator.isPaused)
    }

    /// The other order, and the one that reaches the screen: an Esc landing in
    /// that same 300 ms tail after a *live* dictation was finished would cut the
    /// tail short, fire a `dictationPaused` with no `dictationResumed` to pair
    /// it, and flash the paused face on the way to Transcribing.
    func testAnEscInTheTailAfterFinishingDoesNotPause() async throws {
        let coordinator = makeRecording(backend: StubTranscriptionBackend(transcript: ""))
        speak(coordinator, samples: 20_000)
        let mark = DiagStream.mark()

        coordinator.stopRecording()
        XCTAssertEqual(coordinator.state, .recording, "the tail has not reached the capture yet")

        coordinator.pauseRecording()
        XCTAssertFalse(coordinator.isPaused, "the ending was already under way")

        let finished = await waitUntil { coordinator.state != .recording }
        XCTAssertTrue(finished)
        XCTAssertFalse(
            DiagStream.events(since: mark).contains(.dictationPaused),
            "a pause with no pair went into the stream"
        )
    }

    /// Nothing collects while paused: the clipboard door is shut at the pause and
    /// re-baselined at the resume, so a copy made in between joins no prompt.
    func testNothingIsCollectedWhilePaused() async {
        // The door's own switches, on a suite nobody else can see — the
        // developer's Copying settings must not decide whether this passes.
        _ = isolatedRichInputDefaults("DictationPauseTests")
        defer { RichInputSettings.use(.standard) }
        let pasteboard = NSPasteboard(name: .init("com.lore.test.pause.\(UUID().uuidString)"))
        let coordinator = makeRecording(clipboard: ClipboardWatcher(
            pasteboard: pasteboard, interval: .milliseconds(10)
        ))
        speak(coordinator, samples: 16_000)

        pasteboard.clearContents()
        pasteboard.setString("during the dictation", forType: .string)
        let collected = await waitUntil { coordinator.items.count == 1 }
        XCTAssertTrue(collected, "the door was open")

        coordinator.pauseRecording()
        pasteboard.clearContents()
        pasteboard.setString("while it stood paused", forType: .string)
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(coordinator.items.count, 1, "something was collected while paused")

        coordinator.resumeRecording()
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(
            coordinator.items.count, 1,
            "the resume swept up what was copied while the door was shut"
        )

        pasteboard.clearContents()
        pasteboard.setString("after the continue", forType: .string)
        let reopened = await waitUntil { coordinator.items.count == 2 }
        XCTAssertTrue(reopened, "the door reopened")
        pasteboard.releaseGlobally()
    }

    // MARK: - Through the key that takes it

    /// The board's locked row: Esc pauses, the lock is untouched, Esc again
    /// continues.
    func testEscInALockedRecordingPausesAndContinues() {
        makeLockedRecording()
        speak(coordinator, samples: 16_000)

        hotkeys.handleEscape()
        XCTAssertTrue(coordinator.isPaused)
        XCTAssertTrue(hotkeys.isLocked, "pausing is not an ending — the lock stands")

        hotkeys.handleEscape()
        XCTAssertFalse(coordinator.isPaused)
        XCTAssertTrue(hotkeys.isLocked)
    }

    /// And `Continue`, taken by pointer, is that same second Esc: the bubble's
    /// button calls exactly what the key does.
    func testTheContinueButtonIsTheSecondEsc() {
        makeLockedRecording()
        hotkeys.handleEscape()
        XCTAssertTrue(coordinator.isPaused)

        coordinator.resumeRecording()
        XCTAssertFalse(coordinator.isPaused)
        XCTAssertTrue(hotkeys.isLocked, "and it is not an ending either")
    }

    /// Hold-to-talk: Esc pauses without letting go of Fn, and the release
    /// afterwards finishes — the same outcome ending a hold has always meant.
    func testEscWhileFnIsHeldPausesAndTheReleaseFinishes() async throws {
        makeHotkeyRecording()
        hotkeys.handleFlagsChanged(hotkey(down: true))
        // Past the 150 ms that confirms a hold into a recording.
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(coordinator.state, .recording)
        speak(coordinator, samples: 20_000)

        hotkeys.handleEscape()
        XCTAssertTrue(coordinator.isPaused, "Esc under a held Fn pauses")

        hotkeys.handleFlagsChanged(hotkey(down: false))
        let finished = await waitUntil { self.coordinator.state != .recording }
        XCTAssertTrue(finished, "the release finished it")
        XCTAssertFalse(coordinator.isPaused)
        XCTAssertEqual(storage.audioFiles.count, 1, "the audio is still the dictation's")
    }

    /// Esc before the hold is confirmed is nobody's: a pre-buffer is a gesture
    /// that may still turn out to be a tap, and there is nothing there to pause.
    func testEscDuringThePreBufferIsNotOurs() {
        makeHotkeyRecording()
        coordinator.startPreBuffer()
        XCTAssertTrue(coordinator.isPreBuffering)

        hotkeys.handleEscape()

        XCTAssertFalse(coordinator.isPaused)
        XCTAssertTrue(coordinator.isPreBuffering, "the pre-buffer carried on")
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeCoordinator(
        backend: (any TranscriptionBackend)? = nil, clipboard: ClipboardWatcher? = nil
    ) -> DictationCoordinator {
        let coordinator = storage.coordinator(
            backend: backend, clipboard: clipboard ?? ClipboardWatcher()
        )
        coordinator.settings = isolatedSettings("DictationPauseTests", defaults: storage.defaults)
        self.coordinator = coordinator
        return coordinator
    }

    /// A confirmed recording, writing to storage nothing else can see.
    @discardableResult
    private func makeRecording(
        backend: (any TranscriptionBackend)? = nil, clipboard: ClipboardWatcher? = nil
    ) -> DictationCoordinator {
        let coordinator = makeCoordinator(backend: backend, clipboard: clipboard)
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        return coordinator
    }

    /// The same, with the hotkey manager installed on it so a real key can be
    /// put through the decision both event paths take.
    private func makeHotkeyRecording() {
        let coordinator = makeCoordinator(backend: StubTranscriptionBackend(transcript: ""))
        hotkeys = HotkeyManager()
        hotkeys.install(coordinator: coordinator, settings: coordinator.settings!)
    }

    /// Locked by the bubble's own glyph, which is the Space path itself.
    private func makeLockedRecording() {
        makeHotkeyRecording()
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        hotkeys.toggleLockByClick()
        XCTAssertTrue(hotkeys.isLocked, "the fixture is a locked recording")
    }

    private func hotkey(down: Bool) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero,
            modifierFlags: down ? [.function] : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 63
        )!
    }
}
