import AppKit
import XCTest
@testable import LoreKit

/// The shared window-policy seam for the DynamicNotchKit surfaces (#145).
/// The library's `DynamicNotchPanel` is born captured (`sharingType` never
/// set = AppKit's `.readOnly`) and is rebuilt on every hide/show and screen
/// change, so both notch presenters re-apply `applyFullscreenAuxiliaryVisibility`
/// on every show. These tests pin what the seam owns — capture exclusion per
/// the user setting plus fullscreen auxiliary behavior — and verify that an
/// alive panel is reachable by the settings-toggle sweep
/// (`SettingsStore.applyScreenShareVisibility` iterates `NSApp.windows`).
@MainActor
final class NotchWindowVisibilityTests: XCTestCase {

    private func makeSuite(hideFromScreenShare: Bool? = nil) -> UserDefaults {
        let suite = UserDefaults(suiteName: "com.lore.test.\(UUID().uuidString)")!
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

    // MARK: - The leak, and the seam that closes it

    func testLibraryShapedPanelIsCapturedByDefault() {
        XCTAssertEqual(makeNotchStylePanel().sharingType, .readOnly,
                       "AppKit default — the reason an unpatched notch panel leaks into recordings")
    }

    func testPatchExcludesThePanelWhenTheSettingIsOnOrAbsent() {
        let panel = makeNotchStylePanel()
        panel.applyFullscreenAuxiliaryVisibility(defaults: makeSuite())
        XCTAssertEqual(panel.sharingType, .none, "absent key defaults to hidden (privacy-first)")

        panel.applyFullscreenAuxiliaryVisibility(defaults: makeSuite(hideFromScreenShare: true))
        XCTAssertEqual(panel.sharingType, .none)
    }

    func testPatchLeavesThePanelCapturableWhenTheSettingIsOff() {
        let panel = makeNotchStylePanel()
        panel.applyFullscreenAuxiliaryVisibility(defaults: makeSuite(hideFromScreenShare: false))
        XCTAssertEqual(panel.sharingType, .readOnly)
    }

    func testPatchKeepsFullscreenAuxiliaryBehavior() {
        let panel = makeNotchStylePanel()
        panel.applyFullscreenAuxiliaryVisibility(defaults: makeSuite())
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary),
                      "the seam's original duty must survive the #145 extension")
    }

    // MARK: - Toggle-while-alive (#145 AC 2)

    /// `SettingsStore.applyScreenShareVisibility()` sweeps `NSApp.windows` when
    /// the setting is toggled. An alive notch-shaped panel must appear there —
    /// that listing is what lets the toggle reach a summon already on screen.
    func testAlivePanelIsReachableByTheToggleSweep() {
        _ = NSApplication.shared
        let panel = makeNotchStylePanel()
        XCTAssertTrue(NSApp.windows.contains(panel),
                      "panel absent from NSApp.windows — the settings toggle could not reach an alive notch")
    }

    // MARK: - End to end through the presenter

    /// After a summon, the real DynamicNotchKit panel carries the store's
    /// sharing decision — proving `present()` routes through the seam. Reaches
    /// the panel via `NSApp.windows` (the presenter's notch is private).
    /// Needs a display session: DynamicNotchKit creates its panel on the main
    /// screen and patching happens after its ~0.4s expand animation.
    func testPresentAppliesTheSharingDecisionToTheLibraryPanel() async throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "no display — DynamicNotchKit cannot build its panel")

        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let expected = SettingsStore.screenSharingType(from: .standard)
        let presenter = HealthNotchPresenter(timeout: .seconds(60))
        presenter.present(HealthSummon(trigger: .captureFailed))
        defer { presenter.dismiss() }

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
