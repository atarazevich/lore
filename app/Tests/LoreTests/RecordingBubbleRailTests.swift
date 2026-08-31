import XCTest
@testable import LoreKit

/// The order the bubble's letters stand in (#204).
///
/// The rule is one invariant: whatever is armed already stands in the resting
/// bubble, so opening may only append to its right. A fixed order broke it — an
/// armed `T` shown at rest shifted right the moment opening inserted another
/// letter ahead of it, and so would `V T K` for a lone armed `K`.
///
/// The letters themselves are `V T K` since #224: the key that arms cleanup is
/// V, and `S` left the rail to the paperclip that was already its control.
final class RecordingBubbleRailTests: XCTestCase {

    private func open(_ armed: BubbleRailLetter...) -> [String] {
        BubbleRail.letters(armed: Set(armed), open: true, operatorSend: true).map(\.rawValue)
    }

    private func rest(_ armed: BubbleRailLetter...) -> [String] {
        BubbleRail.letters(armed: Set(armed), open: false, operatorSend: true).map(\.rawValue)
    }

    /// The same two readings with the operator switch off (#223).
    private func openWithoutOperator(_ armed: BubbleRailLetter...) -> [String] {
        BubbleRail.letters(armed: Set(armed), open: true, operatorSend: false).map(\.rawValue)
    }

    private func restWithoutOperator(_ armed: BubbleRailLetter...) -> [String] {
        BubbleRail.letters(armed: Set(armed), open: false, operatorSend: false).map(\.rawValue)
    }

    /// Every case named when the rule was settled.
    func testTheOrderOpeningTakes() {
        XCTAssertEqual(open(), ["T", "K"])
        XCTAssertEqual(open(.operatorSend), ["K", "T"])
        XCTAssertEqual(open(.translate), ["T", "K"])
        XCTAssertEqual(open(.translate, .operatorSend), ["T", "K"])
        XCTAssertEqual(open(.cleanup), ["V", "T", "K"])
        XCTAssertEqual(open(.cleanup, .translate), ["V", "T", "K"])
        XCTAssertEqual(open(.cleanup, .operatorSend), ["V", "K", "T"])
        XCTAssertEqual(open(.cleanup, .translate, .operatorSend), ["V", "T", "K"])
    }

    /// At rest the bubble carries exactly what is armed, read in `V T K`, and
    /// nothing else — an unarmed `V` has nothing to say.
    func testAtRestTheBubbleCarriesWhatIsArmedAndNothingElse() {
        XCTAssertEqual(rest(), [])
        XCTAssertEqual(rest(.operatorSend), ["K"])
        XCTAssertEqual(rest(.translate, .operatorSend), ["T", "K"])
        XCTAssertEqual(rest(.cleanup, .operatorSend), ["V", "K"])
        XCTAssertEqual(rest(.cleanup, .translate, .operatorSend), ["V", "T", "K"])
    }

    /// The rail has three letters and no fourth: the cleanup letter is the key
    /// that arms it, and `S` is not a letter at all (#224).
    func testTheRailHasThreeLettersAndTheyAreTheKeysPressed() {
        XCTAssertEqual(BubbleRailLetter.allCases.map(\.rawValue), ["V", "T", "K"])
    }

    /// With the operator switch off (#223) the `K` is not a letter the rail
    /// has: not as a hint in the open rail, and not standing at rest even when
    /// the dictation carries the flag — which is what an entry armed before the
    /// switch was turned off looks like.
    func testTheOperatorLetterIsGoneWhileTheSwitchIsOff() {
        XCTAssertEqual(openWithoutOperator(), ["T"])
        XCTAssertEqual(openWithoutOperator(.cleanup), ["V", "T"])
        XCTAssertEqual(openWithoutOperator(.translate), ["T"])
        XCTAssertEqual(openWithoutOperator(.operatorSend), ["T"], "no K, armed or not")
        XCTAssertEqual(openWithoutOperator(.cleanup, .translate, .operatorSend), ["V", "T"])
        XCTAssertEqual(restWithoutOperator(), [])
        XCTAssertEqual(restWithoutOperator(.operatorSend), [], "no K standing at rest either")
        XCTAssertEqual(restWithoutOperator(.cleanup, .operatorSend), ["V"])
    }

    /// And the switch touches nothing else: every other letter reads the same
    /// in both positions.
    func testTheSwitchTakesAwayNothingButTheOperatorLetter() {
        for armed in [[], [.cleanup], [.translate], [.cleanup, .translate]] as [[BubbleRailLetter]] {
            for open in [true, false] {
                let on = BubbleRail.letters(armed: Set(armed), open: open, operatorSend: true)
                let off = BubbleRail.letters(armed: Set(armed), open: open, operatorSend: false)
                XCTAssertEqual(on.filter { $0 != .operatorSend }, off,
                               "armed \(armed.map(\.rawValue).joined()), open \(open)")
            }
        }
    }

    /// The invariant itself, over every armed set there is: opening appends and
    /// never inserts, so a letter's position in the rail never changes. Both
    /// switch positions, since the shorter rail has to hold it too.
    func testOpeningOnlyEverAppendsToTheRight() {
        let armable: [BubbleRailLetter] = [.cleanup, .translate, .operatorSend]
        for (mask, operatorSend) in (0..<(1 << armable.count)).flatMap({ mask in
            [(mask, true), (mask, false)]
        }) {
            let armed = Set(armable.indices.filter { mask & (1 << $0) != 0 }.map { armable[$0] })
            let standing = BubbleRail.letters(armed: armed, open: false, operatorSend: operatorSend)
            let opened = BubbleRail.letters(armed: armed, open: true, operatorSend: operatorSend)
            let named = armed.map(\.rawValue).sorted().joined()
            XCTAssertEqual(
                Array(opened.prefix(standing.count)), standing,
                "opening moved a letter that was already on screen, armed [\(named)]"
            )
            XCTAssertEqual(Set(opened).count, opened.count, "a letter is drawn twice, armed [\(named)]")
            var offered = armed.union([.translate])
            if operatorSend { offered.insert(.operatorSend) } else { offered.remove(.operatorSend) }
            XCTAssertEqual(
                Set(opened), offered,
                "the open rail is whatever is armed, plus T and K while the switch is on, "
                + "armed [\(named)]"
            )
        }
    }
}
