import AppKit
import SwiftUI

// MARK: - View

/// One collected item as the indicator draws it (#192) — everything the list
/// needs and nothing it does not: the image's bytes stay on the coordinator,
/// only a thumbnail comes here.
struct DictationItemChip: Identifiable, Equatable {
    let id: UUID
    let kind: DictationItemKind
    /// The item's first words, quoted and ellipsised — empty for an image,
    /// which shows the one word `Screenshot` instead.
    let preview: String
    let thumbnail: NSImage?
    let seconds: Int
    let included: Bool

    /// Verbatim, markdown and all: it is what will be pasted, so it is shown as
    /// it will be pasted. One line, cut short enough to leave the closing quote
    /// on screen.
    static func quoted(_ text: String, limit: Int = 40) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = flat.count > limit ? String(flat.prefix(limit)) + "\u{2026}" : flat
        return "\u{201C}\(clipped)\u{201D}"
    }
}

/// A moment in a dictation, said the same way wherever it appears — the live
/// timer and an item's row read the same clock: `m:ss`, and `h:mm:ss` once an
/// hour has passed.
private func elapsed(_ seconds: Int) -> String {
    let seconds = max(0, seconds)
    guard seconds >= 3600 else { return String(format: "%d:%02d", seconds / 60, seconds % 60) }
    return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
}

/// The width the longest reading of that many seconds needs at `size` —
/// `00:00` under an hour, `0:00:00` past it — measured in the same monospaced
/// face the label draws with, where every digit is one width. Held as a
/// minimum, nothing moves as the clock runs and no number is ever squeezed
/// into two lines.
private func elapsedWidth(_ seconds: Int, size: CGFloat) -> CGFloat {
    let template = seconds >= 3600 ? "0:00:00" : "00:00"
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    return ceil((template as NSString).size(withAttributes: [.font: font]).width)
}

struct DictationIndicatorView: View {
    let state: DictationState
    let audioLevel: Float
    var isLocked = false
    var pendingMode: UpgradeAction?
    /// Fn+K armed or entry flagged (#122): shows the K badge while
    /// recording and fills the upgrade panel's K keycap after paste.
    var operatorAddressed = false
    var recordingSeconds: Int = 0
    var showUpgradeButtons = false
    var hideCleanupButton = false
    /// DSET-06: the C/T keycap hints disappear when the upgrade-keys modifier
    /// toggle is off; the buttons themselves stay clickable.
    var showUpgradeKeycaps = true
    /// DSET-05: with Space-lock turned off there is no lock to offer, so the
    /// glyph is not drawn at all rather than standing there inert (#201).
    var lockEnabled = true
    var upgradeCountdown: Double?
    var lastError: String?
    var bluetoothRedirected = false
    var noSignal = false
    /// What rides along with this dictation (#192), oldest first.
    var items: [DictationItemChip] = []
    /// Collecting is on — the paperclip's own switch (#201), the same one
    /// Settings → Copying carries. Off keeps its place and comes back to what
    /// it held.
    var collecting = true
    /// Screenshots are on in Settings (#201): what the `S` keycap's brightness
    /// reports. `S` is a key you press, never a switch on the bubble.
    var screenshotsEnabled = true
    @State private var showBluetoothInfo = false
    /// The pointer is on the bubble. Everything the bubble can show — the key
    /// rail and the list — is this one state (#201): pointing at the shape
    /// widens it and, if anything has been collected, grows it downward.
    /// Nothing is clicked to open anything.
    ///
    /// One hover region for the whole shape, and a grace before it closes:
    /// hovering the rows themselves was never enough, because the way down to
    /// them crossed padding that belongs to no row, and a list that closed
    /// there shut and reopened under the moving pointer (#192).
    @State private var expanded = false
    @State private var pointerOnBubble = false
    /// The letters and the gear are readable only once the shape has room for
    /// them, so they fade in behind the widening (#201 motion table).
    @State private var railVisible = false
    /// The shape is the resting bubble: not widened, and not still collapsing
    /// back. Only a resting report re-centres the window — while the shape is
    /// wider than that, the panel keeps the resting shape's left edge, so the
    /// widening moves one edge instead of sliding the whole bubble sideways.
    @State private var restSettled = true
    /// The shape's own size, as of the last layout pass, so the moment it
    /// settles can be reported with the size it settled at.
    @State private var bubbleSize: CGSize = .zero
    /// The top row's own width, which the list then stretches to exactly. The
    /// list must contribute nothing to the shape's width — a long copied line
    /// ellipsises instead of pushing the bubble wider.
    @State private var topRowWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onUpgrade: ((UpgradeAction) -> Void)?
    /// Post-paste K toggle (#122) — same tap affordance as the C/T buttons.
    var onOperatorToggle: (() -> Void)?
    /// A row is the switch: in the prompt, or left out (#192).
    var onToggleItem: ((UUID) -> Void)?
    /// The lock glyph is the Space key's other face (#201).
    var onToggleLock: (() -> Void)?
    /// The paperclip turns collecting off and on (#201).
    var onToggleCollecting: (() -> Void)?
    /// `C`, `T` and `K` arm and disarm exactly as Fn+V, Fn+T and Fn+K do
    /// (#201).
    var onArmCleanup: (() -> Void)?
    var onArmTranslate: (() -> Void)?
    var onArmOperator: (() -> Void)?
    /// The gear opens Settings → Copying (#201).
    var onOpenSettings: (() -> Void)?
    /// The shape reports itself, so the panel around it can be exactly its
    /// size at every step of the spring, and knows when that size is the
    /// resting one (#201, `TopCenteredPanel`).
    var onFrameChange: (@MainActor (PanelContentFrame) -> Void)?

