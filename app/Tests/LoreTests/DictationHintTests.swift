import Foundation
import XCTest
@testable import LoreKit

/// The contextual hints (#235): the arbiter's whole policy, and the copy table
/// the board fixed.
///
/// Every deadline the arbiter has is derived from the `now` it is handed rather
/// than from a timer of its own, so six seconds, twenty seconds of quiet and
/// five of digital silence are all reachable here without waiting for any of
/// them — and what is tested is the rule rather than the scheduler.
@MainActor
final class DictationHintTests: XCTestCase {

    /// A fixed moment, so "today" is one day for the whole of a test run and a
    /// rerun repeats exactly.
    private let start = Date(timeIntervalSince1970: 1_757_000_000)

    private var storage: EphemeralDictation!
    /// Where this test's own share of the shared diagnostic ring begins.
    private var mark = 0

    override func setUp() async throws {
        try await super.setUp()
        storage = EphemeralDictation("DictationHintTests")
        mark = DiagStream.mark()
    }

    override func tearDown() async throws {
        storage.tearDown()
        storage = nil
        try await super.tearDown()
    }

    // MARK: - The copy table is the contract

    /// Every sentence, byte for byte from the board's §06. Two of the five are
    /// marked "reused word for word" there, and the two rows below hold them to
    /// the element's own tooltip so the claim cannot quietly stop being true.
    func testEveryHintSaysTheBoardsWords() {
        let fn = HotkeyKey.fn.shortName
        XCTAssertEqual(
            DictationHint.lock.sentence(talkKey: fn).plain,
            "Space locks recording, hands free"
        )
        XCTAssertEqual(
            DictationHint.howItEnds.sentence(talkKey: fn).plain,
            "Press Fn to paste, Esc to cancel"
        )
        XCTAssertEqual(
            DictationHint.pause.sentence(talkKey: fn).plain, "Recording \u{2014} click to pause"
        )
        XCTAssertEqual(
            DictationHint.cleanup.sentence(talkKey: fn).plain, "Fn+V cleans up on paste"
        )
        XCTAssertEqual(
            DictationHint.silentMic.sentence(talkKey: fn).plain,
            "No sound is reaching the microphone"
        )
        XCTAssertEqual(BubbleTipCard.closeName, "Don't show again")

        // "Reused word for word": the lock hint is the open shackle's own
        // tooltip, and "how it ends" is the locked one's.
        XCTAssertEqual(
            DictationHint.howItEnds.sentence(talkKey: fn).plain,
            "Press " + DictationIndicatorView.lockedWaysOut(talkKey: fn)
        )
        // The talk key is whichever one the user recorded (#226), on both.
        XCTAssertEqual(
            DictationHint.howItEnds.sentence(talkKey: "R\u{2318}").plain,
            "Press R\u{2318} to paste, Esc to cancel"
        )
        XCTAssertEqual(
            DictationHint.cleanup.sentence(talkKey: "R\u{2318}").plain,
            "R\u{2318}+V cleans up on paste"
        )
    }

    /// Each hint is at most two lines, which is the room the canvas keeps under
    /// the shape — so a card appearing can never resize the window. The talk key
    /// is the only thing that varies the sentence, so the longest keycap name
    /// the recorder can produce is what this asks about.
    func testNoHintNeedsMoreThanTheTwoLinesTheCanvasReserves() {
        for hint in DictationHint.allCases {
            XCTAssertLessThanOrEqual(
                hint.sentence(talkKey: "R\u{2318}").count, 2, "\(hint) needs a third line"
            )
        }
    }

    /// Report before lesson, and the concept's order among the lessons. The
    /// declaration order *is* the priority list, so this is what pins it.
    func testPriorityIsReportBeforeLesson() {
        XCTAssertEqual(
            DictationHint.allCases, [.silentMic, .lock, .howItEnds, .pause, .cleanup]
        )
    }

    // MARK: - When a hint may speak

    func testTheLockSpeaksAtTenSecondsAndNotBefore() {
        let arbiter = makeArbiter()
        XCTAssertNil(arbiter.tick(signals(elapsed: 9), now: start))
        XCTAssertEqual(arbiter.tick(signals(elapsed: 10), now: start + 1), .lock)
    }

