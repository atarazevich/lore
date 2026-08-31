import AppKit
import XCTest
@testable import LoreKit

/// The shared window-policy seam for the DynamicNotchKit surfaces (#145).
/// The library's `DynamicNotchPanel` is born captured (`sharingType` never
/// set = AppKit's `.readOnly`) and is rebuilt on every hide/show and screen
/// change, so both notch presenters re-apply `applyFullscreenAuxiliaryVisibility`
/// on every show and register with `NotchScreenChangeSweeper` for the rebuilds.
/// These tests pin what the seam owns — the wiring from the store's sharing
/// decision to the panel, fullscreen auxiliary behavior, the sweeper's
/// live/hidden branches — and verify that an alive panel is reachable by the
/// settings-toggle sweep (`SettingsStore.applyScreenShareVisibility` iterates
/// `NSApp.windows`).
@MainActor
final class NotchWindowVisibilityTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        // makeSuite materializes com.lore.test.<UUID>.plist under
        // ~/Library/Preferences — remove the domains so runs don't accumulate.
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    private func makeSuite(hideFromScreenShare: Bool? = nil) -> UserDefaults {
        let name = "com.lore.test.\(UUID().uuidString)"
        suiteNames.append(name)
        let suite = UserDefaults(suiteName: name)!
        if let hideFromScreenShare {
            suite.set(hideFromScreenShare, forKey: "hideFromScreenShare")
        }
        return suite
    }

    /// A panel configured the way DynamicNotchKit builds its
    /// `DynamicNotchPanel` (`initializeWindow`): borderless, non-activating —
    /// the shape that never becomes key, so the key-window sweep never fires
    /// for it and the seam is its only coverage.
    private func makeNotchStylePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        return panel
    }

    // MARK: - The seam's wiring

    /// The on/off/absent decision table is pinned by
    /// `SettingsStoreTests.testScreenSharingTypeFromRawDefaults`; the seam owns
    /// only the wiring — the panel carries whatever the store decides, plus the
    /// fullscreen-auxiliary behavior that was the seam's original duty.
    func testPatchAppliesTheStoresSharingDecisionAndFullscreenBehavior() {
        let panel = makeNotchStylePanel()

        panel.applyFullscreenAuxiliaryVisibility(defaults: makeSuite(hideFromScreenShare: true))
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary),
                      "the seam's original duty must survive the #145 extension")

        panel.applyFullscreenAuxiliaryVisibility(defaults: makeSuite(hideFromScreenShare: false))
        XCTAssertEqual(panel.sharingType, .readOnly)
    }

    // MARK: - Toggle-while-alive (#145 AC 2)

    /// `SettingsStore.applyScreenShareVisibility()` sweeps `NSApp.windows` when
    /// the setting is toggled. An alive notch-shaped panel must appear there —
    /// that listing is what lets the toggle reach a prompt already on screen.
    func testAlivePanelIsReachableByTheToggleSweep() {
        _ = NSApplication.shared
        let panel = makeNotchStylePanel()
        XCTAssertTrue(NSApp.windows.contains(panel),
                      "panel absent from NSApp.windows — the settings toggle could not reach an alive notch")
    }

    // MARK: - Screen-parameter rebuild (shared sweeper)

    /// The library rebuilds and re-fronts its panel on screen-parameter
    /// changes even while hidden. The sweeper's two branches: a hidden
    /// surface's ghost is ordered back out; a live surface's rebuilt panel
    /// gets the policy re-applied. Driven by posting the notification the
    /// sweeper observes; needs a window server to order panels in and out.
    func testSweeperOrdersGhostOutAndReappliesPolicyToLivePanel() async throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "no display — cannot order panels front")

        let ghost = makeNotchStylePanel()
        ghost.orderFrontRegardless()
        let live = makeNotchStylePanel()
        live.orderFrontRegardless()

        // #227: the gap the ghost investigation hit was that a sweep left no
        // trace at all. `onSweep` is the seam the real code wires to
        // DiagStore; here it just proves both branches are observable.
        var ghostSweeps: [Bool] = []
        var liveSweeps: [Bool] = []
        let ghostSweeper = NotchScreenChangeSweeper(
            isLive: { false }, window: { ghost }, onSweep: { ghostSweeps.append($0) }
        )
        let liveSweeper = NotchScreenChangeSweeper(
            isLive: { true }, window: { live }, onSweep: { liveSweeps.append($0) }
        )

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: NSApp)

        let expected = SettingsStore.screenSharingType(from: .standard)
        for _ in 0..<30 {  // the sweeper settles 500 ms; poll past it
            try await Task.sleep(for: .milliseconds(100))
            if !ghost.isVisible, live.sharingType == expected { break }
        }

        XCTAssertFalse(ghost.isVisible, "hidden surface: the rebuilt ghost must be ordered back out")
        XCTAssertEqual(live.sharingType, expected, "live surface: the rebuilt panel must carry the policy")
        XCTAssertFalse(ghostSweeps.isEmpty, "the ghost sweep itself must be traceable (#227)")
        XCTAssertTrue(ghostSweeps.allSatisfy { $0 == false }, "a ghost sweep must never report live")
        XCTAssertFalse(liveSweeps.isEmpty, "the live re-apply must be traceable too (#227)")
        XCTAssertTrue(liveSweeps.allSatisfy { $0 == true }, "a live re-apply must never report a ghost")
        live.orderOut(nil)
        _ = (ghostSweeper, liveSweeper)  // keep the observers alive through the poll
    }

    /// `onSweep` must stay silent before there is ever a window to act on —
    /// nothing to report yet is not the same fact as a ghost was ordered out.
    func testOnSweepNeverFiresWithNoWindowYet() async throws {
        _ = NSApplication.shared
        var sweeps: [Bool] = []
        let sweeper = NotchScreenChangeSweeper(
            isLive: { false }, window: { nil }, onSweep: { sweeps.append($0) }
        )

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(700)) // past both sweep passes

        XCTAssertTrue(sweeps.isEmpty, "no window means nothing to sweep, traced or otherwise")
        _ = sweeper
    }

    // MARK: - End to end through the presenter

    /// After a prompt, the real DynamicNotchKit panel carries the store's
    /// sharing decision — proving `present()` routes through the seam. Reaches
    /// the panel via `NSApp.windows` (the window's notch is private).
    /// Needs a display session: DynamicNotchKit creates its panel on the main
    /// screen and patching happens after its ~0.4s expand animation.
    ///
    /// Driven through the meeting prompt since #151 retired the health summon —
    /// the seam is shared, so one surviving surface proves it for the seam.
    func testPresentAppliesTheSharingDecisionToTheLibraryPanel() async throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "no display — DynamicNotchKit cannot build its panel")

        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let expected = SettingsStore.screenSharingType(from: .standard)
        let window = DynamicNotchPromptWindow()
        await window.present(content: NotchPromptContent(
            appName: "Zoom", onAccept: {}, onNotAMeeting: {}, onIgnoreApp: {}
        ))
        defer { Task { await window.dismiss() } }

        var panel: NSWindow?
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(100))
            panel = NSApp.windows.first {
                !before.contains(ObjectIdentifier($0))
                    && String(describing: type(of: $0)).contains("DynamicNotchPanel")
            }
            if let panel, panel.sharingType == expected { break }
        }

        XCTAssertNotNil(panel, "the library panel never appeared in NSApp.windows")
        XCTAssertEqual(panel?.sharingType, expected,
                       "present() must route the panel through the window-policy seam")
    }
}
