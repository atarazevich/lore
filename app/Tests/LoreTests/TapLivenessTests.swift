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
        XCTAssertEqual(liveness.observe(isAlive: true, hasReceivedKeyDown: true,
                                        tapSilent: over, sessionSilent: 0,
                                        secureInputActive: false), .stalled)
        XCTAssertEqual(liveness.isStarved, true)
    }

    /// "We saw no key events for 30 s" is not a fault — the user was reading.
    /// Nor is it a clean bill of health: no verdict was drawn, and the value
    /// must say so — `nil`, not a foregone `false` (#99).
    func testOurOwnSilenceIsNotAFaultWhenNobodyElseIsTypingEither() {
        var liveness = TapLiveness()
        XCTAssertNil(liveness.observe(isAlive: true, hasReceivedKeyDown: true,
                                      tapSilent: over, sessionSilent: over,
                                      secureInputActive: false))
        XCTAssertNil(liveness.isStarved, "a quiet machine proves nothing — no verdict, not a verdict of health")
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
        XCTAssertNil(liveness.observe(isAlive: true, hasReceivedKeyDown: true,
                                      tapSilent: over, sessionSilent: 0,
                                      secureInputActive: true),
                     "the session fed while we are not is what secure input IS — not evidence about our tap")
        XCTAssertNil(liveness.isStarved, "designed never to conclude here, so no verdict exists (#99)")

        // The password is typed, the field closes, and the user works with the
        // mouse: nobody types, so neither branch can run again.
        XCTAssertNil(liveness.observe(isAlive: true, hasReceivedKeyDown: true,
                                      tapSilent: over * 2, sessionSilent: over,
                                      secureInputActive: false))
        XCTAssertNil(liveness.isStarved, "nothing was ever measured, so there is nothing to hold")
    }

    /// `tapEventsResumed` must mean the tap recovered, not that the machine went
    /// quiet — the 1436-second stall in report 8763HGZT "resolving" in 5 seconds was
    /// the latter. This is also what stops the panel reading green to a user who
    /// merely did not type for 30 s on their way to opening it.
    func testAQuietMachineDoesNotClearAStarvation() {
        var liveness = TapLiveness()
        XCTAssertEqual(liveness.observe(isAlive: true, hasReceivedKeyDown: true,
                                        tapSilent: over, sessionSilent: 0,
                                        secureInputActive: false), .stalled)
        XCTAssertNil(liveness.observe(isAlive: true, hasReceivedKeyDown: true,
                                      tapSilent: over * 2, sessionSilent: over,
                                      secureInputActive: false),
                     "the user simply stopped typing — that is not a recovery")
        XCTAssertEqual(liveness.isStarved, true, "the verdict holds until the tap proves itself fed")
    }

    /// Only positive evidence clears it: our own tap receiving a key-down. It is
    /// evidence whatever else is true of the machine, secure input included — which
    /// is why that term gates only the half that concludes a starvation.
    func testOnlyTheTapReceivingAKeyDownResumesIt() {
        var liveness = TapLiveness()
        _ = liveness.observe(isAlive: true, hasReceivedKeyDown: true, tapSilent: over,
                             sessionSilent: 0, secureInputActive: false)
        XCTAssertEqual(liveness.observe(isAlive: true, hasReceivedKeyDown: true,
                                        tapSilent: 0, sessionSilent: 0,
                                        secureInputActive: true), .resumed)
        XCTAssertEqual(liveness.isStarved, false)
    }

    /// `nil` → `false` is the first verdict ever drawn, not a transition out of a
    /// stall: no `.resumed` edge, or every launch would record a recovery from a
    /// starvation that never happened (#99).
    func testTheFirstFedVerdictIsNotARecovery() {
        var liveness = TapLiveness()
        XCTAssertNil(liveness.observe(isAlive: true, hasReceivedKeyDown: true,
                                      tapSilent: 0, sessionSilent: 0,
                                      secureInputActive: false),
                     "nothing was stalled, so nothing resumed — no event")
        XCTAssertEqual(liveness.isStarved, false, "but the verdict is drawn: measured fed")
    }

    /// The wire shape of "no verdict" (#99): the key is absent, never a foregone
    /// `false`. Old reports, where `false` was ambiguous, must keep decoding.
    func testNoVerdictIsAbsentFromTheWireNotAForegoneFalse() throws {
        var undecided = TapLiveness()
        _ = undecided.observe(isAlive: true, hasReceivedKeyDown: true,
                              tapSilent: over * 2, sessionSilent: over,
                              secureInputActive: false)
        let keys = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(undecided)) as? [String: Any]
        ).keys
        XCTAssertFalse(keys.contains("isStarved"), "no verdict must not serialize as one")

        var fed = TapLiveness()
        _ = fed.observe(isAlive: true, hasReceivedKeyDown: true, tapSilent: 0,
                        sessionSilent: 0, secureInputActive: false)
        let fedKeys = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(fed)) as? [String: Any]
        ).keys
        XCTAssertTrue(fedKeys.contains("isStarved"), "a drawn verdict still rides the wire")

        let oldReport = Data(#"""
        {"isAlive": true, "tapSilentSeconds": 60, "sessionSilentSeconds": 51, "isStarved": false}
        """#.utf8)
        let decoded = try JSONDecoder().decode(TapLiveness.self, from: oldReport)
        XCTAssertEqual(decoded.isStarved, false, "pre-#99 reports keep decoding")
        XCTAssertNil(decoded.hasReceivedKeyDown,
                     "a report from before the fact was measured must not claim it either way (#135)")
    }

    /// The measurement reaches the panel and the uploaded report, so the counts must
    /// be the ones we measured: the user is meant to read the evidence, not just the
    /// conclusion.
    func testTheMeasurementIsCarried() {
        var liveness = TapLiveness()
        _ = liveness.observe(isAlive: false, hasReceivedKeyDown: true, tapSilent: 90.7,
                             sessionSilent: 2.3, secureInputActive: false)
        XCTAssertEqual(liveness.tapSilentSeconds, 90)
        XCTAssertEqual(liveness.sessionSilentSeconds, 2)
        XCTAssertFalse(liveness.isAlive)
    }
}
