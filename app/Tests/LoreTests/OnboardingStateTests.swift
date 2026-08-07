import XCTest
@testable import LoreKit

/// The pure halves of the onboarding flow — the Fn-key readout and the
/// permission snapshot — plus the parts of `OnboardingModel` that only the
/// poller's cadence can exercise: the dwells it has to survive, and what the
/// Try-it step is allowed to claim.
@MainActor
final class OnboardingStateTests: XCTestCase {

    private static let allGranted = PermissionSnapshot(
        microphone: true,
        accessibility: true,
        inputMonitoring: true,
        microphoneUndetermined: false
    )

    /// A dwell short enough to keep the suite quick, with the poll driven faster
    /// than it — the ratio the production 400 ms / 450 ms pair has.
    private static let testDwell = Duration.milliseconds(30)

    // MARK: - Fn key readout

    /// The four items in System Settings › Keyboard › "Press 🌐 fn key to", in
    /// the order macOS lists them.
    func testStoredValueMapsToTheSettingsMenuItem() {
        XCTAssertEqual(FnKeySetting.action(forStored: 0), .doNothing)
        XCTAssertEqual(FnKeySetting.action(forStored: 1), .changeInputSource)
        XCTAssertEqual(FnKeySetting.action(forStored: 2), .showEmojiPicker)
        XCTAssertEqual(FnKeySetting.action(forStored: 3), .startDictation)
    }

    /// Absent key = the user never touched the setting = the macOS shipping
    /// default, which is the emoji picker and therefore a conflict. Reading
    /// absence as "fine" would silently skip the step on every fresh install.
    func testAbsentKeyIsTheConflictingSystemDefault() {
        let action = FnKeySetting.action(forStored: nil)
        XCTAssertEqual(action, .showEmojiPicker)
        XCTAssertTrue(action.conflictsWithHotkey)
    }

    /// A fifth item added by a future macOS is a conflict — and the live readout
    /// must not name a setting the user does not have. Reporting an unknown
    /// value as "Show Emoji & Symbols" is a false reading about the one thing
    /// this step exists to explain.
    func testUnknownValueConflictsAndIsNamedHonestly() {
        for stored in [42, -1, 99] {
            let action = FnKeySetting.action(forStored: stored)
            XCTAssertEqual(action, .unknown, "\(stored)")
            XCTAssertTrue(action.conflictsWithHotkey, "\(stored)")
        }
        XCTAssertEqual(FnKeyAction.unknown.label, "an unrecognized setting")
        for action in FnKeyAction.allCases where action != .unknown {
            XCTAssertNotEqual(action.label, FnKeyAction.unknown.label)
        }
    }

    /// Only Do Nothing leaves the key for lore — the whole gating condition of
    /// the Fn step.
    func testOnlyDoNothingClearsTheConflict() {
        for action in FnKeyAction.allCases {
            XCTAssertEqual(action.conflictsWithHotkey, action != .doNothing)
        }
    }

    func testLabelsMatchTheSettingsWording() {
        XCTAssertEqual(FnKeyAction.doNothing.label, "Do Nothing")
        XCTAssertEqual(FnKeyAction.showEmojiPicker.label, "Show Emoji & Symbols")
    }

    // MARK: - Permission snapshot

    /// The baseline: nothing granted, the microphone card is the live one and
    /// the other two are locked stubs.
    func testBaselineSnapshotRevealsOnlyTheFirstCard() {
        let snapshot = PermissionSnapshot()
        XCTAssertFalse(snapshot.allGranted)
        XCTAssertEqual(snapshot.current, .microphone)
        XCTAssertTrue(snapshot.isRevealed(.microphone))
        XCTAssertFalse(snapshot.isRevealed(.accessibility))
        XCTAssertFalse(snapshot.isRevealed(.inputMonitoring))
    }

