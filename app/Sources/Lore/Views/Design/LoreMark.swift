import AppKit

/// The lore mark on the surfaces Lore draws itself — the sidebar chip and the
/// menu bar. Why the mark, the icon document and these two flat artworks look
/// the way they do: docs/decisions.md, 2026-08-06.
///
/// The geometry lives in the generated `LoreMarkGeometry`; the artwork is
/// generated alongside it by `tools/make_mark.py` and copied into
/// `Contents/Resources` by `build.sh`, so it loads through `Bundle.main` — a
/// SwiftPM resource bundle does not survive the hand-assembled `.app` (the trap
/// `MeetingDetector.swift:365` documents for its meeting-app table).
enum LoreMark {

    /// Sidebar chip, at the size the brand row reserves for it. The artwork
    /// carries the chip rim (board T5: .24 alpha, heavier than the Dock's,
    /// because here the tile sits on a surface of nearly its own value).
    static let chipSize: CGFloat = 28

    static let chip = load("BrandMark", size: NSSize(width: chipSize, height: chipSize),
                           template: false)

    /// Template-rendered, so the menu bar colours the glyph black in a light bar
    /// and white in a dark one.
    static let statusItem = load("MenuBarMark", size: LoreMarkGeometry.statusBox,
                                 template: true)

    /// Where the recording bead sits inside a status-item button of `bounds`.
    ///
    /// Pure and `flipped`-parametric so both conventions are testable without a
    /// menu bar: `NSStatusBarButton` is flipped today, but that is a probed fact,
    /// not an API guarantee.
    static func beadFrame(in bounds: CGRect, flipped: Bool) -> CGRect {
        // The status bar owns the button's size and draws the image centred in
        // it, so the drawing box is centred too.
        let box = LoreMarkGeometry.statusBox
        let inset = CGPoint(x: (bounds.width - box.width) / 2,
                            y: (bounds.height - box.height) / 2)
        // `beadCenter` is measured from the box's top-left.
        let fromTop = inset.y + LoreMarkGeometry.beadCenter.y
        let center = CGPoint(x: inset.x + LoreMarkGeometry.beadCenter.x,
                             y: flipped ? fromTop : bounds.height - fromTop)
        // Padded so the dot's glow is not clipped by the hosting view's bounds.
        let pad = LoreMarkGeometry.beadSize * 2
        return CGRect(x: center.x - pad, y: center.y - pad, width: pad * 2, height: pad * 2)
    }

    private static func load(_ name: String, size: NSSize, template: Bool) -> NSImage {
        // build.sh refuses to assemble a bundle without these, so a miss here is
        // a broken bundle, not a condition to paper over with a blank image.
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else {
            fatalError("\(name).pdf is missing from the app bundle — build.sh must copy it")
        }
        image.size = size
        image.isTemplate = template
        return image
    }
}
