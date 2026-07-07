import XCTest
@testable import LoreKit

/// Stub window: records lifecycle and exposes the content so tests can drive
/// button actions without a display (#79).
@MainActor
private final class StubNotchWindow: NotchPromptWindow {
    let content: NotchPromptContent
    private(set) var presentCount = 0
    private(set) var dismissCount = 0

    init(content: NotchPromptContent) {
        self.content = content
    }

    func present() async { presentCount += 1 }
    func dismiss() async { dismissCount += 1 }
}

@MainActor
final class NotchPromptPresenterTests: XCTestCase {
    private var windows: [StubNotchWindow] = []

    override func setUp() {
        super.setUp()
        windows = []
    }

    private func makePresenter(timeout: Duration = .seconds(60)) -> NotchPromptPresenter {
        NotchPromptPresenter(timeout: timeout) { [self] content in
            let window = StubNotchWindow(content: content)
            windows.append(window)
            return window
        }
    }

    /// Let the presenter's fire-and-forget window Tasks run.
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
        XCTAssertEqual(windows.first?.dismissCount, 1, "window dismissed on timeout")
    }

    func testCancelPendingPreventsTimeout() async {
        let presenter = makePresenter(timeout: .milliseconds(50))
        var timeouts = 0
        presenter.onTimeout = { timeouts += 1 }

        presenter.present(appName: "Zoom")
        presenter.cancelPending()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(timeouts, 0, "cancelPending prevents the timeout callback")
        XCTAssertEqual(windows.first?.dismissCount, 1, "cancelPending dismisses the window")
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
        windows[0].content.onAccept()
        windows[0].content.onAccept() // second click on a resolved prompt
        try? await Task.sleep(for: .milliseconds(200)) // past the timeout

        XCTAssertEqual(accepts, 1, "accept fires exactly once")
        XCTAssertEqual(others, 0, "no other callback fires — including the cancelled timeout")
        XCTAssertEqual(windows[0].dismissCount, 1)
    }

    func testNotAMeetingAndIgnoreRouteToTheirCallbacks() async {
        let presenter = makePresenter()
        var notAMeetings = 0
        var ignores = 0
        presenter.onNotAMeeting = { notAMeetings += 1 }
        presenter.onIgnoreApp = { ignores += 1 }

        presenter.present(appName: "Zoom")
        windows[0].content.onNotAMeeting()
        presenter.present(appName: "Meet")
        windows[1].content.onIgnoreApp()
        await drain()

        XCTAssertEqual(notAMeetings, 1)
        XCTAssertEqual(ignores, 1)
    }

    // MARK: - Replace on re-present

    func testDoublePresentReplacesPendingPrompt() async {
        let presenter = makePresenter(timeout: .milliseconds(100))
        var accepts = 0
        var timeouts = 0
        presenter.onAccept = { accepts += 1 }
        presenter.onTimeout = { timeouts += 1 }

        presenter.present(appName: "Zoom")
        presenter.present(appName: "Meet")
        await drain()

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].dismissCount, 1, "first prompt window dismissed on replace")
        XCTAssertEqual(windows[1].presentCount, 1)
        XCTAssertEqual(windows[1].content.appName, "Meet")

        // The replaced prompt's buttons are dead.
        windows[0].content.onAccept()
        XCTAssertEqual(accepts, 0, "replaced prompt must not fire callbacks")

        // Only the live prompt's timeout fires.
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(timeouts, 1, "exactly one timeout for the live prompt")
        XCTAssertEqual(windows[1].dismissCount, 1)
    }

    // MARK: - cancelPending without a prompt

    func testCancelPendingWithoutPromptIsSafe() {
        let presenter = makePresenter()
        presenter.cancelPending() // must not crash or create windows
        XCTAssertTrue(windows.isEmpty)
    }
}
