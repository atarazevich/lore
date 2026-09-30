import AppKit
import SwiftUI

/// The player's title and the ?'s card (#289), in the words of the board's
/// copy table (`agent-replies-player.html` v3.9 §06) — the contract for every
/// string here.
///
/// The command is spelled once. The title prints it, and the line the card
/// hands to an agent spells it exactly as the title does.
enum AgentReplyHelpCopy {
    /// The title's first half: the command, medium in primary ink.
    static let command = "lore say"
    /// …and its argument, regular and muted.
    static let argument = "\"message\""
    static let title = "\(command) \(argument)"

    /// The card's first line: what the list is.
    static let lead = "Agents in your terminal speak their replies here, one at a time."
    /// The second: the whole setup is the well under it.
    static let setup = "To connect an agent, add this line to its instructions:"
    /// The line Copy takes, written for the agent: it goes into the agent's
    /// instructions as it stands.
    static let line = "When you finish, run \(title)"

    /// What VoiceOver calls the ?.
    static let helpName = "Help"
}

// MARK: - When the card is open

/// Whether the ?'s card is up, and why (#289): the pointer is on the ? or on
/// the card, or a click on the ? pinned it. Pinned, it stays until a click
/// anywhere else or Esc — and while it is pinned Esc closes the card before it
/// does anything else (`HotkeyManager.EscapeAction`).
///
/// Held by `AgentReplyController`, because Esc is read there; the player's
/// title bar and the card's own window only report the pointer to it.
@Observable
@MainActor
final class AgentReplyHelp {
    /// A click on the ? pinned the card.
    private(set) var isPinned = false
    /// The pointer is on the ? or on the card — or left the one for the other
    /// less than `leaveGrace` ago, so crossing the gap between them does not
    /// close it.
    private(set) var isHovered = false

    var isOpen: Bool { isPinned || isHovered }

    /// Where the pointer is, as the two views last reported it. Not observed:
    /// only `isHovered` is drawn.
    @ObservationIgnored private var pointerOnMark = false
    @ObservationIgnored private var pointerOnCard = false
    @ObservationIgnored private var leaveTask: Task<Void, Never>?
    /// The two click monitors a pinned card listens to, nil while it is not.
    @ObservationIgnored private var clickMonitors: [Any] = []

    /// How long the card waits after the pointer leaves the ? or the card:
    /// the pointer crosses two points of the title bar and the caret's side on
    /// its way from one to the other.
    nonisolated static let leaveGrace: Duration = .milliseconds(300)

    func pointer(onMark isOn: Bool) {
        pointerOnMark = isOn
        pointerMoved(entered: isOn)
    }

    func pointer(onCard isOn: Bool) {
        pointerOnCard = isOn
        pointerMoved(entered: isOn)
    }

    private func pointerMoved(entered: Bool) {
        leaveTask?.cancel()
        leaveTask = nil
        if entered {
            isHovered = true
            return
        }
        guard !pointerOnMark, !pointerOnCard else { return }
        leaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.leaveGrace)
            guard !Task.isCancelled, let self, !self.pointerOnMark, !self.pointerOnCard else {
                return
            }
            self.isHovered = false
        }
    }

    /// A click on the ?: an unpinned card — shown by hover or not at all — is
    /// pinned; a pinned one closes.
    func click() {
        if isPinned {
            close()
        } else {
            isPinned = true
            listenForClicksElsewhere()
        }
    }

    /// Esc, a click elsewhere, or a second click on the ?: the card goes, hover
    /// or pin. The pointer has to leave and come back to open it again.
    ///
    /// The card's window goes with it, and a view that is gone never reports
    /// the pointer leaving: the pointer is off the card from here on.
    func close() {
        leaveTask?.cancel()
        leaveTask = nil
        pointerOnCard = false
        isPinned = false
        isHovered = false
        stopListening()
    }

    /// The player went away: the ? went too, so its last report goes as well.
    func reset() {
        pointerOnMark = false
        close()
    }

    /// A mouse button went down somewhere — in lore or in any other app. On
    /// the ? or on the card it is theirs; anywhere else it closes a pinned card
    /// and still reaches whatever it was aimed at.
    func clickedSomewhere() {
        guard isPinned, !pointerOnMark, !pointerOnCard else { return }
        close()
    }

    /// Only while pinned: a local monitor for lore's own windows, a global one
    /// for every other app's. Mouse events need no Accessibility grant.
    private func listenForClicksElsewhere() {
        guard clickMonitors.isEmpty else { return }
        let buttons: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: buttons, handler: { [weak self] event in
            Task { @MainActor in self?.clickedSomewhere() }
            return event
        }) {
            clickMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: buttons, handler: { [weak self] _ in
            Task { @MainActor in self?.clickedSomewhere() }
        }) {
            clickMonitors.append(global)
        }
    }

    private func stopListening() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
    }
}

