import AppKit
import LoreCore
import SwiftUI

/// The drag card (#300): after Allow on Accessibility or Input Monitoring, a
/// small panel of lore's own docks under System Settings' content pane, holding
/// one lore row lined up with the Privacy list's rows. The row drags lore's
/// `.app` bundle into the list. Design authority:
/// `docs/design/prototypes/onboarding-drag-card.html` (v1.3) — its frames and
/// copy table are the contract.
///
/// The card never claims anything on its own: a drop changes nothing here, and
/// "lore is allowed" appears only when the onboarding poll's fresh-process
/// reading (`GrantCheck`) says so and the model calls `allowed()`
/// (`.claude/rules/no-false-positives.md` §1, §3).
///
/// Technique after Scrawl's `helper/PermissionPanel.swift` (MIT, Kit Langton):
/// the Settings window found through the window server by bundle id and
/// re-tracked, a borderless non-activating panel, the drag item a file URL.
@MainActor
protocol GrantCardControl: AnyObject {
    /// The grant whose card is up or on its way; `nil` when none is, including
    /// while "lore is allowed" plays out.
    var shownGrant: RequiredGrant? { get }
    func show(_ grant: RequiredGrant)
    /// The fresh reading said granted: acknowledge for a second, then go.
    func allowed()
    func close(_ reason: DiagEvent.GrantCardExit)
}

// MARK: - Geometry

/// Where the card goes, as a pure function of two rectangles in AppKit screen
/// coordinates, so placement is testable without a screen.
enum GrantCardGeometry {

    /// System Settings on macOS 26 and 27: a fixed-width sidebar, then the
    /// content pane whose Privacy list sits `listInset` in from both edges.
    static let settingsSidebarWidth: CGFloat = 232
    static let listInset: CGFloat = 20
    /// Board: 10 pt under the window; 20 pt above its bottom edge inside it.
    static let gap: CGFloat = 10
    static let insideBottom: CGFloat = 20
    /// Only the window's lowest 30 % is empty on these panes.
    static let emptyLowerShare: CGFloat = 0.3
    static let screenMargin: CGFloat = 8
    static let minimumWidth: CGFloat = 320

    /// The content pane edge to edge, so the card's 20 pt inset puts its row on
    /// the list's edges.
    static func cardWidth(settingsWidth: CGFloat) -> CGFloat {
        max(minimumWidth, settingsWidth - settingsSidebarWidth)
    }

    static func dock(
        card size: CGSize, settings: CGRect, visible: CGRect
    ) -> (origin: CGPoint, dock: DiagEvent.GrantCardDock) {
        let fits = { (r: CGRect) in
            r.minX >= visible.minX && r.maxX <= visible.maxX
                && r.minY >= visible.minY && r.maxY <= visible.maxY
        }
        // The content pane's left edge; nudged left only if a minimum-width
        // card would pass the window's right edge.
        let x = min(settings.minX + settingsSidebarWidth, settings.maxX - size.width)

        let below = CGRect(x: x, y: settings.minY - gap - size.height,
                           width: size.width, height: size.height)
        if fits(below) { return (below.origin, .below) }

        let inside = CGRect(x: x, y: settings.minY + insideBottom,
                            width: size.width, height: size.height)
        if fits(inside), inside.maxY <= settings.minY + settings.height * emptyLowerShare {
            return (inside.origin, .inside)
        }

        let clampedX = min(max(below.minX, visible.minX + screenMargin),
                           visible.maxX - size.width - screenMargin)
        let clampedY = min(max(below.minY, visible.minY + screenMargin),
                           visible.maxY - size.height - screenMargin)
        return (CGPoint(x: clampedX, y: clampedY), .clamped)
    }

    /// CGWindow bounds are top-left based on the primary screen; AppKit's are
    /// bottom-left.
    static func appKit(fromQuartz rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.minY - rect.height,
               width: rect.width, height: rect.height)
    }
}

// MARK: - System Settings' window

