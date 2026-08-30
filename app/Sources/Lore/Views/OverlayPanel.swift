import AppKit
import SwiftUI

/// A floating NSPanel that is invisible to screen sharing.
/// Used by the dictation indicator and the Read Aloud player (#105), via
/// `TopCenteredPanel`.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect, defaults: UserDefaults = .standard) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        sharingType = SettingsStore.screenSharingType(from: defaults)
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Remember position
        setFrameAutosaveName("OverlayPanel")
    }
}

// MARK: - What a self-animating shape tells its panel

/// One layout pass of a content view that animates its own size (#201).
struct PanelContentFrame {
    /// The size SwiftUI just laid the content out at.
    let size: CGSize
    /// This is the content at rest — not opened, and not still animating back
    /// to its resting size. A resting frame is the one the window re-centres
    /// on; every wider one keeps the resting shape's left edge.
    let atRest: Bool
}

/// Where a top-centred panel's frame lands. Pure, because the anchoring is the
/// part that has to be right frame after frame and cannot be judged by reading
/// it (#201: re-centring on every width made the bubble slide left while it
/// sprang open, and back again on the way out — the dot, the lock and the
/// timer moved although nothing about them had changed).
enum TopCenteredFrame {
    /// - Parameters:
    ///   - size: what the content is now.
    ///   - anchorWidth: the resting shape's width. The window's left edge is
    ///     the resting shape's left edge, so a shape wider than that grows to
    ///     the right and moves nothing else. Nil — or wider than the content
    ///     itself — centres the content.
    ///   - visibleMaxY: the top of the screen's visible frame; the panel hangs
    ///     `topInset` under it and grows downward.
    static func frame(
        size: NSSize, anchorWidth: CGFloat?,
        screenFrame: NSRect, visibleMaxY: CGFloat, topInset: CGFloat
    ) -> NSRect {
        let anchor = min(anchorWidth ?? size.width, size.width)
        return NSRect(
            x: screenFrame.origin.x + (screenFrame.width - anchor) / 2,
            y: visibleMaxY - size.height - topInset,
            width: size.width, height: size.height
        )
    }

    /// The resting width the panel carries into the next frame: a report the
    /// content calls resting *is* the measurement, and every other report
    /// leaves the anchor exactly where the resting one put it.
    static func restWidth(after report: PanelContentFrame, previous: CGFloat?) -> CGFloat? {
        report.atRest ? report.size.width : previous
    }
}

// MARK: - Top-centered content-sized panel

/// The machinery shared by the floating top-centered panels (dictation
/// indicator, Read Aloud player): a configured non-activating `OverlayPanel`
/// wrapping an intrinsic-size `NSHostingView`, resize-to-content pinned
/// `topInset` points under the menu bar of the mouse's screen, and show/hide.
/// Managers keep their own polling loops and call `show`/`hide`/
/// `resizeToContent` — or, when the content animates its own shape,
/// `setContentFrame` (#201).
@MainActor
final class TopCenteredPanel<Content: View> {
    private let panel: OverlayPanel
    private let hostingView: NSHostingView<Content>
    private let topInset: CGFloat
    private var lastFrame: NSRect = .zero
    private var currentScreen: NSScreen?
    /// What the content last reported for itself (#201). Once it has spoken,
    /// it is the only source of the frame: a poll's own measurement would
    /// fight it mid-animation.
    private var reported: PanelContentFrame?
    /// The resting shape's width — the anchor its left edge is kept at while
    /// the content is wider than that.
    private var restWidth: CGFloat?

