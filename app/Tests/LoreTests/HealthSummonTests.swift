import XCTest
@testable import LoreKit

/// The summon contract after #140: a summon fires only when a user action just
/// failed (or the launch found an identity migration) — never from a state bit
/// alone. State bits are the *explanation* a summon may carry, and the footer's
/// red dot is what critical probe failures still drive.
final class HealthSummonTests: XCTestCase {

    private func snapshot(_ results: [HealthResult]) -> HealthSnapshot {
        HealthSnapshot(marketingVersion: "2.0.1", build: "2.0.1", results: results)
    }

    // MARK: - Only failed user actions trigger

    /// The event filter is the whole trigger surface: exactly three failure
    /// shapes summon, and no permission/secure-input/tap event does — those were
    /// the flapping-bit and silence-as-failure summons #140 removed.
    func testOnlyTheThreeFailureEventsTrigger() {
        XCTAssertEqual(HealthMonitor.failureTrigger(for: .captureGaveUp(attempts: 3)), .captureFailed)
        XCTAssertEqual(
            HealthMonitor.failureTrigger(for: .pasteAttempt(
                kind: .paste, eventsCreated: false, accessibilityTrusted: true)),
            .pasteFailed
        )
        XCTAssertEqual(
            HealthMonitor.failureTrigger(for: .modelLoad(
                model: .asr, outcome: .failed, seconds: 1, fromCache: false)),
            .modelLoadFailed
        )

        let nonTriggers: [DiagEvent] = [
            // A paste that created its events is not a failure.
            .pasteAttempt(kind: .paste, eventsCreated: true, accessibilityTrusted: false),
            // A VAD load failure is not the dictation-blocking one.
            .modelLoad(model: .vad, outcome: .failed, seconds: 1, fromCache: false),
            .modelLoad(model: .asr, outcome: .ok, seconds: 1, fromCache: true),
            // A single failed attempt retries silently; only giving up counts.
            .captureFailed(stage: .startDevice, osStatus: nil),
            // The killed summons: state bits and silence-derived verdicts.
            .permissionTransition(permission: .accessibility, granted: false),
            .secureInputChanged(active: true, holderPID: 42),
            .tapEventsStalled(seconds: 1800),
            .tapDisabledByOS,
        ]
        for event in nonTriggers {
            XCTAssertNil(HealthMonitor.failureTrigger(for: event),
                         "\(event.caseName) must not summon")
        }
    }

    // MARK: - The banner's words

    /// The state bit is the explanation when it is red, never the trigger: the
    /// same failed capture names the permission when the permission explains it,
    /// and the symptom when the bits all read fine.
    func testCaptureFailureNamesThePermissionOnlyWhenItExplains() {
        let explained = HealthSummon(trigger: .captureFailed, explanation: .microphone)
        XCTAssertTrue(explained.title.contains("microphone access is off"))

        let unexplained = HealthSummon(trigger: .captureFailed)
        XCTAssertTrue(unexplained.title.contains("no audio"))
        XCTAssertFalse(unexplained.title.contains("access is off"),
                       "no red bit — the summon must not accuse a permission")
    }

    /// A failed paste leaves the text on the clipboard — the banner says what
    /// the user can still do, not just what broke.
    func testPasteFailureTellsTheUserTheTextIsStillRecoverable() {
        let summon = HealthSummon(trigger: .pasteFailed)
        XCTAssertTrue(summon.title.contains("clipboard"))

        let explained = HealthSummon(trigger: .pasteFailed, explanation: .accessibility)
        XCTAssertTrue(explained.title.contains("Accessibility"))
    }

    /// `.identityMigration` is raised by the launch check alone (#135): the
    /// condition is a change, not a fault, so no "not working" template fits.
    func testMigrationSummonNamesTheChangeNotAFault() {
        let title = HealthSummon(trigger: .identityMigration).title
        XCTAssertTrue(title.contains("signature changed"))
        XCTAssertFalse(title.contains("not working"))
    }

    /// A failed user action displaces the migration notice on the notch; the
    /// notice displaces nothing.
    func testOnlyTheMigrationNoticeIsNonCritical() {
        XCTAssertFalse(HealthSummon(trigger: .identityMigration).isCritical)
        for trigger: DiagEvent.SummonTrigger in [.captureFailed, .pasteFailed, .modelLoadFailed] {
            XCTAssertTrue(HealthSummon(trigger: trigger).isCritical,
                          "\(trigger.rawValue) is a failure the user just felt")
        }
    }

    // MARK: - The footer's red dot (criticalFailures survives #140 for it)

    func testOnlyTheFiveCriticalLinksTurnTheDotRed() {
        let critical: Set<HealthProbeID> = [.accessibility, .inputMonitoring, .secureInput,
                                            .tap, .microphone]
        for id in HealthProbeID.allCases {
            let snap = snapshot([HealthResult(id: id, status: .failed)])
            if critical.contains(id) {
                XCTAssertEqual(snap.criticalFailures, [id], "\(id.rawValue) should read critical")
            } else {
                XCTAssertTrue(snap.criticalFailures.isEmpty, "\(id.rawValue) must not")
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

    func testCriticalWarningIsNotACriticalFailure() {
        let snap = snapshot([HealthResult(id: .accessibility, status: .warning)])
        XCTAssertTrue(snap.criticalFailures.isEmpty)
    }
}