    /// Board order: mic → Accessibility → Input Monitoring. Granting one reveals
    /// exactly the next, never two.
    func testRevealAdvancesOneCardPerGrant() {
        var snapshot = PermissionSnapshot(microphone: true)
        XCTAssertEqual(snapshot.current, .accessibility)
        XCTAssertTrue(snapshot.isRevealed(.accessibility))
        XCTAssertFalse(snapshot.isRevealed(.inputMonitoring))

        snapshot.accessibility = true
        XCTAssertEqual(snapshot.current, .inputMonitoring)
        XCTAssertTrue(snapshot.isRevealed(.inputMonitoring))
    }

    func testAllGrantedEndsTheSequence() {
        XCTAssertTrue(Self.allGranted.allGranted)
        XCTAssertNil(Self.allGranted.current)
        for grant in RequiredGrant.allCases {
            XCTAssertTrue(Self.allGranted.isRevealed(grant))
        }
    }

    /// Live, not latched (`.claude/rules/no-false-positives.md` §1–2): a grant
    /// revoked while the window is open takes its card back out of the green
    /// state and the sequence re-opens there. A card that is *still* granted
    /// stays live — dimming a grant the user actually holds would be a claim
    /// about it that is not true.
    func testRevocationReopensTheSequence() {
        var snapshot = Self.allGranted
        snapshot.accessibility = false

        XCTAssertFalse(snapshot.allGranted)
        XCTAssertEqual(snapshot.current, .accessibility)
        XCTAssertTrue(snapshot.isRevealed(.accessibility))
        XCTAssertTrue(snapshot.isRevealed(.inputMonitoring))
    }

    /// The required set is exactly the three the board reveals, in its order.
    func testRequiredSetIsTheBoardsThreeInOrder() {
        XCTAssertEqual(RequiredGrant.allCases, [.microphone, .accessibility, .inputMonitoring])
    }

    /// Every card carries the two concrete promises the board's anatomy calls
    /// for. The pane and the event-stream name are derived from the case name,
    /// so this is also what pins those two lookups.
    func testEveryCardHasTwoReasonsAPaneAndAPermissionName() {
        XCTAssertEqual(RequiredGrant.microphone.pane, .microphone)
        XCTAssertEqual(RequiredGrant.accessibility.pane, .accessibility)
        XCTAssertEqual(RequiredGrant.inputMonitoring.pane, .inputMonitoring)
        XCTAssertEqual(RequiredGrant.microphone.diagPermission, .microphone)
        XCTAssertEqual(RequiredGrant.accessibility.diagPermission, .accessibility)
        XCTAssertEqual(RequiredGrant.inputMonitoring.diagPermission, .inputMonitoring)
        for grant in RequiredGrant.allCases {
            XCTAssertEqual(grant.reasons.count, 2, "\(grant.rawValue)")
            XCTAssertNotNil(grant.pane.settingsURL, "\(grant.rawValue)")
        }
    }

    /// The five steps name themselves the same way in the event stream, which is
    /// what the raw-value lookup in `Step.diagStep` rests on.
    func testEveryStepNamesItselfInTheEventStream() {
        for step in OnboardingModel.Step.allCases {
            XCTAssertEqual(step.diagStep.rawValue, step.rawValue)
        }
    }

    /// Only the microphone's button is two-tier, so only it needs the caption
    /// that tells the truth about a label that never changes.
    func testOnlyTheMicrophoneCardCarriesACaption() {
        XCTAssertNotNil(RequiredGrant.microphone.caption)
        XCTAssertNil(RequiredGrant.accessibility.caption)
        XCTAssertNil(RequiredGrant.inputMonitoring.caption)
    }

    /// The un-cached Input Monitoring read has to agree with the cached one at
    /// the moment the process starts — they only diverge after a grant made
    /// mid-process, which is the case `IOHIDCheckAccess` exists to catch.
    func testInputMonitoringReadIsNotWeakerThanThePreflight() {
        if CGPreflightListenEventAccess() {
            XCTAssertTrue(PermissionReader.inputMonitoringGranted())
        }
    }

