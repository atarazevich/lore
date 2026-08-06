import XCTest
@testable import LoreKit

/// Stub window: one long-lived instance per presenter (#141), recording the
/// operation order and exposing presented content so tests can drive button
/// actions without a display (#79).
@MainActor
private final class StubNotchWindow: NotchPromptWindow {
    enum Op: Equatable { case present(appName: String?), dismiss }
    private(set) var ops: [Op] = []
    private(set) var presented: [NotchPromptContent] = []

    /// When true, `dismiss()` suspends until `releaseDismiss()` — the
    /// serialization test drives the dismiss→re-present race with it.
    var gateDismiss = false
    private var dismissGate: CheckedContinuation<Void, Never>?

    /// True while `dismiss()` sits suspended in the gate — the test waits on
    /// it so `releaseDismiss()` cannot silently no-op on a gate nobody has
    /// entered yet (#147).
    var dismissGateEntered: Bool { dismissGate != nil }

    func present(content: NotchPromptContent) async {
        ops.append(.present(appName: content.appName))
        presented.append(content)
    }

    func dismiss() async {
        if gateDismiss {
            await withCheckedContinuation { dismissGate = $0 }
        }
        ops.append(.dismiss)
    }

    func releaseDismiss() {
        dismissGate?.resume()
        dismissGate = nil
    }

    var dismissCount: Int { ops.filter { $0 == .dismiss }.count }
}

/// Every wait in this suite is condition- or expectation-driven (#147): a
/// positive claim waits on the event with a generous ceiling; a negative claim
/// ("this never fires") holds an inverted expectation open for a bounded
/// window, which contention can only make stricter, never flaky.
@MainActor
final class NotchPromptPresenterTests: XCTestCase {
    private var window: StubNotchWindow!

    override func setUp() async throws {
        window = StubNotchWindow()
    }

    private func makePresenter(timeout: Duration = .seconds(60)) -> NotchPromptPresenter {
        NotchPromptPresenter(timeout: timeout, window: window)
    }

    /// Checked, condition-driven replacement for `window.presented[index]`:
    /// waits until the op queue has delivered present #(index + 1), and fails
    /// instead of crashing when it never arrives.
    private func presentedContent(at index: Int) async -> NotchPromptContent? {
        guard await waitUntil({ window.presented.count > index }) else {
            XCTFail("present #\(index + 1) never reached the window; ops so far: \(window.ops)")
            return nil
        }
        return window.presented[index]
    }

    /// Negative-claim window (#147): holds an inverted expectation open for
    /// `window` seconds after rebinding the callback under test — `rebind`
    /// receives the fulfill hook and must keep incrementing the test's own
    /// counter. A fire inside the window fails the test; contention can only
    /// make the check stricter, never flaky.
    private func assertStaysSilent(
        _ description: String,
        window: TimeInterval,
        rebind: (@escaping () -> Void) -> Void
    ) async {
        let silent = expectation(description: description)
        silent.isInverted = true
        rebind { silent.fulfill() }
        await fulfillment(of: [silent], timeout: window)
    }

    // MARK: - Timeout

    func testTimeoutFiresOnTimeoutOnceAndDismissesWindow() async {
        let presenter = makePresenter(timeout: .milliseconds(50))
        var timeouts = 0
        let timedOut = expectation(description: "onTimeout fires")
        presenter.onTimeout = { timeouts += 1; timedOut.fulfill() }

        presenter.present(appName: "Zoom")
        await fulfillment(of: [timedOut], timeout: 5)
        await waitUntil { window.dismissCount == 1 }

        // Bounded negative window: a re-armed timer would fire again in here.
        await assertStaysSilent("timeout does not re-fire", window: 0.2) { fulfill in
            presenter.onTimeout = { timeouts += 1; fulfill() }
        }

        XCTAssertEqual(timeouts, 1, "timeout fires exactly once")
        XCTAssertEqual(window.dismissCount, 1, "window dismissed on timeout")
    }

    func testCancelPendingPreventsTimeout() async {
        let presenter = makePresenter(timeout: .milliseconds(50))
        var timeouts = 0
        presenter.onTimeout = { timeouts += 1 }

        presenter.present(appName: "Zoom")
        presenter.cancelPending()
        await waitUntil { window.dismissCount == 1 }
        // 50ms timer against a 200ms inverted window: a timer cancelPending
        // failed to cancel fires inside it (an earlier fire trips the counter).
        await assertStaysSilent("cancelled timer never fires", window: 0.2) { fulfill in
            presenter.onTimeout = { timeouts += 1; fulfill() }
        }

        XCTAssertEqual(timeouts, 0, "cancelPending prevents the timeout callback")
        XCTAssertEqual(window.dismissCount, 1, "cancelPending dismisses the window")
    }

    // MARK: - Actions route to the matching callback, once, and cancel the timeout