// MARK: - The card

/// The ?'s card (board §01 b, §07): lore's popover fill with no rim, opaque, a
/// caret of the same fill rising to just under the ?, two sentences and the
/// well with the line to take and Copy at its trailing edge.
///
/// Drawn in a window of its own (`AgentReplyHelpWindow`): at 95 pt it is
/// taller than the room kept under the plate and than a plate holding a single
/// reply, so it may reach past the plate's foot.
struct AgentReplyHelpCard: View {
    /// Where the caret stands, from the card's leading edge: under the ?'s
    /// centre.
    let caretX: CGFloat
    /// The pointer arriving on the card or leaving it.
    var onPointer: (Bool) -> Void = { _ in }

    /// Where the head's and the strip's rules end, 6 in from each side of the
    /// plate: the card's edges. The line and Copy need that width.
    static let inset = AgentReplyPlayerView.ruleInset
    static let width: CGFloat = AgentReplyPlayerView.plateWidth - 2 * inset
    /// The caret: 11 tall, 18 across its base, its tip 2 under the ?'s circle.
    static let caretHeight: CGFloat = 11
    static let caretWidth: CGFloat = 18
    static let caretGap: CGFloat = 2

    /// 12 at the sides puts the words on the strip's content edge; 14 above
    /// and below.
    private static let padding = EdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
    /// Popover type, a step under the list: 11 on a 1.4 line.
    private static let textSize: CGFloat = 11
    /// The well's line: mono 10.5 on the same 1.4.
    private static let lineSize: CGFloat = 10.5
    /// Copy stands at least this far after the line.
    private static let copyGap: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sentence(AgentReplyHelpCopy.lead)
            sentence(AgentReplyHelpCopy.setup)
                .padding(.top, 5)
            well
                .padding(.top, 7)
        }
        .padding(Self.padding)
        .frame(width: Self.width, alignment: .leading)
        .padding(.top, Self.caretHeight)
        // Opaque, so no row shows through; no border — the fill and the
        // window's shadow separate it from the rows it covers.
        .background(shape.fill(LoreTheme.Surface.popoverOpaque))
        .contentShape(shape)
        .onHover(perform: onPointer)
        .environment(\.colorScheme, .dark)
    }

    private var shape: AgentReplyHelpCardShape {
        AgentReplyHelpCardShape(
            caretX: caretX, caretWidth: Self.caretWidth, caretHeight: Self.caretHeight,
            radius: LoreTheme.Radius.popover
        )
    }

    private func sentence(_ words: String) -> some View {
        Text(words)
            .font(.system(size: Self.textSize))
            .foregroundStyle(LoreTheme.TextColor.primary)
            .lineLimit(1)
            .frame(height: Self.textSize * 1.4)
    }

    /// One box, its fill, holding the line to take and — at its trailing edge,
    /// at least 24 after the line — Copy.
    private var well: some View {
        HStack(spacing: 0) {
            Text(AgentReplyHelpCopy.line)
                .font(LoreTheme.Typography.mono(Self.lineSize))
                .foregroundStyle(LoreTheme.TextColor.primary)
                .fixedSize()
            Spacer(minLength: Self.copyGap)
            copyButton
        }
        .frame(height: Self.lineSize * 1.4)
        .padding(EdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 3))
        .background(LoreTheme.Surface.card3, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button))
    }

    /// A plain text button, no fill and no border: the app's copy idiom
    /// (`LoreCopyFlash`, `LoreCopyLabel`), the word at the right end of its box
    /// so the swap grows leftward and never moves it. No hover line: the
    /// board's copy table names none.
    private var copyButton: some View {
        LoreCopyFlash(tooltip: nil) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AgentReplyHelpCopy.line, forType: .string)
        } content: { copied, fire in
            LoreCopyLabel(copied: copied, alignment: .trailing)
                .fixedSize()
                // A non-activating window: a SwiftUI `Button` would not receive
                // the click (the reason every control of the player is a tap).
                .contentShape(Rectangle())
                .onTapGesture(perform: fire)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(copied ? LoreCopyLabel.copiedWords : LoreCopyLabel.copy)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { fire() }
        }
    }
}