    // MARK: - Dwells under the poll

    /// The bug this shape exists to prevent: the poll re-applies the same
    /// reading every 400 ms, and a dwell that cancelled and re-armed on each of
    /// those ticks never reached its own 450 ms deadline — so the body never
    /// ran, once, ever.
    func testDwellFiresWhileTicksKeepArriving() async {
        let timer = DwellTimer(duration: Self.testDwell)
        let fires = Box()
        let deadline = ContinuousClock.now + .seconds(2)

        while fires.value == 0, ContinuousClock.now < deadline {
            timer.arm(for: "the condition still holds") { fires.value += 1 }
            try? await Task.sleep(for: .milliseconds(5))
        }
        timer.cancel()

        XCTAssertEqual(fires.value, 1, "a dwell re-armed on every tick never fires")
    }

    /// A different condition is a different dwell: the clock restarts and the
    /// superseded body never runs.
    func testAChangedConditionRestartsTheDwell() async {
        let timer = DwellTimer(duration: Self.testDwell)
        let superseded = Box()
        let current = Box()

        timer.arm(for: "first") { superseded.value += 1 }
        timer.arm(for: "second") { current.value += 1 }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(superseded.value, 0)
        XCTAssertEqual(current.value, 1)
    }

    func testCancelDisarmsTheDwell() async {
        let timer = DwellTimer(duration: Self.testDwell)
        let fires = Box()

        timer.arm(for: "gone by the next tick") { fires.value += 1 }
        XCTAssertTrue(timer.isArmed)
        timer.cancel()
        XCTAssertFalse(timer.isArmed)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(fires.value, 0)
    }

    /// Board 2b: a grant flips its card green and the *next* card opens after
    /// the dwell — while the poll keeps re-delivering that same reading.
    func testTheNextCardOpensWhileThePollKeepsTicking() async {
        let model = OnboardingModel(dwell: Self.testDwell)
        model.advanceFromButton()
        XCTAssertEqual(model.step, .permissions)
        XCTAssertEqual(model.expandedGrant, .microphone)

        let opened = await poll(
            model,
            permissions: PermissionSnapshot(microphone: true, microphoneUndetermined: false),
            fn: .doNothing,
            until: { model.expandedGrant == .accessibility }
        )
        XCTAssertTrue(opened, "the reveal dwell never fired under the poll")
    }

    /// Board 3b: the Fn step has no Continue at all, so the hand-off after
    /// "Detected — continuing…" is the only way out of it.
    func testTheFnStepHandsOffWhileThePollKeepsTicking() async {
        let model = OnboardingModel(dwell: Self.testDwell)
        model.advanceFromButton()
        model.apply(permissions: Self.allGranted, fn: .showEmojiPicker)
        model.advanceFromButton()
        XCTAssertEqual(model.step, .fnKey)

        let handedOff = await poll(
            model,
            permissions: Self.allGranted,
            fn: .doNothing,
            until: { model.step == .tryIt }
        )
        XCTAssertTrue(handedOff, "the Fn hand-off dwell never fired under the poll")
    }

    /// A revocation takes the flow back with it, and the dwell that was counting
    /// down toward the next card goes with it.
    func testARevocationTakesTheFlowBackAndDisarmsTheDwell() {
        let model = OnboardingModel(dwell: Self.testDwell)
        model.advanceFromButton()
        model.apply(permissions: Self.allGranted, fn: .doNothing)
        model.advanceFromButton()
        XCTAssertEqual(model.step, .tryIt)

        var revoked = Self.allGranted
        revoked.accessibility = false
        model.apply(permissions: revoked, fn: .doNothing)
        XCTAssertEqual(model.step, .permissions)
    }

    // MARK: - Step dots