    /// Nil when no screen can be resolved for the mouse (headless edge case).
    init?(content: Content, topInset: CGFloat) {
        guard let screen = Self.screenForMouse() else { return nil }
        self.topInset = topInset
        currentScreen = screen

        // Initial off-screen 1×1 rect — the panel resizes to content.
        let rect = NSRect(
            x: screen.frame.origin.x + screen.frame.width / 2,
            y: screen.visibleFrame.maxY - 50, width: 1, height: 1
        )
        panel = OverlayPanel(contentRect: rect)
        panel.styleMask = [.nonactivatingPanel, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.setFrameAutosaveName("")

        hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = .intrinsicContentSize
        hostingView.appearance = NSAppearance(named: .darkAqua)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hostingView
    }

    /// Order front (if hidden) and fit the frame to the content.
    func show() {
        if !panel.isVisible {
            panel.orderFront(nil)
        }
        resizeToContent()
    }

    func hide() {
        panel.orderOut(nil)
        lastFrame = .zero
    }

    /// The frame the content asked for, applied at once and with no animation
    /// of its own (#201).
    ///
    /// The bubble springs its own shape open in SwiftUI. A window animating on
    /// a second curve underneath cannot keep up with that: while the frame
    /// eased toward the widened size, the window clipped the very shape it was
    /// meant to be revealing, and the 50 ms poll restarted the easing on every
    /// tick. So the window stops animating entirely and becomes an exact
    /// follower — one frame change per layout pass, always the size SwiftUI
    /// just laid out, so the content is never wider than the window that holds
    /// it and only one animation is ever running.
    ///
    /// Following the size is not enough on its own: a window centred on every
    /// width slides half the growth to the left while the shape springs open to
    /// the right. So the report also says whether the content is at rest, and
    /// only a resting one moves the anchor.
    func setContentFrame(_ frame: PanelContentFrame) {
        let size = NSSize(width: ceil(frame.size.width), height: ceil(frame.size.height))
        guard size.width > 10, size.height > 5 else { return }
        let report = PanelContentFrame(size: size, atRest: frame.atRest)
        reported = report
        restWidth = TopCenteredFrame.restWidth(after: report, previous: restWidth)
        applyFrame(size: size, animated: false, tolerance: 0.5)
    }

    func resizeToContent() {
        // Content-driven since the first report: re-apply what it asked for, so
        // the poll still follows the pointer across screens without measuring
        // (and re-animating) a shape mid-spring.
        if let reported {
            applyFrame(size: reported.size, animated: false, tolerance: 0.5)
            return
        }
        hostingView.layoutSubtreeIfNeeded()
        // `fittingSize` is the *smallest* size the content can be pressed into,
        // not the size it wants: a panel sized from it squeezes its own
        // contents, which is how a 19-minute dictation's timer ended up broken
        // across two lines once another group joined the row (#192). The
        // hosting view's intrinsic size is the content's own ideal — the
        // content-driven number `.intrinsicContentSize` sizing exists to give.
        // The larger of the two, so no panel is ever smaller than it was.
        let ideal = hostingView.intrinsicContentSize
        let minimum = hostingView.fittingSize
        let size = NSSize(
            width: max(ideal.width, minimum.width),
            height: max(ideal.height, minimum.height)
        )
        guard size.width > 10 && size.height > 5 else { return }
        applyFrame(size: size, animated: true, tolerance: 1)
    }

    private func applyFrame(size: NSSize, animated: Bool, tolerance: CGFloat) {
        guard let screen = Self.screenForMouse() else { return }

        // Detect cross-screen move by identity, not dimensions
        let screenChanged = screen !== currentScreen
        if screenChanged {
            currentScreen = screen
        }

        let newFrame = TopCenteredFrame.frame(
            size: size, anchorWidth: restWidth,
            screenFrame: screen.frame, visibleMaxY: screen.visibleFrame.maxY, topInset: topInset
        )

        // Only move when the frame actually changes (the 50 ms poll re-applies
        // the same one 20x/sec). The origin counts, not just the size: a
        // resting report can leave the shape the width it already was and
        // still be the one that re-centres it.
        let moved = abs(newFrame.origin.x - lastFrame.origin.x) > tolerance
            || abs(newFrame.origin.y - lastFrame.origin.y) > tolerance
            || abs(newFrame.width - lastFrame.width) > tolerance
            || abs(newFrame.height - lastFrame.height) > tolerance
        guard moved || screenChanged else { return }
        lastFrame = newFrame

        if screenChanged || !animated {
            // Snap instantly across screens — no sliding through the gap
            panel.setFrame(newFrame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        }
    }

    private static func screenForMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
