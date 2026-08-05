import XCTest
@testable import LoreKit

/// One notch at a time, and the right one. The rule matters because the launch
/// migration summon (#135) is non-critical and holds the notch for its whole
/// 30-second timeout — which is precisely the window in which the user, having
/// just been told to remove Lore from Accessibility and Input Monitoring, has an
/// Accessibility failure to be told about. `SummonDebouncer` fires once per
/// outage, so a summon dropped here is lost for the session.
@MainActor
final class HealthNotchPresenterTests: XCTestCase {

    private func presenter() -> HealthNotchPresenter {
        HealthNotchPresenter(timeout: .seconds(60))
    }

    func testACriticalOutageDisplacesThePendingMigrationNotice() {
        let notch = presenter()
        notch.present(HealthSummon(probe: .signing))
        XCTAssertEqual(notch.onScreen?.probe, .signing)

        notch.present(HealthSummon(probe: .accessibility))
        XCTAssertEqual(notch.onScreen?.probe, .accessibility,
                       "the outage must reach the user while the migration notice is up")
    }

    func testANonCriticalNoticeNeverInterruptsACriticalOutage() {
        let notch = presenter()
        notch.present(HealthSummon(probe: .accessibility))
        notch.present(HealthSummon(probe: .signing))
        XCTAssertEqual(notch.onScreen?.probe, .accessibility)
    }

    func testOneCriticalOutageDoesNotRestartAnother() {
        let notch = presenter()
        notch.present(HealthSummon(probe: .accessibility))
        notch.present(HealthSummon(probe: .microphone))
        XCTAssertEqual(notch.onScreen?.probe, .accessibility,
                       "first come, first served among equals — no churn on the notch")
    }

    func testDismissFreesTheNotch() {
        let notch = presenter()
        notch.present(HealthSummon(probe: .signing))
        notch.dismiss()
        XCTAssertNil(notch.onScreen)

        notch.present(HealthSummon(probe: .signing))
        XCTAssertEqual(notch.onScreen?.probe, .signing)
    }
}
