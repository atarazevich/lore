import AppKit
import XCTest
@testable import LoreKit

/// One notch at a time, and the right one. The rule matters because the launch
/// migration summon (#135) is non-critical and holds the notch for its whole
/// 30-second timeout — which is precisely the window in which the user, having
/// just been told to remove Lore from Accessibility and Input Monitoring, has
/// failing pastes and captures to be told about (#140). A summon dropped here
/// could go unseen for the rest of the outage.
@MainActor
final class HealthNotchPresenterTests: XCTestCase {

    private func presenter() -> HealthNotchPresenter {
        HealthNotchPresenter(timeout: .seconds(60))
    }

    func testAFailedActionDisplacesThePendingMigrationNotice() {
        let notch = presenter()
        notch.present(HealthSummon(trigger: .identityMigration))
        XCTAssertEqual(notch.onScreen?.trigger, .identityMigration)

        notch.present(HealthSummon(trigger: .pasteFailed, explanation: .accessibility))
        XCTAssertEqual(notch.onScreen?.trigger, .pasteFailed,
                       "the failure must reach the user while the migration notice is up")
    }

    func testTheMigrationNoticeNeverInterruptsAFailureSummon() {
        let notch = presenter()
        notch.present(HealthSummon(trigger: .captureFailed))
        notch.present(HealthSummon(trigger: .identityMigration))
        XCTAssertEqual(notch.onScreen?.trigger, .captureFailed)
    }

    func testOneFailureSummonDoesNotRestartAnother() {
        let notch = presenter()
        notch.present(HealthSummon(trigger: .captureFailed))
        notch.present(HealthSummon(trigger: .pasteFailed))
        XCTAssertEqual(notch.onScreen?.trigger, .captureFailed,
                       "first come, first served among equals — no churn on the notch")
    }

    func testDismissFreesTheNotch() {
        let notch = presenter()
        notch.present(HealthSummon(trigger: .identityMigration))
        notch.dismiss()
        XCTAssertNil(notch.onScreen)

        notch.present(HealthSummon(trigger: .identityMigration))
        XCTAssertEqual(notch.onScreen?.trigger, .identityMigration)
    }

    /// Self-clear (#144): the ledger's acknowledge withdraws the migration
    /// notice while it is up — and only that notice; a failure summon reports
    /// its own event, not the ledger, and must survive the ack.
    func testClearSummonWithdrawsOnlyTheMatchingSummon() {
        let notch = presenter()
        notch.present(HealthSummon(trigger: .identityMigration))
        notch.clearSummon(trigger: .identityMigration)
        XCTAssertNil(notch.onScreen, "the ledger acknowledged — the claim is stale")

        notch.present(HealthSummon(trigger: .captureFailed))
        notch.clearSummon(trigger: .identityMigration)
        XCTAssertEqual(notch.onScreen?.trigger, .captureFailed,
                       "a failure summon is not the ledger's to clear")
    }

    /// Rule 2 of `no-false-positives` reaches the failure summons too (#149):
    /// the user grants Screen & System Audio Recording, the next capture works,
    /// and the notch withdraws instead of sitting there until its timeout.
    func testASystemAudioSummonWithdrawsWhenTheCaptureSucceeds() {
        let notch = presenter()
        notch.present(HealthSummon(trigger: .systemAudioFailed))
        XCTAssertEqual(notch.onScreen?.trigger, .systemAudioFailed)

        let recovered = try! XCTUnwrap(
            HealthMonitor.summonSignal(for: .systemAudioCapture(outcome: .ok, osStatus: nil))
        )
        XCTAssertTrue(recovered.succeeded)
        notch.clearSummon(trigger: recovered.trigger)
        XCTAssertNil(notch.onScreen, "the condition cleared — so does the report")
    }

    // MARK: - The ghost (#149)

    /// The incident: a "Recording failed" summon appeared on a process that had
    /// recorded no failure in its whole lifetime — no `healthSummonFired`, so
    /// nobody presented it. DynamicNotchKit rebuilds and re-fronts its panel on
    /// every screen-parameter change, and the panel rendered content latched
    /// from an earlier summon. A screen change with nothing live must leave
    /// nothing to render.
    func testAScreenParameterChangeDropsContentNoSummonIsBehind() async {
        let notch = presenter()
        notch.present(HealthSummon(trigger: .captureFailed))
        notch.dismiss()
        XCTAssertNil(notch.onScreen)
        XCTAssertNotNil(notch.latchedTrigger, "the copy outlives the hide animation")

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        await settle(until: { notch.latchedTrigger == nil })

        XCTAssertNil(notch.latchedTrigger,
                     "a rebuild after this must have no summon copy to re-show")
        // And the trace that made the incident diagnosable at all: a ghost is a
        // withdrawal nobody in this app chose (no-false-positives §5).
        XCTAssertTrue(recorded(.healthSummonWithdrawn(trigger: .captureFailed, reason: .sweptGhost)),
                      "a popup that leaves no trace cannot be debugged")
    }

    /// Every exit names itself, so events.json can answer "why did it go".
    func testEachExitPathRecordsItsOwnReason() {
        let notch = presenter()
        notch.present(HealthSummon(trigger: .captureFailed))
        notch.clearSummon(trigger: .captureFailed)
        XCTAssertTrue(recorded(.healthSummonWithdrawn(trigger: .captureFailed, reason: .recovered)))

        notch.present(HealthSummon(trigger: .identityMigration))
        notch.present(HealthSummon(trigger: .pasteFailed))
        XCTAssertTrue(recorded(.healthSummonWithdrawn(trigger: .identityMigration, reason: .displaced)))

        notch.dismiss()
        XCTAssertTrue(recorded(.healthSummonWithdrawn(trigger: .pasteFailed, reason: .dismissed)))
    }

    // MARK: - Helpers

    private func recorded(_ event: DiagEvent) -> Bool {
        DiagStore.shared.recent(DiagStore.capacity).contains { $0.event == event }
    }

    /// Wait for a main-actor condition the screen-parameter sweep sets, rather
    /// than sleeping a guessed interval (#147's rule for these tests).
    private func settle(
        until condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(2)
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    /// A recovery on a different subsystem leaves it alone: a mic delivering
    /// frames says nothing about the system-audio tap.
    func testAMicRecoveryDoesNotClearTheSystemAudioSummon() {
        let notch = presenter()
        notch.present(HealthSummon(trigger: .systemAudioFailed))
        let recovered = try! XCTUnwrap(HealthMonitor.summonSignal(for: .micFramesFlowing))
        notch.clearSummon(trigger: recovered.trigger)
        XCTAssertEqual(notch.onScreen?.trigger, .systemAudioFailed)
    }
}
