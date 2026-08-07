import CoreAudio
import XCTest
@testable import LoreKit

/// What the capture adds on top of `RetryBudget` (whose semantics are pinned in
/// `RetryBudgetTests`): a spent budget reaches no further than the throw, and the
/// throw names the grant. A TCC grant cannot be revoked from a test, so the
/// failure is injected at the tap-creation seam a missing one fails at.
final class SystemAudioCaptureRetryTests: XCTestCase {

    /// Counts starts and fails them, standing in for the HAL refusing the tap.
    private final class FailingStart: @unchecked Sendable {
        private let lock = NSLock()
        private var _attempts = 0
        var attempts: Int { lock.withLock { _attempts } }

        var handler: @Sendable (AudioDeviceID?) async throws -> Void {
            { [self] _ in
                lock.withLock { _attempts += 1 }
                throw SystemAudioCapture.CaptureError.tapCreationFailed(-1)
            }
        }
    }

    /// Ten starts, one HAL call: the rest are refused before touching the device,
    /// which is what stops an unattended re-drive from hammering it.
    func testASpentBudgetRefusesWithoutTouchingTheHAL() async {
        let seam = FailingStart()
        let capture = SystemAudioCapture(startOverride: seam.handler)

        for _ in 0..<10 {
            do {
                _ = try await capture.bufferStream()
                XCTFail("the injected seam always fails")
            } catch SystemAudioCapture.CaptureError.givenUp {
                // Refused before the seam — the case this test is about.
            } catch {
                // The one real attempt.
            }
        }
        XCTAssertEqual(seam.attempts, SystemAudioCapture.maxStartAttempts)

        // A fresh user signal buys a real attempt again — nothing is bricked.
        capture.resetFailureBudget()
        _ = try? await capture.bufferStream()
        XCTAssertEqual(seam.attempts, SystemAudioCapture.maxStartAttempts + 1)
    }

    /// The message the meeting view shows names the grant, not an OSStatus.
    func testGivenUpDescriptionNamesTheGrant() {
        let message = SystemAudioCapture.CaptureError.givenUp(attempts: 1).localizedDescription
        XCTAssertTrue(message.contains("Screen & System Audio Recording"))
    }
}
