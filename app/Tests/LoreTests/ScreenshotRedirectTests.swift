import CoreGraphics
import XCTest
@testable import LoreKit

/// While a dictation records, a system screenshot shortcut is stood in for by
/// its clipboard variant, so the picture joins the prompt (#199). This is the
/// decision the event tap makes: which chord, and whether the two switches
/// governing it are on.
@MainActor
final class ScreenshotRedirectTests: XCTestCase {
    private let cmdShift: CGEventFlags = [.maskCommand, .maskShift]

    func testTheTwoChordsLoreStandsInFor() {
        XCTAssertEqual(ScreenshotShortcut(keyCode: 21, flags: cmdShift), .region)
        XCTAssertEqual(ScreenshotShortcut(keyCode: 20, flags: cmdShift), .wholeScreen)
        XCTAssertEqual(ScreenshotShortcut(keyCode: 20, flags: cmdShift)?.isFullScreen, true)
        XCTAssertEqual(ScreenshotShortcut(keyCode: 21, flags: cmdShift)?.isFullScreen, false)
    }

    /// A real key-down carries device-level bits and whatever else is latched;
    /// the match is against the modifier keys alone.
    func testTheBitsARealKeyDownCarriesDoNotBreakTheMatch() {
        let deviceBits = CGEventFlags(rawValue: 0x100).union(.maskAlphaShift)
        XCTAssertEqual(ScreenshotShortcut(keyCode: 21, flags: cmdShift.union(deviceBits)), .region)
    }

    /// The Ctrl variant already puts the picture on the clipboard — consuming
    /// it would post the chord twice. Everything else is somebody else's key.
    func testEveryOtherChordIsLeftAlone() {
        XCTAssertNil(ScreenshotShortcut(keyCode: 21, flags: [.maskCommand, .maskShift, .maskControl]))
        XCTAssertNil(ScreenshotShortcut(keyCode: 21, flags: [.maskCommand, .maskShift, .maskAlternate]))
        XCTAssertNil(ScreenshotShortcut(keyCode: 21, flags: [.maskCommand, .maskShift, .maskSecondaryFn]))
        XCTAssertNil(ScreenshotShortcut(keyCode: 21, flags: [.maskCommand]))
        XCTAssertNil(ScreenshotShortcut(keyCode: 21, flags: [.maskShift]))
        // Cmd+Shift+5 is the system's own capture UI; S is Lore's Fn chord.
        XCTAssertNil(ScreenshotShortcut(keyCode: 23, flags: cmdShift))
        XCTAssertNil(ScreenshotShortcut(keyCode: 1, flags: cmdShift))
    }

    /// Both switches govern it, and either one off closes the door. The
    /// recording gate itself is the tap's `isRecordingFlag`.
    func testBothSwitchesGovernTheRedirect() {
        let defaults = isolatedRichInputDefaults("ScreenshotRedirectTests")
        defer { RichInputSettings.use(.standard) }

        XCTAssertTrue(RichInputSettings.screenshotsEnabled)
        XCTAssertTrue(RichInputSettings.redirectsSystemScreenshot)

        defaults.set(false, forKey: RichInputSettings.Switch.redirectSystemScreenshot.key)
        XCTAssertFalse(RichInputSettings.redirectsSystemScreenshot)
        XCTAssertTrue(RichInputSettings.screenshotsEnabled, "Fn+S is unaffected by the redirect switch")

        defaults.set(true, forKey: RichInputSettings.Switch.redirectSystemScreenshot.key)
        defaults.set(false, forKey: RichInputSettings.Switch.screenshots.key)
        XCTAssertFalse(RichInputSettings.screenshotsEnabled, "screenshots off closes both doors")
    }
}
