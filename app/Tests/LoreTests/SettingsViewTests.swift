import XCTest
@testable import LoreKit

/// The audio-retention deletion decision (#52): pruning fires only when the
/// effective limit shrinks. 0 is the unlimited sentinel on both sides.
final class SettingsViewTests: XCTestCase {

    func testShouldPruneImmediately() {
        // ∞ → finite is a decrease: prune.
        XCTAssertTrue(SettingsView.shouldPruneImmediately(current: 0, next: 100))
        // Finite → ∞ deletes nothing.
        XCTAssertFalse(SettingsView.shouldPruneImmediately(current: 1000, next: 0))
        // Plain decrease: prune.
        XCTAssertTrue(SettingsView.shouldPruneImmediately(current: 500, next: 100))
        // Increase never deletes (and never resurrects).
        XCTAssertFalse(SettingsView.shouldPruneImmediately(current: 100, next: 500))
        // Off-ladder current (hand-edited defaults) still prunes on decrease.
        XCTAssertTrue(SettingsView.shouldPruneImmediately(current: 750, next: 500))
    }
}
