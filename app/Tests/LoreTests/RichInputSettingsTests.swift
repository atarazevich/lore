import AppKit
import XCTest
@testable import LoreKit

/// A defaults suite nobody else can see, installed as the store the live
/// Copying reads go through (#198). A test must never let `RichInputSettings`
/// read `.standard`: the developer's own switches would decide whether it
/// passes. Pair every call with `RichInputSettings.use(.standard)` in teardown.
func isolatedRichInputDefaults(_ label: String) -> UserDefaults {
    let suiteName = "\(label)-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    RichInputSettings.use(suite)
    return suite
}

/// The Copying section's switches (#198): what a machine that has never opened
/// the section does, which key each switch owns, and what the door is allowed
/// to collect.
@MainActor
final class RichInputSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = isolatedRichInputDefaults("RichInputSettingsTests")
    }

    override func tearDown() async throws {
        RichInputSettings.use(.standard)
        defaults = nil
    }

    // MARK: - Defaults

    /// Collecting is the feature, so it is on; files are the one kind that gets
    /// copied by accident and rarely helps a prompt, so they are off.
    func testDefaultsOutOfTheBox() {
        for item in RichInputSettings.Switch.allCases where item != .files {
            XCTAssertTrue(RichInputSettings.isOn(item, in: defaults), "\(item.rawValue) defaults on")
        }
        XCTAssertFalse(RichInputSettings.isOn(.files, in: defaults))
        XCTAssertEqual(RichInputSettings.keepMegabytes(in: defaults), 200)
    }

    /// The keys are a contract with every surface that reads them live — the
    /// bubble's paperclip and `S`, the paste's own text, the event tap.
    func testKeysAreTheDocumentedOnes() {
        XCTAssertEqual(
            RichInputSettings.Switch.allCases.map(\.key),
            [
                "richInput.collect",
                "richInput.text",
                "richInput.images",
                "richInput.files",
                "richInput.screenshots",
                "richInput.tags",
                "richInput.redirectSystemScreenshot",
            ]
        )
        XCTAssertEqual(RichInputSettings.keepMegabytesKey, "richInput.keepMB")
    }

    // MARK: - Kinds

    /// A copied link rides the text switch: it is words on the clipboard, and
    /// the section offers pictures and files, not addresses.
    func testEveryKindHasAnOwner() {
        XCTAssertEqual(RichInputSettings.owner(of: .text), .text)
        XCTAssertEqual(RichInputSettings.owner(of: .url), .text)
        XCTAssertEqual(RichInputSettings.owner(of: .image), .images)
        XCTAssertEqual(RichInputSettings.owner(of: .fileURL), .files)
    }

    func testASwitchedOffKindIsNotCollectedAndTheOthersStillAre() {
        defaults.set(false, forKey: RichInputSettings.Switch.images.key)
        XCTAssertFalse(RichInputSettings.collects(.image, in: defaults))
        XCTAssertTrue(RichInputSettings.collects(.text, in: defaults))
        XCTAssertTrue(RichInputSettings.collects(.url, in: defaults))
        // Files were off before anyone touched anything.
        XCTAssertFalse(RichInputSettings.collects(.fileURL, in: defaults))
    }

    func testTheMasterSwitchOffCollectsNothingAtAll() {
        defaults.set(false, forKey: RichInputSettings.Switch.collect.key)
        for kind in DictationItemKind.allCases {
            XCTAssertFalse(RichInputSettings.collects(kind, in: defaults), "\(kind.rawValue)")
        }
    }

    // MARK: - The door reads them live

    /// A kind switched off produces no item and no count — the door does not
    /// even read the bytes.
    func testTheDoorCollectsNothingOfASwitchedOffKind() {
        let board = NSPasteboard(name: NSPasteboard.Name("com.lore.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let watcher = ClipboardWatcher(pasteboard: board)
        watcher.start(offset: { 0 }, onItem: { _ in })
        watcher.stop()

        defaults.set(false, forKey: RichInputSettings.Switch.text.key)
        board.clearContents()
        board.setString("not going anywhere", forType: .string)
        XCTAssertNil(watcher.collect(at: 1.0))

        // Switched back on mid-recording, the next copy is collected: the read
        // is live, nothing is cached for the length of a dictation.
        defaults.set(true, forKey: RichInputSettings.Switch.text.key)
        board.clearContents()
        board.setString("this one travels", forType: .string)
        XCTAssertEqual(watcher.collect(at: 2.0)?.kind, .text)
    }

    // MARK: - The card writes what the door reads

    /// One store, two surfaces: what the Settings card flips is exactly what
    /// the live readers see, with no restart in between.
    func testTheCardsSwitchIsTheOneTheReadersRead() {
        let settings = isolatedSettings("RichInputSettingsTests", defaults: defaults)
        XCTAssertTrue(settings.richInput(.tags))
        XCTAssertTrue(RichInputSettings.tagsEnabled)

        settings.setRichInput(.tags, false)
        XCTAssertFalse(settings.richInput(.tags))
        XCTAssertFalse(RichInputSettings.tagsEnabled)
        XCTAssertFalse(RichInputSettings.isOn(.tags, in: defaults))

        settings.setRichInput(.screenshots, false)
        XCTAssertFalse(RichInputSettings.screenshotsEnabled)

        settings.richInputKeepMegabytes = 500
        XCTAssertEqual(RichInputSettings.keepMegabytes(in: defaults), 500)
    }

    /// Flipping one switch writes one key: a machine that never opened the
    /// section keeps every other default absent, so a later change of mind
    /// about a default still reaches it.
    func testOnlyTheChangedSwitchIsWritten() {
        let settings = isolatedSettings("RichInputSettingsTests", defaults: defaults)
        settings.setRichInput(.files, true)

        XCTAssertEqual(defaults.object(forKey: RichInputSettings.Switch.files.key) as? Bool, true)
        for item in RichInputSettings.Switch.allCases where item != .files {
            XCTAssertNil(defaults.object(forKey: item.key), "\(item.rawValue) must stay absent")
        }
    }
}
