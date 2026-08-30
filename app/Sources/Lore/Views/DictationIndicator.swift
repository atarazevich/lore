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

/// The two moments of a bubble drag the window has to hear about (#213). No
/// translation rides along: the window reads the pointer off the screen itself,
/// because a translation measured in the window's own space is a translation
/// that collapses to nothing as the window follows it.
enum BubbleDrag: Sendable { case moved, ended }

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

/// One letter in the recording bubble's rail (#201) — the key on the keyboard,
/// which is why the letters teach the shortcut by standing there.
enum BubbleRailLetter: String, CaseIterable, Sendable {
    case cleanup = "C"
    case translate = "T"
    case operatorSend = "K"
    case screenshot = "S"
}

/// What order the letters stand in (#204).
///
/// Whatever is armed already stands in the bubble at rest, so opening may only
/// append to the right of it: a letter that was on screen before the pointer
/// arrived may not move. So the armed letters come first, in `C T K`, and
/// whatever is not armed follows in `T K S`. An unarmed `C` never appears —
/// an unarmed cleanup letter has nothing to say — and `S` is only ever in the
/// tail, because it names a setting rather than something armed for this
/// dictation.
///
/// A fixed `C T K S` was the first answer and it broke the invariant for a lone
/// armed `K`: opening would insert `T` ahead of it, and the `K` the user was
/// reading would shift right. Ordering by what is armed is what makes the
/// closed rail a prefix of the open one for every armed set, which is the
/// property `RecordingBubbleRailTests` checks.
enum BubbleRail {
    /// `C T K` — the order armed letters are read in.
    static let armedOrder: [BubbleRailLetter] = [.cleanup, .translate, .operatorSend]
    /// `T K S` — what opening appends, for whatever is not armed already.
    static let restOrder: [BubbleRailLetter] = [.translate, .operatorSend, .screenshot]

    /// - Parameter open: the bubble is widened. Closed, only the armed letters
    ///   are drawn at all.
    static func letters(armed: Set<BubbleRailLetter>, open: Bool) -> [BubbleRailLetter] {
        let standing = armedOrder.filter(armed.contains)
        guard open else { return standing }
        return standing + restOrder.filter { !armed.contains($0) }
    }
}

// MARK: - The bubble's own tooltip (#207)

/// Which element of the bubble the pointer is on. Identity rather than the
/// line it carries, so the element the pointer *left* can only take its own
/// line down: SwiftUI may report the neighbour's arrival before the departure,
/// and a blind clear there would swallow the line that just replaced it.
private enum BubbleTipOwner: Hashable {
    case dot, lock, waveform, timer, clip, count, gear
    case letter(BubbleRailLetter)
    case row(UUID)
}

/// One line of the copy table, and whose it is.
private struct BubbleTip: Equatable {
    let owner: BubbleTipOwner
    let text: String
}

/// The canvas's own coordinate space, so every element reports the pointer in
/// the numbers the card is placed in.
private let bubbleTipSpace = "lore.bubble.tip"

extension View {
    /// What every element carrying a line in the copy table wears (#207). It
    /// reports the pointer and nothing else — no size, no padding, no
    /// background — so a tooltip can never move anything in the shape (#204).
    ///
    /// Continuous, and in the canvas's space, because the card is drawn under
    /// whatever is being pointed at: the position arrives with the crossing
    /// into the element and then follows the pointer across it.
    fileprivate func bubbleTip(
        _ owner: BubbleTipOwner, _ text: String,
        hovered: Binding<BubbleTip?>, pointer: BubblePointer
    ) -> some View {
        onContinuousHover(coordinateSpace: .named(bubbleTipSpace)) { phase in
            switch phase {
            case .active(let location):
                pointer.x = location.x
                // Every mouse move lands here; only a real arrival is a change
                // the shape has to be re-rendered for.
                let arrived = BubbleTip(owner: owner, text: text)
                if hovered.wrappedValue != arrived { hovered.wrappedValue = arrived }
            case .ended:
                // Its own line only: SwiftUI may report the neighbour's
                // arrival before this departure.
                if hovered.wrappedValue?.owner == owner { hovered.wrappedValue = nil }
            }
        }
    }
}

/// The tooltip the bubble draws for itself (#207), to the board's F6: one line
/// on a popover card under the whole shape, clear of the list, pointing at
/// whatever the pointer is on.
///
/// Lore draws it because AppKit will not. `.help()` does not put the string on
/// the view (`NSView.toolTip` stays nil) — it registers an AppKit tooltip rect,
/// and `NSToolTipManager` only ever shows one for a window of the *active*
/// application. This panel is a `.nonactivatingPanel` ordered front, never made
/// key (`canBecomeKey` is false), floating over whichever app is being dictated
/// into; its window had never asked for the mouse-moved stream that manager
/// tracks with either (`acceptsMouseMovedEvents` was false — `OverlayPanel`
/// now sets it, because this card follows the pointer). Both were read off the
/// panel. And AppKit's delay is the system's ~1.5 s where the board asks for
/// 300 ms, so `.help` could not have delivered this even where it does show.
///
/// Not private: `gap` and `height` are the room the canvas keeps under the
/// shape, and `RecordingBubbleRenderTests` reads them to check the card lands
/// inside it (the same reason `clipBox` is not private).
struct BubbleTipCard: View {
    let text: String
    /// Where the pointer was when the line appeared, in the shape's own space.
    let pointerX: CGFloat
    /// The canvas the card must stay inside — a line for the gear may not hang
    /// off the right edge of the window.
    let canvasWidth: CGFloat

