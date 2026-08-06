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

@MainActor
final class NotchPromptPresenterTests: XCTestCase {
    private var window: StubNotchWindow!

    override func setUp() {
        super.setUp()
        window = StubNotchWindow()
    }

    private func makePresenter(timeout: Duration = .seconds(60)) -> NotchPromptPresenter {
        NotchPromptPresenter(timeout: timeout, window: window)
    }

    /// Let the presenter's queued window Tasks run.
    private func drain() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - Timeout

    func testTimeoutFiresOnTimeoutOnceAndDismissesWindow() async {
        let presenter = makePresenter(timeout: .milliseconds(50))
        var timeouts = 0
        presenter.onTimeout = { timeouts += 1 }

        presenter.present(appName: "Zoom")
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(timeouts, 1, "timeout fires exactly once")
        XCTAssertEqual(window.dismissCount, 1, "window dismissed on timeout")
    }

    func testCancelPendingPreventsTimeout() async {
        let presenter = makePresenter(timeout: .milliseconds(50))
        var timeouts = 0
        presenter.onTimeout = { timeouts += 1 }

        presenter.present(appName: "Zoom")
        presenter.cancelPending()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(timeouts, 0, "cancelPending prevents the timeout callback")
        XCTAssertEqual(window.dismissCount, 1, "cancelPending dismisses the window")
    }

    // MARK: - Actions route to the matching callback, once, and cancel the timeout

    func testAcceptFiresOnAcceptAndDismisses() async {
        let presenter = makePresenter(timeout: .milliseconds(50))
        var accepts = 0
        var others = 0
        presenter.onAccept = { accepts += 1 }
        presenter.onNotAMeeting = { others += 1 }
        presenter.onIgnoreApp = { others += 1 }
        presenter.onTimeout = { others += 1 }

        presenter.present(appName: "Zoom")
        await drain()
        window.presented[0].onAccept()
        window.presented[0].onAccept() // second click on a resolved prompt
        try? await Task.sleep(for: .milliseconds(200)) // past the timeout

        XCTAssertEqual(accepts, 1, "accept fires exactly once")
        XCTAssertEqual(others, 0, "no other callback fires — including the cancelled timeout")
        XCTAssertEqual(window.dismissCount, 1)
    }

    func testNotAMeetingAndIgnoreRouteToTheirCallbacks() async {
        let presenter = makePresenter()
        var notAMeetings = 0
        var ignores = 0
        presenter.onNotAMeeting = { notAMeetings += 1 }
        presenter.onIgnoreApp = { ignores += 1 }

        presenter.present(appName: "Zoom")
        await drain()
        window.presented[0].onNotAMeeting()
        presenter.present(appName: "Meet")
        await drain()
        window.presented[1].onIgnoreApp()
        await drain()

        XCTAssertEqual(notAMeetings, 1)
        XCTAssertEqual(ignores, 1)
    }

    // MARK: - Replace on re-present

    func testDoublePresentReplacesPendingPromptInPlace() async {
        let presenter = makePresenter(timeout: .milliseconds(100))
        var accepts = 0
        var timeouts = 0
        presenter.onAccept = { accepts += 1 }
        presenter.onTimeout = { timeouts += 1 }

        presenter.present(appName: "Zoom")
        presenter.present(appName: "Meet")
        await drain()

        // A replace is a content swap, not a down-and-up: no dismiss between
        // the two presents — the panel must not dip mid-replace.
        XCTAssertEqual(window.ops, [.present(appName: "Zoom"), .present(appName: "Meet")])

        // The replaced prompt's buttons are dead.
        window.presented[0].onAccept()
        XCTAssertEqual(accepts, 0, "replaced prompt must not fire callbacks")

        // Only the live prompt's timeout fires, and it takes the panel down.
        try? await Task.sleep(for: .milliseconds(300))
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
        await drain()
        presenter.cancelPending() // dismiss starts and suspends in the gate
        presenter.present(appName: "Meet") // must queue behind it
        await drain()

        XCTAssertEqual(window.ops, [.present(appName: "Zoom")],
                       "the second present must not start while the dismiss is in flight")

        window.releaseDismiss()
        await drain()
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
        await drain()
        XCTAssertTrue(window.ops.isEmpty)
    }
}