    func testNothingSpeaksInTheRecordingsFirstTwoSeconds() {
        let arbiter = makeArbiter()
        // The trigger is satisfied — a long-running recording's elapsed cannot
        // be under two seconds, so this is the gate alone that answers.
        XCTAssertNil(arbiter.tick(signals(elapsed: 1, noSignal: true), now: start + 60))
        XCTAssertNil(arbiter.tick(signals(elapsed: 1, noSignal: true), now: start + 61))
    }

    func testNothingSpeaksOverAFailureFaceWhilePausedOrUnderAHoverTooltip() {
        for (name, blocked) in [
            ("a failure face", signals(failure: true, elapsed: 30)),
            ("paused", signals(elapsed: 30, paused: true)),
            ("a hover tooltip", signals(elapsed: 30, hoverTip: true)),
        ] {
            let arbiter = makeArbiter()
            XCTAssertNil(arbiter.tick(blocked, now: start), "a hint spoke over \(name)")
        }
    }

    func testALockedRecordingNeverSeesTheLockHint() {
        let arbiter = makeArbiter()
        for elapsed in [3, 10, 60, 300] {
            XCTAssertNotEqual(
                arbiter.tick(signals(elapsed: elapsed, locked: true), now: start + 1),
                .lock, "the open lock spoke inside a locked recording at \(elapsed) s"
            )
        }
    }

    func testCleanupSpeaksAtTwoMinutesAndNeverWhenItIsAlreadyOn() {
        let armed = retireTheLockLessons(makeArbiter())
        XCTAssertNil(armed.tick(signals(elapsed: 200, cleanupArmed: true), now: start))

        // Cleanup on for every dictation: the arbiter reads that setting itself.
        let (byDefault, settings) = makeArbiterAndSettings()
        settings.cleanupByDefault = true
        retireTheLockLessons(byDefault)
        XCTAssertNil(byDefault.tick(signals(elapsed: 200), now: start))
        XCTAssertTrue(settings.dictationHints[.cleanup].done)

        let arbiter = retireTheLockLessons(makeArbiter())
        XCTAssertNil(arbiter.tick(signals(elapsed: 119), now: start))
        XCTAssertEqual(arbiter.tick(signals(elapsed: 120), now: start + 1), .cleanup)
    }

    /// Twenty seconds under the speech floor, and only after speech was heard —
    /// a recording that has been silent from the first frame is the microphone
    /// report's business, not the pause's.
    func testThePauseSpeaksAfterTwentySecondsOfQuiet() {
        let arbiter = makeArbiter()
        arbiter.tick(signals(elapsed: 5, locked: true, level: 0.6), now: start)
        // The lock transition on the first tick latched "how it ends"; let it
        // speak and leave, so the pause's own trigger is what answers below.
        XCTAssertEqual(
            show(arbiter, signals(elapsed: 6, locked: true), now: start + 1), .howItEnds
        )
        arbiter.tick(signals(capturing: false), now: start + 2)

        arbiter.tick(signals(elapsed: 5, locked: true, level: 0.6), now: start + 10)
        arbiter.tick(signals(elapsed: 6, locked: true, level: 0.01), now: start + 11)
        XCTAssertNil(
            arbiter.tick(signals(elapsed: 25, locked: true, level: 0.01), now: start + 30),
            "nineteen seconds of quiet was enough"
        )
        XCTAssertEqual(
            arbiter.tick(signals(elapsed: 26, locked: true, level: 0.01), now: start + 31), .pause
        )
    }

    func testASoundResetsTheQuietClock() {
        let arbiter = makeArbiter()
        arbiter.tick(signals(elapsed: 5, locked: true, level: 0.6), now: start)
        arbiter.tick(signals(elapsed: 6, locked: true), now: start + 1)  // "how it ends"
        arbiter.tick(signals(capturing: false), now: start + 2)
        arbiter.tick(signals(elapsed: 5, locked: true, level: 0.6), now: start + 10)
        arbiter.tick(signals(elapsed: 6, locked: true, level: 0.01), now: start + 11)
        // Nineteen seconds in, one word — the twenty starts again.
        arbiter.tick(signals(elapsed: 25, locked: true, level: 0.6), now: start + 30)
        XCTAssertNil(
            arbiter.tick(signals(elapsed: 40, locked: true, level: 0.01), now: start + 45)
        )
    }