    /// The board's card: 9 and 5 inside it, 11.5 text, and 222 as the widest it
    /// may be — a cap now, not the width (#212). Every card was 222 across
    /// whatever it held, so `Settings` was drawn on a card two thirds empty.
    static let maxWidth: CGFloat = 222
    private static let fontSize: CGFloat = 11.5
    private static let padY: CGFloat = 5
    private static let padX: CGFloat = 9
    private static let arrowSide: CGFloat = 8

    /// Two lines of that face, the card's own padding, and a couple of points
    /// of slack around its half-point border. Only the cap can put a line on a
    /// second row, and `lineLimit(2)` is what makes this a ceiling and not an
    /// estimate: it is the room the canvas keeps under the shape whatever the
    /// line turns out to be, so no line appearing ever resizes the window.
    static let height: CGFloat = {
        let font = NSFont.systemFont(ofSize: fontSize)
        return ceil(font.ascender - font.descender + font.leading) * 2 + 2 * padY + 3
    }()

    /// The board hangs the card 51 under a 43-tall row.
    static let gap: CGFloat = 8

    /// What the canvas keeps under the shape whether a line is showing or not,
    /// so one appearing never resizes the window (#204).
    static var room: CGFloat { gap + height }

    /// Where the card's left edge lands, given the width SwiftUI gave the line:
    /// centred on what is being pointed at, pushed back inside the canvas.
    ///
    /// Taken during layout rather than from a width measured beforehand — the
    /// card is as wide as the line SwiftUI laid out, and asking a second text
    /// engine what that will be is a guess that needs a fudge factor to survive.
    private func leading(cardWidth: CGFloat) -> CGFloat {
        min(max(pointerX - cardWidth / 2, 0), max(canvasWidth - cardWidth, 0))
    }

    /// The arrow stays on what is being pointed at even where the card could
    /// not follow, and clear of the card's own corners — which, on a card as
    /// narrow as `Settings`, is the middle of it.
    private func arrowX(cardWidth: CGFloat) -> CGFloat {
        let margin = LoreTheme.Radius.popover + Self.arrowSide
        return min(
            max(pointerX - leading(cardWidth: cardWidth), margin),
            max(margin, cardWidth - margin)
        )
    }

    var body: some View {
        // The cap reaches the line as a *proposal*, and the card is the size the
        // line answers with. Nothing here measures text.
        CardWidthCap(maxWidth: Self.maxWidth - 2 * Self.padX) {
            Text(text)
                .font(.system(size: Self.fontSize))
                .foregroundStyle(LoreTheme.TextColor.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
            // No shadow: the bubble this hangs under carries none either
            // (`TopCenteredPanel` sets `hasShadow = false`, the shape draws
            // none), and one here would need window room the canvas would have
            // to reserve and the user would never see.
            .lorePopoverChrome(
                inset: Self.padY, horizontalInset: Self.padX,
                stroke: LoreTheme.Shadow.windowRim, strokeWidth: 0.5, shadow: false
            )
            // The arrow stands on the card at `arrowX`, which is a fact about
            // the card's own width — so the card carries it as an alignment
            // guide and the overlay reads it off, rather than either of them
            // being told a number from outside.
            .alignmentGuide(.bubbleTipArrow) { arrowX(cardWidth: $0.width) }
            .overlay(alignment: Alignment(horizontal: .bubbleTipArrow, vertical: .top)) { arrow }
            // And the same for where the card itself stands: its leading guide
            // is pushed right by `leading`, inside a box the width of the
            // canvas, so the placement is done with the width SwiftUI settled on.
            .alignmentGuide(.leading) { -leading(cardWidth: $0.width) }
            .frame(width: canvasWidth, alignment: .leading)
            // It explains what the pointer is on; it is never what the pointer
            // is on. A card that answered the mouse would be a click the app
            // underneath the canvas never receives.
            .allowsHitTesting(false)
            // The line is the element's own VoiceOver name already; read here
            // it would be read twice.
            .accessibilityHidden(true)
    }

    /// The board's arrow: a square on the card's top edge, turned 45°, carrying
    /// the rim on the two sides that end up facing out.
    private var arrow: some View {
        Rectangle()
            .fill(LoreTheme.Surface.popover)
            .overlay {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: Self.arrowSide))
                    path.addLine(to: .zero)
                    path.addLine(to: CGPoint(x: Self.arrowSide, y: 0))
                }
                .stroke(LoreTheme.Shadow.windowRim, lineWidth: 0.5)
            }
            .frame(width: Self.arrowSide, height: Self.arrowSide)
            .rotationEffect(.degrees(45))
            // Its own centre is where the guide puts it; only the lift onto the
            // card's top edge is left to say.
            .offset(y: -Self.arrowSide / 2 - 0.5)
    }
}

/// Proposes at most `maxWidth` to the one view it holds, and is exactly the
/// size that comes back (#212).
///
/// `frame(maxWidth:)` cannot do this either way round. Handed a width it takes
/// that width and clamps it, so every card is the full 222 whatever the line is
/// — the thing being undone. Handed none it clamps its own size without passing
/// the cap on, so a long line stays on one row and runs out of the plate
/// (measured: the over-cap line drew a 33 pt card where two rows are 46). The
/// cap has to arrive at the text as a proposal, and the card has to be what the
/// text answers with.
private struct CardWidthCap: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: capped(proposal))
    }

    /// Whatever is going, but never more than the cap — and the cap itself when
    /// nothing is proposed at all, which is what a `fixedSize` ancestor hands
    /// down.
    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height)
    }
}