/// System Settings' main window through the window server: no Accessibility
/// needed, and matched by bundle id so a localized app name does not matter.
/// Bounds and owner come without Screen Recording; titles do not, so which
/// pane is showing cannot be read and is not relied on.
enum SettingsWindowLocator {
    static let bundleID = "com.apple.systempreferences"

    struct Window: Equatable {
        let id: CGWindowID
        /// Quartz (top-left) coordinates.
        let frame: CGRect
    }

    /// The largest ordinary on-screen window System Settings owns.
    static func main() -> Window? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier))
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var best: Window?
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let frame = bounds(info),
                  frame.width >= 300, frame.height >= 200
            else { continue }
            if best.map({ frame.width * frame.height > $0.frame.width * $0.frame.height }) ?? true {
                best = Window(id: id, frame: frame)
            }
        }
        return best
    }

    /// One known window's bounds while it is on screen — cheaper than listing
    /// every window, so it is what the per-frame tracking asks.
    static func frame(of id: CGWindowID) -> CGRect? {
        let ids = [UnsafeRawPointer(bitPattern: UInt(id))] as CFArray
        guard let info = (CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true
        else { return nil }
        return bounds(info)
    }

    private static func bounds(_ info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
}

// MARK: - Presenter

@MainActor
final class GrantCardPresenter: GrantCardControl {

    private(set) var shownGrant: RequiredGrant?

    /// Room around the card for its shadow; transparent, so it is not a target.
    static let shadowMargin: CGFloat = 44
    static let fadeDuration: TimeInterval = 0.18
    /// "lore is allowed" holds this long before the card fades.
    static let allowedHold: Duration = .seconds(1)
    /// How long Allow waits for System Settings' window to appear.
    static let findTimeout: TimeInterval = 6
    /// A window that is gone this long is closed, not mid-redraw.
    static let missingGrace: TimeInterval = 0.6

    private let state = GrantCardState()
    private var panel: GrantCardPanel?
    private var settings: SettingsWindowLocator.Window?
    private var missingSince: Date?
    private var steppedAside = false
    private var findTask: Task<Void, Never>?
    private var trackTimer: Timer?

    func show(_ grant: RequiredGrant) {
        if shownGrant == grant, panel != nil || findTask != nil { return }
        if shownGrant != nil { close(.onboardingMoved) }
        // A previous card still saying "lore is allowed" goes first.
        takeDown()
        shownGrant = grant
        state.phase = .docked
        state.dragging = false
        findTask = Task { [weak self] in await self?.findSettingsWindow(for: grant) }
    }

    func allowed() {
        guard let grant = shownGrant else { return }
        shownGrant = nil
        stopFollowing()
        DiagStore.record(.grantCardAllowed(permission: grant.diagPermission))
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        state.phase = .allowed
        if panel.alphaValue < 1 { fade(panel, to: 1) }
        Task { [weak self] in
            try? await Task.sleep(for: Self.allowedHold)
            guard let self, self.panel === panel else { return }
            self.takeDown()
        }
    }

    func close(_ reason: DiagEvent.GrantCardExit) {
        guard let grant = shownGrant else { return }
        shownGrant = nil
        stopFollowing()
        DiagStore.record(.grantCardGone(permission: grant.diagPermission, reason: reason))
        takeDown()
    }

    // MARK: Arriving

    /// Docks on the first sight of the Settings window; `follow()` re-places
    /// the card while it is still opening or moving.
    private func findSettingsWindow(for grant: RequiredGrant) async {
        let deadline = Date().addingTimeInterval(Self.findTimeout)
        while !Task.isCancelled, shownGrant == grant {
            if let window = SettingsWindowLocator.main() {
                findTask = nil
                dock(grant, at: window)
                return
            } else if Date() > deadline {
                findTask = nil
                close(.settingsNotFound)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func dock(_ grant: RequiredGrant, at window: SettingsWindowLocator.Window) {
        settings = window
        let width = GrantCardGeometry.cardWidth(settingsWidth: window.frame.width)
        let panel = GrantCardPanel(state: state, cardWidth: width, margin: Self.shadowMargin)
        self.panel = panel
        let dock = place(panel, against: window.frame)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        fade(panel, to: 1)
        DiagStore.record(.grantCardShown(permission: grant.diagPermission, dock: dock))
        steppedAside = false
        startFollowing()
    }

    /// Positions the panel for a Settings frame and says which dock it took.
    @discardableResult
    private func place(_ panel: GrantCardPanel, against quartz: CGRect) -> DiagEvent.GrantCardDock {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let settings = GrantCardGeometry.appKit(fromQuartz: quartz, primaryHeight: primaryHeight)
        let center = CGPoint(x: settings.midX, y: settings.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.first { $0.frame.intersects(settings) } ?? NSScreen.main
        let card = panel.cardSize
        let plan = GrantCardGeometry.dock(card: card, settings: settings,
                                          visible: screen?.visibleFrame ?? settings)
        let margin = Self.shadowMargin
        panel.setFrameOrigin(CGPoint(x: plan.origin.x - margin, y: plan.origin.y - margin))
        return plan.dock
    }

    // MARK: Following

    private func startFollowing() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackTimer = timer
    }

    private func stopFollowing() {
        findTask?.cancel()
        findTask = nil
        trackTimer?.invalidate()
        trackTimer = nil
        missingSince = nil
    }

    /// Follows the Settings window 1:1 while the user moves it, and steps aside
    /// while another app is in front.
    private func follow() {
        guard let grant = shownGrant, let panel else { return }
        var frame = settings.flatMap { SettingsWindowLocator.frame(of: $0.id) }
        if frame == nil, let window = SettingsWindowLocator.main() {
            settings = window
            frame = window.frame
        }
        guard let frame else {
            let since = missingSince ?? Date()
            missingSince = since
            if Date().timeIntervalSince(since) > Self.missingGrace { close(.settingsClosed) }
            return
        }
        missingSince = nil
        if let id = settings?.id, frame != settings?.frame {
            settings = SettingsWindowLocator.Window(id: id, frame: frame)
            place(panel, against: frame)
        }

        let front = NSWorkspace.shared.frontmostApplication
        let inFront = front?.bundleIdentifier == SettingsWindowLocator.bundleID
            || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || state.dragging
        guard inFront == steppedAside else { return }
        steppedAside = !inFront
        fade(panel, to: inFront ? 1 : 0)
        panel.ignoresMouseEvents = !inFront
        DiagStore.record(inFront
                         ? .grantCardReturned(permission: grant.diagPermission)
                         : .grantCardSteppedAside(permission: grant.diagPermission))
    }

    // MARK: Going

    private func takeDown() {
        guard let panel else { return }
        self.panel = nil
        settings = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = alpha
        }
    }
}

// MARK: - Panel

@MainActor
@Observable
final class GrantCardState {
    enum Phase: Equatable { case docked, allowed }
    var phase: Phase = .docked
    var dragging = false
}

/// lore's floating, non-activating overlay: clicking or dragging the row
/// leaves System Settings the active app, which is what the drop needs.
final class GrantCardPanel: OverlayPanel {
    let cardSize: CGSize

    init(state: GrantCardState, cardWidth: CGFloat, margin: CGFloat) {
        let source = GrantCardDragSource(state: state)
        let host = NSHostingView(rootView: GrantCardView(state: state, width: cardWidth,
                                                         margin: margin, dragSource: source))
        host.sizingOptions = []
        let fitting = host.fittingSize
        cardSize = CGSize(width: cardWidth, height: fitting.height - margin * 2)
        super.init(contentRect: CGRect(origin: .zero, size: fitting))
        host.frame = CGRect(origin: .zero, size: fitting)
        contentView = host
        // The card draws its own shadow (board: Shadow.popover).
        hasShadow = false
        // lore is not the active app while Settings is in front.
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
}

// MARK: - Card

/// Board F2–F6: the lore row at the list's row height, the sentence, the small
/// line; F5a: "lore is allowed". Every string is the board's copy table.
private struct GrantCardView: View {
    let state: GrantCardState
    let width: CGFloat
    let margin: CGFloat
    let dragSource: GrantCardDragSource

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch state.phase {
            case .docked: docked.transition(.opacity)
            case .allowed: allowed.transition(.opacity)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .padding(margin)
        .animation(.easeOut(duration: 0.2), value: state.phase)
        .preferredColorScheme(.dark)
    }

    private var docked: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            VStack(alignment: .leading, spacing: 3) {
                Text("Drag \(LoreBrand.wordmark) into the list above, then turn its switch on.")
                    .font(LoreTheme.Typography.secondary)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                Text("Can't drag? Use the + button under the list.")
                    .font(LoreTheme.Typography.meta)
                    .foregroundStyle(LoreTheme.TextColor.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 9)
            .padding(.horizontal, 12)
            .padding(.bottom, 3)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 20)
        .frame(width: width, alignment: .leading)
        .cardChrome()
    }

    /// The row the list will show once it lands. Dimmed in place while its
    /// copy is dragged (F3); the drag itself is AppKit's, over the row.
    private var row: some View {
        HStack(spacing: 10) {
            Image(nsImage: LoreMark.chip)
                .resizable()
                .frame(width: 22, height: 22)
            Text(LoreBrand.wordmark)
                .font(LoreTheme.Typography.control)
                .foregroundStyle(LoreTheme.TextColor.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .opacity(state.dragging ? 0.3 : 1)
        .overlay(DragHost(view: dragSource))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(LoreBrand.wordmark), drag into the list above, then turn its switch on")
    }

    private var allowed: some View {
        Text("\(LoreBrand.wordmark) is allowed")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(LoreTheme.TextColor.primary)
            .padding(.vertical, 9)
            .padding(.horizontal, 15)
            .cardChrome()
    }
}

private extension View {
    /// lore's own panel, not part of Settings: popover surface, window rim.
    func cardChrome() -> some View {
        background(LoreTheme.Surface.popover,
                   in: RoundedRectangle(cornerRadius: LoreTheme.Radius.window))
            .overlay(
                RoundedRectangle(cornerRadius: LoreTheme.Radius.window)
                    .strokeBorder(LoreTheme.Shadow.windowRim, lineWidth: 1)
            )
            .loreShadow(LoreTheme.Shadow.popover)
    }
}

private struct DragHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Drag source

/// The row's hit area. SwiftUI draws the row; this is the `NSDraggingSource`,
/// and its one pasteboard item is the file URL of the bundle macOS grants.
final class GrantCardDragSource: NSView, NSDraggingSource {
    private let state: GrantCardState
    private var mouseDownEvent: NSEvent?

    /// This running lore's bundle — the one TCC keys the grant to.
    static var bundleURL: URL { Bundle.main.bundleURL }

    init(state: GrantCardState) {
        self.state = state
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }
    override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let distance = hypot(event.locationInWindow.x - down.locationInWindow.x,
                             event.locationInWindow.y - down.locationInWindow.y)
        guard distance >= 3 else { return }
        mouseDownEvent = nil
        let item = NSDraggingItem(pasteboardWriter: Self.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: dragImage())
        let session = beginDraggingSession(with: [item], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        state.dragging = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// A drop is not a grant: only the state of the row returns.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        state.dragging = false
    }

    /// The row as the list will show it, opaque so it reads over any window it
    /// crosses (board F3's lifted row).
    private func dragImage() -> NSImage {
        let size = bounds.size
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: LoreTheme.Radius.card, yRadius: LoreTheme.Radius.card)
            NSColor(LoreTheme.Surface.popoverOpaque).setFill()
            path.fill()
            NSColor(LoreTheme.Surface.line2).setStroke()
            path.lineWidth = 1
            path.stroke()
            LoreMark.chip.draw(in: CGRect(x: 12, y: (size.height - 22) / 2, width: 22, height: 22))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor(LoreTheme.TextColor.primary),
            ]
            let name = LoreBrand.wordmark as NSString
            let height = name.size(withAttributes: attributes).height
            name.draw(at: CGPoint(x: 44, y: (size.height - height) / 2), withAttributes: attributes)
            return true
        }
    }
}
