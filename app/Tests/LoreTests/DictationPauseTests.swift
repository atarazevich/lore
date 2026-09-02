import AppKit
import XCTest
@testable import LoreKit

/// #206: no key destroys a recording. #233: Esc cancels one — the dictation
/// ends without pasting and the entry lands in history with its audio, its
/// words and its items — and the pause moves onto the talk key, where the same
/// chord suspends capture in place and brings it back into the same entry and
/// the same audio file.
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

    /// The board's Space rows, through the manager that decides them: the
    /// bare key locks a held recording, the chord pauses a locked one and
    /// resumes a paused one, and a bare Space inside a locked recording is the
    /// user typing.
    func testWhoseSpaceItIs() {
        makeLockedRecording()
        XCTAssertEqual(
            hotkeys.spaceAction(talkKeyHeld: false), .passThrough,
            "a bare Space while locked is a space"
        )
        XCTAssertEqual(hotkeys.spaceAction(talkKeyHeld: true), .pause)

        coordinator.pauseRecording()
        XCTAssertEqual(
            hotkeys.spaceAction(talkKeyHeld: false), .passThrough,
            "and it is still a space while paused"
        )
        XCTAssertEqual(hotkeys.spaceAction(talkKeyHeld: true), .resume)
    }

    /// Unlocked, Space is the lock it has always been — held key or not.
    func testSpaceStillLocksAHeldRecording() {
        makeHotkeyRecording()
        coordinator.startPreBuffer()
        coordinator.confirmRecording()

        XCTAssertEqual(hotkeys.spaceAction(talkKeyHeld: false), .lock)
        XCTAssertEqual(hotkeys.spaceAction(talkKeyHeld: true), .lock)
        hotkeys.handleSpace(.lock, isRepeat: false)
        XCTAssertTrue(hotkeys.isLocked)
    }

    /// Outside a recording Space is nobody's, whatever is held.
    func testSpaceOutsideARecordingIsNotOurs() {
        makeHotkeyRecording()
        XCTAssertEqual(hotkeys.spaceAction(talkKeyHeld: true), .passThrough)
    }

    /// `.option` is one mask for two keys, and the chord's own event carries no
    /// keycode for the modifier that raised it. So a Left Option+Space typed
    /// into a locked dictation must reach the app being typed into: only the
    /// tracked press — set by keycode, the way `matchesPress` reads one — says
    /// the talk key is the one down.
    func testLeftOptionSpaceIsNotTheChordWhenRightOptionIsTheTalkKey() {
        makeLockedRecording(talkKey: .rightOption)

        XCTAssertFalse(hotkeys.talkKeyHeld([.option]), "left Option raises the same mask")
        XCTAssertEqual(
            hotkeys.spaceAction(talkKeyHeld: hotkeys.talkKeyHeld([.option])), .passThrough,
            "Left Option+Space was swallowed and paused the dictation"
        )

        // And the real Right Option, tracked by its own keycode, is the chord.
        hotkeys.handleFlagsChanged(
            flagsChanged(keyCode: HotkeyKey.rightOptionKeyCode, flags: [.option])
        )
        XCTAssertTrue(hotkeys.talkKeyHeld([.option]))
        XCTAssertEqual(hotkeys.spaceAction(talkKeyHeld: hotkeys.talkKeyHeld([.option])), .pause)
    }

    /// The same, one key over and with a shortcut behind it: with a recorded
    /// Right Command as the talk key, Cmd+Space is Spotlight's and has to leave
    /// a locked dictation untouched.
    func testCommandSpaceStaysSpotlightsWhenTheTalkKeyIsARecordedCommand() {
        makeLockedRecording(talkKey: .custom(keyCode: Self.rightCommandKeyCode))

        XCTAssertFalse(hotkeys.talkKeyHeld([.command]), "left Command raises the same mask")
        XCTAssertEqual(
            hotkeys.spaceAction(talkKeyHeld: hotkeys.talkKeyHeld([.command])), .passThrough,
            "Cmd+Space was swallowed inside a locked recording"
        )
    }

    /// Held down, Space auto-repeats at the key-repeat rate. Each repeat used to
    /// re-read `isPaused` and take the other branch — the 2026-09-01 stream has
    /// four pause/resume flips inside one second, from Esc doing exactly this.
    /// One physical press, one action.
    func testAHeldSpaceChordIsOnePause() {
        makeLockedRecording()
        speak(coordinator, samples: 16_000)

        for repeated in 0..<30 {
            hotkeys.handleSpace(
                hotkeys.spaceAction(talkKeyHeld: true), isRepeat: repeated > 0
            )
        }

        XCTAssertTrue(coordinator.isPaused, "the repeats flipped the pause back off")
        XCTAssertTrue(hotkeys.isLocked)
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

    func testAPauseKeepsBothFilesAndTheEntry() async {
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
            "the pause discarded something"
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
    func testResumeKeepsOneEntryAndOneContiguousStream() async throws {
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

    /// A talk-key tap while paused is the dictation's ending — the same one a
    /// release takes. Which is why `Finish` never needed to be a second button.
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
    /// `.recording` and `isPaused`. A resume landing there must not open a
    /// microphone the pipeline is about to close again.
    func testAResumeAfterTheEndingDoesNotReopenTheCapture() async throws {
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

    /// The other order, and the one that reaches the screen: a pause landing in
    /// that same 300 ms tail after a *live* dictation was finished would cut the
    /// tail short, fire a `dictationPaused` with no `dictationResumed` to pair
    /// it, and flash the paused face on the way to Transcribing.
    func testAPauseInTheTailAfterFinishingDoesNotPause() async throws {
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

    // MARK: - The cancel (#219 by pointer, #233 by key)

    /// A cancel is a finish minus the paste: the entry lands in history with its
    /// audio, its words and what rode along, nothing is inserted, and no paste
    /// event goes into the stream. The shape says `Cancelled — in history` from
    /// the moment the entry is saved and hides on its own, while the pipeline
    /// goes on transcribing behind it.
    func testCancellingKeepsTheWholeEntryAndPastesNothing() async throws {
        // The door's own switches, on a suite nobody else can see.
        _ = isolatedRichInputDefaults("DictationPauseTests")
        defer { RichInputSettings.use(.standard) }
        let pasteboard = NSPasteboard(name: .init("com.lore.test.stop.\(UUID().uuidString)"))
        var posted = 0
        let coordinator = makeRecording(
            backend: StubTranscriptionBackend(),
            clipboard: ClipboardWatcher(pasteboard: pasteboard, interval: .milliseconds(10)),
            deliver: { _ in
                posted += 1
                return Task { true }
            }
        )
        speak(coordinator, samples: 20_000)
        pasteboard.clearContents()
        pasteboard.setString("a stack trace", forType: .string)
        let collected = await waitUntil { coordinator.items.count == 1 }
        XCTAssertTrue(collected, "nothing was collected to ride along")
        coordinator.pauseRecording()
        let mark = DiagStream.mark()

        coordinator.cancelRecording()

        XCTAssertTrue(coordinator.cancelled, "the leaving face is not up")
        let saved = await waitUntil { coordinator.state == .done }
        XCTAssertTrue(saved, "the leaving face never came up")
        XCTAssertTrue(coordinator.cancelled, "and it says the dictation was cancelled")
        let transcribed = await waitUntil {
            coordinator.history.entries.first?.status == .transcribed
        }
        XCTAssertTrue(transcribed, "the words never reached history")

        let entry = try XCTUnwrap(coordinator.history.entries.first)
        let text = try XCTUnwrap(entry.rawText)
        XCTAssertTrue(text.contains("mock transcription"), "the spoken words: \(text)")
        XCTAssertTrue(text.contains("a stack trace"), "what was copied: \(text)")
        XCTAssertNotNil(entry.audioFilename, "the entry lost its audio")
        XCTAssertEqual(storage.audioFiles.count, 1)
        XCTAssertEqual(entry.items?.count, 1, "what rode along was dropped")
        XCTAssertEqual(posted, 0, "the cancel pasted")
        XCTAssertNil(coordinator.lastError, "a face over a dictation that went to plan")

        let seen = DiagStream.events(since: mark)
        XCTAssertTrue(
            seen.contains { if case .dictationRecorded = $0 { true } else { false } },
            "the cancel never ran the pipeline"
        )
        XCTAssertFalse(
            seen.contains { if case .dictationPasted = $0 { true } else { false } },
            "a paste event from a dictation that pasted nothing"
        )
        XCTAssertFalse(
            seen.contains { if case .dictationItemsPasted = $0 { true } else { false } },
            "an items-pasted event from a dictation that pasted nothing"
        )
        // And the face leaves by itself, without a key or a click.
        let left = await waitUntil { coordinator.state == .idle }
        XCTAssertTrue(left, "the shape stayed on screen")
        pasteboard.releaseGlobally()
    }

    /// And a transcription that comes back with nothing after a cancel is
    /// history's own retry, not a face for a bubble that has gone.
    func testATranscriptionThatFailsAfterACancelRaisesNoFace() async throws {
        let coordinator = makeRecording(backend: StubTranscriptionBackend(transcript: ""))
        speak(coordinator, samples: 20_000)

        coordinator.cancelRecording()

        let saved = await waitUntil { coordinator.history.entries.count == 1 }
        XCTAssertTrue(saved, "the entry never landed")
        let left = await waitUntil { coordinator.state == .idle }
        XCTAssertTrue(left, "the shape did not leave")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(coordinator.state, .idle, "the shape came back to report a failure")
        XCTAssertNil(coordinator.lastError, "a face nobody can see")
    }

    // MARK: - Through the key that takes it

    /// The board's locked row: Esc ends the dictation into history, and the lock
    /// goes with the recording it belonged to (#225).
    func testEscInALockedRecordingCancelsIt() async {
        await assertEscCancelsALockedRecording(paused: false)
    }

    /// A paused one cancels the same way, under the same name — one outcome
    /// from either state, which is what "one action, one name" means here, and
    /// what the pill beside the pause glyph does too.
    func testEscInAPausedRecordingCancelsIt() async {
        await assertEscCancelsALockedRecording(paused: true)
    }

    private func assertEscCancelsALockedRecording(
        paused: Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        makeLockedRecording()
        speak(coordinator, samples: 20_000)
        if paused { coordinator.pauseRecording() }

        hotkeys.handleEscape()

        XCTAssertTrue(coordinator.cancelled, file: file, line: line)
        XCTAssertFalse(
            hotkeys.isLocked, "a cancel is an ending — the lock goes with it",
            file: file, line: line
        )
        let saved = await waitUntil { self.coordinator.history.entries.count == 1 }
        XCTAssertTrue(saved, "the entry never landed", file: file, line: line)
        XCTAssertEqual(
            storage.audioFiles.count, 1, "the audio is still the dictation's",
            file: file, line: line
        )
        // The pause goes with the capture, which the pipeline takes after the
        // tail — so this is read once the entry has landed, not at the keypress.
        XCTAssertFalse(
            coordinator.isPaused, "the pause left with the recording", file: file, line: line
        )
    }

    /// Held down, Esc auto-repeats at ~30 a second and none of it is filtered on
    /// the way in — the 2026-09-01 stream has four pause/resume flips inside one
    /// second. One press, one cancel: the dictation is ended once, and one entry
    /// lands.
    func testAHeldEscIsStillOneCancel() async throws {
        makeLockedRecording()
        speak(coordinator, samples: 20_000)
        let mark = DiagStream.mark()

        for _ in 0..<30 { hotkeys.handleEscape() }

        let saved = await waitUntil { self.coordinator.history.entries.count == 1 }
        XCTAssertTrue(saved, "the entry never landed")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(coordinator.history.entries.count, 1, "a repeat made a second entry")
        XCTAssertEqual(storage.audioFiles.count, 1, "a repeat made a second audio file")
        let recorded = DiagStream.events(since: mark).filter { event in
            if case .dictationRecorded = event { true } else { false }
        }
        XCTAssertEqual(recorded.count, 1, "the pipeline ran \(recorded.count) times")
    }

    /// Hold-to-talk: Esc cancels without letting go of the talk key, and
    /// releasing it afterwards does nothing — the dictation is already in
    /// history, and a paste there would insert the words the cancel declined.
    func testEscWhileFnIsHeldCancelsAndTheReleaseDoesNothing() async throws {
        makeHotkeyRecording()
        let mark = DiagStream.mark()
        hotkeys.handleFlagsChanged(hotkey(down: true))
        // Past the 150 ms that confirms a hold into a recording.
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(coordinator.state, .recording)
        speak(coordinator, samples: 20_000)

        hotkeys.handleEscape()
        XCTAssertTrue(coordinator.cancelled, "Esc under a held talk key cancels")

        hotkeys.handleFlagsChanged(hotkey(down: false))
        let saved = await waitUntil { self.coordinator.history.entries.count == 1 }
        XCTAssertTrue(saved, "the entry never landed")
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(coordinator.history.entries.count, 1, "the release started a second ending")
        XCTAssertFalse(
            DiagStream.events(since: mark).contains {
                if case .dictationPasted = $0 { true } else { false }
            },
            "the release pasted the words the cancel declined"
        )
        XCTAssertEqual(storage.audioFiles.count, 1, "the audio is still the dictation's")
    }

    /// Esc before the hold is confirmed is nobody's: a pre-buffer is a gesture
    /// that may still turn out to be a tap, and there is nothing there to end.
    func testEscDuringThePreBufferIsNotOurs() {
        makeHotkeyRecording()
        coordinator.startPreBuffer()
        XCTAssertTrue(coordinator.isPreBuffering)

        hotkeys.handleEscape()

        XCTAssertFalse(coordinator.cancelled)
        XCTAssertTrue(coordinator.isPreBuffering, "the pre-buffer carried on")
    }

    /// The chord, both ways: the talk key with Space pauses a locked recording
    /// and the same chord brings it back, with the lock untouched throughout.
    func testTheSpaceChordPausesAndResumesALockedRecording() {
        makeLockedRecording()
        speak(coordinator, samples: 16_000)

        hotkeys.handleSpace(hotkeys.spaceAction(talkKeyHeld: true), isRepeat: false)
        XCTAssertTrue(coordinator.isPaused)
        XCTAssertTrue(hotkeys.isLocked, "pausing is not an ending — the lock stands")

        hotkeys.handleSpace(hotkeys.spaceAction(talkKeyHeld: true), isRepeat: false)
        XCTAssertFalse(coordinator.isPaused)
        XCTAssertTrue(hotkeys.isLocked)
    }

    /// And the chord's own release is the end of the chord, not the end of the
    /// dictation — the same latch Fn+V, Fn+T and Fn+K already set.
    func testTheReleaseAfterTheSpaceChordDoesNotFinish() async throws {
        makeHotkeyRecording()
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        hotkeys.toggleLockByClick()
        speak(coordinator, samples: 16_000)
        // The talk key goes down inside the locked recording, as it does for
        // every chord.
        hotkeys.handleFlagsChanged(hotkey(down: true))

        hotkeys.handleSpace(hotkeys.spaceAction(talkKeyHeld: true), isRepeat: false)
        XCTAssertTrue(coordinator.isPaused)

        hotkeys.handleFlagsChanged(hotkey(down: false))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(coordinator.state, .recording, "the chord's release ended the dictation")
        XCTAssertTrue(coordinator.isPaused, "and it is still paused")
        XCTAssertTrue(hotkeys.isLocked)
    }

    // MARK: - The slot, clicked (#234)

    /// The row's own glyph is the control it looks like: clicking the record dot
    /// pauses and clicking the pause mark resumes, exactly as the chord does and
    /// leaving the chord's own traces. Driven through the manager that installs
    /// the door, so this is the wiring the pointer really reaches — the view
    /// decides *which* action to hand over (`DictationIndicatorView.slotAction`,
    /// walked in `RecordingBubbleRenderTests`), and this is what happens to it.
    func testClickingTheSlotPausesAndResumes() async throws {
        makeLockedRecording()
        speak(coordinator, samples: 16_000)
        let indicator = DictationIndicatorManager()
        indicator.start(coordinator: coordinator, hotkeyManager: hotkeys)
        defer { indicator.stop() }
        let click = try XCTUnwrap(indicator.model.onSpaceCap, "the slot has no door to the app")

        var mark = DiagStream.mark()
        click(try XCTUnwrap(DictationIndicatorView.slotAction(locked: true, paused: false)))
        let paused = await waitUntil { self.coordinator.isPaused }
        XCTAssertTrue(paused, "the dot did not pause")
        XCTAssertTrue(
            DiagStream.events(since: mark).contains(.dictationPaused),
            "the click left none of the chord's trace"
        )
        XCTAssertTrue(hotkeys.isLocked, "clicking the dot ended the recording")

        mark = DiagStream.mark()
        click(try XCTUnwrap(DictationIndicatorView.slotAction(locked: true, paused: true)))
        let resumed = await waitUntil { !self.coordinator.isPaused }
        XCTAssertTrue(resumed, "the glyph did not resume")
        XCTAssertTrue(DiagStream.events(since: mark).contains(.dictationResumed))
    }

    /// And a held recording's dot is not a control at all: Space there is the
    /// lock, and the lock is the glyph beside it — a dot that locked would be a
    /// second name for that control, and would not be the pause the board
    /// promises.
    func testTheDotOfAHeldRecordingIsNotAControl() {
        makeHotkeyRecording()
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        XCTAssertFalse(hotkeys.isLocked)

        XCTAssertNil(DictationIndicatorView.slotAction(locked: false, paused: false))
        XCTAssertEqual(
            hotkeys.spaceAction(talkKeyHeld: true), .lock,
            "the key still locks a held recording — only the dot declines to"
        )
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeCoordinator(
        backend: (any TranscriptionBackend)? = nil, clipboard: ClipboardWatcher? = nil,
        deliver: @escaping DictationDelivery = { _ in Task { true } }
    ) -> DictationCoordinator {
        let coordinator = storage.coordinator(
            backend: backend, clipboard: clipboard ?? ClipboardWatcher(), deliver: deliver
        )
        coordinator.settings = isolatedSettings("DictationPauseTests", defaults: storage.defaults)
        self.coordinator = coordinator
        return coordinator
    }

    /// A confirmed recording, writing to storage nothing else can see.
    @discardableResult
    private func makeRecording(
        backend: (any TranscriptionBackend)? = nil, clipboard: ClipboardWatcher? = nil,
        deliver: @escaping DictationDelivery = { _ in Task { true } }
    ) -> DictationCoordinator {
        let coordinator = makeCoordinator(
            backend: backend, clipboard: clipboard, deliver: deliver
        )
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        return coordinator
    }

    /// Right Command — a recorded talk key that shares `.command` with the key
    /// every Mac shortcut is held on.
    private static let rightCommandKeyCode: UInt16 = 54

    /// The same, with the hotkey manager installed on it so a real key can be
    /// put through the decision both event paths take.
    private func makeHotkeyRecording(talkKey: HotkeyKey = .fn) {
        let fixture = storage.gestures("DictationPauseTests", talkKey: talkKey)
        coordinator = fixture.coordinator
        hotkeys = fixture.hotkeys
    }

    /// Locked by the bubble's own glyph, which is the Space path itself.
    private func makeLockedRecording(talkKey: HotkeyKey = .fn) {
        makeHotkeyRecording(talkKey: talkKey)
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        hotkeys.toggleLockByClick()
        XCTAssertTrue(hotkeys.isLocked, "the fixture is a locked recording")
    }

    private func hotkey(down: Bool) -> NSEvent { fnKeyEvent(down: down) }
}