/// Where the tooltip card's arrow stands on it. A custom guide, because the
/// only view that knows the number is the card itself, during its own layout:
/// the arrow is an overlay on it and reads the guide off it (#212).
private extension HorizontalAlignment {
    enum BubbleTipArrow: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
            dimensions[HorizontalAlignment.center]
        }
    }

    static let bubbleTipArrow = HorizontalAlignment(BubbleTipArrow.self)
}

/// What an offscreen render is handed in place of the motion it cannot run
/// (#204, #207, #210).
///
/// An `ImageRenderer` runs no tasks and no animations, so a rendered bubble
/// draws its rail at zero opacity behind a fade that never starts, no tooltip at
/// all behind a 300 ms wait that never ends, and a paperclip at rest — and a
/// comparison of any of those would be a comparison of nothing. Each field is
/// one such thing, held at the state the user sees.
///
/// Only `RecordingBubbleRenderTests` sets this; nothing in the app does. It is
/// one value rather than three flags because it was three flags, and each of
/// them had to be threaded through the model, the host and the view by hand.
struct BubbleRenderPreview: Equatable {
    /// The rail as it stands 120 ms in, past its fade.
    var railVisible = false
    /// The line the pointer would have waited out its 300 ms for.
    var tip: String?
    /// The paperclip at the top of a bounce: the symbol drawn larger than the
    /// effect ever grows it, inside the same fixed box — which is the whole of
    /// what the invariant is about, since whatever the glyph does inside that
    /// box, nothing beside it moves.
    var clipBouncing = false
}

/// The pointer's place inside the shape, deliberately off the view's state:
/// it changes with every mouse move, and a `@State` write per move would
/// re-render the bubble — probes and all — for a number that is only read when
/// a line appears.
@MainActor
private final class BubblePointer {
    var x: CGFloat = 0
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
    /// The hotkey is being held inside a locked recording (#205). It opens the
    /// bubble exactly as the pointer does, for as long as it is held — which is
    /// the moment Fn+T, Fn+K and Fn+S are pressed, so the rail is on screen when
    /// those chords apply.
    var held = false
    @State private var showBluetoothInfo = false
    /// How many items have arrived during this dictation (#210). Not a count of
    /// the list — a number that changes once per arrival, which is what the
    /// symbol effect watches; what the list holds is `items`.
    @State private var arrivals = 0
    /// The pointer is on the bubble. Everything the bubble can show — the key
    /// rail and the list — is this one state (#201): pointing at the shape
    /// widens it and, if anything has been collected, grows it downward.
    /// Nothing is clicked to open anything.
    ///
    /// One hover region for the whole shape, and a grace before it closes:
    /// hovering the rows themselves was never enough, because the way down to
    /// them crossed padding that belongs to no row, and a list that closed
    /// there shut and reopened under the moving pointer (#192).
    @State private var pointerExpanded = false
    @State private var pointerOnBubble = false
    /// The letters and the gear are readable only once the shape has room for
    /// them, so they fade in behind the widening (#201 motion table).
    @State private var railFadedIn = false
    /// What an offscreen render is handed in place of what it cannot run
    /// (`BubbleRenderPreview`). Only `RecordingBubbleRenderTests` sets it;
    /// nothing in the app does.
    var renderPreview = BubbleRenderPreview()
    private var railVisible: Bool { railFadedIn || renderPreview.railVisible }
    /// The element the pointer is on, and the line it carries (#207).
    @State private var hoveredTip: BubbleTip?
    /// The line actually on screen — the same value, 300 ms later.
    @State private var shownTip: BubbleTip?
    /// Where the pointer was at that moment. Frozen with the line, so the card
    /// does not drift under a pointer wandering inside one element.
    @State private var tipPointerX: CGFloat = 0
    /// A line has already appeared during this visit to the shape, so the next
    /// element the pointer moves to swaps in with no delay of its own. Cleared
    /// when the pointer leaves the shape, and by a click.
    @State private var tipWarm = false
    @State private var pointer = BubblePointer()
    /// The open shape's size, measured off a copy of it that is never drawn —
    /// the window's own size while a dictation records (#204).
    @State private var canvasSize: CGSize = .zero
    /// The resting row's width, measured the same way. It is what the window is
    /// centred on, and it cannot be read off the visible shape once that shape
    /// has widened.
    @State private var restingRowWidth: CGFloat = 0
    /// Open, by pointer or by key (#205). The 300 ms grace on the way out is the
    /// pointer's alone: it exists for a pointer travelling down to a row, and a
    /// key that has been let go is not travelling anywhere.
    private var expanded: Bool { pointerExpanded || held }
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
    /// The shape is being dragged (#213): where the user puts the bubble is
    /// where it stays, for the rest of this recording and for the next one.
    var onDrag: ((BubbleDrag) -> Void)?
    /// The shape measures the window it wants (#204, `TopCenteredPanel`): the
    /// canvas it may grow inside while recording, and `nil` for every other
    /// state, where the window simply fits what it holds.
    var onCanvasChange: (@MainActor (BubbleCanvas?) -> Void)?

