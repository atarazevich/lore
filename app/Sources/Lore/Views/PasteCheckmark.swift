import AppKit
import SwiftUI

/// How the checkmark leaves the bubble once the words are away (#211), and the
/// clock the whole paste moment runs on.
///
/// The insertion point is unknown to lore; the cursor is. So the mark falls
/// toward `NSEvent.mouseLocation`, and where that is decides which of these
/// three this fall is.
enum PasteFall: Equatable, Sendable {
    /// The cursor is somewhere else entirely, so a window of its own carries the
    /// mark there — and the bubble's slot is empty from the first frame of the
    /// fall, because two marks would read as two marks.
    case toCursor
    /// The cursor is inside the bubble's own window: the mark falls there, by
    /// this much in the shape's own space, and no second window is opened.
    case inside(CGSize)
    /// Reduce Motion: no travel and no shrink. The mark fades where it stands,
    /// with the shape.
    case still

    /// Which of the three, given where the mark stands and where the cursor is —
    /// both in screen coordinates — and the window the mark is standing in.
    ///
    /// Pure, because this is the whole of the decision the fall makes and a live
    /// window is a bad place to read a decision from.
    static func resolve(
        mark: NSPoint, cursor: NSPoint, window: NSRect, reduceMotion: Bool
    ) -> PasteFall {
        guard !reduceMotion else { return .still }
        guard window.contains(cursor) else { return .toCursor }
        // Screen coordinates count upward; the shape's own space counts down.
        return .inside(CGSize(width: cursor.x - mark.x, height: mark.y - cursor.y))
    }

    // MARK: - The paste moment's one clock

    /// How long the mark stands in the spinner's slot before it detaches. The
    /// board's "≤150 ms after the text is ready" is the latency of its
    /// appearing, not a wait; this is the beat between its frames 2 and 3.
    static let standing: Duration = .milliseconds(150)

    /// The fall itself: the mark's travel and the shape's fade, together, so the
    /// bubble is gone by the time the mark lands rather than after it.
    static let duration: TimeInterval = 0.25

    /// How much of itself the mark keeps by the time it lands.
    static let shrink: CGFloat = 0.4

    /// How late the shape may be in learning that the words went. The indicator
    /// reads the coordinator on a poll, so a whole tick of it can pass before
    /// the mark even starts standing (`DictationIndicatorManager.pollInterval`,
    /// bound to this by `PasteCheckmarkTests`).
    static let notice: Duration = .milliseconds(50)

    /// How long the shape is held after the words go, which is the latest the
    /// mark's fade can possibly end.
    ///
    /// This is what keeps the bubble from blinking out mid-fall: the coordinator
    /// counts from the paste and the fall counts from the tick that noticed it,
    /// so the hold has to cover the gap between the two. It is one number in one
    /// place for the same reason — two clocks that disagree end either with a
    /// shape standing there empty or with one taken away mid-fade.
    static var hold: Duration {
        notice + standing + .milliseconds(Int(duration * 1000))
    }
}

/// The green mark the paste leaves behind (#211) — drawn the same in the
/// bubble's icon slot and in the window that carries it away, because it has to
/// read as the one object leaving the first for the second.
struct PasteCheckmarkGlyph: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            // The size the failure faces' glyph is drawn at: the two icons that
            // can stand in this slot are one size, from one constant.
            .font(.system(size: DictationIndicatorView.faceGlyphSize))
            .foregroundStyle(LoreTheme.Accent.green)
    }
}

/// The window the checkmark falls in (#211).
///
/// The mark has to leave the bubble to reach the cursor and a window cannot draw
/// outside itself, so for the quarter second of the fall there is a second one.
/// It is the app's own `OverlayPanel` — floating, clear, out of a screen share
/// on the setting every overlay reads — with the four things this one use needs
/// on top: no chrome, no shadow, no mouse events at all, and no window
/// animation of its own. And it is torn down when the fall lands: a window that
/// outlives its one animation is a window nobody will ever find again.
@MainActor
final class PasteCheckmarkFall {
    /// The window, while there is one. Nil before the fall starts and again
    /// after it lands, which is the whole of the lifecycle.
    private(set) var panel: NSPanel?
    private var teardown: Task<Void, Never>?

    /// Fly the mark between two screen points — each the mark's own centre — and
    /// take the window down behind it.
    func fly(
        from: NSPoint, to: NSPoint,
        duration: TimeInterval = PasteFall.duration,
        defaults: UserDefaults = .standard
    ) {
        cancel()
        // One window big enough for both ends, so the mark is animated inside it
        // rather than by dragging a window across the screen: a frame moved
        // sixty times a second is the one thing AppKit does worse than Core
        // Animation.
        let margin = DictationIndicatorView.faceGlyphSize
        let frame = NSRect(
            x: min(from.x, to.x) - margin, y: min(from.y, to.y) - margin,
            width: abs(to.x - from.x) + margin * 2,
            height: abs(to.y - from.y) + margin * 2
        )
        let panel = OverlayPanel(contentRect: frame, defaults: defaults)
        // The same four overrides `TopCenteredPanel` makes, plus the two this
        // window alone needs: it answers no mouse event, and it opens and closes
        // without AppKit's own fade over the top of the fall's.
        panel.styleMask = [.nonactivatingPanel, .fullSizeContentView]
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        // After the name, never before: `OverlayPanel` autosaves the bubble's
        // own frame under it, and this window must not be placed by it.
        panel.setFrameAutosaveName("")
        panel.setFrame(frame, display: false)

        // The window's own space, which counts downward where the screen counts
        // up.
        let view = NSHostingView(rootView: FallingCheckmark(
            from: CGPoint(x: from.x - frame.minX, y: frame.maxY - from.y),
            to: CGPoint(x: to.x - frame.minX, y: frame.maxY - to.y),
            duration: duration
        ))
        view.appearance = NSAppearance(named: .darkAqua)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
        panel.orderFront(nil)
        self.panel = panel

        teardown = Task { @MainActor [weak self] in
            // The fall, and the frame it waits for before it starts.
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 50))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    /// Take the window down now — the fall landed, or a new dictation started on
    /// top of it.
    func cancel() {
        teardown?.cancel()
        teardown = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The mark's quarter second: down toward the cursor, to 40% of its size, to
/// nothing (#211). `easeIn`, because it is a thing falling — it leaves slowly
/// and is gone quickly.
private struct FallingCheckmark: View {
    let from: CGPoint
    let to: CGPoint
    let duration: TimeInterval
    @State private var landed = false

    var body: some View {
        PasteCheckmarkGlyph()
            .scaleEffect(landed ? PasteFall.shrink : 1)
            .opacity(landed ? 0 : 1)
            .position(landed ? to : from)
            .animation(.easeIn(duration: duration), value: landed)
            .task {
                // One frame standing where it left, so the fall is a fall and
                // not a window that opened with the mark already on its way.
                try? await Task.sleep(for: .milliseconds(16))
                landed = true
            }
    }
}