    // MARK: - The report

    /// Five seconds of digital silence with frames arriving, and it goes the
    /// instant sound arrives — live and self-clearing (`no-false-positives.md`).
    func testTheReportStandsAfterFiveSecondsAndClearsTheInstantSoundArrives() {
        let arbiter = makeArbiter()
        arbiter.tick(signals(elapsed: 3, noSignal: true, level: 0), now: start)
        XCTAssertNil(
            arbiter.tick(signals(elapsed: 7, noSignal: true, level: 0), now: start + 4),
            "four seconds of silence was enough"
        )
        XCTAssertEqual(
            show(arbiter, signals(elapsed: 8, noSignal: true, level: 0), now: start + 5),
            .silentMic
        )
        // Sound arrives: the card is gone on the same tick, well inside its six
        // seconds — and says why, which is not a lesson's `actionPerformed`.
        XCTAssertNil(arbiter.tick(signals(elapsed: 9, level: 0.6), now: start + 6))
        XCTAssertEqual(
            lastWithdrawal(), .conditionCleared, "the report outstayed its condition"
        )
    }

    /// A pause tears the capture down, so `noSignal` goes false with it: the
    /// report's condition has ended, and that is the exit it takes rather than a
    /// lesson's displacement.
    func testAPauseClearsTheReportsCondition() {
        let arbiter = makeArbiter()
        reportSilence(arbiter)
        XCTAssertNil(arbiter.tick(signals(elapsed: 9, paused: true, level: 0), now: start + 6))
        XCTAssertEqual(lastWithdrawal(), .conditionCleared)
    }

    /// The report is not a lesson: it is never counted against the three days,
    /// never closed, and may speak in a recording where a lesson already has.
    func testTheReportIsNeitherCountedNorSuppressedByALesson() {
        let (arbiter, settings) = makeArbiterAndSettings()
        arbiter.tick(signals(elapsed: 3), now: start)
        XCTAssertEqual(show(arbiter, signals(elapsed: 10), now: start + 1), .lock)
        arbiter.tick(signals(elapsed: 11, hoverTip: true), now: start + 2)  // displaced

        arbiter.tick(signals(elapsed: 12, noSignal: true, level: 0), now: start + 3)
        XCTAssertEqual(
            show(arbiter, signals(elapsed: 20, noSignal: true, level: 0), now: start + 9),
            .silentMic,
            "a lesson shown earlier in this recording suppressed a true report"
        )
        XCTAssertTrue(settings.dictationHints[.silentMic].shownDays.isEmpty)
    }

    /// One card per standing silence: a microphone that stays muted is named
    /// once, and the dimmed dot and flat bars go on saying it (#216).
    func testAStandingSilenceIsReportedOnceUntilSoundComesBack() {
        let arbiter = retireTheLockLessons(makeArbiter())
        reportSilence(arbiter)
        XCTAssertNil(arbiter.tick(signals(elapsed: 20, noSignal: true, level: 0), now: start + 12))
        XCTAssertNil(arbiter.tick(signals(elapsed: 40, noSignal: true, level: 0), now: start + 40))
    }

    // MARK: - How a card goes

    func testTheCardLeavesAfterSixSeconds() {
        let arbiter = makeArbiter()
        XCTAssertEqual(show(arbiter, signals(elapsed: 10), now: start), .lock)
        XCTAssertEqual(arbiter.tick(signals(elapsed: 15), now: start + 5.9), .lock)
        XCTAssertNil(arbiter.tick(signals(elapsed: 16), now: start + 6))
        XCTAssertEqual(lastWithdrawal(), .timedOut)
    }

    func testHoveringHoldsTheCardAndTheSixSecondsStartAgainWhenThePointerLeaves() {
        let arbiter = makeArbiter()
        XCTAssertEqual(show(arbiter, signals(elapsed: 10), now: start), .lock)
        arbiter.hold(true)
        XCTAssertEqual(arbiter.tick(signals(elapsed: 40), now: start + 30), .lock)
        arbiter.hold(false)
        XCTAssertEqual(
            arbiter.tick(signals(elapsed: 45), now: start + 35), .lock,
            "the six seconds did not start again when the pointer left"
        )
        XCTAssertNil(arbiter.tick(signals(elapsed: 46), now: start + 36.1))
    }

