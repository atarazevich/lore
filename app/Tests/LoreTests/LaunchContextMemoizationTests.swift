import XCTest
@testable import LoreKit

/// Split-brain regression (see LoreRootApp.sharedContext): every
/// LoreRootApp construction must expose the same instance set.
@MainActor
final class LaunchContextMemoizationTests: XCTestCase {

    func testRepeatedRootAppInitsShareOneInstanceSet() {
        // Seam must be installed before the first sharedContext access;
        // no other test constructs LoreRootApp.
        let stub = MeetingHarness.makeLaunchContext()
        LoreRootApp.makeContext = { stub }

        let first = LoreRootApp()
        let second = LoreRootApp()

        XCTAssertTrue(
            LoreRootApp.sharedContext.coordinator === stub.coordinator,
            "sharedContext must come from the installed stub, not a live bootstrap"
        )
        XCTAssertTrue(
            first.coordinator === second.coordinator,
            "every LoreRootApp init must share one coordinator"
        )
        XCTAssertTrue(
            first.shell === second.shell,
            "every LoreRootApp init must share one shell model"
        )
    }
}
