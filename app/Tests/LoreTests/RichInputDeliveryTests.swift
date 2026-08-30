import XCTest
@testable import LoreKit

/// Web delivery (#195): which form the app that is about to receive the paste
/// gets, what a picture is called in that form, and how a composed dictation is
/// cut into the pastes a composer can absorb.
final class RichInputDeliveryTests: XCTestCase {

    // The tags around an item are a Copying switch (#198) and `pasteText` reads
    // it live, so every expectation here needs a store of its own.
    override func setUp() async throws {
        _ = isolatedRichInputDefaults("RichInputDeliveryTests")
    }

    override func tearDown() async throws {
        RichInputSettings.use(.standard)
    }

    private let shotA = "/Users/a/Library/Application Support/Lore/RichInput/674C1E0A-1.png"
    private let shotB = "/Users/a/Library/Application Support/Lore/RichInput/674C1E0A-2.png"

    private func image(_ path: String, at offset: Double) -> DictationItem {
        DictationItem(kind: .image, offset: offset, path: path)
    }

    // MARK: - Which form the target gets

    /// The path form is the exception, kept as a list of bundle ids: "can this
    /// app open a path" cannot be asked of a running process.
    func testATerminalReadsPathsAndEverythingElseGetsTheWebForm() {
        for terminal in [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty", "dev.warp.Warp-Stable", "org.alacritty",
            "com.github.wez.wezterm", "com.cmuxterm.app", "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",
        ] {
            XCTAssertEqual(PasteTarget.of(terminal), .path, terminal)
        }
        for composer in ["com.google.Chrome", "com.openai.chat", "company.thebrowser.Browser"] {
            XCTAssertEqual(PasteTarget.of(composer), .web, composer)
        }
        // A frontmost app that reports no bundle id is likelier a composer than
        // a terminal, and the web form still reads when nothing attaches.
        XCTAssertEqual(PasteTarget.of(nil), .web)
    }

    // MARK: - What a file is called

    /// The tag is the same in both forms and stays where the item happened;
    /// only the name inside it changes. A composer shows the attachment under
    /// its filename, so the text names it the same way.
    func testAPictureIsNamedTheWayTheTargetCanReachIt() {
        XCTAssertEqual(
            image(shotA, at: 1).pasteText(for: .web),
            "<screenshot>674C1E0A-1.png</screenshot>"
        )
        XCTAssertEqual(
            image(shotA, at: 1).pasteText(for: .path),
            "<screenshot>\(shotA)</screenshot>"
        )
        XCTAssertEqual(
            DictationItem(kind: .fileURL, offset: 1, path: "/Users/a/notes 2026.md")
                .pasteText(for: .web),
            "<file>notes 2026.md</file>"
        )
        // Text is text in both forms — nothing is attached for it.
        XCTAssertEqual(
            DictationItem(kind: .text, offset: 1, text: "two\nlines").pasteText(for: .web),
            "<copied>\ntwo\nlines\n</copied>"
        )
        XCTAssertEqual(
            DictationItem(kind: .url, offset: 1, text: "https://example.com").pasteText(for: .web),
            "<link>https://example.com</link>"
        )
        XCTAssertNil(DictationItem(kind: .image, offset: 1).pasteText(for: .web))
    }

    // MARK: - How it is delivered

    /// The dictation the owner will run by hand: a copied paragraph and a
    /// screenshot, into a browser composer.
    func testACopiedParagraphAndAScreenshotAreThreeSteps() {
        let copied = DictationItem(kind: .text, offset: 0.2, text: "the paragraph he copied")
        let shot = image(shotA, at: 0.6)
        let words = spokenWords([0.2, 0.4, 0.6, 0.9, 1.2], endingClauseAt: [0, 2])
        let composed = RichInput.compose(
            spoken: "Смотри, вот скриншот, что скажешь", items: [copied, shot], words: words
        )

        XCTAssertEqual(
            RichInput.delivery(text: composed, items: [copied, shot], target: .web),
            [
                .text(
                    "Смотри,\n\n<copied>\nthe paragraph he copied\n</copied>\n\nвот скриншот,"
                        + "\n\n<screenshot>674C1E0A-1.png</screenshot>"
                ),
                .files([shotA]),
                .text("\n\nчто скажешь"),
            ]
        )
    }

    /// A terminal keeps what #192 ships: one paste, the text exactly as the
    /// history entry holds it.
    func testATerminalGetsOnePasteOfTheTextItself() {
        let shot = image(shotA, at: 0.6)
        let composed = RichInput.compose(
            spoken: "Посмотри на это.", items: [shot],
            words: spokenWords([0.3, 0.6, 0.9], endingClauseAt: [2])
        )
        XCTAssertEqual(
            RichInput.delivery(text: composed, items: [shot], target: .path), [.text(composed)]
        )
    }

    /// Nothing to attach, nothing to cut — the dictation everyone dictates is
    /// still one write and one Cmd+V.
    func testADictationWithNothingAttachedIsOnePaste() {
        XCTAssertEqual(
            RichInput.delivery(text: "просто слова", items: [], target: .web),
            [.text("просто слова")]
        )
        let copied = DictationItem(kind: .text, offset: 1, text: "x")
        XCTAssertEqual(
            RichInput.delivery(
                text: "слова\n\n<copied>\nx\n</copied>", items: [copied], target: .web
            ),
            [.text("слова\n\n<copied>\nx\n</copied>")]
        )
    }