    var body: some View {
        bubble
            .fixedSize()
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onHover { pointerOnBubble = $0 }
            // Coming back cancels the close — the task is keyed on being
            // outside, and on the recording still being there to widen for.
            .task(id: [pointerOnBubble, canExpand]) { await followPointer() }
            .task(id: [expanded, canExpand]) { await followExpansion() }
            .animation(expanded ? widenAnimation : closeAnimation, value: expanded)
            .animation(railFade, value: railVisible)
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                bubbleSize = size
                report(size)
            }
            // The shape settles a moment after its last layout pass, and the
            // window's anchor is only allowed to move then.
            .onChange(of: restSettled) { _, _ in report(bubbleSize) }
            .environment(\.colorScheme, .dark)
    }

    private func report(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        onFrameChange?(PanelContentFrame(size: size, atRest: restSettled))
    }

    /// One shape: the row, and — when something has been collected — the list
    /// at the bottom of the same surface (#201). Three floating surfaces for
    /// one panel read as three things; this is one.
    private var bubble: some View {
        VStack(spacing: 0) {
            panel
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { topRowWidth = $0 }
            if showItemList {
                LoreTheme.Surface.line.frame(height: 1)
                itemList
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Hover, and the motion it drives

    /// A recording is what the rail and the list belong to; an error row is
    /// not something to widen.
    private var canExpand: Bool { state == .recording && lastError == nil }

    /// There is something collected, and a recording to show it for. With
    /// collecting off nothing is in the prompt, so there is no list either —
    /// turning it back on brings both back.
    private var showItemList: Bool { canExpand && expanded && collecting && !items.isEmpty }

    private func followPointer() async {
        guard canExpand else {
            expanded = false
            railVisible = false
            return
        }
        guard !pointerOnBubble else {
            expanded = true
            return
        }
        // The grace absorbs the hover that blinks off while the shape moves
        // under a pointer that never did, and lets the pointer travel down to
        // a row without the bubble shutting under it.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        expanded = false
    }

    private func followExpansion() async {
        // The recording the rail and the anchor belong to is over. The panel
        // is about to hold different content, and neither the letters nor the
        // resting width of the shape that just left may reach it — a stale
        // anchor would hang the next shape off to one side.
        guard canExpand else {
            railVisible = false
            restSettled = true
            return
        }
        // Nothing is animating, so there is nothing to wait out: waiting the
        // collapse's length over a layout that already snapped is how the
        // window ends up holding an anchor the shape has left behind.
        guard !reduceMotion else {
            railVisible = expanded
            restSettled = !expanded
            return
        }
        if expanded {
            // The shape is on the move from this instant, so the window stops
            // re-centring before the first widened layout reaches it.
            restSettled = false
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            railVisible = true
        } else {
            // Reset behind the collapse, never during it: the letters leave
            // with the shape, as one movement.
            try? await Task.sleep(for: .seconds(Self.closeDuration))
            guard !Task.isCancelled else { return }
            railVisible = false
            try? await Task.sleep(for: Self.settleGrace)
            guard !Task.isCancelled else { return }
            restSettled = true
        }
    }

    private var widenAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)
    }

    /// How long the shape takes to close — the easing and the wait that has to
    /// outlast it are one fact, so they are one number.
    private static let closeDuration: TimeInterval = 0.2
    /// A frame past that close, so the width the window adopts as the resting
    /// one is the width the shape stopped at and not a step of the collapse.
    private static let settleGrace: Duration = .milliseconds(60)

    private var closeAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: Self.closeDuration)
    }

    private var railFade: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    private var panel: some View {
        Group {
            switch state {
            case .recording:
                if let error = lastError {
                    // Mic stall surfaced by the first-frame watchdog — show it loudly
                    // instead of a normal-looking recording meter.
                    statusRow(icon: "xmark.circle.fill", iconColor: LoreTheme.Accent.red, text: error, wrap: true)
                } else {
                    recordingContent
                }
            case .loadingModel:
                statusRow(icon: "arrow.down.circle", text: "Downloading model...")
            case .processing:
                processingContent
            case .done:
                if showUpgradeButtons {
                    upgradeContent
                } else if let error = lastError {
                    statusRow(icon: "xmark.circle.fill", iconColor: LoreTheme.Accent.red, text: error, wrap: true)
                } else {
                    statusRow(icon: "checkmark.circle.fill", iconColor: LoreTheme.Accent.green, text: "Done")
                }
            case .idle:
                EmptyView()
            }
        }
    }

    // MARK: - Recording

    /// The bubble at rest, and the rail it widens to show (#201). At rest the
    /// only letters are the armed ones: what will happen to these words is a
    /// fact about the dictation in progress, and a fact the bubble hides until
    /// it is pointed at is a fact the user does not have (the shipped bubble
    /// said nothing at all while translate was armed). Everything else — `S`,
    /// the unarmed letters, the gear — arrives with the pointer.
    private var recordingContent: some View {
        HStack(spacing: 10) {
            statusGroup
            clip
            if !railKeys.isEmpty {
                groupDivider
                    .opacity(armedKeys.isEmpty && !railVisible ? 0 : 1)
                HStack(spacing: 6) {
                    ForEach(railKeys) { key in
                        // An armed letter was already standing there, so it
                        // does not fade in with the rail and does not blink
                        // out under the pointer that came to read it; a hint
                        // is nothing to click, or speak, before it can be
                        // read.
                        keycap(key.letter.rawValue, bright: key.bright,
                               help: key.help, action: key.action)
                            .opacity(key.armed || railVisible ? 1 : 0)
                            .allowsHitTesting(key.armed || railVisible)
                    }
                }
            }
            if expanded {
                groupDivider
                    .opacity(railVisible ? 1 : 0)
                gear
                    .opacity(railVisible ? 1 : 0)
                    .allowsHitTesting(railVisible)
            }
        }
    }

    /// One letter in the bubble (#201). `armed` is what the letter reports
    /// about this dictation — cleanup or translate on paste, the operator —
    /// and it is also why the letter stands in the resting bubble. `S` is
    /// never armed: its brightness reports a setting, and it is a key you
    /// press, not a switch you flip.
    private struct RailKey: Identifiable {
        /// The letter is the key on the keyboard, and the keyboard has these
        /// four.
        enum Letter: String {
            case screenshot = "S"
            case cleanup = "C"
            case translate = "T"
            case operatorSend = "K"
        }

        let letter: Letter
        let bright: Bool
        let help: String
        let action: (() -> Void)?
        let armed: Bool
        var id: Letter { letter }
    }

    private var cleanupKey: RailKey {
        let armed = pendingMode == .cleanup
        return RailKey(
            letter: .cleanup, bright: armed,
            help: armed ? "Cleaning up on paste" : "Clean up on paste (Fn+V)",
            action: onArmCleanup, armed: armed
        )
    }

    private var translateKey: RailKey {
        let armed = pendingMode == .translate
        return RailKey(
            letter: .translate, bright: armed,
            help: armed ? "Translating on paste" : "Translate on paste (Fn+T)",
            action: onArmTranslate, armed: armed
        )
    }

    private var operatorKey: RailKey {
        RailKey(
            letter: .operatorSend, bright: operatorAddressed,
            help: operatorAddressed ? "Going to the operator" : "Send to the operator (Fn+K)",
            action: onArmOperator, armed: operatorAddressed
        )
    }

    /// What is armed, in the order `C` `T` `K` — the letters the resting
    /// bubble carries. DSET-06 turns the *hints* off, not the facts, so this
    /// list is drawn whatever `showUpgradeKeycaps` says.
    private var armedKeys: [RailKey] {
        [cleanupKey, translateKey, operatorKey].filter(\.armed)
    }

    /// Widened, the board's `S T K` — with `C` before `T` while cleanup is
    /// armed, because a letter that was standing in the resting bubble may not
    /// disappear when the shape opens. With the keycap hints off, only the
    /// armed letters, for the same reason.
    private var railKeys: [RailKey] {
        guard expanded, showUpgradeKeycaps else { return armedKeys }
        var keys = [
            RailKey(
                letter: .screenshot, bright: screenshotsEnabled,
                help: "Screenshot into the prompt (Fn+S)", action: nil, armed: false
            )
        ]
        if pendingMode == .cleanup { keys.append(cleanupKey) }
        keys.append(translateKey)
        keys.append(operatorKey)
        return keys
    }

    private var groupDivider: some View {
        LoreTheme.Surface.line.frame(width: 1, height: 14)
    }

    /// The paperclip and its count together (#201): gray while collecting and
    /// empty, bright with the badge once something is in, and a slashed glyph
    /// when collecting is off. Click turns collecting off and on.
    private var clip: some View {
        clipSwitch
            // Outside the switch's own element, so the count keeps its voice:
            // an ignored-children container would have swallowed it.
            .overlay(alignment: .topTrailing) { if clipBright { badge } }
    }

    private var clipSwitch: some View {
        clipGlyph
            // The tint reaches the slash as well as the symbol, so the two
            // strokes of one glyph are never two colours.
            .foregroundStyle(clipBright ? LoreTheme.TextColor.primary : LoreTheme.TextColor.muted)
            // No plate under it, at rest or bright: the dot, the lock, the
            // waveform and the timer beside it stand on the bubble itself, and
            // a glyph on its own tile read as a button pasted into the row.
            // What the paperclip is doing is said by its brightness, by the
            // badge and by the slash. The pointer gets the same lift the gear
            // gets, and nothing before that.
            .loreHoverFill(cornerRadius: LoreTheme.Radius.button)
            .contentShape(Rectangle())
            .onTapGesture { onToggleCollecting?() }
            .help(collecting ? "What you copy joins the prompt" : "Copies stay out of the prompt")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                collecting ? "What you copy joins the prompt" : "Copies stay out of the prompt"
            )
            .accessibilityAddTraits(.isToggle)
            // The one state change that has to be legible in peripheral
            // vision, so it is the fastest.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: collecting)
    }

    /// Bright is "holding something that is going to the prompt" — which is
    /// also exactly when the badge has a number to show.
    private var clipBright: Bool { collecting && includedCount > 0 }

    /// The glyph, and — collecting off — the `.slash` idiom the board draws
    /// (there is no `paperclip.slash` symbol): one thin stroke falling
    /// left-to-right, with the paperclip knocked out where it crosses, so the
    /// slash never reads as a third clip stroke. The mask exists only for that
    /// knockout: a mask over the collecting glyph is a mask that can only cut
    /// it, which is exactly what a 13×13 box did to a 15×17 symbol — the
    /// shipped paperclip was clipped on every side.
    @ViewBuilder
    private var clipGlyph: some View {
        if collecting {
            clipSymbol
        } else {
            clipSymbol
                .mask {
                    ZStack {
                        Rectangle().fill(Color.white)
                        slash.stroke(
                            Color.white,
                            style: StrokeStyle(lineWidth: Self.clipKnockout, lineCap: .round)
                        )
                        .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                .overlay {
                    slash.stroke(style: StrokeStyle(lineWidth: Self.clipStroke, lineCap: .round))
                }
        }
    }

    /// The symbol in the box it is drawn in — the box the mask, the slash and
    /// the hover lift are all measured against.
    private var clipSymbol: some View {
        Image(systemName: "paperclip")
            .font(.system(size: Self.clipSide, weight: .regular))
            .frame(width: Self.clipBox.width, height: Self.clipBox.height)
    }

    private static let clipSide: CGFloat = 13

    /// The box the paperclip is drawn in: the symbol's own bounds at that
    /// point size, and a point of slack around them. Asked for rather than
    /// assumed — a 13pt `paperclip` measures 15×17, so the square box it was
    /// given cut the glyph rather than holding it.
    private static let clipBox: CGSize = {
        let bounds = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: clipSide, weight: .regular))?.size
            ?? CGSize(width: clipSide, height: clipSide)
        return CGSize(width: ceil(bounds.width) + clipSlack, height: ceil(bounds.height) + clipSlack)
    }()

    /// The slack, split around the glyph, so nothing it draws lands on the
    /// frame's edge.
    private static let clipSlack: CGFloat = 1

    /// The board hangs the badge 5pt above the glyph's box and 6pt past its
    /// right edge (`.bdg`: top −5, right −6). The overlay is measured against
    /// `clipBox`, which holds the glyph with half the slack on each side, so
    /// half of it comes back off both numbers — the badge sits on the glyph
    /// the board drew it on, not on the box that carries it.
    private static let badgeOffset = CGSize(width: 6 - clipSlack / 2, height: -5 + clipSlack / 2)

    /// The board's 24-unit proportions, read against the box the glyph
    /// actually got: 1.7/24 of it wide, over a 4.4/24 gap cut under it.
    private static let clipStroke: CGFloat = min(clipBox.width, clipBox.height) * 1.7 / 24
    private static let clipKnockout: CGFloat = min(clipBox.width, clipBox.height) * 4.4 / 24

    /// Corner to corner of that same box, inset 3.4/24 of it.
    private var slash: Path {
        let box = Self.clipBox
        let inset = CGSize(width: box.width * 3.4 / 24, height: box.height * 3.4 / 24)
        var path = Path()
        path.move(to: CGPoint(x: inset.width, y: inset.height))
        path.addLine(to: CGPoint(x: box.width - inset.width, y: box.height - inset.height))
        return path
    }

    /// The macOS badge idiom: a ring painted in the bubble's own surface
    /// colour cuts the badge out of the plate instead of letting it read as
    /// two shapes overlapping. Tabular, so the paperclip never moves as it
    /// counts, and read only — the list is already open, because pointing at
    /// the bubble opened it.
    private var badge: some View {
        Text("\(includedCount)")
            .font(LoreTheme.Typography.mono(9, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(LoreTheme.TextColor.primary)
            .padding(.horizontal, 3)
            .frame(minWidth: 13, minHeight: 13)
            .background(Capsule().fill(Color.white.opacity(0.20)))
            .background(Capsule().fill(LoreTheme.Surface.window).padding(-1.5))
            .offset(Self.badgeOffset)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: includedCount)
            .help("\(includedCount) in the prompt")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(includedCount) in the prompt")
    }

    private var includedCount: Int { items.filter(\.included).count }

    /// The letter is the key on the keyboard, so the letters teach the
    /// shortcut by standing there. `S` carries a tooltip and no click: it is a
    /// key you press, not a switch you flip.
    private func keycap(
        _ label: String, bright: Bool, help: String, action: (() -> Void)?
    ) -> some View {
        Text(label)
            .font(LoreTheme.Typography.mono(11, weight: .semibold))
            .foregroundStyle(bright ? LoreTheme.TextColor.primary : LoreTheme.TextColor.muted)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 17)
            // No hover lift: the fill is what says armed or not, and a
            // brightening dim key would read as the armed one.
            .background(
                RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                    .fill(Color.white.opacity(bright ? 0.12 : 0.04))
            )
            .contentShape(Rectangle())
            .onTapGesture { action?() }
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(help)
            .accessibilityAddTraits(action == nil ? .isStaticText : .isToggle)
    }

    private var gear: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(LoreTheme.TextColor.muted)
            .frame(width: 17, height: 17)
            .loreHoverFill(cornerRadius: LoreTheme.Radius.button)
            .contentShape(Rectangle())
            .onTapGesture { onOpenSettings?() }
            .help("Settings")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Settings")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - The list, opened

    /// One group: every row the same height and the same three columns — the
    /// picture (or the quote mark standing in the same box), the item's first
    /// words on one line, and the moment it belongs to.
    private var itemList: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    LoreTheme.Surface.line.frame(height: 1)
                }
                itemRow(item)
            }
        }
        // The bottom of the same shape (#201): no card, no chrome of its own,
        // and exactly the top row's width — the list contributes nothing to
        // how wide the bubble is, and then stretches to all of it.
        .padding(.vertical, 4)
        .frame(width: topRowWidth > 0 ? topRowWidth : nil)
    }

    private func itemRow(_ item: DictationItemChip) -> some View {
        HStack(spacing: 9) {
            leadingSlot(item)
            Text(item.kind == .image ? "Screenshot" : item.preview)
                .font(.system(size: 12.5))
                .foregroundStyle(LoreTheme.TextColor.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(!item.included)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(elapsed(item.seconds))
                .font(LoreTheme.Typography.mono(11))
                .monospacedDigit()
                .foregroundStyle(LoreTheme.TextColor.faint)
                // 32 points held four characters, so `17:29` broke after
                // `17:2` and took the row's height with it (#192). One width
                // for the whole column, sized for the latest moment in it.
                .fixedSize()
                .frame(width: momentColumnWidth, alignment: .trailing)
        }
        // The row's own left edge is the bubble's: same 20 as the top row.
        .padding(.horizontal, 20)
        .frame(height: 38)
        // Off is drawn, not only spoken: the whole row dims, words struck
        // through, so the state is legible without colour.
        .opacity(item.included ? 1 : 0.42)
        .contentShape(Rectangle())
        .loreHoverFill()
        .onTapGesture { onToggleItem?(item.id) }
        .help(item.included ? "In the prompt" : "Left out")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.included ? "In the prompt" : "Left out")
        .accessibilityAddTraits(.isToggle)
    }

    @ViewBuilder
    private func leadingSlot(_ item: DictationItemChip) -> some View {
        if let thumbnail = item.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 33, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(LoreTheme.Surface.card3)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                )
                .overlay(
                    Image(systemName: "quote.opening")
                        .font(.system(size: 11))
                        .foregroundStyle(LoreTheme.TextColor.muted)
                )
                .frame(width: 33, height: 26)
        }
    }

    /// One width for the moment column: what the latest item in the list needs.
    /// Every row the same, so the moments line up under each other.
    private var momentColumnWidth: CGFloat {
        elapsedWidth(items.map(\.seconds).max() ?? 0, size: 11)
    }

    private var statusGroup: some View {
        HStack(spacing: 10) {
            Circle()
                // No-signal keeps its distinct dimmed look (not a token color
                // — it must read as "not recording red").
                .fill(noSignal ? Color.white.opacity(0.3) : LoreTheme.Accent.red)
                .frame(width: 8, height: 8)
                .help("Recording")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording")
            if lockEnabled { lockGlyph }
            waveform
                .help("Your voice level")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Your voice level")
            if noSignal {
                Text("No signal from microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LoreTheme.TextColor.muted)
            } else {
                Text(elapsed(recordingSeconds))
                    .font(LoreTheme.Typography.mono(13))
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .monospacedDigit()
                    // The panel grows; the number does not break. With a mode
                    // armed beside it, a 19-minute dictation showed `19` over
                    // `:3` — the panel was sized to the smallest its content
                    // could be pressed into (#192, `resizeToContent`). Fixed
                    // size refuses the squeeze; the template width keeps a
                    // digit change from shifting everything beside it.
                    .fixedSize()
                    .frame(minWidth: elapsedWidth(recordingSeconds, size: 13), alignment: .leading)
                    // Two sentences, because the second one is the answer.
                    .help("Dictate as long as you like. Audio is saved as you speak.")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Dictate as long as you like. Audio is saved as you speak.")
            }
            if bluetoothRedirected {
                Group {
                    if showBluetoothInfo {
                        Text("Using laptop mic — AirPods mic compresses audio below what speech recognition needs")
                            .font(LoreTheme.Typography.meta)
                            .foregroundStyle(LoreTheme.TextColor.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Image(systemName: "laptopcomputer.and.arrow.down")
                            .font(.system(size: 11))
                            .foregroundStyle(LoreTheme.TextColor.muted)
                    }
                }
                .onTapGesture { showBluetoothInfo.toggle() }
                .onHover { hovering in showBluetoothInfo = hovering }
            }
        }
    }

    /// The lock, both ways round (#201). It stands in the bubble from the
    /// first second — an open shackle is what tells someone holding Fn that
    /// they can let go — and clicking it is the Space key: it locks, and while
    /// locked it ends the dictation the way Fn does.
    private var lockGlyph: some View {
        Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
            .font(.system(size: 11))
            .foregroundStyle(isLocked ? LoreTheme.TextColor.primary : LoreTheme.TextColor.muted)
            .frame(width: 15, height: 15)
            .loreHoverFill(cornerRadius: LoreTheme.Radius.button)
            .contentShape(Rectangle())
            .onTapGesture { onToggleLock?() }
            .help(lockHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lockHelp)
            .accessibilityAddTraits(.isToggle)
    }

    private var lockHelp: String {
        isLocked
            ? "Locked, hands free \u{2014} press Fn to stop"
            : "Space locks recording, hands free"
    }

    /// Shared Lore waveform while live; the no-signal state keeps its distinct
    /// flat dimmed bars. Fixed 18pt frame preserves the pre-Stage-H panel
    /// height (`.fixedSize()` sizing is load-bearing — see the manager).
    private var waveform: some View {
        Group {
            if noSignal {
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 2, height: 4)
                    }
                }
            } else {
                LoreLiveWaveform(level: audioLevel)
            }
        }
        .frame(height: 18)
    }

    // MARK: - Status rows (processing, downloading, done, error)

    private var processingContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Processing...")
                .font(LoreTheme.Typography.body)
                .foregroundStyle(LoreTheme.TextColor.primary)
        }
    }

    private func statusRow(icon: String, iconColor: Color = LoreTheme.TextColor.muted, text: String, wrap: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.system(size: 14))
            // Errors can carry a longer message — wrap at a capped width instead of stretching
            // the panel into one wide line. The panel is `.fixedSize()`, so the width must be
            // constrained BEFORE `.fixedSize(vertical:)` measures height — otherwise the text is
            // measured at unbounded width (one line), that 1-line height is locked in, and the
            // later wrap clips vertically. A definite `.frame(width:)` is proposed to the Text so
            // it wraps; `fixedSize(vertical:)` then reports the true multi-line height the panel
            // grows to. No line limit on wrap so the full message always shows.
            Text(text)
                .font(LoreTheme.Typography.body)
                .foregroundStyle(LoreTheme.TextColor.primary)
                .lineLimit(wrap ? nil : 1)
                .multilineTextAlignment(.leading)
                .frame(width: wrap ? 260 : nil, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Upgrade

    @ViewBuilder
    private var upgradeContent: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                // A failed cleanup/translate must not render as success (#50):
                // red row states what happened; C/T stay available as retry.
                if let error = lastError {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LoreTheme.Accent.red)
                        .font(.system(size: 12))
                    Text(error)
                        .font(LoreTheme.Typography.body)
                        .foregroundStyle(LoreTheme.TextColor.primary)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LoreTheme.Accent.green)
                        .font(.system(size: 12))
                    Text("Pasted")
                        .font(LoreTheme.Typography.body)
                        .foregroundStyle(LoreTheme.TextColor.muted)
                }

                LoreTheme.Surface.line
                    .frame(width: 1, height: 14)

                if !hideCleanupButton {
                    upgradeButton(label: "C", subtitle: "Cleanup") { onUpgrade?(.cleanup) }
                }
                upgradeButton(label: "T", subtitle: "Translate") { onUpgrade?(.translate) }
                // Fn+K (#122): filled while the entry is flagged — the bare-K
                // press's visual feedback; tap toggles like the keycap does.
                upgradeButton(label: "K", subtitle: "Operator",
                              highlighted: operatorAddressed) { onOperatorToggle?() }
            }

            if let countdown = upgradeCountdown, countdown > 0 {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: geo.size.width * (countdown / DictationCoordinator.upgradePanelDuration))
                }
                .frame(height: 2)
            }
        }
    }

    @ViewBuilder
    private func upgradeButton(
        label: String, subtitle: String, highlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            if showUpgradeKeycaps {
                Text(label)
                    .font(LoreTheme.Typography.mono(11, weight: .semibold))
                    .foregroundStyle(highlighted ? LoreTheme.TextColor.primary : LoreTheme.TextColor.muted)
            }
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LoreTheme.TextColor.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            // Design `.ibtn` fill — same white .07 as LoreIconButton; the
            // highlighted (flagged) state fills with the selection accent.
            RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                .fill(highlighted ? LoreTheme.Accent.blue.opacity(0.35) : Color.white.opacity(0.07))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

// MARK: - Model

@Observable
@MainActor
final class DictationIndicatorModel {
    var state: DictationState = .idle
    var audioLevel: Float = 0
    var isLocked = false
    var pendingMode: UpgradeAction?
    var operatorAddressed = false
    var recordingSeconds: Int = 0
    var showUpgradeButtons = false
    var hideCleanupButton = false
    var showUpgradeKeycaps = true
    var lockEnabled = true
    var upgradeCountdown: Double?
    var lastError: String?
    var bluetoothRedirected = false
    var noSignal = false
    var items: [DictationItemChip] = []
    var collecting = true
    var screenshotsEnabled = true
    var onUpgrade: ((UpgradeAction) -> Void)?
    var onOperatorToggle: (() -> Void)?
    var onToggleItem: ((UUID) -> Void)?
    var onToggleLock: (() -> Void)?
    var onToggleCollecting: (() -> Void)?
    var onArmCleanup: (() -> Void)?
    var onArmTranslate: (() -> Void)?
    var onArmOperator: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Synchronous on purpose (#201): the panel's frame is set from the same
    /// layout pass that produced the size, so the window is never a frame
    /// behind the shape it holds.
    var onFrameChange: (@MainActor (PanelContentFrame) -> Void)?
}

/// SwiftUI wrapper that reads the observable model.
private struct DictationIndicatorHost: View {
    @State var model: DictationIndicatorModel

    var body: some View {
        DictationIndicatorView(
            state: model.state,
            audioLevel: model.audioLevel,
            isLocked: model.isLocked,
            pendingMode: model.pendingMode,
            operatorAddressed: model.operatorAddressed,
            recordingSeconds: model.recordingSeconds,
            showUpgradeButtons: model.showUpgradeButtons,
            hideCleanupButton: model.hideCleanupButton,
            showUpgradeKeycaps: model.showUpgradeKeycaps,
            lockEnabled: model.lockEnabled,
            upgradeCountdown: model.upgradeCountdown,
            lastError: model.lastError,
            bluetoothRedirected: model.bluetoothRedirected,
            noSignal: model.noSignal,
            items: model.items,
            collecting: model.collecting,
            screenshotsEnabled: model.screenshotsEnabled,
            onUpgrade: model.onUpgrade,
            onOperatorToggle: model.onOperatorToggle,
            onToggleItem: model.onToggleItem,
            onToggleLock: model.onToggleLock,
            onToggleCollecting: model.onToggleCollecting,
            onArmCleanup: model.onArmCleanup,
            onArmTranslate: model.onArmTranslate,
            onArmOperator: model.onArmOperator,
            onOpenSettings: model.onOpenSettings,
            onFrameChange: model.onFrameChange
        )
    }
}

// MARK: - Manager (dynamic sizing)

@MainActor
final class DictationIndicatorManager {
    private var panel: TopCenteredPanel<DictationIndicatorHost>?
    private var observationTask: Task<Void, Never>?
    /// Observable dictation state mirror; the shell reads `model.isLocked`
    /// for the Dictation nav live dot (SHELL-10).
    let model = DictationIndicatorModel()
    private var recordingStartDate: Date?
    /// One decode per collected image, not one per 50 ms poll (#192). Keyed by
    /// the item's id and emptied with the items themselves.
    private var thumbnails: [UUID: NSImage] = [:]
    func start(coordinator: DictationCoordinator, hotkeyManager: HotkeyManager) {
        guard let panel = TopCenteredPanel(
            content: DictationIndicatorHost(model: model), topInset: 8
        ) else { return }
        self.panel = panel

        // Wire up upgrade callback
        model.onUpgrade = { [weak coordinator] action in
            Task { @MainActor in
                await coordinator?.applyUpgradeByKey(action)
            }
        }
        model.onOperatorToggle = { [weak coordinator] in
            Task { @MainActor in
                coordinator?.toggleOperatorAddressedByKey()
            }
        }
        model.onToggleItem = { [weak coordinator] id in
            Task { @MainActor in
                coordinator?.toggleItem(id: id)
            }
        }
        // The lock glyph is the Space key (#201) — one path, one lock.
        model.onToggleLock = { [weak hotkeyManager] in
            Task { @MainActor in
                hotkeyManager?.toggleLockByClick()
            }
        }
        // `C`, `T` and `K` are the Fn+V / Fn+T / Fn+K chords, taken by pointer.
        model.onArmCleanup = { [weak coordinator] in
            Task { @MainActor in
                coordinator?.setPendingMode(.cleanup)
            }
        }
        model.onArmTranslate = { [weak coordinator] in
            Task { @MainActor in
                coordinator?.setPendingMode(.translate)
            }
        }
        model.onArmOperator = { [weak coordinator] in
            Task { @MainActor in
                coordinator?.toggleOperatorAddressed()
            }
        }
        // The paperclip and Settings → Copying are one switch with two faces
        // (#201): the click goes through the card's own store, so the section's
        // row moves with it and the door sees it live (#198).
        model.onToggleCollecting = { [weak coordinator] in
            Task { @MainActor in
                guard let settings = coordinator?.settings else { return }
                settings.setRichInput(.collect, !settings.richInput(.collect))
            }
        }
        // The gear names the section it belongs to and the shell fronts the
        // window (#198) — the one door, installed by the scene.
        model.onOpenSettings = { SettingsSection.open(.copying) }
        // The frame is set from the layout pass that produced the size, so the
        // window is exactly the shape SwiftUI is springing open (#201).
        model.onFrameChange = { [weak self] frame in
            self?.panel?.setContentFrame(frame)
        }

        // Poll coordinator state and push into model
        observationTask = Task { [weak self, weak coordinator, weak hotkeyManager] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let coordinator else { break }

                let newState = coordinator.state

                // Track recording duration from pre-buffer start (when audio actually begins)
                let isCapturing = newState == .recording || coordinator.isPreBuffering
                if isCapturing && self.recordingStartDate == nil {
                    self.recordingStartDate = Date()
                } else if !isCapturing {
                    self.recordingStartDate = nil
                }
                let newSeconds: Int
                if let start = self.recordingStartDate {
                    newSeconds = Int(Date().timeIntervalSince(start))
                } else {
                    newSeconds = 0
                }

                // Push to model
                self.model.state = newState
                self.model.audioLevel = coordinator.audioLevel
                self.model.isLocked = hotkeyManager?.isLocked ?? false
                self.model.pendingMode = coordinator.pendingCleanupMode
                self.model.operatorAddressed = coordinator.operatorAddressedDisplayed
                if newSeconds != self.model.recordingSeconds {
                    self.model.recordingSeconds = newSeconds
                }
                self.model.showUpgradeButtons = coordinator.isUpgradePanelVisible
                self.model.hideCleanupButton = coordinator.cleanupAlreadyApplied
                self.model.showUpgradeKeycaps =
                    coordinator.settings?.modifierUpgradeKeysEnabled ?? true
                self.model.lockEnabled = coordinator.settings?.modifierLockEnabled ?? true
                self.model.upgradeCountdown = coordinator.upgradeCountdown
                self.model.lastError = coordinator.lastError
                self.model.bluetoothRedirected = coordinator.bluetoothMicRedirected
                self.model.noSignal = coordinator.noSignal
                self.model.collecting = RichInputSettings.isOn(.collect)
                self.model.screenshotsEnabled = RichInputSettings.screenshotsEnabled
                let chips = self.chips(for: coordinator.items)
                if chips != self.model.items { self.model.items = chips }

                // Keep CGEvent tap flag in sync
                hotkeyManager?.updateUpgradeShowingFlag(coordinator.isUpgradePanelVisible)

                // Show/hide and resize
                if newState == .idle {
                    self.panel?.hide()
                } else {
                    self.panel?.show()
                }
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        panel?.hide()
    }

    /// The list's own view of the coordinator's items (#192). An image is
    /// decoded once and kept until the items are gone; everything else is
    /// derived on the spot.
    private func chips(for items: [DictationItem]) -> [DictationItemChip] {
        guard !items.isEmpty else {
            if !thumbnails.isEmpty { thumbnails.removeAll() }
            return []
        }
        return items.map { item in
            var thumbnail = thumbnails[item.id]
            if thumbnail == nil, item.kind == .image, let data = item.imageData {
                thumbnail = NSImage(data: data)
                thumbnails[item.id] = thumbnail
            }
            return DictationItemChip(
                id: item.id,
                kind: item.kind,
                preview: DictationItemChip.quoted(item.text ?? item.path ?? ""),
                thumbnail: thumbnail,
                seconds: max(0, Int(item.offset)),
                included: item.included
            )
        }
    }
}
