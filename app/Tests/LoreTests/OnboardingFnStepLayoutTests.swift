import AppKit
import SwiftUI
import XCTest
@testable import LoreKit

/// The Fn step gained a second card (#226), and the onboarding window is a fixed
/// 660 × 540 that nothing scrolls. So the question this answers is the only one
/// the new card can get wrong: does all of it still land on screen — the card
/// with the choice on it, and the footer under both.
///
/// Rendered rather than reasoned about, the way the bubble's frames are: a
/// height budget worked out on paper is the thing that was wrong the last time
/// a card was added to a fixed window.
@MainActor
final class OnboardingFnStepLayoutTests: XCTestCase {

    private static let allGranted = PermissionSnapshot(
        microphone: true, accessibility: true, inputMonitoring: true,
        microphoneUndetermined: false
    )

    /// A model parked on the Fn step, with Fn as the talk key and macOS holding
    /// it — the reading that puts the step on screen.
    private func modelAtFnStep() -> OnboardingModel {
        let model = OnboardingModel(dwell: .milliseconds(30))
        model.advanceFromButton()
        model.apply(permissions: Self.allGranted, fn: .showEmojiPicker)
        model.advanceFromButton()
        XCTAssertEqual(model.step, .fnKey)
        return model
    }

    /// Ink in every band from the heading to the footer: the two cards and the
    /// row under them are all inside the window, not pushed past its bottom.
    func testBothCardsAndTheFooterFitTheFixedWindow() throws {
        let raster = try SwiftUIRaster.render(
            OnboardingFlowView(model: modelAtFnStep()), scale: 1, opaque: true
        )
        XCTAssertEqual(raster.width, Int(OnboardingWindowController.size.width))
        XCTAssertEqual(raster.height, Int(OnboardingWindowController.size.height))

        // Five bands down the window. The step is heading, card, card, footer,
        // so every one of them has to carry ink; an empty band at the bottom is
        // the second card having pushed the footer off, and an empty band in
        // the middle is a card that never drew.
        let bandHeight = raster.height / 5
        for band in 0..<5 {
            let rows = (band * bandHeight)..<((band + 1) * bandHeight)
            XCTAssertGreaterThan(
                raster.ink(in: rows), 0,
                "nothing is drawn in rows \(rows.lowerBound)–\(rows.upperBound)"
            )
        }

        // And the footer's own rows specifically — its 34pt band above the
        // window's 28pt padding. It is the first thing a card too tall evicts.
        let footer = (raster.height - 62)..<(raster.height - 28)
        XCTAssertGreaterThan(raster.ink(in: footer), 0, "the footer was pushed off the window")

        // The room the recorder needs when it opens: the button becomes a
        // two-line prompt in place, which is the only way this step grows after
        // the first frame. Measured rather than assumed — the slack is what
        // says the prompt has somewhere to go.
        let cardBottom = try XCTUnwrap(raster.lastInkRow(before: footer.lowerBound))
        XCTAssertGreaterThan(
            footer.lowerBound - cardBottom, 40,
            "the recorder's prompt has nowhere to open into"
        )
    }
}
