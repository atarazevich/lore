import XCTest
@testable import LoreKit

/// The gate's whole contract: setup incomplete ⟹ nothing starts; complete ⟹
/// everything starts, once.
@MainActor
final class AppBootTests: XCTestCase {

    /// A configured machine's ordinary launch takes the boot path immediately —
    /// there is no onboarding branch left on it.
    func testConfiguredMachineBootsImmediately() {
        let boot = AppBoot(needsSetup: false)
        XCTAssertEqual(boot.phase, .running)

        var started = 0
        boot.startSubsystemsOnce { started += 1; return true }
        XCTAssertEqual(started, 1)
    }

    /// Nothing starts before setup completes; afterwards the scene's `onAppear`
    /// and the completion call both reach in and only one may win. Two menu bar
    /// items / two event taps is what a second win would mean.
    func testSubsystemsStartExactlyOnce() {
        let boot = AppBoot(needsSetup: true)
        var started = 0

        boot.startSubsystemsOnce { started += 1; return true }   // onAppear, still in setup
        XCTAssertEqual(started, 0, "no subsystem may be constructed before setup completes")

        boot.markSetupComplete()
        boot.startSubsystemsOnce { started += 1; return true }   // setup finished
        boot.startSubsystemsOnce { started += 1; return true }   // a late onAppear
        boot.startSubsystemsOnce { started += 1; return true }

        XCTAssertEqual(boot.phase, .running)
        XCTAssertEqual(started, 1)
    }

    /// The latch is burned on a start that *ran*, not on one that was attempted.
    /// `completeSetup()` can reach here before the scene handed the delegate its
    /// coordinator, and a latch burned on that no-op leaves the machine with no
    /// menu bar, no health monitor and no updater until the next launch.
    func testAStartThatDidNothingDoesNotBurnTheLatch() {
        let boot = AppBoot(needsSetup: false)
        var attempts = 0

        boot.startSubsystemsOnce { attempts += 1; return false }
        boot.startSubsystemsOnce { attempts += 1; return false }
        XCTAssertEqual(attempts, 2, "a start that did nothing must be retried")

        var started = 0
        boot.startSubsystemsOnce { started += 1; return true }
        boot.startSubsystemsOnce { started += 1; return true }
        XCTAssertEqual(started, 1, "the start that ran latches")
    }
}