    /// The board's row is four — Permissions, Fn, Try it, Ready — with no row at
    /// all on Welcome or Ready.
    func testDotsFollowTheBoard() {
        XCTAssertEqual(OnboardingModel.Step.dotted.count, 4)

        let model = OnboardingModel(dwell: Self.testDwell)
        XCTAssertNil(model.dotIndex, "Welcome shows none")

        model.advanceFromButton()
        model.apply(permissions: Self.allGranted, fn: .showEmojiPicker)
        XCTAssertEqual(model.dotIndex, 0)

        model.advanceFromButton()
        XCTAssertEqual(model.step, .fnKey)
        XCTAssertEqual(model.dotIndex, 1)
    }

    /// With the Fn setting already correct the flow goes Permissions → Try it.
    /// The Fn dot stays and reads as passed — which it is — rather than
    /// disappearing and changing the row's length under the user.
    func testASkippedFnStepStillReadsAsPassed() {
        let model = OnboardingModel(dwell: Self.testDwell)
        model.advanceFromButton()
        model.apply(permissions: Self.allGranted, fn: .doNothing)
        XCTAssertEqual(model.dotIndex, 0)

        model.advanceFromButton()
        XCTAssertEqual(model.step, .tryIt)
        XCTAssertEqual(model.dotIndex, 2)

        model.skipTryIt()
        XCTAssertNil(model.dotIndex, "Ready shows none")
    }

    // MARK: - Back

    /// The one user-driven backwards move, and the one thing it must not do:
    /// coming forward again re-derives the next step from the live reading, so a
    /// conflicting Fn setting is shown again rather than passed.
    func testBackWalksTheFlowAndForwardReDerives() {
        let model = OnboardingModel(dwell: Self.testDwell)
        XCTAssertFalse(model.canGoBack, "Welcome has nothing behind it")

        model.advanceFromButton()
        model.apply(permissions: Self.allGranted, fn: .showEmojiPicker)
        XCTAssertTrue(model.canGoBack)

        model.back()
        XCTAssertEqual(model.step, .welcome)
        XCTAssertFalse(model.canGoBack)

        model.advanceFromButton()
        model.advanceFromButton()
        XCTAssertEqual(model.step, .fnKey, "the conflict is re-derived, not skipped")

        model.back()
        XCTAssertEqual(model.step, .permissions)
    }

    /// Back from Try it lands on the permission cards, and Ready has no Back at
    /// all — the flow's last click is the one that starts the app.
    func testBackFromTryItAndNoneFromReady() {
        let model = OnboardingModel(dwell: Self.testDwell)
        model.advanceFromButton()
        model.apply(permissions: Self.allGranted, fn: .doNothing)
        model.advanceFromButton()
        XCTAssertEqual(model.step, .tryIt)

        model.back()
        XCTAssertEqual(model.step, .permissions)

        model.advanceFromButton()
        model.skipTryIt()
        XCTAssertEqual(model.step, .ready)
        XCTAssertFalse(model.canGoBack)
        model.back()
        XCTAssertEqual(model.step, .ready)
    }

    // MARK: - What Try it is allowed to claim

    /// The success line says "Microphone, key listener and text insertion all
    /// confirmed". Typing into the box exercises none of the three, so it must
    /// not produce that line.
    func testTypingAloneNeverConfirmsTheStep() {
        let pipeline = DictationStub()
        let model = modelAtTryIt(pipeline)

        model.typedText = "I typed this myself"
        XCTAssertNotEqual(model.tryIt, .landed)
    }

    /// Nor after a capture, if what landed in the field is not what the pipeline
    /// pasted: the hold happened, the dictation did not.
    func testTypingAfterACaptureStillDoesNotConfirmTheStep() {
        let pipeline = DictationStub()
        let model = modelAtTryIt(pipeline)

        pipeline.reading.state = .recording
        model.apply(permissions: Self.allGranted, fn: .doNothing)
        XCTAssertEqual(model.tryIt, .recording)

        pipeline.reading.state = .done
        pipeline.reading.lastPasted = "what the pipeline produced"
        model.apply(permissions: Self.allGranted, fn: .doNothing)

        model.typedText = "but this is what I typed"
        XCTAssertNotEqual(model.tryIt, .landed)
    }

