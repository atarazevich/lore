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
        // The bubble draws its own tooltips and places each one under whatever
        // the pointer is on (#207), which needs the pointer's position while it
        // travels, not only where it crossed in. A window is sent mouse-moved
        // events only when it asks — the default is off, and that same flag
        // being off is half of why AppKit's own tooltips never surfaced here.
        acceptsMouseMovedEvents = true
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

// MARK: - The canvas a self-growing shape hangs in

/// The window a recording bubble lives in (#204), measured by the shape itself.
///
/// The bubble only grows: the rail appends to its right, the list opens
/// downward. A window that follows that growth frame by frame moves the shape
/// under the pointer — the paperclip slid out from under a pointer reaching for
/// it — and an anchor re-derived from "at rest" reports (3900a37) depended on the
/// order of a geometry callback against a state flip and did not hold in use. So
/// the window stops following. While a dictation records it is a transparent
/// canvas already big enough for everything the shape may become, with the shape
/// laid out at its top-leading corner, and the pointer's arrival changes nothing
/// about it.
struct BubbleCanvas: Equatable {
    /// Everything the shape may occupy while this recording runs: the widened
    /// row's width, and the open shape's height with its list.
    let size: CGSize
    /// The resting row's width. The window is centred on *this*, not on itself,
    /// so what the user sees at rest is centred on screen and every growth
    /// happens into the margin at its right.
    let restingWidth: CGFloat
}

/// Where a top-centred panel's frame lands. Pure, because the anchoring is the
/// part that has to be right frame after frame and cannot be judged by reading
/// it (#201: re-centring on every width made the bubble slide left while it
/// sprang open, and back again on the way out — the dot, the lock and the
/// timer moved although nothing about them had changed).
enum TopCenteredFrame {
    /// - Parameters:
    ///   - size: the window's size — a recording bubble's whole canvas, or the
    ///     measured size of any other content.
    ///   - anchorWidth: the width to centre on. A canvas centres on the resting
    ///     row it started with, so that row is centred on screen and the
    ///     canvas's spare width lies to its right. Nil — or wider than the
    ///     window itself — centres the window.
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
}

// MARK: - Top-centered content-sized panel

/// The machinery shared by the floating top-centered panels (dictation
/// indicator, Read Aloud player): a configured non-activating `OverlayPanel`
/// wrapping an intrinsic-size `NSHostingView`, resize-to-content pinned
/// `topInset` points under the menu bar of the mouse's screen, and show/hide.
/// Managers keep their own polling loops and call `show`/`hide`/
/// `resizeToContent` — or, when the content is a shape that grows inside a
/// window of its own measuring, `setCanvas` (#204).
@MainActor
final class TopCenteredPanel<Content: View> {
    private let panel: OverlayPanel
    private let hostingView: NSHostingView<Content>
    private let topInset: CGFloat
    private var lastFrame: NSRect = .zero
    private var currentScreen: NSScreen?
    /// The canvas the content measured for itself (#204). While it is set it is
    /// the only source of the frame: a poll's own measurement of a shape
    /// mid-spring would fight it, and the window would move.
    private var canvas: BubbleCanvas?
    /// The resting width the window was centred on when this recording's first
    /// canvas arrived, kept for the whole of it. A resting row that grows later
    /// — a timer digit at the hour, the badge arriving — grows to the right like
    /// everything else: re-centring it would move the dot, the lock and the
    /// timer, which had not changed at all (#204).
    private var restingAnchor: CGFloat?

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
        // A canvas is mostly transparent margin (#204), and a window that is
        // movable by its background answers a mouse-down anywhere the content
        // did not — which is a click the app below never receives. The frame is
        // set by the owner's poll anyway, so the window was never draggable in
        // practice; this only stops it from swallowing the attempt.
        panel.isMovableByWindowBackground = false
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

    /// The canvas the content measured for itself, applied at once and with no
    /// animation of its own (#204) — or `nil` when the content is not that
    /// shape, and the window goes back to fitting and centring what it holds
    /// (processing, done, the upgrade panel, an error, the Read Aloud player).
    ///
    /// A canvas is set once per recording and re-applied unchanged by the poll.
    /// It changes only when the resting row's own width changes (a timer digit,
    /// the badge) or the list's height does — never as a side effect of the
    /// pointer arriving, because the shape it was measured from was the open one
    /// from the start. Every such change grows the window from its top-left
    /// corner, which is where the recording's first canvas put it.
    func setCanvas(_ canvas: BubbleCanvas?) {
        guard let canvas else {
            restingAnchor = nil
            guard self.canvas != nil else { return }
            self.canvas = nil
            resizeToContent()
            return
        }
        let size = NSSize(width: ceil(canvas.size.width), height: ceil(canvas.size.height))
        guard size.width > 10, size.height > 5, canvas.restingWidth > 0 else { return }
        self.canvas = BubbleCanvas(
            size: CGSize(width: size.width, height: size.height),
            restingWidth: ceil(canvas.restingWidth)
        )
        restingAnchor = restingAnchor ?? ceil(canvas.restingWidth)
        applyCanvas()
    }

    private func applyCanvas() {
        guard let canvas else { return }
        applyFrame(
            size: NSSize(width: canvas.size.width, height: canvas.size.height),
            animated: false, tolerance: 0.5
        )
    }

    func resizeToContent() {
        // Canvas-driven while one is set: re-apply it, so the poll still follows
        // the pointer across screens without measuring (and re-animating) a
        // shape mid-spring.
        if canvas != nil {
            applyCanvas()
            return
        }
        hostingView.layoutSubtreeIfNeeded()
        // Laying out is what makes a recording bubble measure and report its
        // canvas, and that report arrives inside the call above. Ask again
        // before falling back: otherwise the first poll tick of a dictation
        // would overwrite the canvas frame it had just been given with one
        // centred on the whole canvas, drawing the bubble half a margin off
        // centre until the next tick.
        if canvas != nil {
            applyCanvas()
            return
        }
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
            size: size, anchorWidth: restingAnchor,
            screenFrame: screen.frame, visibleMaxY: screen.visibleFrame.maxY, topInset: topInset
        )

        // Only move when the frame actually changes (the 50 ms poll re-applies
        // the same one 20x/sec). The origin counts, not just the size: crossing
        // to another screen re-centres a window that is the size it already was.
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
