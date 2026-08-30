import XCTest
@testable import LoreKit

/// The order the bubble's letters stand in (#204).
///
/// The rule is one invariant: whatever is armed already stands in the resting
/// bubble, so opening may only append to its right. `S T K` broke it — an armed
/// `T` shown at rest shifted right the moment opening inserted `S` ahead of it —
/// and so would a fixed `C T K S`, for a lone armed `K`.
final class RecordingBubbleRailTests: XCTestCase {

    private func open(_ armed: BubbleRailLetter...) -> [String] {
        BubbleRail.letters(armed: Set(armed), open: true).map(\.rawValue)
    }

    private func rest(_ armed: BubbleRailLetter...) -> [String] {
        BubbleRail.letters(armed: Set(armed), open: false).map(\.rawValue)
    }

    /// Every case named when the rule was settled.
    func testTheOrderOpeningTakes() {
        XCTAssertEqual(open(), ["T", "K", "S"])
        XCTAssertEqual(open(.operatorSend), ["K", "T", "S"])
        XCTAssertEqual(open(.translate), ["T", "K", "S"])
        XCTAssertEqual(open(.translate, .operatorSend), ["T", "K", "S"])
        XCTAssertEqual(open(.cleanup), ["C", "T", "K", "S"])
        XCTAssertEqual(open(.cleanup, .translate), ["C", "T", "K", "S"])
        XCTAssertEqual(open(.cleanup, .operatorSend), ["C", "K", "T", "S"])
        XCTAssertEqual(open(.cleanup, .translate, .operatorSend), ["C", "T", "K", "S"])
    }

    /// At rest the bubble carries exactly what is armed, read in `C T K`, and
    /// nothing else — `S` names a setting rather than something armed for this
    /// dictation, and an unarmed `C` has nothing to say.
    func testAtRestTheBubbleCarriesWhatIsArmedAndNothingElse() {
        XCTAssertEqual(rest(), [])
        XCTAssertEqual(rest(.operatorSend), ["K"])
        XCTAssertEqual(rest(.translate, .operatorSend), ["T", "K"])
        XCTAssertEqual(rest(.cleanup, .operatorSend), ["C", "K"])
        XCTAssertEqual(rest(.cleanup, .translate, .operatorSend), ["C", "T", "K"])
        XCTAssertEqual(rest(.screenshot), [], "S is never armed")
    }

    /// The invariant itself, over every armed set there is: opening appends and
    /// never inserts, so a letter's position in the rail never changes.
    func testOpeningOnlyEverAppendsToTheRight() {
        let armable: [BubbleRailLetter] = [.cleanup, .translate, .operatorSend]
        for mask in 0..<(1 << armable.count) {
            let armed = Set(armable.indices.filter { mask & (1 << $0) != 0 }.map { armable[$0] })
            let standing = BubbleRail.letters(armed: armed, open: false)
            let opened = BubbleRail.letters(armed: armed, open: true)
            let named = armed.map(\.rawValue).sorted().joined()
            XCTAssertEqual(
                Array(opened.prefix(standing.count)), standing,
                "opening moved a letter that was already on screen, armed [\(named)]"
            )
            XCTAssertEqual(Set(opened).count, opened.count, "a letter is drawn twice, armed [\(named)]")
            XCTAssertEqual(
                Set(opened), armed.union([.translate, .operatorSend, .screenshot]),
                "the open rail is whatever is armed, plus T K S"
            )
        }
    }
}