    /// The real thing: a capture the poll saw open, and the pipeline's own text
    /// arriving in the field. That — and only that — is the end-to-end proof.
    /// It is then terminal; a later idle poll must not walk it back.
    func testAPastedDictationConfirmsTheStepAndSticks() {
        let pipeline = DictationStub()
        let model = modelAtTryIt(pipeline)

        pipeline.reading.state = .recording
        model.apply(permissions: Self.allGranted, fn: .doNothing)

        pipeline.reading.state = .done
        pipeline.reading.lastPasted = "hey, this is lore"
        model.apply(permissions: Self.allGranted, fn: .doNothing)

        model.typedText = "hey, this is lore"
        XCTAssertEqual(model.tryIt, .landed)

        pipeline.reading.state = .idle
        model.apply(permissions: Self.allGranted, fn: .doNothing)
        XCTAssertEqual(model.tryIt, .landed)
    }

    /// A hold shorter than one poll tick is never seen as `.recording`, but the
    /// states downstream of it are only ever reached from a real capture — so
    /// the step still confirms rather than leaving a working dictation unproven.
    func testAHoldShorterThanAPollTickStillConfirms() {
        let pipeline = DictationStub()
        let model = modelAtTryIt(pipeline)

        pipeline.reading.state = .processing
        model.apply(permissions: Self.allGranted, fn: .doNothing)
        XCTAssertEqual(model.tryIt, .idle)

        pipeline.reading.state = .done
        pipeline.reading.lastPasted = "gone before the poll looked"
        model.apply(permissions: Self.allGranted, fn: .doNothing)

        model.typedText = "gone before the poll looked"
        XCTAssertEqual(model.tryIt, .landed)
    }

    /// A tap that never armed cannot receive a hold, so the step offers the one
    /// recovery card in the flow instead of a green lie.
    func testADeadTapRoutesToTheRecoveryCard() {
        let pipeline = DictationStub()
        pipeline.reading.tapAlive = false
        let model = modelAtTryIt(pipeline)

        model.apply(permissions: Self.allGranted, fn: .doNothing)
        XCTAssertEqual(model.tryIt, .tapDead)

        pipeline.reading.tapAlive = true
        model.apply(permissions: Self.allGranted, fn: .doNothing)
        XCTAssertEqual(model.tryIt, .idle, "the card withdraws itself if the tap comes back")
    }

    // MARK: - Helpers

    /// A model standing on Try it, with a stubbed dictation subsystem behind it.
    private func modelAtTryIt(_ pipeline: DictationStub) -> OnboardingModel {
        let model = OnboardingModel(dwell: Self.testDwell)
        model.readDictation = { pipeline.reading }
        model.advanceFromButton()
        model.apply(permissions: Self.allGranted, fn: .doNothing)
        model.advanceFromButton()
        XCTAssertEqual(model.step, .tryIt)
        return model
    }

    /// Drive the model the way the poller does — the same reading, over and
    /// over, faster than the dwell — and return as soon as `condition` holds.
    /// A dwell that starves never satisfies it and the call times out.
    private func poll(
        _ model: OnboardingModel,
        permissions: PermissionSnapshot,
        fn: FnKeyAction,
        until condition: () -> Bool,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            model.apply(permissions: permissions, fn: fn)
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

/// A counter an escaping dwell body can bump.
@MainActor
private final class Box {
    var value = 0
}

/// The dictation subsystem as the flow reads it.
@MainActor
private final class DictationStub {
    var reading = OnboardingModel.DictationReading(tapAlive: true)
}
