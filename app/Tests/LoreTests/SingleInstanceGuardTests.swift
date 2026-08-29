import XCTest
@testable import LoreKit

/// The #193 decision: two `com.lore.app` processes must not both start
/// subsystems, and a launch-instant tie must not let both — or neither —
/// survive. Pure over pid/launch-date pairs so it needs no
/// `NSRunningApplication` or launched bundle to exercise.
final class SingleInstanceGuardTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 0)

    func testNoOtherProcessMeansStay() {
        let me = SingleInstanceGuard.Candidate(pid: 100, launchDate: epoch)
        XCTAssertNil(
            SingleInstanceGuard.processToDeferTo(candidates: [me], myPID: 100)
        )
    }

    func testOlderInstanceMeansDefer() {
        let older = SingleInstanceGuard.Candidate(pid: 200, launchDate: epoch)
        let me = SingleInstanceGuard.Candidate(pid: 100, launchDate: epoch.addingTimeInterval(1))
        XCTAssertEqual(
            SingleInstanceGuard.processToDeferTo(candidates: [older, me], myPID: 100),
            older
        )
    }

    func testIAmTheOldestMeansStay() {
        let me = SingleInstanceGuard.Candidate(pid: 100, launchDate: epoch)
        let newer = SingleInstanceGuard.Candidate(pid: 200, launchDate: epoch.addingTimeInterval(1))
        XCTAssertNil(
            SingleInstanceGuard.processToDeferTo(candidates: [me, newer], myPID: 100)
        )
    }

    /// Two direct-exec launches landing in the same instant — the gap a
    /// snapshot with no tie-break leaves open — resolve toward the lower pid,
    /// so every process reaches the same verdict independently.
    func testEqualLaunchDatesMeanLowerPIDStays() {
        let lower = SingleInstanceGuard.Candidate(pid: 100, launchDate: epoch)
        let higher = SingleInstanceGuard.Candidate(pid: 200, launchDate: epoch)
        XCTAssertNil(
            SingleInstanceGuard.processToDeferTo(candidates: [lower, higher], myPID: 100)
        )
        XCTAssertEqual(
            SingleInstanceGuard.processToDeferTo(candidates: [lower, higher], myPID: 200),
            lower
        )
    }
}
