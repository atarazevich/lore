import XCTest
@testable import LoreKit

/// The surface that replaced the notch summon (#151): a quiet amber dot in the
/// mark's bead slot, shown only once a failure has *stood*, derived on every
/// read so it cannot outlive its condition. Design: docs/design/diagnostics.md §6.
@MainActor
final class MenuBarHealthTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// The monitor's injected clock; tests move it instead of waiting.
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    /// A monitor over a healthy machine. `onProbe` counts passes for the
    /// two-surfaces test; `emptyStore`/`liveness` are `HealthProberTests`'
    /// shared health fixtures.
    private func monitor(
        sleeper: @escaping @Sendable (Duration) async -> Void = { _ in },
        onProbe: @escaping () -> Void = {}
    ) -> HealthMonitor {
        HealthMonitor(
            prober: HealthProber(
                readTapLiveness: {
                    onProbe()
                    return HealthProberTests.liveness(alive: true, stalled: false)
                },
                readSecureInput: { HealthProberTests.secureInputState(active: false) },
                hasOpenAIKey: { true },
                store: HealthProberTests.emptyStore()
            ),
            now: { self.clock },
            sleep: sleeper
        )
    }

    override func setUp() { clock = t0 }

    // MARK: - Persistence

    /// One timeline, which is how the rule is actually experienced: a failure
    /// appears, repeats, and only once it has *stood* a full minute does the
    /// mark say anything. The repeat at +30 must not restart the clock — the
    /// condition never went away, so it may not buy another minute of silence.
    func testAFailureIsSilentUntilItHasStoodTheWholeWindow() {
        let monitor = monitor()

        monitor.note(.init(trigger: .captureFailed, succeeded: false))
        XCTAssertFalse(monitor.hasSustainedFailure, "it has stood for no time at all")

        clock = t0.addingTimeInterval(30)
        monitor.note(.init(trigger: .captureFailed, succeeded: false))
        XCTAssertFalse(monitor.hasSustainedFailure, "a repeat is the same condition, not a new one")

        clock = t0.addingTimeInterval(59)
        monitor.noteFailure(.captureFailed)
        XCTAssertFalse(monitor.hasSustainedFailure, "one second short is still short")

        clock = t0.addingTimeInterval(60)
        monitor.noteFailure(.captureFailed)
        XCTAssertTrue(monitor.hasSustainedFailure)
        XCTAssertEqual(monitor.sustainedSubjects, [.captureFailed])
    }

    /// Rule 2 of `no-false-positives`, which the notch surface kept failing:
    /// the condition clears, the report goes — on the same hop, not on a timer,
    /// not at the next screen change.
    func testARecoveryClearsTheDotImmediately() {
        let monitor = monitor()
        monitor.noteFailure(.captureFailed)
        clock = t0.addingTimeInterval(60)
        monitor.noteFailure(.captureFailed)
        XCTAssertTrue(monitor.hasSustainedFailure)

        clock = t0.addingTimeInterval(61)
        monitor.note(.init(trigger: .captureFailed, succeeded: true))

        XCTAssertFalse(monitor.hasSustainedFailure, "the condition is over — so is the claim")
        XCTAssertTrue(monitor.failingSince.isEmpty, "and nothing is left ticking")
    }

    /// A recovery on one subsystem says nothing about another: a mic delivering
    /// frames does not clear the system-audio tap's claim (the #149 conflation,
    /// now enforced one layer down).
    func testARecoveryClearsOnlyItsOwnCondition() {
        let monitor = monitor()
        monitor.noteFailure(.systemAudioFailed)
        monitor.noteFailure(.captureFailed)

        clock = t0.addingTimeInterval(60)
        monitor.clearFailure(.captureFailed)

        XCTAssertEqual(monitor.sustainedSubjects, [.systemAudioFailed])
    }

    /// The #144 identity notice enters the same rule rather than keeping its own
    /// (its false alarms are what ended the popup): when the re-granted
    /// permissions do work, the first keystroke acknowledges the ledger inside
    /// the window and the mark never says a word.
    func testAnIdentityMigrationAcknowledgedInsideTheWindowNeverShows() {
        let monitor = monitor()
        monitor.noteFailure(.identityMigration)

        clock = t0.addingTimeInterval(5)
        monitor.clearFailure(.identityMigration)

        XCTAssertFalse(monitor.hasSustainedFailure)
        XCTAssertTrue(
            HealthMonitor.sustainedFailures(among: monitor.failingSince,
                                            now: t0.addingTimeInterval(3600), delay: 60).isEmpty,
            "nothing survives the ack to resurface an hour later")
    }

    // MARK: - The time axis agrees with the panel's (#140 ceiling)

    /// Past 24 h the panel row behind a condition has already downgraded to
    /// "not tested recently", so the dot must stop claiming it too — two
    /// surfaces have to agree on the time axis as much as on the facts.
    func testAnObservationPastThePanelsCeilingStopsSustaining() {
        let day = TimeInterval(HealthLastAttempt.maxFreshAgeSeconds)
        let fresh = HealthMonitor.sustainedFailures(
            among: [.captureFailed: t0], now: t0.addingTimeInterval(day), delay: 60)
        XCTAssertEqual(fresh, [.captureFailed], "at the ceiling it still counts")

        let stale = HealthMonitor.sustainedFailures(
            among: [.captureFailed: t0], now: t0.addingTimeInterval(day + 1), delay: 60)
        XCTAssertTrue(stale.isEmpty, "past it the row says 'not tested recently' and so must the dot")
    }

    /// `.identityMigration` is the exception, and not an arbitrary one: its row
    /// is re-derived live from the ledger at every launch and never goes stale,
    /// so a ceiling on the dot would create the disagreement it exists to stop.
    func testTheIdentityMigrationNeverAgesOut() {
        let week = TimeInterval(HealthLastAttempt.maxFreshAgeSeconds) * 7
        let sustained = HealthMonitor.sustainedFailures(
            among: [.identityMigration: t0], now: t0.addingTimeInterval(week), delay: 60)
        XCTAssertEqual(sustained, [.identityMigration])
    }

    // MARK: - The wake

    /// The one moment the derivation changes with no event to carry it: a
    /// failure crossing the window while nothing else happens. The injected
    /// sleeper returns at once and the clock is moved past the crossing, so the
    /// wake's re-read is driven rather than waited out.
    func testTheWakePublishesACrossingNoEventAnnounces() async {
        let monitor = monitor(sleeper: { _ in })
        monitor.noteFailure(.pasteFailed)
        XCTAssertFalse(monitor.hasSustainedFailure)

        clock = t0.addingTimeInterval(60)
        await monitor.sustainWake?.value

        XCTAssertTrue(monitor.hasSustainedFailure,
                      "the crossing arrived on its own — nothing else was going to publish it")
        XCTAssertNil(monitor.sustainWake, "and nothing is left armed once everything has crossed")
    }

    // MARK: - Precedence

    /// The mark has one bead slot (#137). Recording wins it — rarer and
    /// time-critical — and losing the slot is not losing the condition: it keeps
    /// its own clock, so amber returns by itself when the recording ends.
    func testRecordingOutranksAmberAndAmberReturnsAfterwards() {
        XCTAssertEqual(MenuBarBead.resolve(recording: true, sustainedFailure: true), .recording)
        XCTAssertEqual(MenuBarBead.resolve(recording: true, sustainedFailure: false), .recording)
        XCTAssertEqual(MenuBarBead.resolve(recording: false, sustainedFailure: true), .health)
        XCTAssertEqual(MenuBarBead.resolve(recording: false, sustainedFailure: false), .none)
    }

    // MARK: - What the mark says

    /// The dot points; it never diagnoses (`no-false-positives` §3). One
    /// standing condition names its subject, several are counted — a set has no
    /// order worth arbitrating over.
    func testTheLabelNamesTheSubjectAndCountsBeyondOne() {
        let one = MenuBarController.label(for: .health, standing: [.pasteFailed])
        XCTAssertTrue(one.contains("paste needs a look"))
        XCTAssertFalse(one.localizedCaseInsensitiveContains("accessibility"),
                       "naming a cause would be an accusation the mark cannot support")

        let two = MenuBarController.label(for: .health, standing: [.pasteFailed, .captureFailed])
        XCTAssertTrue(two.contains("2 things need a look"))

        XCTAssertEqual(MenuBarController.label(for: .none, standing: []), LoreTheme.wordmark)
    }

    // MARK: - Traces (`no-false-positives` §5)

    /// Every transition leaves a pair, per condition and at that condition's own
    /// crossing — so two failures standing at once are two traces rather than
    /// one arbitrated winner, and a dot that appears or vanishes with nothing in
    /// events.json behind it stays impossible.
    func testEveryConditionTracesItsOwnCrossing() {
        let monitor = monitor()

        monitor.noteFailure(.pasteFailed)
        XCTAssertFalse(recorded(.healthConditionSustained(trigger: .pasteFailed)),
                       "nothing stands yet — and so nothing is claimed in the record either")

        clock = t0.addingTimeInterval(60)
        monitor.noteFailure(.pasteFailed)
        XCTAssertTrue(recorded(.healthConditionSustained(trigger: .pasteFailed)))

        // A second condition crosses later and gets its own trace, not a
        // rewrite of the first.
        clock = t0.addingTimeInterval(100)
        monitor.noteFailure(.modelLoadFailed)
        clock = t0.addingTimeInterval(160)
        monitor.noteFailure(.modelLoadFailed)
        XCTAssertTrue(recorded(.healthConditionSustained(trigger: .modelLoadFailed)))
        XCTAssertEqual(monitor.sustainedSubjects, [.pasteFailed, .modelLoadFailed])

        monitor.clearFailure(.pasteFailed)
        XCTAssertTrue(recorded(.healthConditionCleared(trigger: .pasteFailed)))
        XCTAssertTrue(monitor.hasSustainedFailure, "the other one is still standing")
    }

    /// A failure that heals inside the window is a non-event in every sense:
    /// no dot, and no trace claiming one.
    func testAFailureThatHealsInsideTheWindowLeavesNoTrace() {
        let monitor = monitor()
        monitor.noteFailure(.systemAudioFailed)
        clock = t0.addingTimeInterval(10)
        monitor.clearFailure(.systemAudioFailed)

        XCTAssertFalse(recorded(.healthConditionSustained(trigger: .systemAudioFailed)))
        XCTAssertFalse(recorded(.healthConditionCleared(trigger: .systemAudioFailed)))
    }

    // MARK: - The two surfaces agree

    /// The dot and the panel are published by one pass over one prober, so they
    /// cannot disagree about the machine (`no-false-positives` §2). Counted
    /// rather than compared: what matters is that no signal moves the dot
    /// without re-reading the state the panel will show behind it.
    func testTheDotAndThePanelArePublishedFromOneReading() {
        var probes = 0
        let monitor = monitor(onProbe: { probes += 1 })
        let atInit = probes

        monitor.note(.init(trigger: .captureFailed, succeeded: false))
        XCTAssertEqual(probes, atInit + 1, "the failure re-read the chain the panel renders")
        XCTAssertFalse(monitor.items.isEmpty, "and published it")

        monitor.note(.init(trigger: .captureFailed, succeeded: true))
        XCTAssertEqual(probes, atInit + 2, "so did the recovery")
    }

    /// And the panel has a row for what the dot points at: a failed paste is
    /// read from the same `pasteAttempt` the `pasteFailed` condition is, so the
    /// gauge can never be silent about a subject the mark is naming.
    func testAFailedPasteReachesThePanelAsItsOwnRow() {
        let store = HealthProberTests.emptyStore()
        store.record(.pasteAttempt(kind: .paste, eventsCreated: false, accessibilityTrusted: false))
        let prober = HealthProber(
            readTapLiveness: { HealthProberTests.liveness(alive: true, stalled: false) },
            readSecureInput: { HealthProberTests.secureInputState(active: false) },
            hasOpenAIKey: { true },
            store: store
        )

        let row = prober.probe().items.first { $0.result.id == .paste }
        XCTAssertEqual(row?.result.status, .failed)
        XCTAssertTrue(row?.remedy?.actions.contains(.openSettings(.accessibility)) == true,
                      "the remedy names the grant a posted Cmd+V needs")
        XCTAssertTrue(row?.remedy?.instruction.localizedCaseInsensitiveContains("clipboard") == true,
                      "and what the user can still do about the text that did not land")
    }

    // MARK: - Helpers

    private func recorded(_ event: DiagEvent) -> Bool {
        DiagStore.shared.recent(DiagStore.capacity).contains { $0.event == event }
    }
}