    func testPerformingTheActionTakesTheCardDown() {
        let (arbiter, settings) = makeArbiterAndSettings()
        XCTAssertEqual(show(arbiter, signals(elapsed: 10), now: start), .lock)
        XCTAssertNil(arbiter.tick(signals(elapsed: 11, locked: true), now: start + 1))
        XCTAssertEqual(lastWithdrawal(), .actionPerformed)
        XCTAssertTrue(settings.dictationHints[.lock].done)
    }

    func testAHoverTooltipDisplacesTheCardAndItStillCountsAsShown() {
        let (arbiter, settings) = makeArbiterAndSettings()
        XCTAssertEqual(show(arbiter, signals(elapsed: 10), now: start), .lock)
        XCTAssertNil(arbiter.tick(signals(elapsed: 11, hoverTip: true), now: start + 1))
        XCTAssertEqual(lastWithdrawal(), .displaced)
        XCTAssertEqual(settings.dictationHints[.lock].shownDays.count, 1)
    }

    func testTheEndOfTheRecordingTakesTheCardDown() {
        let arbiter = makeArbiter()
        XCTAssertEqual(show(arbiter, signals(elapsed: 10), now: start), .lock)
        XCTAssertNil(arbiter.tick(signals(capturing: false), now: start + 1))
        XCTAssertEqual(lastWithdrawal(), .recordingEnded)
    }

    func testACancelledDictationTakesTheCardDown() {
        let arbiter = makeArbiter()
        XCTAssertEqual(show(arbiter, signals(elapsed: 10), now: start), .lock)
        XCTAssertNil(arbiter.tick(signals(cancelled: true, elapsed: 11), now: start + 1))
        XCTAssertEqual(lastWithdrawal(), .recordingEnded)
    }

    func testTheCrossEndsTheHintForGood() {
        let (arbiter, settings) = makeArbiterAndSettings()
        XCTAssertEqual(show(arbiter, signals(elapsed: 10), now: start), .lock)
        arbiter.close()
        XCTAssertNil(arbiter.showing)
        XCTAssertEqual(lastWithdrawal(), .closed)
        XCTAssertTrue(settings.dictationHints[.lock].closed)

        // Tomorrow, in a fresh recording, with the trigger satisfied.
        arbiter.tick(signals(capturing: false), now: start + 60)
        XCTAssertNil(arbiter.tick(signals(elapsed: 10), now: start + 86_400))
    }

    /// The report carries no ×, so nothing can close it.
    func testTheReportCannotBeClosed() {
        let (arbiter, settings) = makeArbiterAndSettings()
        reportSilence(arbiter)
        arbiter.close()
        XCTAssertEqual(arbiter.showing, .silentMic)
        XCTAssertFalse(settings.dictationHints[.silentMic].closed)
    }

    /// A pause takes a standing lesson down: a card teaching a live recording
    /// has nothing to say over a capture standing still, and the policy that
    /// keeps a hint from appearing while paused has to hold for one already up.
    func testAPauseTakesAStandingLessonDown() {
        let (arbiter, settings) = makeArbiterAndSettings()
        XCTAssertEqual(show(arbiter, signals(elapsed: 10), now: start), .lock)
        XCTAssertNil(arbiter.tick(signals(elapsed: 11, paused: true), now: start + 1))
        XCTAssertEqual(lastWithdrawal(), .displaced)
        // It was on screen, so it still spent its day.
        XCTAssertEqual(settings.dictationHints[.lock].shownDays.count, 1)
    }

    // MARK: - A card nobody saw

