import XCTest
@testable import LoreKit

/// The bound that replaced two unbounded retry loops (#149). The incident it
/// comes from ran a 5 s tap rebuild for three hours and left 1993 of the
/// diagnostic ring's 2000 slots holding that loop.
final class RetryBudgetTests: XCTestCase {

    func testBudgetAllowsExactlyItsLimitOfFailedAttempts() {
        var budget = RetryBudget(limit: 3)
        for attempt in 1...3 {
            XCTAssertTrue(budget.allowsAttempt, "attempt \(attempt) is within the limit")
            budget.noteFailure()
        }
        XCTAssertFalse(budget.allowsAttempt, "a fourth attempt is the loop, not a retry")
        XCTAssertEqual(budget.failures, 3)
    }

    /// The exhausting failure is the one moment worth a diagnostic event — so
    /// "why did the retries stop" stays answerable from events.json rather than
    /// from the absence of events.
    func testOnlyTheExhaustingFailureReportsItself() {
        var budget = RetryBudget(limit: 3)
        XCTAssertFalse(budget.noteFailure())
        XCTAssertFalse(budget.noteFailure())
        XCTAssertTrue(budget.noteFailure(), "the third failure exhausts the budget")
        XCTAssertFalse(budget.noteFailure(), "an exhausted budget must not report again")
    }

    /// Nothing is permanently bricked: a fresh signal — a permission that just
    /// changed, a meeting the user just started — starts the count over.
    func testResetRestoresTheFullBudget() {
        var budget = RetryBudget(limit: 2)
        budget.noteFailure()
        budget.noteFailure()
        XCTAssertFalse(budget.allowsAttempt)

        budget.reset()
        XCTAssertTrue(budget.allowsAttempt)
        XCTAssertEqual(budget.failures, 0)
        XCTAssertTrue(budget.noteFailure() == false, "the count really starts over")
    }

    func testAnExhaustedBudgetStopsCounting() {
        var budget = RetryBudget(limit: 1)
        budget.noteFailure()
        for _ in 0..<100 { budget.noteFailure() }
        XCTAssertEqual(budget.failures, 1, "an exhausted budget takes no more attempts")
    }
}