    /// The last thing said was a screenshot: the words carry its name, the file
    /// follows, and no empty paste trails behind them.
    func testATrailingScreenshotEndsTheSequence() {
        let shot = image(shotA, at: 0.6)
        let composed = RichInput.compose(
            spoken: "Посмотри на это.", items: [shot],
            words: spokenWords([0.3, 0.6, 0.9], endingClauseAt: [2])
        )
        XCTAssertEqual(
            RichInput.delivery(text: composed, items: [shot], target: .web),
            [
                .text("Посмотри на это.\n\n<screenshot>674C1E0A-1.png</screenshot>"),
                .files([shotA]),
            ]
        )
    }

    /// Two pictures taken in the same breath ride one pasteboard — Chrome and
    /// WebKit attach every `public.file-url` item — and a word spoken between
    /// them ends the run, so each lands where it was taken.
    func testAdjacentPicturesShareOnePasteAndAWordBetweenThemEndsTheRun() {
        let first = image(shotA, at: 0.6)
        let second = image(shotB, at: 0.62)
        let together = RichInput.compose(
            spoken: "вот они, смотри", items: [first, second],
            words: spokenWords([0.3, 0.6, 1.0], endingClauseAt: [1])
        )
        XCTAssertEqual(
            RichInput.delivery(text: together, items: [first, second], target: .web),
            [
                .text(
                    "вот они,\n\n<screenshot>674C1E0A-1.png</screenshot>"
                        + "\n\n<screenshot>674C1E0A-2.png</screenshot>"
                ),
                .files([shotA, shotB]),
                .text("\n\nсмотри"),
            ]
        )

        let apart = image(shotB, at: 1.3)
        let spread = RichInput.compose(
            spoken: "первый, второй, всё", items: [first, apart],
            words: spokenWords([0.6, 1.2, 1.6], endingClauseAt: [0, 1])
        )
        XCTAssertEqual(
            RichInput.delivery(text: spread, items: [first, apart], target: .web),
            [
                .text("первый,\n\n<screenshot>674C1E0A-1.png</screenshot>"),
                .files([shotA]),
                .text("\n\nвторой,\n\n<screenshot>674C1E0A-2.png</screenshot>"),
                .files([shotB]),
                .text("\n\nвсё"),
            ]
        )
    }

    // MARK: - Untagged

    /// With "Mark each item in the text" off (#198) the items arrive bare — the
    /// copied words as a plain paragraph, the picture as the name the composer
    /// will show — and everything else about the delivery is unchanged: same
    /// place, same cut, same file on the pasteboard.
    func testWithTheMarkersOffTheItemsArriveBare() {
        let defaults = isolatedRichInputDefaults("RichInputDeliveryTests-untagged")
        defaults.set(false, forKey: RichInputSettings.Switch.tags.key)

        let copied = DictationItem(kind: .text, offset: 0.2, text: "the paragraph he copied")
        let shot = image(shotA, at: 0.6)
        XCTAssertEqual(copied.pasteText(for: .path), "the paragraph he copied")
        XCTAssertEqual(shot.pasteText(for: .path), shotA)
        XCTAssertEqual(shot.pasteText(for: .web), "674C1E0A-1.png")
        XCTAssertEqual(
            DictationItem(kind: .url, offset: 1, text: "https://example.com")
                .pasteText(for: .web),
            "https://example.com"
        )

        let words = spokenWords([0.2, 0.4, 0.6, 0.9, 1.2], endingClauseAt: [0, 2])
        let composed = RichInput.compose(
            spoken: "Смотри, вот скриншот, что скажешь", items: [copied, shot], words: words
        )
        XCTAssertEqual(
            RichInput.delivery(text: composed, items: [copied, shot], target: .web),
            [
                .text(
                    "Смотри,\n\nthe paragraph he copied\n\nвот скриншот,\n\n674C1E0A-1.png"
                ),
                .files([shotA]),
                .text("\n\nчто скажешь"),
            ]
        )
    }

    // MARK: - The paperclip at release

    /// The paperclip off at release means no file paste either (#208): the web
    /// composer gets one step, the words, and is handed nothing — the same
    /// dictation `testACopiedParagraphAndAScreenshotAreThreeSteps` delivers in
    /// three steps with a picture attached.
    func testCollectingOffAtReleaseHandsTheComposerNoFile() {
        let copied = DictationItem(kind: .text, offset: 0.2, text: "the paragraph he copied")
        let shot = image(shotA, at: 0.6)
        let words = spokenWords([0.2, 0.4, 0.6, 0.9, 1.2], endingClauseAt: [0, 2])
        let spoken = "Смотри, вот скриншот, что скажешь"

        let left = RichInput.atRelease([copied, shot], collecting: false)
        let composed = RichInput.compose(spoken: spoken, items: left, words: words)
        XCTAssertEqual(composed, spoken)
        XCTAssertEqual(
            RichInput.delivery(text: composed, items: left, target: .web), [.text(spoken)]
        )
    }

    /// A row switched off travels as nothing at all, and an item whose tag is
    /// no longer in the text is left alone rather than guessed at — the same
    /// discipline `split` uses.
    func testWhatDoesNotTravel() {
        var excluded = image(shotA, at: 0.6)
        excluded.included = false
        let composed = "Посмотри.\n\n<screenshot>\(shotA)</screenshot>"
        XCTAssertEqual(
            RichInput.delivery(text: composed, items: [excluded], target: .web), [.text(composed)]
        )
        XCTAssertEqual(
            RichInput.delivery(
                text: "слова без тега", items: [image(shotA, at: 0.6)], target: .web
            ),
            [.text("слова без тега")]
        )
    }
}