    /// The cleanup card speaks from the `V` keycap, which only exists once the
    /// rail has widened — so the shape reports when the card is really drawn,
    /// and nothing is spent until it is. A day, a trace and the six seconds all
    /// start there.
    func testACardTheShapeCannotDrawYetSpendsNothing() {
        let (arbiter, settings) = makeArbiterAndSettings()
        retireTheLockLessons(arbiter)

        // Chosen, and the shape has not drawn it yet.
        let mark = DiagStream.mark()
        XCTAssertEqual(
            arbiter.tick(signals(cardDrawn: false, elapsed: 200), now: start), .cleanup
        )
        XCTAssertNil(arbiter.showing, "an undrawn card was counted as showing")
        XCTAssertTrue(settings.dictationHints[.cleanup].shownDays.isEmpty)
        XCTAssertTrue(DiagStream.events(since: mark).isEmpty, "an undrawn card left a trace")

        // The rail widens, the anchor arrives, the card is on screen.
        XCTAssertEqual(arbiter.tick(signals(elapsed: 201), now: start + 1), .cleanup)
        XCTAssertEqual(arbiter.showing, .cleanup)
        XCTAssertEqual(settings.dictationHints[.cleanup].shownDays.count, 1)
        XCTAssertTrue(DiagStream.events(since: mark).contains(.hintShown(hint: .cleanup)))

        // And the six seconds run from there, not from the choice.
        XCTAssertEqual(arbiter.tick(signals(elapsed: 206), now: start + 6.5), .cleanup)
        XCTAssertNil(arbiter.tick(signals(elapsed: 208), now: start + 7.1))
    }

    /// A card the shape never manages to draw is dropped as quietly as it was
    /// chosen: no day, no trace, and the recording is not left holding it.
    func testACardTheShapeNeverDrawsIsDroppedUnshown() {
        let (arbiter, settings) = makeArbiterAndSettings()
        let mark = DiagStream.mark()
        XCTAssertEqual(arbiter.tick(signals(cardDrawn: false, elapsed: 10), now: start), .lock)
        XCTAssertNil(arbiter.tick(signals(cardDrawn: false, elapsed: 16), now: start + 6.1))
        XCTAssertTrue(settings.dictationHints[.lock].shownDays.isEmpty)
        XCTAssertTrue(DiagStream.events(since: mark).isEmpty, "a card nobody saw left a trace")
        // And the recording's one lesson was not spent on it.
        XCTAssertEqual(arbiter.tick(signals(elapsed: 20), now: start + 7), .lock)
    }

    // MARK: - How often it may return

    func testOnlyOneLessonPerRecording() {
        let arbiter = makeArbiter()
        XCTAssertEqual(show(arbiter, signals(elapsed: 10), now: start), .lock)
        arbiter.tick(signals(elapsed: 16), now: start + 6)  // timed out
        // Two minutes in, with cleanup unarmed: eligible, triggered, and refused
        // because this recording has already had its hint.
        XCTAssertNil(arbiter.tick(signals(elapsed: 130), now: start + 130))
    }

    func testAHintIsNotShownTwiceInOneDay() {
        let arbiter = makeArbiter()
        XCTAssertEqual(show(arbiter, signals(elapsed: 10), now: start), .lock)
        arbiter.tick(signals(capturing: false), now: start + 7)
        XCTAssertNil(
            arbiter.tick(signals(elapsed: 10), now: start + 600),
            "the same hint spoke twice in one day"
        )
    }

    func testThreeDaysIsTheCeiling() {
        let (arbiter, settings) = makeArbiterAndSettings()
        for day in 0..<3 {
            let now = start + Double(day) * 86_400
            XCTAssertEqual(
                show(arbiter, signals(elapsed: 10), now: now), .lock, "day \(day) said nothing"
            )
            arbiter.tick(signals(capturing: false), now: now + 7)
        }
        XCTAssertEqual(settings.dictationHints[.lock].shownDays.count, 3)
        XCTAssertNil(
            arbiter.tick(signals(elapsed: 10), now: start + 3 * 86_400),
            "a fourth day spoke past the ceiling"
        )
    }

    /// The action retires a hint whether or not it was ever shown: a user who
    /// already locks never sees the lock hint at all.
    func testTheActionRetiresTheHintUnseen() {
        let (arbiter, settings) = makeArbiterAndSettings()
        arbiter.tick(signals(elapsed: 3, locked: true), now: start)
        arbiter.tick(signals(capturing: false), now: start + 1)
        XCTAssertTrue(settings.dictationHints[.lock].done)
        XCTAssertTrue(settings.dictationHints[.lock].shownDays.isEmpty)
        // Tomorrow, ten seconds into a held recording — nothing.
        XCTAssertNil(arbiter.tick(signals(elapsed: 10), now: start + 86_400))
    }