    var body: some View {
        content
            .fixedSize()
            // Coming back cancels the close — the task is keyed on being
            // outside, and on the recording still being there to widen for.
            .task(id: [pointerOnBubble, canExpand]) { await followPointer() }
            .task(id: [expanded, canExpand]) { await followExpansion() }
            .task(id: hoveredTip) { await followTip() }
            .animation(expanded ? widenAnimation : closeAnimation, value: expanded)
            .animation(railFade, value: railVisible)
            .onChange(of: canvas, initial: true) { _, measured in
                // A canvas that has not been laid out yet is not a report: the
                // window keeps the frame it has rather than fitting itself to a
                // measurement that does not exist.
                guard let measured else { return }
                onCanvasChange?(measured)
            }
            // An item landing bounces the paperclip once (#210). A row switched
            // off and on changes `items` too and nothing arrived, so the trigger
            // is a new id and not a new list — and the end of a dictation, which
            // empties it, is not an arrival either.
            .onChange(of: items) { previous, current in
                guard Self.itemArrived(from: previous, to: current) else { return }
                arrivals += 1
            }
            .onChange(of: canExpand, initial: true) { _, expandable in
                // Processing, done, the upgrade panel, an error: not a canvas.
                // The window goes back to fitting its content and centring it,
                // and the measurements leave with the shape they were taken
                // from — the next recording measures its own rather than
                // opening inside the last one's.
                guard !expandable else { return }
                canvasSize = .zero
                restingRowWidth = 0
                onCanvasChange?(nil)
            }
            .environment(\.colorScheme, .dark)
    }

