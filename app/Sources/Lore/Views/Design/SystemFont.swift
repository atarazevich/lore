import AppKit
import CoreText

/// The system font, as AppKit measures with it — looked up so that an empty
/// answer is survivable (#255).
///
/// `NSFont.monospacedSystemFont(ofSize:weight:)` is imported into Swift as never
/// nil, and on a release build it returned nil: the bubble's timer measured
/// with it (`elapsedWidth`), `NSString.size(withAttributes:)` threw inside
/// CoreText, and the app aborted mid-dictation. `NSFont.systemFont(ofSize:)` is
/// the same kind of call. Swift cannot check a value it was promised, so the
/// font is reached here through calls each declared as able to come back
/// empty, and every reading has an answer for when one does — SF's own
/// proportions, which are what the live font answers (the fallback tests in
/// `RecordingBubbleRenderTests` and `DictationActivityTests` hold them to it).
enum SystemFont {
    static func font(size: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false) -> NSFont? {
        guard let system = CTFontCreateUIFontForLanguage(.system, size, nil) else { return nil }
        var descriptor = CTFontCopyFontDescriptor(system) as NSFontDescriptor
        if monospaced {
            guard let design = descriptor.withDesign(.monospaced) else { return nil }
            descriptor = design
        }
        return NSFont(
            descriptor: descriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]]),
            size: size
        )
    }

    /// `text`'s width in that font, or nil when there is no font to measure with.
    static func width(
        _ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
        monospaced: Bool = false, tracking: CGFloat = 0
    ) -> CGFloat? {
        guard let font = font(size: size, weight: weight, monospaced: monospaced) else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if tracking != 0 { attributes[.kern] = tracking }
        return (text as NSString).size(withAttributes: attributes).width
    }

    /// The width in SF Mono, measured when the font is there and its own advance
    /// when it is not.
    static func monospacedWidth(
        _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, tracking: CGFloat = 0
    ) -> CGFloat {
        width(text, size: size, weight: weight, monospaced: true, tracking: tracking)
            ?? advanceWidth(text, size: size, tracking: tracking)
    }

    /// SF Mono without the font: every character one advance of 1266/2048 of the
    /// em, every weight alike, and the tracking after each character.
    static func advanceWidth(_ text: String, size: CGFloat, tracking: CGFloat = 0) -> CGFloat {
        CGFloat(text.count) * (size * 1266 / 2048 + tracking)
    }

    /// Vertical metrics as AppKit states them, the descender negative.
    struct Metrics: Equatable {
        let ascender: CGFloat
        let descender: CGFloat
        let leading: CGFloat

        /// SF without the font: ascender 1980 and descender 432 of a 2048 em,
        /// no leading.
        static func proportional(size: CGFloat) -> Metrics {
            Metrics(ascender: size * 1980 / 2048, descender: -size * 432 / 2048, leading: 0)
        }
    }

    static func metrics(size: CGFloat) -> Metrics {
        guard let font = font(size: size) else { return .proportional(size: size) }
        return Metrics(ascender: font.ascender, descender: font.descender, leading: font.leading)
    }
}
