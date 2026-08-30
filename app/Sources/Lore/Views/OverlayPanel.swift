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

    /// Where a window the user has dragged sits (#213).
    ///
    /// - Parameters:
    ///   - topLeft: the corner they put it at. The *top* left, because that is
    ///     the corner the shape grows from: a list opening or a second digit in
    ///     the timer must push the window's bottom edge down, exactly as the
    ///     top-centred frame keeps `maxY` fixed, and an origin kept as AppKit's
    ///     bottom-left would have pushed the whole bubble up the screen instead.
    ///   - visibleFrame: what the shape has to stay inside. A window dragged
    ///     past an edge is pushed back rather than followed off the screen; the
    ///     corner itself is kept unclamped by the caller, so coming back is the
    ///     same movement as going.
    static func draggedFrame(topLeft: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSRect {
        // A window with no room to be pushed into — bigger than the screen it is
        // on — keeps its *top-left* corner on it rather than hanging off both
        // ends at once. That corner is where the shape is drawn; the rest of a
        // canvas is transparent margin, so it is the only one whose staying on
        // screen means anything.
        let x = min(
            max(topLeft.x, visibleFrame.minX),
            max(visibleFrame.minX, visibleFrame.maxX - size.width)
        )
        let top = max(
            min(topLeft.y, visibleFrame.maxY),
            min(visibleFrame.maxY, visibleFrame.minY + size.height)
        )
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
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
    /// The frame the panel decided, last time it decided one. Not private:
    /// `RecordingBubbleFrameTests` reads it to check that a dragged bubble stays
    /// where it was put, and reading the decision is steadier than reading the
    /// window back.
    private(set) var lastFrame: NSRect = .zero
    private var currentScreen: NSScreen?
    /// The canvas the content measured for itself (#204). While it is set it is
    /// the only source of the frame: a poll's own measurement of a shape
    /// mid-spring would fight it, and the window would move.
    private var canvas: BubbleCanvas?
    /// The resting width the window was centred on when this recording's first
    /// canvas arrived, kept for the whole of it. A resting row that grows later
    /// — a timer digit at the hour, the count arriving — grows to the right like
    /// everything else: re-centring it would move the dot, the lock and the
    /// timer, which had not changed at all (#204).
    private var restingAnchor: CGFloat?
    /// Where the user has put the bubble (#213), as the top-left corner every
    /// later frame is measured from. Once it is set nothing re-centres the
    /// window again: not the 50 ms poll, not a canvas report, not the end of the
    /// recording — and the next recording opens where the last one was left.
    /// It lives on the panel and nowhere else, so quitting forgets it: where a
    /// bubble was dragged is a decision about this session, not a setting.
    private var draggedTopLeft: NSPoint?
    /// Where inside the window the pointer took hold, kept for as long as the
    /// button is down. Non-nil is what "a drag is under way" means: the frame is
    /// applied with no animation while it is, and the offset is what keeps the
    /// shape from jumping under the pointer on the first move.
    private var dragGrab: CGSize?

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
        // did not — which is a click the app below never receives. Dragging came
        // back by the shape instead (#213, `drag(to:)`), which is the half of
        // this the user wanted; the margin stays what it is, a hole.
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
        // A drag whose window went away is over; where it put the window is not.
        dragGrab = nil
    }

    /// The pointer has moved with the button down inside the shape (#213), in
    /// screen coordinates.
    ///
    /// The pointer is read from AppKit rather than taken off the gesture on
    /// purpose. SwiftUI reports a drag's translation in the window's own space,
    /// and a window that follows that translation moves out from under it: the
    /// pointer's position inside the window stops changing the moment the window
    /// starts keeping up with it, so the translation collapses to nothing and
    /// the shape springs back. The screen's own number does not care what the
    /// window does.
    ///
    /// The first move is what takes hold: the offset is measured from where the
    /// window is at that moment, so the shape does not jump the threshold's
    /// worth of distance the instant the drag is recognised. From the frame the
    /// panel decided, not the one AppKit rounded onto the backing grid — the
    /// rounding is applied once, at the window, and is never read back into the
    /// arithmetic, so it cannot accumulate across a drag.
    func drag(to pointer: NSPoint) {
        let held = lastFrame.width > 0 ? lastFrame : panel.frame
        let grab = dragGrab ?? CGSize(
            width: pointer.x - held.minX, height: pointer.y - held.maxY
        )
        dragGrab = grab
        draggedTopLeft = NSPoint(x: pointer.x - grab.width, y: pointer.y - grab.height)
        resizeToContent()
    }

    func endDrag() { dragGrab = nil }

    /// The canvas the content measured for itself, applied at once and with no
    /// animation of its own (#204) — or `nil` when the content is not that
    /// shape, and the window goes back to fitting what it holds (processing,
    /// done, the upgrade panel, an error, the Read Aloud player) and centring it
    /// unless the user has dragged it somewhere (#213).
    ///
    /// A canvas is set once per recording and re-applied unchanged by the poll.
    /// It changes only when the resting row's own width changes (a timer digit,
    /// the count) or the list's height does — never as a side effect of the
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
        // Once the bubble has been dragged, centring is over for the rest of
        // the session (#213) — so the width it would have centred on is not
        // latched either.
        if draggedTopLeft == nil {
            restingAnchor = restingAnchor ?? ceil(canvas.restingWidth)
        }
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

        // A bubble the user has placed is never re-centred (#213) — it only
        // grows from the corner they left it at, the same way the top-centred
        // one grows from the corner the recording started at.
        let newFrame = draggedTopLeft.map {
            TopCenteredFrame.draggedFrame(
                topLeft: $0, size: size, visibleFrame: screen.visibleFrame
            )
        } ?? TopCenteredFrame.frame(
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

        // A drag is never animated: 0.15 s of easing behind a pointer is the
        // shape lagging, not the shape moving.
        if screenChanged || !animated || dragGrab != nil {
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
