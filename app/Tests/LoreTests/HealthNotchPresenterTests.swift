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
    func testClearIdentitySummonWithdrawsOnlyTheMigrationNotice() {
        let notch = presenter()
        notch.present(HealthSummon(trigger: .identityMigration))
        notch.clearIdentitySummon()
        XCTAssertNil(notch.onScreen, "the ledger acknowledged — the claim is stale")

        notch.present(HealthSummon(trigger: .captureFailed))
        notch.clearIdentitySummon()
        XCTAssertEqual(notch.onScreen?.trigger, .captureFailed,
                       "a failure summon is not the ledger's to clear")
    }
}