    /// "How it ends" speaks on the first lock ever, and the first finish from a
    /// locked recording retires it — which is what makes "the first time ever"
    /// true without a second flag to keep.
    func testHowItEndsSpeaksOnTheFirstLockAndRetiresAtTheFirstLockedFinish() {
        let (arbiter, settings) = makeArbiterAndSettings()
        arbiter.tick(signals(elapsed: 3, locked: true), now: start)
        XCTAssertEqual(
            show(arbiter, signals(elapsed: 4, locked: true), now: start + 1), .howItEnds
        )
        arbiter.tick(signals(capturing: false), now: start + 2)
        XCTAssertTrue(settings.dictationHints[.howItEnds].done)

        // A second lock, tomorrow: the lesson is over.
        arbiter.tick(signals(elapsed: 3, locked: true), now: start + 86_400)
        XCTAssertNil(arbiter.tick(signals(elapsed: 4, locked: true), now: start + 86_401))
    }

    // MARK: - What is remembered

    func testTheRecordSurvivesRelaunch() {
        let settings = isolatedSettings("DictationHintTests", defaults: storage.defaults)
        let arbiter = DictationHintArbiter(settings: settings, history: nil)
        XCTAssertEqual(show(arbiter, signals(elapsed: 10), now: start), .lock)
        arbiter.close()

        // The settings a next launch would build over the same defaults.
        let relaunched = isolatedSettings("DictationHintTests", defaults: storage.defaults)
        XCTAssertTrue(relaunched.dictationHints[.lock].closed)
        XCTAssertEqual(relaunched.dictationHints[.lock].shownDays.count, 1)
    }

    /// Seeded from what history can answer: a cleaned entry means this user
    /// already knows about cleanup, so the hint is done before it is ever shown.
    /// Read at every launch rather than behind a first-run flag, so an entry
    /// cleaned after the update counts too.
    func testACleanedEntryInHistorySeedsCleanupDone() {
        let history = storage.history()
        var entry = DictationHistoryEntry(durationSeconds: 180)
        entry.rawText = "raw"
        entry.cleanedText = "cleaned"
        entry.status = .cleaned
        history.add(entry)

        let settings = isolatedSettings("DictationHintTests")
        let arbiter = retireTheLockLessons(
            DictationHintArbiter(settings: settings, history: history)
        )
        XCTAssertTrue(settings.dictationHints[.cleanup].done)
        XCTAssertNil(arbiter.tick(signals(elapsed: 200), now: start))
    }

    func testAHistoryWithNothingCleanedSeedsNothing() {
        let history = storage.history()
        history.add(DictationHistoryEntry(durationSeconds: 12))
        let settings = isolatedSettings("DictationHintTests")
        let arbiter = retireTheLockLessons(
            DictationHintArbiter(settings: settings, history: history)
        )
        XCTAssertFalse(settings.dictationHints[.cleanup].done)
        XCTAssertEqual(arbiter.tick(signals(elapsed: 200), now: start), .cleanup)
    }

    /// Eligibility, as the record answers it on its own. Days are calendar days
    /// in the user's own calendar, so a showing at midday and one an hour later
    /// are the same day and one 24 hours on is not.
    func testEligibilityIsNotClosedNotDoneUnderThreeDaysAndNotToday() {
        var record = DictationHintRecord()
        XCTAssertTrue(record.isEligible(.lock, now: start))

        record.markShown(.lock, on: start)
        XCTAssertFalse(record.isEligible(.lock, now: start), "twice in one day")
        XCTAssertFalse(
            record.isEligible(.lock, now: start + 3600), "an hour later is the same day"
        )
        XCTAssertTrue(record.isEligible(.lock, now: start + 86_400))

        record.markShown(.lock, on: start + 86_400)
        record.markShown(.lock, on: start + 2 * 86_400)
        XCTAssertFalse(
            record.isEligible(.lock, now: start + 3 * 86_400), "past the three-day ceiling"
        )

        var closed = DictationHintRecord()
        closed.markClosed(.pause)
        XCTAssertFalse(closed.isEligible(.pause, now: start))

        var done = DictationHintRecord()
        done.markDone(.cleanup)
        XCTAssertFalse(done.isEligible(.cleanup, now: start))

        // The report is never gated by any of it.
        var report = DictationHintRecord()
        report.markShown(.silentMic, on: start)
        report.markClosed(.silentMic)
        report.markDone(.silentMic)
        XCTAssertTrue(report.isEligible(.silentMic, now: start))
    }

