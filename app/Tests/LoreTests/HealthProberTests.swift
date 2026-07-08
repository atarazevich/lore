import XCTest
@testable import LoreKit

/// C1 (#83): the tap probe must reflect the *starved* verdict, not just
/// "the tap object exists". An enabled-but-starved tap — the reported "Fn dead,
/// all toggles on" incident, caused by secure input — has to read as failed so
/// the critical link fails and the notch summons itself. `tapIsEnabled` alone
/// reads it as healthy, which is exactly why the bug went unseen.
@MainActor
final class HealthProberTests: XCTestCase {

    /// A fresh empty event store so the expensive probes have no last-attempt.
    private func emptyStore() -> DiagStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HealthProber-\(UUID().uuidString)", isDirectory: true)
        return DiagStore(directory: dir)
    }

    private func prober(alive: Bool, stalled: Bool) -> HealthProber {
        HealthProber(
            isEventTapAlive: { alive },
            isEventTapStalled: { stalled },
            hasOpenAIKey: { true },
            store: emptyStore()
        )
    }

    private func tapResult(_ prober: HealthProber) -> HealthResult {
        prober.probe().snapshot.results.first { $0.id == .tap }!
    }

    func testEnabledAndFlowingTapIsHealthy() {
        XCTAssertEqual(tapResult(prober(alive: true, stalled: false)).status, .ok)
    }

    func testEnabledButStarvedTapReadsAsFailed() {
        // The whole point: alive == true, yet no events flow → failed.
        let result = tapResult(prober(alive: true, stalled: true))
        XCTAssertEqual(result.status, .failed, "enabled-but-starved must not read healthy")
    }

    func testDeadTapReadsAsFailed() {
        XCTAssertEqual(tapResult(prober(alive: false, stalled: false)).status, .failed)
    }

    func testStalledTapIsACriticalFailure() {
        let snapshot = prober(alive: true, stalled: true).probe().snapshot
        XCTAssertTrue(snapshot.criticalFailures.contains(.tap),
                      "a starved tap is a critical link failure")
    }

    /// The single-source-of-truth guard: `HealthProbeID.cost` is the ONE place
    /// that decides cheap (auto-run) vs expensive (Test-now-only). `readings()`
    /// dispatches on it, `countsInFooter` excludes untested expensive warnings by
    /// it, and the remedy copy routes by it — but each needs a per-id extractor /
    /// labels table. This pins the extractor table's key set to the cost set, so
    /// a new expensive probe cannot be added to one without the other, which is
    /// exactly the drift that would silently reintroduce the footer cry-wolf.
    func testExpensiveExtractorSetEqualsCost() {
        XCTAssertEqual(
            Set(HealthProber.expensiveOutcome.keys),
            Set(HealthProbeID.allCases.filter { $0.cost == .expensive }),
            "the readings() Test-now-only set must equal { id.cost == .expensive }"
        )
    }

    /// The same invariant, observed through the remedy layer: exactly the
    /// expensive probes carry a `Test now` action for their own id.
    func testOnlyExpensiveProbesCarryTheirOwnTestNowRemedy() {
        for id in HealthProbeID.allCases {
            let item = HealthCatalog.describe(HealthResult(id: id, status: .warning))
            let hasOwnTestNow = item.remedy?.actions.contains(.testNow(id)) ?? false
            XCTAssertEqual(hasOwnTestNow, id.cost == .expensive,
                           "\(id.rawValue): own Test-now action ⟺ expensive")
        }
    }

    /// End to end: a stalled-tap verdict drives the monitor to summon the notch.
    func testStalledTapTriggersTheSummon() {
        let monitor = HealthMonitor(prober: prober(alive: true, stalled: true), summonThreshold: 1)
        var summoned: HealthSummon?
        monitor.onSummon = { summoned = $0 }

        monitor.refresh()

        XCTAssertNotNil(summoned, "a starved tap must summon the notch")
    }
}