    /// The bubble, and — while a dictation records — the transparent canvas it
    /// hangs in (#204).
    ///
    /// The canvas is a clear rectangle of the size the probes measured, with the
    /// bubble in its top-leading corner, so everything the shape gains it gains
    /// into the margin and nothing that was on screen at rest moves.
    ///
    /// Until the probes have reported, the canvas is nothing at all and this is
    /// just the bubble — so the window's own fallback fits and centres the
    /// resting bubble, which is exactly where the canvas is about to put it. The
    /// first frame of a recording has nowhere to jump from.
    @ViewBuilder
    private var content: some View {
        if canExpand {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: canvasWithTip.width, height: canvasWithTip.height)
                bubble
                if let tip = visibleTip {
                    BubbleTipCard(
                        text: tip.text, pointerX: tipPointerX, canvasWidth: canvasWithTip.width
                    )
                    // Offset, so the card contributes its own size to the
                    // canvas and not its position: the room below the shape is
                    // the clear rectangle's, kept there whether a line is
                    // showing or not.
                    .offset(y: canvasSize.height + BubbleTipCard.gap)
                    .transition(.opacity)
                }
            }
            .coordinateSpace(.named(bubbleTipSpace))
            // Measured, never drawn, and contributing nothing to the layout:
            // a background is proposed the primary view's size and the probes
            // ignore the proposal, so they can be bigger than what they measure
            // for without becoming it.
            .background(alignment: .topLeading) { probes }
        } else {
            bubble
        }
    }

    /// What the window is while a dictation records (#204). Nil until both
    /// probes have been laid out, and for every state that is not the recording
    /// bubble.
    private var canvas: BubbleCanvas? {
        guard canExpand, canvasWithTip.width > 0, restingRowWidth > 0 else { return nil }
        return BubbleCanvas(size: canvasWithTip, restingWidth: restingRowWidth)
    }

    /// The window while a dictation records: the shape's own canvas with the
    /// tooltip's room kept under it (#207) and at least the widest a card may
    /// be across, so a line appearing never resizes the window and never hangs
    /// off its edge. Zero until the probes have reported, which is what leaves the
    /// first frame of a recording to the window's own fitting (#204).
    private var canvasWithTip: CGSize {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        return CGSize(
            width: max(canvasSize.width, BubbleTipCard.maxWidth),
            height: canvasSize.height + BubbleTipCard.room
        )
    }

    /// Something in the list was not in it a moment ago (#210). Not private:
    /// the rule is the whole of the bounce's trigger, and
    /// `RecordingBubbleClipTests` reads it.
    static func itemArrived(from previous: [DictationItemChip], to current: [DictationItemChip]) -> Bool {
        let known = Set(previous.map(\.id))
        return current.contains { !known.contains($0.id) }
    }

    /// What the bounce watches. Under Reduce Motion it is pinned, so the value
    /// never changes and the glyph never bounces — while the count goes on
    /// changing, because the count's own animation is already nil there and a
    /// `numericText` transition with no animation is a swap (#210).
    private var bounceTrigger: Int { reduceMotion ? 0 : arrivals }

    /// The line on screen — or the one an offscreen render was handed.
    private var visibleTip: BubbleTip? {
        shownTip ?? renderPreview.tip.map { BubbleTip(owner: .timer, text: $0) }
    }

    /// One shape: the row, and — when something has been collected — the list
    /// at the bottom of the same surface (#201). Three floating surfaces for
    /// one panel read as three things; this is one.
    private func shape(open: Bool, measuring: Bool, listWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            paddedRow(open: open, measuring: measuring)
            if showsItemList(open: open) {
                LoreTheme.Surface.line.frame(height: 1)
                itemList(width: listWidth)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func paddedRow(open: Bool, measuring: Bool) -> some View {
        panel(open: open, measuring: measuring)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
    }

    /// The bubble the user sees, and the only part of the canvas that answers a
    /// pointer — the margin around it belongs to whatever window is underneath.
    private var bubble: some View {
        shape(open: expanded, measuring: false, listWidth: topRowWidth)
            .fixedSize()
            .contentShape(RoundedRectangle(cornerRadius: 12))
            // On the shape, past its own content shape, so the transparent
            // margin is not a handle (#213) — and after the keycaps, the rows
            // and the gear have theirs, so a click still belongs to whatever it
            // landed on.
            .gesture(dragGesture)
            .onHover { inside in
                pointerOnBubble = inside
                // Leaving the shape ends the visit the tooltip's hand-off
                // belongs to (#207); crossing a gap inside it does not.
                if !inside { tipWarm = false }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { topRowWidth = $0 }
    }

    /// The canvas, measured from the shape rather than guessed at (#204).
    ///
    /// The open shape is laid out here too and never drawn, so the window is
    /// already the size the shape may need before the pointer arrives — which is
    /// what lets the arrival change nothing about the window. The resting row is
    /// measured beside it because that is what the window is centred on, and it
    /// cannot be read off the visible shape once that shape has widened: reading
    /// it there is what 3900a37 did, and it made the answer depend on the order
    /// of a geometry callback against a state flip.
    ///
    /// They are laid out and never drawn, and they draw the waveform as a clear
    /// box of its exact width rather than running a `TimelineView` of their own,
    /// so a recording still has one animation in it and not three. Nothing here
    /// can churn the window either: every size in a measuring copy is fixed.
    private var probes: some View {
        ZStack(alignment: .topLeading) {
            shape(open: true, measuring: true, listWidth: topRowWidth)
            paddedRow(open: false, measuring: true)
                // Once per recording (#204): the window is centred on the resting
                // row it started with, so every later reading is computed and
                // thrown away. Cleared with the rest when the recording ends.
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
                    if restingRowWidth == 0 { restingRowWidth = width }
                }
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: \.size) { canvasSize = $0 }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Hover, and the motion it drives

    /// A recording is what the rail and the list belong to; an error row is
    /// not something to widen.
    private var canExpand: Bool { state == .recording && lastError == nil }

    /// There is something collected, and a recording to show it for. With
    /// collecting off nothing is in the prompt, so there is no list either —
    /// turning it back on brings both back.
    private func showsItemList(open: Bool) -> Bool {
        canExpand && open && collecting && !items.isEmpty
    }

    /// The board's timing (#207): a line appears 300 ms after the pointer
    /// arrives at an element, and — while one is already up — the next element
    /// swaps in with none. It goes the moment the pointer leaves, or clicks.
    private func followTip() async {
        guard let hovered = hoveredTip, canExpand else {
            // The elements are separated by real gaps — the row's 6, 9 and 10
            // point spacings and its dividers — and crossing one reports the
            // departure before the arrival. So a line already up is held for a
            // moment: a neighbour arriving inside that cancels this task and
            // swaps straight into it, which is the board's "no delay between
            // neighbours". Leaving the shape is not a gap — `pointerOnBubble`
            // is already false by the time this runs — and hides at once.
            if shownTip != nil, pointerOnBubble, canExpand {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            withAnimation(tipFade) { shownTip = nil }
            // The hand-off was not taken, so the next line waits its own 300 ms.
            tipWarm = false
            return
        }
        if !tipWarm {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        tipWarm = true
        tipPointerX = pointer.x
        withAnimation(tipFade) { shownTip = hovered }
    }

    /// A click takes the line down and spends the warmth with it — the next
    /// one waits its 300 ms again.
    private func hideTip() {
        hoveredTip = nil
        tipWarm = false
    }

    /// Dragging the bubble by its own shape (#213). Before #204's fixed canvas
    /// the window was movable by its background and the gesture came free with
    /// it; the canvas is mostly transparent margin, so that had to go — a window
    /// draggable by its background answers mouse-downs the app underneath never
    /// receives.
    ///
    /// `minimumDistance` is the whole of what keeps a click a click: a drag
    /// gesture that cannot be recognised before the pointer has travelled cannot
    /// take a keycap's click, and a keycap's click cannot become a drag. Past
    /// that distance the gesture is the one that has claimed the sequence, so
    /// the control the press began on does not fire on release.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: Self.dragThreshold)
            .onChanged { _ in
                // A line under a shape that is moving points at nothing.
                if hoveredTip != nil || tipWarm { hideTip() }
                onDrag?(.moved)
            }
            .onEnded { _ in onDrag?(.ended) }
    }

    private static let dragThreshold: CGFloat = 4

    private func followPointer() async {
        guard canExpand else {
            pointerExpanded = false
            railFadedIn = false
            hoveredTip = nil
            tipWarm = false
            return
        }
        guard !pointerOnBubble else {
            pointerExpanded = true
            return
        }
        // The grace absorbs the hover that blinks off while the shape moves
        // under a pointer that never did, and lets the pointer travel down to
        // a row without the bubble shutting under it.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        pointerExpanded = false
    }

    private func followExpansion() async {
        // The recording the rail belongs to is over.
        guard canExpand else {
            railFadedIn = false
            return
        }
        // Nothing is animating, so there is nothing to wait out.
        guard !reduceMotion else {
            railFadedIn = expanded
            return
        }
        if expanded {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            railFadedIn = true
        } else {
            // Reset behind the collapse, never during it: the letters leave
            // with the shape, as one movement.
            try? await Task.sleep(for: .seconds(Self.closeDuration))
            guard !Task.isCancelled else { return }
            railFadedIn = false
        }
    }

    private var widenAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)
    }

    /// How long the shape takes to close — the easing and the wait that has to
    /// outlast it are one fact, so they are one number.
    private static let closeDuration: TimeInterval = 0.2

    private var closeAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: Self.closeDuration)
    }

    private var railFade: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    /// The tooltip's own appearance, the same 120 ms — one timing for
    /// everything that arrives behind the pointer. Under Reduce Motion the
    /// line still shows; it just does not fade in (#207).
    private var tipFade: Animation? { railFade }

    /// `measuring` marks a copy of the shape that is laid out and never drawn,
    /// so anything that would animate stands still in it (#204, `probes`).
    @ViewBuilder
    private func panel(open: Bool, measuring: Bool) -> some View {
        switch state {
        case .recording:
            if let error = lastError {
                // Mic stall surfaced by the first-frame watchdog — show it loudly
                // instead of a normal-looking recording meter.
                statusRow(icon: "xmark.circle.fill", iconColor: LoreTheme.Accent.red, text: error, wrap: true)
            } else {
                recordingContent(open: open, measuring: measuring)
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

    // MARK: - Recording

    /// The bubble at rest, and the rail it widens to show (#201). At rest the
    /// only letters are the armed ones: what will happen to these words is a
    /// fact about the dictation in progress, and a fact the bubble hides until
    /// it is pointed at is a fact the user does not have (the shipped bubble
    /// said nothing at all while translate was armed). Everything else — `S`,
    /// the unarmed letters, the gear — arrives with the pointer, and arrives to
    /// the right of what was already there (`BubbleRail`), so nothing the user
    /// was reading moves.
    private func recordingContent(open: Bool, measuring: Bool) -> some View {
        let keys = railKeys(open: open)
        return HStack(spacing: 10) {
            statusGroup(measuring: measuring)
            clip
            if !keys.isEmpty {
                groupDivider
                    .opacity(armedLetters.isEmpty && !railVisible ? 0 : 1)
                HStack(spacing: Self.glyphGap) {
                    ForEach(keys) { key in
                        // An armed letter was already standing there, so it
                        // does not fade in with the rail and does not blink
                        // out under the pointer that came to read it; a hint
                        // is nothing to click, or speak, before it can be
                        // read.
                        keycap(key.letter, bright: key.bright,
                               help: key.help, action: key.action)
                            .opacity(key.armed || railVisible ? 1 : 0)
                            .allowsHitTesting(key.armed || railVisible)
                    }
                }
            }
            if open {
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
        let letter: BubbleRailLetter
        let bright: Bool
        let help: String
        let action: (() -> Void)?
        let armed: Bool
        var id: BubbleRailLetter { letter }
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

    private var screenshotKey: RailKey {
        RailKey(
            letter: .screenshot, bright: screenshotsEnabled,
            help: "Screenshot into the prompt (Fn+S)", action: nil, armed: false
        )
    }

    /// What this dictation already carries — the letters the resting bubble
    /// stands with, and what `BubbleRail` orders the open rail around.
    private var armedLetters: Set<BubbleRailLetter> {
        var armed: Set<BubbleRailLetter> = []
        if pendingMode == .cleanup { armed.insert(.cleanup) }
        if pendingMode == .translate { armed.insert(.translate) }
        if operatorAddressed { armed.insert(.operatorSend) }
        return armed
    }

    /// The rail, at rest and open (#204). DSET-06 turns the *hints* off, not the
    /// facts: with the keycaps disabled the bubble still shows what is armed,
    /// opened or not, because a letter that stands at rest may never disappear
    /// when the shape opens.
    private func railKeys(open: Bool) -> [RailKey] {
        BubbleRail
            .letters(armed: armedLetters, open: open && showUpgradeKeycaps)
            .map { key(for: $0) }
    }

    private func key(for letter: BubbleRailLetter) -> RailKey {
        switch letter {
        case .cleanup: cleanupKey
        case .translate: translateKey
        case .operatorSend: operatorKey
        case .screenshot: screenshotKey
        }
    }

    private var groupDivider: some View {
        LoreTheme.Surface.line.frame(width: 1, height: 14)
    }

    /// The paperclip and its count together (#201): gray while collecting and
    /// empty, bright with the count beside it once something is in, and a
    /// slashed glyph when collecting is off. Click turns collecting off and on.
    ///
    /// The count is plain text to the right of the glyph (#209, B2), at the
    /// same 6 pt the rail leaves between its own letters. It was a ring hung
    /// off the glyph's top-right corner, and the ring itself was the objection:
    /// a badge overlapping a 14 pt glyph has no room to move that reads as
    /// deliberate rather than clipped.
    private var clip: some View {
        HStack(spacing: Self.glyphGap) {
            clipSwitch
            if clipBright { count }
        }
    }

    private var clipSwitch: some View {
        clipGlyph
            // The tint reaches the slash as well as the symbol, so the two
            // strokes of one glyph are never two colours.
            .foregroundStyle(clipBright ? LoreTheme.TextColor.primary : LoreTheme.TextColor.muted)
            // The target is the glyph plus a margin (#203): 16×18 pt of
            // paperclip is a click the pointer has to aim at, and it was the
            // whole of both the hit area and the hover fill.
            .frame(width: Self.clipHitBox.width, height: Self.clipHitBox.height)
            // No plate under it, at rest or bright: the dot, the lock, the
            // waveform and the timer beside it stand on the bubble itself, and
            // a glyph on its own tile read as a button pasted into the row.
            // What the paperclip is doing is said by its brightness, by the
            // count and by the slash. The pointer gets the same lift the gear
            // gets, and nothing before that.
            .loreHoverFill(cornerRadius: LoreTheme.Radius.button)
            .contentShape(Rectangle())
            .onTapGesture {
                hideTip()
                onToggleCollecting?()
            }
            // One switch, one name, on and off alike (#212): two sentences for
            // the two faces of one control read as two different things.
            .bubbleTip(.clip, "Toggle prompt attachments", hovered: $hoveredTip, pointer: pointer)
            // The spoken name still says which way it is set — a screen reader
            // has no brightness, no count and no slash to read it off.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                collecting ? "What you copy joins the prompt" : "Copies stay out of the prompt"
            )
            .accessibilityAddTraits(.isToggle)
            // The one state change that has to be legible in peripheral
            // vision, so it is the fastest.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: collecting)
            // The margin is given straight back to the layout: the row lays
            // this out as the glyph's own box, so the count beside it, the
            // 10 pt past that and everything after are where the board draws
            // them, and only the fill and the hit shape grew (#203).
            .padding(-Self.clipHitMargin)
    }

    /// Bright is "holding something that is going to the prompt" — which is
    /// also exactly when there is a count to show.
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
            // One bounce per item that lands (#210, the board's A3): a copy
            // happens many times in a dictation, so the feedback is the smallest
            // motion that reads — the glyph and the digit beside it, nothing
            // else. On the symbol rather than on the composed glyph, so the
            // slashed face bounces too: the off state's mask is a stencil over
            // this same box and cannot suppress what the symbol does inside it.
            .symbolEffect(.bounce, value: bounceTrigger)
            .scaleEffect(renderPreview.clipBouncing ? Self.clipBouncePeak : 1)
            .frame(width: Self.clipBox.width, height: Self.clipBox.height)
    }

    /// Bigger than the bounce ever grows the glyph, so a render that holds at
    /// this scale holds for the effect. The box does not care either way — that
    /// is the point of it — and 1.3 of a 15×17 symbol still stops 1.75 pt inside
    /// the 4 pt of margin around the box.
    private static let clipBouncePeak: CGFloat = 1.3

    private static let clipSide: CGFloat = 13

    /// The box the paperclip is drawn in: the symbol's own bounds at that
    /// point size, and a point of slack around them. Asked for rather than
    /// assumed — a 13pt `paperclip` measures 15×17, so the square box it was
    /// given cut the glyph rather than holding it. Not private, because it and
    /// `clipGlyphTarget` are what `RecordingBubbleClipTests` reads to hold the
    /// growing target away from everything beside it (#203).
    static let clipBox: CGSize = {
        let bounds = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: clipSide, weight: .regular))?.size
            ?? CGSize(width: clipSide, height: clipSide)
        return CGSize(width: ceil(bounds.width) + clipSlack, height: ceil(bounds.height) + clipSlack)
    }()

    /// The slack, split around the glyph, so nothing it draws lands on the
    /// frame's edge.
    private static let clipSlack: CGFloat = 1

    /// How far past the glyph is still the paperclip (#203). The board asks for
    /// a target of at least 24×24 pt; 4 pt on every side of a 16×18 glyph box
    /// gives 24×26, and 4 pt is the reach the acceptance names — a click within
    /// it, on any side, toggles collecting.
    static let clipHitMargin: CGFloat = 4

    /// What the hover fill covers, and the whole of what the pointer hits.
    /// Never what the row lays out: `clipSwitch` takes the margin back with
    /// negative padding, so this box grows without moving anything beside it.
    static let clipHitBox = CGSize(
        width: clipBox.width + 2 * clipHitMargin,
        height: clipBox.height + 2 * clipHitMargin
    )

    /// What the pointer answers, in the glyph box's own coordinates: #203's
    /// 24×26 pt target, and never a point more (#209, B2). It reached out over
    /// the badge's own corner while the badge existed (#212); the count is a
    /// sibling now, so there is nothing out there to click. Read by
    /// `RecordingBubbleClipTests`.
    static var clipGlyphTarget: CGRect {
        CGRect(
            x: -clipHitMargin, y: -clipHitMargin,
            width: clipHitBox.width, height: clipHitBox.height
        )
    }

    /// What the row leaves between one glyph and the next: the rail's letters,
    /// and the paperclip and its count (#209, B2). One value, because it is one
    /// fact — "another glyph beside this one" — and not two numbers that happen
    /// to agree. Not private: `RecordingBubbleRenderTests` measures the glyph's
    /// own band off it.
    static let glyphGap: CGFloat = 6

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

    /// The count beside the clip (#209, B2): plain mono text, muted whatever the
    /// paperclip's own brightness is doing, tabular so the shape never twitches
    /// as it counts. Read, never clicked — it counts what the switch holds, and
    /// the list it belongs to is already open, because pointing at the bubble
    /// opened it. The roll it takes on an arrival is #210's, unchanged.
    private var count: some View {
        Text("\(includedCount)")
            .font(LoreTheme.Typography.mono(Self.countSize))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(LoreTheme.TextColor.muted)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: includedCount)
            .bubbleTip(.count, "\(includedCount) in the prompt", hovered: $hoveredTip, pointer: pointer)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(includedCount) in the prompt")
    }

    /// The count's own size — mono 11, the board's `.cnt`.
    static let countSize: CGFloat = 11

    /// One tabular figure at that size. The count is 1…9 in practice, and this
    /// is the room each one takes: `RecordingBubbleRenderTests` measures the
    /// glyph's band back from the row's trailing edge through it.
    static let countDigitWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: countSize, weight: .regular)
        return ceil(("0" as NSString).size(withAttributes: [.font: font]).width)
    }()

    private var includedCount: Int { items.filter(\.included).count }

    /// The letter is the key on the keyboard, so the letters teach the
    /// shortcut by standing there. `S` carries a tooltip and no click: it is a
    /// key you press, not a switch you flip.
    private func keycap(
        _ letter: BubbleRailLetter, bright: Bool, help: String, action: (() -> Void)?
    ) -> some View {
        Text(letter.rawValue)
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
            .onTapGesture {
                hideTip()
                action?()
            }
            .bubbleTip(.letter(letter), help, hovered: $hoveredTip, pointer: pointer)
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
            .onTapGesture {
                hideTip()
                onOpenSettings?()
            }
            .bubbleTip(.gear, "Settings", hovered: $hoveredTip, pointer: pointer)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Settings")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - The list, opened

    /// One group: every row the same height and the same three columns — the
    /// picture (or the quote mark standing in the same box), the item's first
    /// words on one line, and the moment it belongs to.
    private func itemList(width: CGFloat) -> some View {
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
        .frame(width: width > 0 ? width : nil)
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
        .onTapGesture {
            hideTip()
            onToggleItem?(item.id)
        }
        .bubbleTip(.row(item.id), item.included ? "In the prompt" : "Left out", hovered: $hoveredTip, pointer: pointer)
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

    private func statusGroup(measuring: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                // No-signal keeps its distinct dimmed look (not a token color
                // — it must read as "not recording red").
                .fill(noSignal ? Color.white.opacity(0.3) : LoreTheme.Accent.red)
                .frame(width: 8, height: 8)
                .bubbleTip(.dot, "Recording", hovered: $hoveredTip, pointer: pointer)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording")
            if lockEnabled { lockGlyph }
            waveform(measuring: measuring)
                .bubbleTip(.waveform, "Your voice level", hovered: $hoveredTip, pointer: pointer)
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
                    // The same two facts in a third of the words (#212).
                    .bubbleTip(
                        .timer, Self.timerHelp, hovered: $hoveredTip, pointer: pointer
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.timerHelp)
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
            .onTapGesture {
                hideTip()
                onToggleLock?()
            }
            .bubbleTip(.lock, lockHelp, hovered: $hoveredTip, pointer: pointer)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lockHelp)
            .accessibilityAddTraits(.isToggle)
    }

    /// What the timer answers: how long it may run, and where the words are
    /// meanwhile. Two facts, and after #212 six words — the sentence it
    /// replaces said the same thing in three times the room.
    private static let timerHelp = "Unlimited dictation. Locally saved."

    /// Both ways out, not only the stop (#212): the owner locked a dictation
    /// and had to guess whether Esc kept the words.
    private var lockHelp: String {
        isLocked
            ? "Press Fn to paste, Esc to stop"
            : "Space locks recording, hands free"
    }

    /// Shared Lore waveform while live; the no-signal state keeps its distinct
    /// flat dimmed bars. Fixed 18pt frame preserves the pre-Stage-H panel
    /// height (`.fixedSize()` sizing is load-bearing — see the manager).
    private func waveform(measuring: Bool) -> some View {
        Group {
            if noSignal {
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 2, height: 4)
                    }
                }
            } else if measuring {
                // The bars' exact width and nothing else. The real waveform is a
                // `TimelineView` at 30 fps, and the probes would have run one
                // each — three timelines for one recording, two of them for
                // shapes nobody sees. What the probes need from it is its size.
                Color.clear.frame(width: LoreLiveWaveform.width)
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
    var held = false
    /// Render-only — see `BubbleRenderPreview`.
    var renderPreview = BubbleRenderPreview()
    var onUpgrade: ((UpgradeAction) -> Void)?
    var onOperatorToggle: (() -> Void)?
    var onToggleItem: ((UUID) -> Void)?
    var onToggleLock: (() -> Void)?
    var onToggleCollecting: (() -> Void)?
    var onArmCleanup: (() -> Void)?
    var onArmTranslate: (() -> Void)?
    var onArmOperator: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Where the user drags the bubble (#213).
    var onDrag: ((BubbleDrag) -> Void)?
    /// The window the shape wants (#204): the canvas it grows inside while
    /// recording, `nil` for every other state.
    var onCanvasChange: (@MainActor (BubbleCanvas?) -> Void)?
}

/// SwiftUI wrapper that reads the observable model. Not private, because it is
/// the seam `RecordingBubbleRenderTests` renders the bubble through — the view
/// itself carries private state, so its memberwise initialiser is private, and
/// the model is how the app drives it anyway (#204).
struct DictationIndicatorHost: View {
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
            held: model.held,
            renderPreview: model.renderPreview,
            onUpgrade: model.onUpgrade,
            onOperatorToggle: model.onOperatorToggle,
            onToggleItem: model.onToggleItem,
            onToggleLock: model.onToggleLock,
            onToggleCollecting: model.onToggleCollecting,
            onArmCleanup: model.onArmCleanup,
            onArmTranslate: model.onArmTranslate,
            onArmOperator: model.onArmOperator,
            onOpenSettings: model.onOpenSettings,
            onDrag: model.onDrag,
            onCanvasChange: model.onCanvasChange
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
        // Where the bubble is dragged to is where it stays (#213). The pointer
        // is read here, off the screen, rather than taken from the gesture:
        // SwiftUI measures a drag in the window's own space, and that number
        // stops moving the instant the window starts following it.
        model.onDrag = { [weak self] phase in
            switch phase {
            case .moved: self?.panel?.drag(to: NSEvent.mouseLocation)
            case .ended: self?.panel?.endDrag()
            }
        }
        // The shape measures its own window and the window stops following it
        // (#204): one canvas per recording, and hover changes nothing about it.
        model.onCanvasChange = { [weak self] canvas in
            self?.panel?.setCanvas(canvas)
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
                // Holding the hotkey inside a locked recording opens the bubble
                // for as long as it is held (#205) — the same surface hovering
                // opens, arriving through the poll that already reads the lock.
                self.model.held = hotkeyManager?.isFnHoldingBubble ?? false
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