    func testAcceptFiresOnAcceptAndDismisses() async {
        // 60s timeout: the accept cannot race a live deadline (the old 50ms
        // timer vs 50ms drain coin flip). Mis-routes to the other callbacks
        // are synchronous inside the click, so the counters catch them.
        // Accept-path timer cancellation is NOT pinned by this suite — doing
        // that deterministically needs a cancellation seam on the presenter,
        // deliberately out of #147's test-only scope.
        let presenter = makePresenter(timeout: .seconds(60))
        var accepts = 0
        var others = 0
        presenter.onAccept = { accepts += 1 }
        presenter.onNotAMeeting = { others += 1 }
        presenter.onIgnoreApp = { others += 1 }
        presenter.onTimeout = { others += 1 }

        presenter.present(appName: "Zoom")
        guard let prompt = await presentedContent(at: 0) else { return }
        prompt.onAccept()
        prompt.onAccept() // second click on a resolved prompt
        await waitUntil { window.dismissCount == 1 }

        XCTAssertEqual(accepts, 1, "accept fires exactly once")
        XCTAssertEqual(others, 0, "no other callback fires")
        XCTAssertEqual(window.dismissCount, 1)
    }

    func testNotAMeetingAndIgnoreRouteToTheirCallbacks() async {
        let presenter = makePresenter()
        var notAMeetings = 0
        var ignores = 0
        presenter.onNotAMeeting = { notAMeetings += 1 }
        presenter.onIgnoreApp = { ignores += 1 }

        presenter.present(appName: "Zoom")
        guard let zoom = await presentedContent(at: 0) else { return }
        zoom.onNotAMeeting() // resolves synchronously

        presenter.present(appName: "Meet")
        guard let meet = await presentedContent(at: 1) else { return }
        meet.onIgnoreApp()

        XCTAssertEqual(notAMeetings, 1)
        XCTAssertEqual(ignores, 1)
    }

    // MARK: - Replace on re-present

    func testDoublePresentReplacesPendingPromptInPlace() async {
        let presenter = makePresenter(timeout: .milliseconds(100))
        var accepts = 0
        var timeouts = 0
        let timedOut = expectation(description: "the live prompt times out")
        presenter.onAccept = { accepts += 1 }
        presenter.onTimeout = { timeouts += 1; timedOut.fulfill() }

        presenter.present(appName: "Zoom")
        presenter.present(appName: "Meet")
        await waitUntil { window.ops.count >= 2 }

        // A replace is a content swap, not a down-and-up: no dismiss between
        // the two presents — the panel must not dip mid-replace. (The live
        // prompt's timeout dismiss lands later, beyond this prefix.)
        XCTAssertEqual(
            Array(window.ops.prefix(2)),
            [.present(appName: "Zoom"), .present(appName: "Meet")]
        )

        // The replaced prompt's buttons are dead — stale generation, so this
        // holds whether or not the live prompt has timed out yet.
        guard let zoom = await presentedContent(at: 0) else { return }
        zoom.onAccept()
        XCTAssertEqual(accepts, 0, "replaced prompt must not fire callbacks")

        // Only the live prompt's timeout fires, and it takes the panel down.
        await fulfillment(of: [timedOut], timeout: 5)
        await waitUntil { window.dismissCount == 1 }

        // Bounded negative window: had the replaced prompt's timer survived,
        // it was armed alongside the live one and fires in here.
        await assertStaysSilent("the replaced prompt's timer is dead", window: 0.3) { fulfill in
            presenter.onTimeout = { timeouts += 1; fulfill() }
        }

        XCTAssertEqual(timeouts, 1, "exactly one timeout for the live prompt")
        XCTAssertEqual(window.dismissCount, 1)
    }

    // MARK: - Serialization (#141 fix pass)

    /// The stranded-continuation race: DynamicNotchKit cancels its close task
    /// when a state change lands during hide()'s ~0.4s animation, and a
    /// cancelled close task never resumes hide()'s continuation — the awaiting
    /// Task would leak forever. So the presenter serializes: a present arriving
    /// while a dismiss is in flight waits for it, never overlaps it.
    func testAPresentDuringAnInFlightDismissWaitsForTheDismissToFinish() async {
        let presenter = makePresenter()
        window.gateDismiss = true

        presenter.present(appName: "Zoom")
        presenter.cancelPending() // dismiss queues behind the present, then suspends in the gate
        presenter.present(appName: "Meet") // must queue behind the dismiss
        let gateEntered = await waitUntil { window.dismissGateEntered }
        XCTAssertTrue(gateEntered, "dismiss never reached its gate")

        XCTAssertEqual(window.ops, [.present(appName: "Zoom")],
                       "the second present must not start while the dismiss is in flight")

        window.releaseDismiss()
        await waitUntil { window.ops.count >= 3 }
        XCTAssertEqual(
            window.ops,
            [.present(appName: "Zoom"), .dismiss, .present(appName: "Meet")],
            "FIFO: the dismiss completes, then the replacement presents"
        )
    }

    // MARK: - cancelPending without a prompt

    func testCancelPendingWithoutPromptIsSafe() async {
        let presenter = makePresenter()
        presenter.cancelPending() // must not crash or touch the window
        // Bounded negative wait: a regressed window op gets 200ms to surface.
        await waitUntil(timeout: .milliseconds(200)) { !window.ops.isEmpty }
        XCTAssertTrue(window.ops.isEmpty)
    }
}
