import XCTest
@testable import LoreKit

/// The critical-vs-non-critical summon decision and its flap debounce (#83,
/// design §6): only Accessibility, Input Monitoring, tap and microphone summon
/// the notch, and only after the failure persists past a transient blip.
final class HealthSummonTests: XCTestCase {

    private func snapshot(_ results: [HealthResult]) -> HealthSnapshot {
        HealthSnapshot(marketingVersion: "2.0.1", build: "2.0.1", results: results)
    }

    // MARK: - Which failures are critical

    func testOnlyTheFourCriticalLinksSummon() {
        let critical: Set<HealthProbeID> = [.accessibility, .inputMonitoring, .tap, .microphone]
        for id in HealthProbeID.allCases {
            let snap = snapshot([HealthResult(id: id, status: .failed)])
            if critical.contains(id) {
                XCTAssertEqual(snap.criticalFailures, [id], "\(id.rawValue) should summon")
            } else {
                XCTAssertTrue(snap.criticalFailures.isEmpty, "\(id.rawValue) must stay silent")
            }
        }
    }

    func testCriticalFailuresAreOrderedUpstreamFirst() {
        let snap = snapshot([
            HealthResult(id: .microphone, status: .failed),
            HealthResult(id: .accessibility, status: .failed),
        ])
        XCTAssertEqual(snap.criticalFailures, [.accessibility, .microphone])
    }

    func testCriticalWarningDoesNotSummon() {
        // Only .failed summons; a warning on a critical link does not.
        let snap = snapshot([HealthResult(id: .accessibility, status: .warning)])
        XCTAssertTrue(snap.criticalFailures.isEmpty)
    }

    // MARK: - Debounce

    func testDebounceRequiresTwoConsecutiveCyclesThenFiresOnce() {
        var debouncer = SummonDebouncer(threshold: 2)
        XCTAssertFalse(debouncer.record(hasCriticalFailure: true), "first cycle: hold")
        XCTAssertTrue(debouncer.record(hasCriticalFailure: true), "second cycle: fire")
        XCTAssertFalse(debouncer.record(hasCriticalFailure: true), "already fired: silent")
    }

    func testTransientFlapNeverSummons() {
        var debouncer = SummonDebouncer(threshold: 2)
        XCTAssertFalse(debouncer.record(hasCriticalFailure: true))
        XCTAssertFalse(debouncer.record(hasCriticalFailure: false), "cleared before threshold")
        XCTAssertFalse(debouncer.record(hasCriticalFailure: true), "counter reset — one cycle only")
    }

    func testReArmsAfterAClearCycle() {
        var debouncer = SummonDebouncer(threshold: 1)
        XCTAssertTrue(debouncer.record(hasCriticalFailure: true))
        XCTAssertFalse(debouncer.record(hasCriticalFailure: true), "still the same outage")
        XCTAssertFalse(debouncer.record(hasCriticalFailure: false), "recovered")
        XCTAssertTrue(debouncer.record(hasCriticalFailure: true), "new outage summons again")
    }
}
