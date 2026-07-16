import XCTest
@testable import LoreKit

/// The footer's one-line readout for 0, 1 and N issues (#83, design §6), the
/// rule that the named issue is the most upstream link in chain order, and the
/// cry-wolf fix: an expensive probe that was simply never exercised must not
/// keep the always-visible footer amber forever.
final class HealthSummaryTests: XCTestCase {

    private func result(_ id: HealthProbeID, _ status: HealthStatus) -> HealthResult {
        HealthResult(id: id, status: status)
    }

    private func summary(_ results: [HealthResult]) -> HealthSummary {
        HealthSummary(HealthSnapshot(marketingVersion: "2.0.2", build: "2.0.2", results: results))
    }

    func testAllClearReadsAllSystemsReady() {
        let s = summary(HealthProbeID.allCases.map { result($0, .ok) })
        XCTAssertEqual(s.issueCount, 0)
        XCTAssertFalse(s.hasCriticalFailure)
        XCTAssertEqual(s.status, .ok)
        XCTAssertEqual(s.text, "All systems ready")
    }

    func testSingleIssueUsesSingularNounAndNamesIt() {
        let s = summary([result(.accessibility, .failed), result(.tap, .ok)])
        XCTAssertEqual(s.issueCount, 1)
        XCTAssertTrue(s.hasCriticalFailure)
        XCTAssertEqual(s.status, .failed)
        XCTAssertEqual(s.text, "1 issue — Accessibility")
    }

    func testMultipleIssuesUsePluralNoun() {
        let s = summary([
            result(.accessibility, .failed),
            result(.microphone, .failed),
            result(.diskSpace, .warning),
        ])
        XCTAssertEqual(s.issueCount, 3)
        XCTAssertEqual(s.text, "3 issues — Disk space",
                       "disk space is upstream of accessibility in chain order")
    }

    func testNamedIssueIsMostUpstreamRegardlessOfInputOrder() {
        let s = summary([result(.openAIKey, .failed), result(.accessibility, .failed)])
        XCTAssertEqual(s.firstIssueShortName, "Accessibility")
    }

    /// #94: secure input starves the tap, so it sits above it in chain order and
    /// the footer names it — never the Fn key it starved, or the footer points the
    /// user at the one link they cannot fix. One physical condition, one issue: the
    /// tap's `.warning` means "no verdict" (it is returned only under secure input),
    /// so counting it would inflate this into "2 issues".
    func testUnderSecureInputTheFooterNamesOneIssueAndItIsTheCause() {
        let s = summary([result(.tap, .warning), result(.secureInput, .failed)])
        XCTAssertEqual(s.text, "1 issue — Secure input")
        XCTAssertTrue(s.hasCriticalFailure, "a starved keyboard is not a mere warning")
        XCTAssertEqual(s.status, .failed)
    }

    func testCheapWarningIsAnIssueButNotCritical() {
        let s = summary([result(.diskSpace, .warning)])
        XCTAssertEqual(s.issueCount, 1)
        XCTAssertFalse(s.hasCriticalFailure)
        XCTAssertEqual(s.status, .warning)
        XCTAssertEqual(s.text, "1 issue — Disk space")
    }

    // MARK: - C2: untested expensive probes must not cry wolf

    /// A dictation-only user, with everything working, never exercises System
    /// audio or OpenAI liveness — those sit at `.warning` ("not tested"). The
    /// footer must still read "All systems ready", or the healthy state is
    /// unreachable.
    func testUntestedExpensiveWarningsDoNotCountInFooter() {
        var results = HealthProbeID.allCases
            .filter { $0.cost == .cheap }
            .map { result($0, .ok) }
        results += HealthProbeID.allCases
            .filter { $0.cost == .expensive }
            .map { result($0, .warning) }   // never tested

        let s = summary(results)
        XCTAssertEqual(s.issueCount, 0, "untested expensive probes are not footer issues")
        XCTAssertEqual(s.text, "All systems ready")
    }

    /// A *recorded* expensive failure (a real captureFailed / apiCall failed) is
    /// a genuine issue and still counts.
    func testRecordedExpensiveFailureCountsInFooter() {
        let s = summary([result(.systemAudio, .failed)])
        XCTAssertEqual(s.issueCount, 1)
        XCTAssertEqual(s.text, "1 issue — System audio")
    }
}
