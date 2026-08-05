import XCTest
@testable import LoreKit

/// The critical-vs-non-critical summon decision and its flap debounce (#83,
/// design §6): only Accessibility, Input Monitoring, secure input, tap and
/// microphone summon the notch, and only after the failure persists past a
/// transient blip.
final class HealthSummonTests: XCTestCase {

    private func snapshot(_ results: [HealthResult]) -> HealthSnapshot {
        HealthSnapshot(marketingVersion: "2.0.1", build: "2.0.1", results: results)
    }

    // MARK: - Which failures are critical

    /// `.secureInput` joined the set in #94: it withholds keystrokes from every
    /// app, so it is an outage, not the curiosity #83 filed it as.
    func testOnlyTheFiveCriticalLinksSummon() {
        let critical: Set<HealthProbeID> = [.accessibility, .inputMonitoring, .secureInput,
                                            .tap, .microphone]
        for id in HealthProbeID.allCases {
            let snap = snapshot([HealthResult(id: id, status: .failed)])
            if critical.contains(id) {
                XCTAssertEqual(snap.criticalFailures, [id], "\(id.rawValue) should summon")
            } else {
                XCTAssertTrue(snap.criticalFailures.isEmpty, "\(id.rawValue) must stay silent")
            }
        }
    }

    // MARK: - The banner's words (#94)

    /// The name at the root of the whole complaint (#97). No surface may raise a
    /// banner about the Fn key on the tap's behalf: Fn hold-to-talk runs entirely
    /// on the NSEvent monitors and never reaches the tap, which carries only the
    /// keys Lore intercepts while another app is focused. A probe that cannot
    /// observe the Fn key told a user, in its own name, that theirs was broken —
    /// and every fix before this one plumbed around that name instead of fixing it.
    func testNoBannerBlamesTheFnKeyForTheTapWhichCannotObserveIt() {
        let title = HealthSummon(probe: .tap).title
        XCTAssertFalse(title.contains("Fn"), "the tap probe cannot answer for the Fn key")
        XCTAssertTrue(title.contains("Keyboard shortcuts"), "it answers for the keys it carries")
    }

    /// `"\(shortName) not working"` would render the nonsense "Secure input not
    /// working" — secure input *working* is the problem (#94).
    func testSecureInputBannerNamesTheSystemWideConditionNotTheFnKey() {
        let title = HealthSummon(probe: .secureInput).title
        XCTAssertFalse(title.contains("Fn key"), "no surface may blame the Fn key for a system-wide lock")
        XCTAssertFalse(title.contains("not working"), "secure input working is the condition, not a fault")
        XCTAssertTrue(title.contains("no app"), "the user's Raycast hotkey died too — say so")
    }

    /// `.signing` is summoned by the launch check alone (#135), never by the
    /// debouncer — so the template's "Signing not working" would name a fault
    /// where the condition is a change.
    func testSigningSummonNamesTheChangeNotAFault() {
        let title = HealthSummon(probe: .signing).title
        XCTAssertTrue(title.contains("signature changed"))
        XCTAssertFalse(title.contains("not working"))
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