/// The card and its caret as one outline, so the two are one fill with no
/// seam where they meet, and the window's shadow follows both.
struct AgentReplyHelpCardShape: Shape {
    let caretX: CGFloat
    let caretWidth: CGFloat
    let caretHeight: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let body = CGRect(
            x: rect.minX, y: rect.minY + caretHeight,
            width: rect.width, height: rect.height - caretHeight
        )
        path.addRoundedRect(in: body, cornerSize: CGSize(width: radius, height: radius))
        // The base dips a point into the body: one outline, filled once.
        let x = min(max(caretX, radius + caretWidth / 2), rect.width - radius - caretWidth / 2)
        path.move(to: CGPoint(x: rect.minX + x - caretWidth / 2, y: body.minY + 1))
        path.addLine(to: CGPoint(x: rect.minX + x, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + x + caretWidth / 2, y: body.minY + 1))
        path.closeSubpath()
        return path
    }
}

// MARK: - The card's own window

/// A borderless, non-activating panel for the card, a child of the player's:
/// it floats over the rows, moves with the plate, and never takes focus from
/// the app in front. The shadow is the window's own, cast from the card's
/// outline — a shadow drawn inside the window would need a transparent margin
/// round the card, and that margin would take the clicks meant for the rows
/// under it.
@MainActor
final class AgentReplyHelpWindow {
    private let panel: OverlayPanel
    private let hosting: NSHostingView<AgentReplyHelpCard>
    private let onPointer: (Bool) -> Void

    init(onPointer: @escaping (Bool) -> Void) {
        self.onPointer = onPointer
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1))
        // Up exactly while the card is open: a panel's default is to hide when
        // the app resigns active, which would leave a pinned card holding Esc
        // and the click monitors with nothing on screen.
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        hosting = NSHostingView(rootView: AgentReplyHelpCard(caretX: 0, onPointer: onPointer))
        hosting.sizingOptions = .intrinsicContentSize
        hosting.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hosting
    }

    /// Puts the card up, or keeps it where it is, with the caret's tip at `tip`
    /// on the screen, `caretX` in from the card's leading edge.
    func show(tip: NSPoint, caretX: CGFloat, over parent: NSWindow) {
        if hosting.rootView.caretX != caretX {
            hosting.rootView = AgentReplyHelpCard(caretX: caretX, onPointer: onPointer)
        }
        let size = hosting.fittingSize
        let frame = NSRect(
            x: (tip.x - caretX).rounded(), y: (tip.y - size.height).rounded(),
            width: size.width, height: size.height
        )
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        guard !panel.isVisible else { return }
        panel.orderFront(nil)
        // The shadow is cast from what the window has drawn, which is the
        // caret and the card only once SwiftUI has laid them out.
        DispatchQueue.main.async { [panel] in panel.invalidateShadow() }
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// Where the card hangs from: a view the size of the ?, present only while the
/// card is open. It puts the card's window up, keeps it under the ? as the
/// plate is dragged or grows, and takes it down when it goes.
struct AgentReplyHelpAnchor: NSViewRepresentable {
    let caretX: CGFloat
    let onPointer: (Bool) -> Void

    func makeNSView(context: Context) -> AnchorView {
        AnchorView(onPointer: onPointer)
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.caretX = caretX
        view.place()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.tearDown()
    }

    final class AnchorView: NSView {
        var caretX: CGFloat = 0
        private let onPointer: (Bool) -> Void
        private var card: AgentReplyHelpWindow?
        private var observers: [NSObjectProtocol] = []

        init(onPointer: @escaping (Bool) -> Void) {
            self.onPointer = onPointer
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// A report and nothing else: the pointer belongs to the ? above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                // The plate dragged, or grown from its top as replies arrive:
                // the card follows the ?.
                for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.place() }
                    })
                }
            }
            place()
        }

        /// SwiftUI laying the ? out: the first frame arrives after the view is
        /// in its window, and a later one when the title moves inside it.
        override func setFrameOrigin(_ origin: NSPoint) {
            super.setFrameOrigin(origin)
            place()
        }

        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            place()
        }

        func place() {
            guard let window, window.isVisible, bounds.width > 0 else {
                card?.hide()
                return
            }
            let card = self.card ?? AgentReplyHelpWindow(onPointer: onPointer)
            self.card = card
            let onScreen = window.convertToScreen(convert(bounds, to: nil))
            card.show(
                tip: NSPoint(x: onScreen.midX, y: onScreen.minY - AgentReplyHelpCard.caretGap),
                caretX: caretX, over: window
            )
        }

        func tearDown() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            card?.hide()
            card = nil
        }
    }
}
