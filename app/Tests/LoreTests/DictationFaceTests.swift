import XCTest
@testable import LoreKit

/// The bubble's failure faces as values (#209) — what the board's logic table
/// says each one leads to, and what its copy table says it may carry.
final class DictationFaceTests: XCTestCase {

    /// Every face the code can reach, with the mic sentence the board draws.
    private let faces: [DictationFace] = [
        .micUnavailable("The AirPods Pro microphone is unavailable."),
        .nothingCameThrough,
        .modelDownloadFailed,
        .pasteFailed,
        .cleanupFailed,
        .translateFailed,
    ]

    /// One sentence, and at most one thing to do about it. A face with two
    /// actions would be a decision the board never asked anyone to make.
    func testEveryFaceIsOneSentenceAndAtMostOneAction() {
        for face in faces {
            XCTAssertFalse(face.sentence.isEmpty, "\(face) says nothing")
            XCTAssertFalse(
                face.sentence.contains("\n"), "\(face) is more than one line"
            )
            XCTAssertTrue(
                face.sentence.hasSuffix("."), "\(face) is not written as a sentence"
            )
        }
    }

    /// One action, one name (ui-language.md rule 1): the two faces that lead to
    /// the input device lead there by the same word, and no two of the three
    /// actions a face can offer name their destination alike.
    func testTheTwoMicFacesOfferTheSameActionByTheSameName() {
        XCTAssertEqual(DictationFace.micUnavailable("x").action, .openLoreSettings)
        XCTAssertEqual(DictationFace.nothingCameThrough.action, .openLoreSettings)
        let offered: [DictationFaceAction] = [
            .openLoreSettings, .tryAgain, .openSettings(.accessibility),
        ]
        XCTAssertEqual(Set(offered.map(\.label)).count, offered.count, "two actions share a label")
    }

    /// And the same name across surfaces, by construction rather than by
    /// agreement: the bubble's paste-failed face and the health panel's paste
    /// remedy open the same pane, so they borrow the one label it has.
    func testAFaceSaysWhatTheHealthPanelSaysForTheSameDoor() {
        XCTAssertEqual(
            DictationFace.pasteFailed.action?.label,
            HealthRemedyAction.openSettings(.accessibility).buttonLabel
        )
        XCTAssertEqual(
            DictationFace.nothingCameThrough.action?.label,
            HealthRemedyAction.openLoreSettings.buttonLabel
        )
    }

    /// The words are already where they were going, so there is nothing left to
    /// decide — the raw text landed and history is where it gets fixed.
    func testTheFacesThatAlreadyPastedOfferNothing() {
        XCTAssertNil(DictationFace.cleanupFailed.action)
        XCTAssertNil(DictationFace.translateFailed.action)
    }

    /// Only the paste-failed face carries a second line at all, and it carries
    /// it out of the row — the sentence says what happened, the detail says how
    /// to get the words back (ui-language.md rule 3).
    func testOnlyThePasteFaceCarriesADetail() {
        for face in faces where face != .pasteFailed {
            XCTAssertNil(face.detail, "\(face) has grown a second clause")
        }
        XCTAssertNotNil(DictationFace.pasteFailed.detail)
    }

    /// And its own sentence carries none of that detail: the clipboard
    /// reassurance moved to the tooltip when P1 put a button in the row.
    func testThePasteFaceSaysOnlyWhatHappened() {
        XCTAssertFalse(DictationFace.pasteFailed.sentence.contains("clipboard"))
        XCTAssertEqual(DictationFace.pasteFailed.action, .openSettings(.accessibility))
        XCTAssertTrue(DictationFace.pasteFailed.actionIsInline, "P1 puts this one in the row")
        for face in faces where face != .pasteFailed {
            XCTAssertFalse(face.actionIsInline, "\(face) folded its action into the row")
        }
    }

    /// The mic sentence names what happened and stops. The second clause —
    /// "Check your input device and try again" — is the button under it now,
    /// and saying it twice is what the board took out.
    func testTheMicSentenceHasNoSecondClause() {
        let named = MicrophonePermission.micUnavailableMessage(deviceName: "AirPods Pro")
        let anonymous = MicrophonePermission.micUnavailableMessage(deviceName: nil)
        print("[#209] the mic sentence: \"\(named)\" · \"\(anonymous)\"")
        XCTAssertEqual(named, "The AirPods Pro microphone is unavailable.")
        XCTAssertEqual(anonymous, "The microphone is unavailable.")
        for sentence in [named, anonymous] {
            XCTAssertEqual(
                sentence.filter { $0 == "." }.count, 1, "the sentence carries a second clause"
            )
        }
    }
}
