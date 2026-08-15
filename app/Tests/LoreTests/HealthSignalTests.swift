import XCTest
@testable import LoreKit

/// The failure-door contract after #140, kept intact when #151 retired the notch
/// surface it used to feed: a health claim moves only when a user action just
/// failed (or the launch found an identity migration) — never from a state bit
/// alone. The footer's red dot is what critical probe failures still drive.
/// Where the claim *lands* is `MenuBarHealthTests`.
final class HealthSignalTests: XCTestCase {

    private func snapshot(_ results: [HealthResult]) -> HealthSnapshot {
        HealthSnapshot(marketingVersion: "2.0.1", build: "2.0.1", results: results)
    }

    // MARK: - Only failed user actions trigger

    /// The whole failure door in one table: four failure shapes, each with the
    /// event that proves it is over, and nothing else moves a health claim — no
    /// permission bit, no secure-input flag, no silence-derived verdict (#140).
    /// One table also means a trigger cannot gain a failure without a way to
    /// clear, which is rule 2 of `no-false-positives`.
    func testTheSignalTableIsTheFourFailuresAndTheirRecoveries() {
        let failures: [(DiagEvent, DiagEvent.HealthTrigger)] = [
            (.captureGaveUp(attempts: 3), .captureFailed),
            (.systemAudioGaveUp(attempts: 1), .systemAudioFailed),
            (.pasteAttempt(kind: .paste, eventsCreated: false, accessibilityTrusted: true), .pasteFailed),
            (.modelLoad(model: .asr, outcome: .failed, seconds: 1, fromCache: false), .modelLoadFailed),
        ]
        for (event, trigger) in failures {
            XCTAssertEqual(HealthMonitor.healthSignal(for: event),
                           .init(trigger: trigger, succeeded: false), event.caseName)
        }

        let recoveries: [(DiagEvent, DiagEvent.HealthTrigger)] = [
            (.micFramesFlowing, .captureFailed),
            (.systemAudioCapture(outcome: .ok, osStatus: nil), .systemAudioFailed),
            (.pasteAttempt(kind: .paste, eventsCreated: true, accessibilityTrusted: false), .pasteFailed),
            (.modelLoad(model: .asr, outcome: .ok, seconds: 1, fromCache: false), .modelLoadFailed),
        ]
        for (event, trigger) in recoveries {
            XCTAssertEqual(HealthMonitor.healthSignal(for: event),
                           .init(trigger: trigger, succeeded: true), event.caseName)
        }
        XCTAssertEqual(Set(failures.map(\.1)), Set(recoveries.map(\.1)),
                       "a claim with no way to clear itself never stops lying")

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
            // A cache hit loaded nothing, so it certifies nothing: the app
            // prepares more than one ASR instance, and a hit on one used to
            // clear a failure another had just reported (#169).
            .modelLoad(model: .asr, outcome: .ok, seconds: 0, fromCache: true),
            // The killed summons: state bits and silence-derived verdicts.
            .permissionTransition(permission: .accessibility, granted: false),
            .secureInputChanged(active: true, holderPID: 42),
            .tapEventsStalled(seconds: 1800),
            .tapDisabledByOS,
            .tapGaveUp(attempts: 3),
        ]
        for event in silent {
            XCTAssertNil(HealthMonitor.healthSignal(for: event),
                         "\(event.caseName) must not move a health claim")
        }
    }

    /// The #149 incident in one assertion: the microphone was fine, the
    /// system-audio tap was not, and the report blamed the microphone. The two
    /// causes must stay two conditions, each with its own clock and its own
    /// panel row.
    func testTheSystemAudioTapAndTheMicrophoneAreSeparateConditions() {
        XCTAssertNotEqual(HealthMonitor.healthSignal(for: .systemAudioGaveUp(attempts: 1)),
                          HealthMonitor.healthSignal(for: .captureGaveUp(attempts: 3)))

        // And a recovery on one side says nothing about the other.
        let micRecovery = HealthMonitor.healthSignal(for: .micFramesFlowing)
        XCTAssertEqual(micRecovery, .init(trigger: .captureFailed, succeeded: true))
        XCTAssertNotEqual(micRecovery?.trigger, .systemAudioFailed)
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
