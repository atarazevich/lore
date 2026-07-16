import XCTest
@testable import LoreKit

/// #97: the tap probe's verdict must be a function of whether **the tap** is
/// receiving keystrokes — not of whether the user paused typing, and not of
/// whether they pressed Fn. `HotkeyManager` cannot be tested (its state is private
/// and `install()` creates a real tap), so the measurement lives in `TapLiveness`
/// and this is where it is pinned.
final class TapLivenessTests: XCTestCase {

    private let over = TapLiveness.threshold + 1

    /// The defect in one test. The old comparison was
    /// `min(sinceKeyDown, sinceFlagsChanged)`, so a user holding Fn every few
    /// seconds reset the counter and the probe never saw the key-down starvation it
    /// exists to catch: it was blind to precisely the failure the reporting user
    /// had, because their working Fn key kept reassuring it. Key-downs alone now.
    func testTapStarvesWhileTheSessionIsFedKeyDowns() {
        var liveness = TapLiveness()
        XCTAssertEqual(liveness.observe(isAlive: true, tapSilent: over, sessionSilent: 0,
                                        secureInputActive: false), .stalled)
        XCTAssertTrue(liveness.isStarved)
    }

    /// "We saw no key events for 30 s" is not a fault — the user was reading.
    func testOurOwnSilenceIsNotAFaultWhenNobodyElseIsTypingEither() {
        var liveness = TapLiveness()
        XCTAssertNil(liveness.observe(isAlive: true, tapSilent: over, sessionSilent: over,
                                      secureInputActive: false))
        XCTAssertFalse(liveness.isStarved)
    }

    /// Secure input is the one benign cause of the two counters diverging, and it
    /// diverges them exactly as a starvation does: the session is fed, every tap on
    /// the machine is starved. Latching that would outlive the condition — the #94
    /// gate that hides it stops applying the moment secure input clears, and only
    /// our tap receiving a key-down lifts a latch. So anyone who typed a password
    /// and then reached for the mouse would be told, permanently, that Lore's
    /// shortcuts are broken. This is the inverse of the bug the fix exists to kill.
    func testAStarvationIsNotDrawnWhileSecureInputMakesItUnmeasurable() {
        var liveness = TapLiveness()
        XCTAssertNil(liveness.observe(isAlive: true, tapSilent: over, sessionSilent: 0,
                                      secureInputActive: true),
                     "the session fed while we are not is what secure input IS — not evidence about our tap")
        XCTAssertFalse(liveness.isStarved)

        // The password is typed, the field closes, and the user works with the
        // mouse: nobody types, so neither branch can run again.
        XCTAssertNil(liveness.observe(isAlive: true, tapSilent: over * 2, sessionSilent: over,
                                      secureInputActive: false))
        XCTAssertFalse(liveness.isStarved, "nothing was ever measured, so there is nothing to hold")
    }

    /// `tapEventsResumed` must mean the tap recovered, not that the machine went
    /// quiet — the 1436-second stall in report 8763HGZT "resolving" in 5 seconds was
    /// the latter. This is also what stops the panel reading green to a user who
    /// merely did not type for 30 s on their way to opening it.
    func testAQuietMachineDoesNotClearAStarvation() {
        var liveness = TapLiveness()
        XCTAssertEqual(liveness.observe(isAlive: true, tapSilent: over, sessionSilent: 0,
                                        secureInputActive: false), .stalled)
        XCTAssertNil(liveness.observe(isAlive: true, tapSilent: over * 2, sessionSilent: over,
                                      secureInputActive: false),
                     "the user simply stopped typing — that is not a recovery")
        XCTAssertTrue(liveness.isStarved, "the verdict holds until the tap proves itself fed")
    }

    /// Only positive evidence clears it: our own tap receiving a key-down. It is
    /// evidence whatever else is true of the machine, secure input included — which
    /// is why that term gates only the half that concludes a starvation.
    func testOnlyTheTapReceivingAKeyDownResumesIt() {
        var liveness = TapLiveness()
        _ = liveness.observe(isAlive: true, tapSilent: over, sessionSilent: 0, secureInputActive: false)
        XCTAssertEqual(liveness.observe(isAlive: true, tapSilent: 0, sessionSilent: 0,
                                        secureInputActive: true), .resumed)
        XCTAssertFalse(liveness.isStarved)
    }

    /// The measurement reaches the panel and the uploaded report, so the counts must
    /// be the ones we measured: the user is meant to read the evidence, not just the
    /// conclusion.
    func testTheMeasurementIsCarried() {
        var liveness = TapLiveness()
        _ = liveness.observe(isAlive: false, tapSilent: 90.7, sessionSilent: 2.3, secureInputActive: false)
        XCTAssertEqual(liveness.tapSilentSeconds, 90)
        XCTAssertEqual(liveness.sessionSilentSeconds, 2)
        XCTAssertFalse(liveness.isAlive)
    }
}
