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

    /// The whole summon surface in one table: four failure shapes, each with the
    /// event that proves it is over, and nothing else moves the notch — no
    /// permission bit, no secure-input flag, no silence-derived verdict (#140).
    /// One table also means a trigger cannot gain a failure without a way to
    /// clear, which is rule 2 of `no-false-positives`.
    func testTheSummonTableIsTheFourFailuresAndTheirRecoveries() {
        let failures: [(DiagEvent, DiagEvent.SummonTrigger)] = [
            (.captureGaveUp(attempts: 3), .captureFailed),
            (.systemAudioGaveUp(attempts: 1), .systemAudioFailed),
            (.pasteAttempt(kind: .paste, eventsCreated: false, accessibilityTrusted: true), .pasteFailed),
            (.modelLoad(model: .asr, outcome: .failed, seconds: 1, fromCache: false), .modelLoadFailed),
        ]
        for (event, trigger) in failures {
            XCTAssertEqual(HealthMonitor.summonSignal(for: event),
                           .init(trigger: trigger, succeeded: false), event.caseName)
        }

        let recoveries: [(DiagEvent, DiagEvent.SummonTrigger)] = [
            (.micFramesFlowing, .captureFailed),
            (.systemAudioCapture(outcome: .ok, osStatus: nil), .systemAudioFailed),
            (.pasteAttempt(kind: .paste, eventsCreated: true, accessibilityTrusted: false), .pasteFailed),
            (.modelLoad(model: .asr, outcome: .ok, seconds: 1, fromCache: true), .modelLoadFailed),
        ]
        for (event, trigger) in recoveries {
            XCTAssertEqual(HealthMonitor.summonSignal(for: event),
                           .init(trigger: trigger, succeeded: true), event.caseName)
        }
        XCTAssertEqual(Set(failures.map(\.1)), Set(recoveries.map(\.1)),
                       "a summon with no way to clear itself lies until it times out")

        let silent: [DiagEvent] = [
            // A start is not evidence of frames: AudioDeviceStart returns noErr
            // for the wedged device the no-frames watchdog gives up on (#149).
            .captureStart(deviceKind: .builtIn, ms: 12),
            // A single failed attempt retries silently; only giving up counts.
            .captureFailed(stage: .startDevice, osStatus: nil),
            // Every unattended re-drive of a failing tap — one cause, one report.
            .systemAudioCapture(outcome: .failed, osStatus: -1),
            // A VAD failure is not the dictation-blocking one; an inconclusive
            // load is no verdict either way.
            .modelLoad(model: .vad, outcome: .failed, seconds: 1, fromCache: false),
            .modelLoad(model: .asr, outcome: .unknown, seconds: 1, fromCache: false),
            // The killed summons: state bits and silence-derived verdicts.
            .permissionTransition(permission: .accessibility, granted: false),
            .secureInputChanged(active: true, holderPID: 42),
            .tapEventsStalled(seconds: 1800),
            .tapDisabledByOS,
            .tapGaveUp(attempts: 3),
        ]
        for event in silent {
            XCTAssertNil(HealthMonitor.summonSignal(for: event),
                         "\(event.caseName) must not move a summon")
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

    /// The #149 incident in one assertion: the microphone was fine, the
    /// system-audio tap was not, and the summon blamed the microphone. The two
    /// causes must reach the user as two different sentences.
    func testTheSystemAudioTapAndTheMicrophoneRaiseDifferentDiagnoses() {
        XCTAssertNotEqual(HealthMonitor.summonSignal(for: .systemAudioGaveUp(attempts: 1)),
                          HealthMonitor.summonSignal(for: .captureGaveUp(attempts: 3)))

        let tapTitle = HealthSummon(trigger: .systemAudioFailed).title
        XCTAssertTrue(tapTitle.localizedCaseInsensitiveContains("system audio"))
        XCTAssertFalse(tapTitle.localizedCaseInsensitiveContains("microphone"),
                       "the microphone was never the failing side")

        // And the mic side keeps its own attribution unchanged.
        XCTAssertTrue(HealthSummon(trigger: .captureFailed).title
            .localizedCaseInsensitiveContains("microphone"))
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
        for trigger: DiagEvent.SummonTrigger in [.captureFailed, .systemAudioFailed,
                                                 .pasteFailed, .modelLoadFailed] {
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
