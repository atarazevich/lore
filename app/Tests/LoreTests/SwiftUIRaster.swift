import AppKit
import SwiftUI
@testable import LoreKit

/// A SwiftUI view rendered to pixels, and the questions the render tests ask of
/// it.
///
/// `RecordingBubbleRenderTests` and `OnboardingFnStepLayoutTests` had grown
/// near-identical copies of the renderer and the buffer behind it — the same
/// `ImageRenderer`, the same `CGContext.draw` into an RGBA array — differing
/// only in which accessors each needed. This is the union; each suite keeps its
/// own assertions, which are the part that is actually about its own surface.
struct SwiftUIRaster {
    let width: Int
    let height: Int
    let scale: CGFloat
    let pixels: [UInt8]

    enum Failure: Error { case didNotRender, noContext }

    /// `opaque` is the difference between the two callers and it is meaningful:
    /// the bubble renders transparent so the material draws nothing and the
    /// comparison is about *where* things are, while the onboarding window
    /// renders opaque so its flat backdrop is one colour to measure ink against.
    @MainActor
    static func render(_ view: some View, scale: CGFloat, opaque: Bool) throws -> SwiftUIRaster {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = opaque
        guard let image = renderer.cgImage else { throw Failure.didNotRender }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.noContext }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return SwiftUIRaster(width: width, height: height, scale: scale, pixels: pixels)
    }

    func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    // MARK: - Where the drawing ends (alpha)

    /// The whole render, canvas included — the bubble sits in its top-leading
    /// corner and the rest is transparent margin.
    var pointWidth: CGFloat { CGFloat(width) / scale }

    /// The same downward — the canvas's whole height, tooltip room and all.
    var pointHeight: CGFloat { CGFloat(height) / scale }

    /// Where the drawing itself ends: the last column that has anything in it.
    /// The canvas past that is empty, so this is measured rather than assumed.
    var paintedWidth: CGFloat { CGFloat(lastPainted(along: .horizontal) + 1) / scale }

    /// The same downward: the resting row's own depth, under which an open
    /// shape draws its list and a resting one draws nothing.
    var paintedHeight: CGFloat { CGFloat(lastPainted(along: .vertical) + 1) / scale }

    private enum Axis { case horizontal, vertical }

    private func lastPainted(along axis: Axis) -> Int {
        let outer = axis == .horizontal ? width : height
        let inner = axis == .horizontal ? height : width
        for a in stride(from: outer - 1, through: 0, by: -1) {
            for b in 0..<inner {
                let x = axis == .horizontal ? a : b
                let y = axis == .horizontal ? b : a
                if pixels[(y * width + x) * 4 + 3] > 0 { return a }
            }
        }
        return -1
    }

    // MARK: - Ink against a flat backdrop

    /// The window's backdrop, sampled from a corner the layout never reaches.
    var background: (UInt8, UInt8, UInt8) {
        let i = (2 * width + 2) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    /// Pixels in these rows that are not the backdrop.
    func ink(in rows: Range<Int>) -> Int {
        let (br, bg, bb) = background
        var count = 0
        for y in rows.clamped(to: 0..<height) {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let delta = max(
                    abs(Int(pixels[i]) - Int(br)),
                    max(abs(Int(pixels[i + 1]) - Int(bg)),
                        abs(Int(pixels[i + 2]) - Int(bb)))
                )
                if delta > 12 { count += 1 }
            }
        }
        return count
    }

    /// The lowest row carrying ink above `row` — the bottom edge of whatever
    /// was drawn last.
    func lastInkRow(before row: Int) -> Int? {
        (0..<min(row, height)).last { ink(in: $0..<($0 + 1)) > 0 }
    }
}