    // MARK: - Tracing

    func testEveryAppearanceAndExitLeavesATrace() {
        let arbiter = makeArbiter()
        XCTAssertEqual(show(arbiter, signals(elapsed: 10), now: start), .lock)
        arbiter.tick(signals(elapsed: 16), now: start + 6)
        let events = DiagStream.events(since: mark)
        XCTAssertTrue(events.contains(.hintShown(hint: .lock)))
        XCTAssertTrue(events.contains(.hintWithdrawn(hint: .lock, reason: .timedOut)))
    }

    // MARK: - Fixtures

    private func makeArbiter() -> DictationHintArbiter { makeArbiterAndSettings().0 }

    /// One hint, up on screen the way the app puts it there: the arbiter chooses
    /// it on one tick, the shape draws it, and the next tick is where it starts
    /// costing a day, leaving a trace and running its six seconds.
    @discardableResult
    private func show(
        _ arbiter: DictationHintArbiter, _ moment: DictationHintSignals, now: Date
    ) -> DictationHint? {
        arbiter.tick(moment, now: now)
        return arbiter.tick(moment, now: now)
    }

    /// The report's card on screen: five seconds of digital silence with frames
    /// arriving, which is the only way to get there.
    private func reportSilence(_ arbiter: DictationHintArbiter) {
        arbiter.tick(signals(elapsed: 3, noSignal: true, level: 0), now: start)
        XCTAssertEqual(
            show(arbiter, signals(elapsed: 8, noSignal: true, level: 0), now: start + 5),
            .silentMic
        )
    }

    /// An arbiter for someone who already locks: one lock, yesterday, retires
    /// both lock lessons by the action — exactly as it does for anyone who has
    /// ever pressed Space. Tests about the hints *below* those two in the
    /// priority order start here, so what answers is their own trigger and not
    /// a lesson that outranks them.
    @discardableResult
    private func retireTheLockLessons(_ arbiter: DictationHintArbiter) -> DictationHintArbiter {
        arbiter.tick(signals(elapsed: 3, locked: true), now: start - 86_400)
        arbiter.tick(signals(capturing: false), now: start - 86_400 + 1)
        return arbiter
    }

    private func makeArbiterAndSettings() -> (DictationHintArbiter, AppSettings) {
        let settings = isolatedSettings("DictationHintTests")
        return (DictationHintArbiter(settings: settings, history: nil), settings)
    }

    /// A running, held, audible recording whose shape draws whatever it is given
    /// — the row every test varies one field of. `level` is above the speech
    /// floor by default, so nothing is quiet unless a test says so.
    private func signals(
        capturing: Bool = true,
        cancelled: Bool = false,
        failure: Bool = false,
        cardDrawn: Bool = true,
        elapsed: Int = 30,
        locked: Bool = false,
        paused: Bool = false,
        hoverTip: Bool = false,
        noSignal: Bool = false,
        level: Float = 0.6,
        cleanupArmed: Bool = false
    ) -> DictationHintSignals {
        DictationHintSignals(
            capturing: capturing && !cancelled,
            // The shape's own predicate, given the same three facts the poll
            // reads — so a test cannot set up a state the app cannot be in.
            canSpeak: DictationIndicatorView.canExpand(
                state: capturing ? .recording : .processing,
                error: failure ? .pasteFailed : nil,
                cancelled: cancelled
            ),
            cardDrawn: cardDrawn,
            elapsedSeconds: elapsed, locked: locked, paused: paused,
            hoverTipShowing: hoverTip, noSignal: noSignal, level: level,
            cleanupArmed: cleanupArmed
        )
    }

    /// The reason on the last `hintWithdrawn` *this test* caused. Scoped to the
    /// test's own mark, so an exit that never happened reads as nil rather than
    /// as whatever the test before it left in the shared ring.
    private func lastWithdrawal() -> DiagEvent.HintWithdrawal? {
        DiagStream.events(since: mark).reversed().compactMap {
            if case .hintWithdrawn(_, let reason) = $0 { reason } else { nil }
        }.first
    }
}
