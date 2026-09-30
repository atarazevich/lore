import AppKit
import SwiftUI

/// The agent replies in the floating player (#260, #263), drawn to the approved
/// board `docs/design/prototypes/agent-replies-player.html` (v2.6 §07), whose
/// copy table is the contract for every word here.
///
/// Three surfaces, never two at once: the queue as one list with the reply being
/// read as a card (board d, e, h), the quiet capsule that says how many replies
/// wait while a microphone is in use or mute is on (f, g), and nothing at all.
/// The decision is `AgentReplySurface`, and both the view and the panel's poll
/// read it from the live controller — so the window and its content can never
/// disagree (`no-false-positives.md`).
///
/// Everything is behind the feature's switch (#256): off, `decide` answers
/// `.hidden` and none of this is built.

// MARK: - What the surface shows

enum AgentReplySurface: Equatable, Sendable {
    case hidden
    case waiting(AgentReplyWaitingCapsule)
    case player

    /// Pure, and derived at presentation time from nothing stored.
    ///
    /// Speaking wins over every hold: an explicit play reads a reply even while
    /// a microphone is in use (#256), and while lore reads, the player is
    /// visible — speakers can be muted or quiet, so the words have to be
    /// readable. A paused reply keeps the player up (it is what play resumes),
    /// and the microphone freeing with replies waiting opens it stopped (h).
    ///
    /// `isLingering` is the ten seconds after the last reply ended (#260
    /// review): the player disappearing on the final word took with it the Go
    /// to of the reply just read, which is how that chat is reached.
    ///
    /// `isHidden` is the owner putting it away himself (#263) — and then nothing
    /// is drawn, the capsule included: the capsule explains a silence he did not
    /// ask for, and this one he did.
    ///
    /// Except while a reply is read — speaking or paused, the reply he is on —
    /// and for the linger after it (#285): he could not tell which chat was
    /// talking to him. The player shows over his choice unless he put it away
    /// during this very reply
    /// (`isHiddenUntilNextReply`), and never while a microphone holds reading —
    /// a dictation or a call keeps it out of the way as before. When the linger
    /// runs out, his choice is what is drawn again.
    static func decide(
        isEnabled: Bool, playback: AgentReplyController.Playback,
        isHeldByMicrophone: Bool, isMuted: Bool, waiting: Int, isLingering: Bool = false,
        isHidden: Bool = false, isHiddenUntilNextReply: Bool = false
    ) -> AgentReplySurface {
        let readingShows = !isHiddenUntilNextReply && !isHeldByMicrophone
            && (playback != .idle || isLingering)
        guard isEnabled, !isHidden || readingShows else { return .hidden }
        if playback == .speaking { return .player }
        if isHeldByMicrophone || isMuted, waiting > 0 {
            return .waiting(AgentReplyWaitingCapsule(isMuted: isMuted, waiting: waiting))
        }
        // A microphone in use with nothing waiting: nothing to say. Mute with
        // nothing waiting falls through to the linger (#278): a tap that brings
        // the player back over replies already heard shows them, muted or not.
        if isHeldByMicrophone { return .hidden }
        if playback == .paused || waiting > 0 { return .player }
        return isLingering ? .player : .hidden
    }

    /// The same decision off the live controller — the one call both the view
    /// and `ReadAloudPanelManager`'s poll make.
    @MainActor
    static func of(_ replies: AgentReplyController) -> AgentReplySurface {
        decide(
            isEnabled: replies.isEnabled, playback: replies.playback,
            isHeldByMicrophone: replies.isHeldByMicrophone, isMuted: replies.isMuted,
            waiting: replies.waitingCount, isLingering: replies.isLingering,
            isHidden: replies.isPlayerHidden,
            isHiddenUntilNextReply: replies.isHiddenUntilNextReply
        )
    }
}

/// The capsule in the player's place (board f, g): how many replies wait, and —
/// when mute is why nothing is read — mute's own key, because unmuting is what
/// the reader wants next.
struct AgentReplyWaitingCapsule: Equatable, Sendable {
    let isMuted: Bool
    let waiting: Int

    /// "3 replies waiting" / "1 reply waiting"; muted says so first.
    var words: String {
        let count = waiting == 1 ? "1 reply waiting" : "\(waiting) replies waiting"
        return isMuted ? "Muted \u{2014} \(count)" : count
    }

    var keys: [String] {
        isMuted ? HotkeyManager.AgentReplyChord.mute.caps : []
    }

    /// While muted, the strip's own words — one action, one name.
    var tooltip: String {
        isMuted
            ? HotkeyManager.AgentReplyChord.mute.name
            : "Replies wait while the microphone is in use"
    }
}

// MARK: - The keys, as the strip prints them

extension HotkeyManager.AgentReplyChord {
    /// The letter on the talk key, as the keycap prints it.
    var letter: String {
        switch self {
        case .playOrPause: "R"
        case .previous: "["
        case .next: "]"
        case .goToChat: "J"
        case .mute: "M"
        }
    }

    /// The keycap run: `fn` is printed on every chord. The strip prints its own
    /// `fn` once at the head (#263); everywhere a key stands alone — Settings,
    /// the capsule, a tooltip — it carries the whole chord.
    var caps: [String] { ["fn", letter] }

    /// The board's copy table, one order for the two-word keys. The pair stays
    /// the name wherever there is room for it — Settings, and the tooltip on the
    /// strip; the strip's own word is the half that is true at that moment.
    var name: String {
        switch self {
        case .playOrPause: "Play / Pause"
        case .previous: "Previous"
        case .next: "Next"
        case .goToChat: "Go to / Open"
        case .mute: "Mute / Unmute"
        }
    }

    /// The chords the strip prints, in its reading order at the player's foot
    /// (board §07): every one pressed with the `fn` at the head.
    ///
    /// R is not among them since #278. Its word would have to be Pause while a
    /// reply speaks — the same act as the Esc beside it — and with Unmute and
    /// Go to on the line that is 6.5 pt more than the foot of the player has
    /// (`testTheKeyStripIsOneLine`). Settings lists it.
    static let stripOrder: [Self] = [.previous, .next, .goToChat, .mute]
}

/// One entry of the key strip: the key as its cap prints it, the word that is
/// true right now, and the line it says on hover.
struct AgentReplyStripKey: Equatable, Sendable, Identifiable {
    /// The whole chord, for the tooltip and for VoiceOver: neither of them has a
    /// head to read the `fn` from.
    let fullCaps: [String]
    /// What this key does at this moment: "Mute" or "Unmute", "Pause" or "Play".
    let word: String
    /// The copy table's line for it; the chords keep the pair Settings names, so
    /// the two never disagree about the key.
    let tooltip: String

    /// The caps of this entry alone — a single letter for the chords, since the
    /// strip prints `fn` once at its head, and `esc` for the key that is not
    /// one. Which is the last of the chord either way, never a second field to
    /// keep in step with the first.
    var caps: [String] { Array(fullCaps.suffix(1)) }

    var id: String { fullCaps.joined() }
}

/// The strip at the player's foot, as the board's §07 prints it: `fn +` at the
/// head, the four chords it governs, then Esc.
///
/// Every word is read from state and none is stored — the strip says what the
/// key will do if it is pressed now, which is the same rule the tooltips and
/// Esc itself follow (`no-false-positives.md`).
struct AgentReplyStrip: Equatable, Sendable {
    /// The head: the modifier the four letters after it are pressed with.
    static let head = "fn"
    /// The copy table's line for Esc, the one key that does two things (#263).
    static let escapeTooltip = "Pauses. Press again to hide the player."

    /// Every entry in reading order: the four chords the head governs, then Esc,
    /// which is not one of them. One run, so the entry that carries the extra
    /// margin is simply the last of it.
    let keys: [AgentReplyStripKey]

    /// - Parameters:
    ///   - goToWord: the word on the playing card's own button — "Go to" for a
    ///     chat that is open, "Open" for one that is not. One action, one name.
    ///   - isSpeaking: what the next Esc does: pause a reply that speaks,
    ///     otherwise put the player away.
    init(isMuted: Bool, isSpeaking: Bool, goToWord: String) {
        keys = HotkeyManager.AgentReplyChord.stripOrder.map { chord in
            let word: String = switch chord {
            case .goToChat: goToWord
            case .mute: isMuted ? "Unmute" : "Mute"
            // The two whose word is the whole of what the key does: the copy
            // table names them once, in `name`, and the strip reads it. R is
            // not in `stripOrder`.
            case .previous, .next, .playOrPause: chord.name
            }
            return AgentReplyStripKey(
                fullCaps: chord.caps, word: word,
                tooltip: chord.name
            )
        } + [
            AgentReplyStripKey(
                fullCaps: ["esc"], word: isSpeaking ? "Pause" : "Hide",
                tooltip: Self.escapeTooltip
            )
        ]
    }

    /// The live strip: the words come from the same reading the keys act on.
    @MainActor
    init(replies: AgentReplyController, chats: AgentChatNavigator) {
        self.init(
            isMuted: replies.isMuted, isSpeaking: replies.isSpeaking,
            goToWord: replies.currentReply
                .flatMap { chats.destination(for: $0)?.title } ?? "Go to"
        )
    }
}

// MARK: - The list, as the player draws it

/// What the player draws and in which order (board d, e, h): every reply the
/// store keeps, in arrival order, which never changes — the reply at the
/// position as the card, the rest as rows, and "Next up · N" before the first
/// reply after the card that is still waiting.
///
/// One list of entries drawn by one loop, and every reply is in it: the board's
/// caps (three read rows above the card, four below) are how much of it *shows*
/// — the rest is reached by scrolling (board §06), so a reply can never become
/// unreachable by sitting too far from the card.
struct AgentReplyListLayout: Equatable, Sendable {
    /// The board's caps: three read rows above the card, four rows below —
    /// seven in the plate that held five, on the denser row.
    static let maxAbove = 3
    static let maxBelow = 4

    /// One drawn thing: a reply's row, the card of the one being read, or the
    /// label that counts what is still coming.
    enum Entry: Equatable, Sendable, Identifiable {
        case row(index: Int, isStarted: Bool)
        case card(index: Int)
        case label(count: Int)

        static let cardID = "card"

        var id: String {
            switch self {
            case .row(let index, _): "row\(index)"
            case .card: Self.cardID
            case .label: "next-up"
            }
        }
    }

    let entries: [Entry]
    /// What "Next up · N" counts: every reply still waiting except the card
    /// itself — including the ones sitting *above* it, which a jump forward or
    /// a step back leaves there (#260 review: they were drawn at full strength
    /// and counted nowhere).
    let nextUpCount: Int
    /// The row the list keeps in view: the card, or the last row when reading
    /// has run out and the player is only lingering.
    let focus: String?

    init(count: Int, position: Int, started: Set<Int>) {
        let card = (0..<count).contains(position) ? position : nil
        nextUpCount = (0..<count).count { $0 != card && !started.contains($0) }
        // The label precedes the first reply after the card that is still
        // waiting; with none drawn after it, it closes the list, so the count is
        // never hidden.
        let labelIndex = nextUpCount == 0
            ? nil
            : (0..<count).first { $0 > (card ?? -1) && !started.contains($0) }
        var entries: [Entry] = []
        for index in 0..<count {
            if index == labelIndex { entries.append(.label(count: nextUpCount)) }
            entries.append(
                index == card
                    ? .card(index: index)
                    : .row(index: index, isStarted: started.contains(index))
            )
        }
        if nextUpCount > 0, labelIndex == nil { entries.append(.label(count: nextUpCount)) }
        self.entries = entries
        focus = card.map { _ in Entry.cardID } ?? entries.last?.id
    }
}

// MARK: - The player

/// The title bar with its ? and ×, the queue as one list, the card, the
/// one-line key strip — and, under all of it, the room one tooltip line needs
/// (`AgentReplyTipRow`).
struct AgentReplyPlayerView: View {
    let replies: AgentReplyController
    let chats: AgentChatNavigator
    /// lore's mark in the title bar (#289): the sidebar chip's artwork
    /// (`LoreMark.chip`). Handed in rather than read here, because it loads
    /// from the app bundle and a test process has none.
    let mark: NSImage
    /// Press anywhere that is not a control and drag: the window moves (#267).
    var onDrag: ((BubbleDrag) -> Void)?

    @State private var tip: AgentReplyTip?
    /// The whole list as it came out, so a queue shorter than the window takes
    /// only the room it needs. Nil until it has been laid out, which is the
    /// window itself — never more.
    @State private var listHeight: CGFloat?
    /// Where the ?'s centre stands across the plate, which is where the card's
    /// caret goes — measured, since it follows the title's own width.
    @State private var helpMarkX: CGFloat = 0

    /// The board's plate: 376 across, 14/8 of padding around the content. The
    /// top padding is the header's now (#263): the bar takes its place, so
    /// nothing inside reflows, and 4 of lead falls under it.
    static let plateWidth: CGFloat = 376
    /// Not private: what the plate leaves for its content is the width the key
    /// strip has to fit, and that is what its test holds it to.
    static let padding = EdgeInsets(top: 4, leading: 14, bottom: 8, trailing: 14)
    /// The title bar itself (board §07, #289): 22 → 28, the one height that
    /// moves — the plate grows by those 6 and the list's window does not.
    static let headerHeight: CGFloat = 28
    /// The plate's rules — the title bar's and the key strip's — stop this far
    /// in from each side: the plate's padding, less what the strip bleeds.
    static let ruleInset: CGFloat = padding.leading - AgentReplyKeyStrip.bleed

    /// The label's own row: the board's 10 pt caps at the foot of it.
    static let labelHeight: CGFloat = 16
    /// The card at its tallest: its two-band header, four lines of the reply
    /// and the progress row inside the padding around them. Stated rather than
    /// measured — the list's window may not depend on a reading that arrives a
    /// pass later — and held to the card itself by `AgentReplyPanelTests`, which
    /// is where the figure comes from: the board's prose says 127 off its own
    /// HTML, and the drawing settles it at 125, as the key strip's 20 is settled.
    static let cardHeight: CGFloat = 125

    /// What the list shows before it scrolls (board §06): the board's seven
    /// rows, the card between them, and the label.
    static let window: CGFloat =
        CGFloat(AgentReplyListLayout.maxAbove + AgentReplyListLayout.maxBelow)
            * AgentReplyRowView.height
            + cardHeight + labelHeight

    private var layout: AgentReplyListLayout {
        AgentReplyListLayout(
            count: replies.queue.replies.count,
            position: replies.queue.position,
            started: replies.queue.startedIndices
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            plate
            AgentReplyTipRow(tip: tip, width: Self.plateWidth)
        }
        .frame(width: Self.plateWidth)
        .coordinateSpace(.named(agentReplyTipSpace))
        // Every row's chat state, read live for as long as the player is up:
        // at once when it appears, then on its own cadence (#258, #260 review —
        // the rows used to open with no button at all for a tick).
        .task { await chats.readWhileShown() }
    }

    private var plate: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 0) {
                list
                AgentReplyKeyStrip(
                    strip: AgentReplyStrip(replies: replies, chats: chats), tip: $tip
                )
            }
            .padding(Self.padding)
        }
        .background(
            .ultraThinMaterial, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LoreTheme.Radius.panel)
                .strokeBorder(LoreTheme.Shadow.windowRim, lineWidth: 0.5)
        )
        // The pointer on the player is someone reading it: the ten seconds
        // after the last reply start again while it is there.
        .onHover { if $0 { replies.keepPlayerUp() } }
        // Press anywhere that is not a control and drag (#267): the panel is
        // non-activating and its window is not movable by its background,
        // because a window that is answers a mouse-down the app underneath
        // never receives.
        .gesture(BubbleDrag.gesture { onDrag?($0) })
    }

    /// The title bar (board §01, #289): translucent over the plate's own frost,
    /// 28 tall, and one axis through its middle carrying four things — lore's
    /// mark in the rows' empty left column, the title on the column the chat
    /// names keep, the ? after it, and the × on the right. Its rule is the
    /// strip's own: the same weight, the same inset.
    ///
    /// Neither the mark nor the title is a control: pressed and dragged, they
    /// move the plate like any bare part of it. The × withdraws the player
    /// exactly as a tap of fn does (#278), and never the speech, which is what
    /// its line says out loud.
    private var header: some View {
        HStack(spacing: 0) {
            Image(nsImage: mark)
                .resizable()
                .frame(width: Self.markSide, height: Self.markSide)
                // The title says whose panel this is.
                .accessibilityHidden(true)
            title
                .padding(.leading, Self.markGap)
            helpMark
                .padding(.leading, Self.titleGap)
            Spacer(minLength: 0)
            closeMark
        }
        // The title starts on the names' column, the mark 7 before it.
        .padding(.leading, Self.padding.leading + AgentReplyRowView.leftEdge - Self.markGap - Self.markSide)
        .padding(.trailing, Self.closeTrailing)
        .frame(height: Self.headerHeight)
        .background(
            LoreTheme.Surface.card2,
            in: UnevenRoundedRectangle(
                topLeadingRadius: LoreTheme.Radius.panel,
                topTrailingRadius: LoreTheme.Radius.panel
            )
        )
        .overlay(alignment: .bottom) {
            LoreTheme.Surface.line
                .frame(height: 1)
                .padding(.horizontal, Self.ruleInset)
        }
        .onDisappear { replies.help.reset() }
    }

    /// The mark at the 16 of a title-bar icon, and the 7 after it.
    private static let markSide: CGFloat = 16
    private static let markGap: CGFloat = 7
    /// Between the title and the ?.
    private static let titleGap: CGFloat = 6
    /// The ×'s glyph draws 4.5 inside its 16 pt box, so the box ends 4.5 past
    /// the rail the rows' Go to pill ends on (the plate's padding and the
    /// row's trailing 8): the glyph's own edge is on it.
    private static let closeTrailing: CGFloat = padding.trailing + AgentReplyRowView.rightEdge - 4.5

    /// The command that fills the list, as a chat calls it — quieter than the
    /// names it heads: mono 10.5, the command medium in primary ink, its
    /// argument regular and muted. Not a control.
    private var title: some View {
        HStack(spacing: 0) {
            Text(AgentReplyHelpCopy.command)
                .fontWeight(.medium)
                .foregroundStyle(LoreTheme.TextColor.primary)
            Text(" " + AgentReplyHelpCopy.argument)
                .foregroundStyle(LoreTheme.TextColor.muted)
        }
        .font(LoreTheme.Typography.mono(10.5))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentReplyHelpCopy.title)
        .accessibilityAddTraits(.isHeader)
    }

    /// The ? (#289): muted like the ×, bright while its card is up. The
    /// pointer on it opens the card; a click pins it until a click elsewhere or
    /// Esc.
    private var helpMark: some View {
        let help = replies.help
        return Image(systemName: "questionmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(help.isOpen ? LoreTheme.TextColor.primary : LoreTheme.TextColor.muted)
            .frame(width: 12, height: 12)
            // The circle is 12; the pointer gets 2 more on every side.
            .padding(2)
            .contentShape(Rectangle())
            .onHover { help.pointer(onMark: $0) }
            .onTapGesture { help.click() }
            .padding(-2)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(agentReplyTipSpace)).midX
            } action: { helpMarkX = $0 }
            .background {
                if help.isOpen {
                    AgentReplyHelpAnchor(
                        caretX: helpMarkX - AgentReplyHelpCard.inset,
                        onPointer: { [replies] isOn in
                            replies.help.pointer(onCard: isOn)
                            // The pointer on the card is someone reading the
                            // player: the ten seconds after the last reply
                            // start again, as they do for the plate itself.
                            if isOn { replies.keepPlayerUp() }
                        }
                    )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AgentReplyHelpCopy.helpName)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { help.click() }
    }

    private var closeMark: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(LoreTheme.TextColor.muted)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .onTapGesture { replies.hidePlayer(by: .closeMark) }
            .loreTipReport(
                AgentReplyTipOwner.close, Self.hideName,
                keys: [AgentReplyStrip.head],
                in: agentReplyTipSpace, tip: $tip
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Self.hideName), fn")
            .accessibilityAddTraits(.isButton)
    }

    /// The ×'s own line, in the board's copy table: what it does, in the words
    /// the strip's esc uses when nothing speaks — one action, one name.
    static let hideName = "Hide the player"

    /// The whole queue in one scroll, the board's caps worth of it showing.
    ///
    /// The window is stated, never proposed: this plate hangs in a panel that
    /// sizes itself to its content (`fixedSize`), and a scroll view asked for
    /// its ideal size answers with all fifty replies — which is the plate
    /// growing down the screen instead of scrolling.
    private var list: some View {
        let layout = layout
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                AgentReplyListView(layout: layout, replies: replies, chats: chats, tip: $tip)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        listHeight = $0
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(listHeight ?? Self.window, Self.window))
            // The card is what the list is about, wherever it sits in 50
            // replies — so the list is put on it, again whenever it moves.
            .task(id: layout.focus) {
                guard let focus = layout.focus else { return }
                proxy.scrollTo(focus, anchor: .center)
            }
        }
    }
}

/// The entries as they are drawn: the rows already read, the card, the label,
/// what is coming — one list in one loop.
///
/// Its own view, and not private, because a `ScrollView`'s content draws as
/// nothing in an `ImageRenderer`: this is what the render tests put beside the
/// board, while the plate above wraps the same thing in the scroll.
struct AgentReplyListView: View {
    let layout: AgentReplyListLayout
    let replies: AgentReplyController
    let chats: AgentChatNavigator
    @Binding var tip: AgentReplyTip?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(layout.entries) { entry(for: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func entry(for entry: AgentReplyListLayout.Entry) -> some View {
        switch entry {
        case .row(let index, let isStarted):
            AgentReplyRowView(
                reply: replies.queue.replies[index], isStarted: isStarted,
                replies: replies, chats: chats, tip: $tip
            )
        case .card(let index):
            AgentReplyCardView(
                reply: replies.queue.replies[index], replies: replies, chats: chats, tip: $tip
            )
        case .label(let count):
            // "Next up · 2" — the label, and the number counting what is still
            // coming.
            LoreSectionLabel(text: "Next up \u{00B7} \(count)", size: 10, trackingEm: 0.03)
                .padding(.leading, AgentReplyRowView.leftEdge - 10)
                .frame(height: AgentReplyPlayerView.labelHeight, alignment: .bottomLeading)
        }
    }
}

// MARK: - A chat as a row

/// One chat's two bands, drawn the same in a row and in the card's header
/// (board §01): the names the owner typed with the host app's button beside
/// them, and under them — the whole width of the row, the button included —
/// what the chat calls itself. That second line is what tells two tabs of one
/// workspace apart, so it gets the room the first line's button leaves it.
///
/// The card differs only in the face, in the accent on its button, and in that
/// a row reading has been through lets its words recede.
private struct AgentReplyChatLines: View {
    let reply: AgentReply
    let name: AgentChatName
    let chats: AgentChatNavigator
    /// The expanded face of the same chat: the bigger title, the accent on the
    /// button, and the key that does the same thing in its tooltip.
    let onCard: Bool
    var isStarted = false
    @Binding var tip: AgentReplyTip?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(name.line)
                    .font(onCard ? LoreTheme.Typography.control : Self.rowFont)
                    .foregroundStyle(
                        isStarted ? LoreTheme.TextColor.muted : LoreTheme.TextColor.primary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(ChatTip(reply: reply, name: name, owner: .row(reply.id), tip: $tip))
                    .accessibilityAddTraits(.isButton)
                AgentReplyGoButton(reply: reply, chats: chats, onCard: onCard, tip: $tip)
            }
            .frame(height: AgentReplyRowView.nameBand)
            Text(name.meta)
                .font(LoreTheme.Typography.meta)
                .foregroundStyle(isStarted ? LoreTheme.TextColor.faint : LoreTheme.TextColor.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    maxWidth: .infinity, minHeight: AgentReplyRowView.metaBand,
                    maxHeight: AgentReplyRowView.metaBand, alignment: .leading
                )
                .modifier(ChatTip(reply: reply, name: name, owner: .meta(reply.id), tip: $tip))
                // The band above it reads both lines; this one would say the
                // second of them twice.
                .accessibilityHidden(true)
        }
    }

    private static let rowFont = Font.system(size: 12.5, weight: .medium)

    /// Both lines cut, so either one hovered says both of them whole (board
    /// §05). Two owners and not one, because the button stands inside the first
    /// band and a report wrapped around it would speak over the button's own.
    private struct ChatTip: ViewModifier {
        let reply: AgentReply
        let name: AgentChatName
        let owner: AgentReplyTipOwner
        @Binding var tip: AgentReplyTip?

        func body(content: Content) -> some View {
            content
                .loreTipReport(owner, name.tooltip, in: agentReplyTipSpace, tip: $tip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(name.meta.isEmpty ? name.line : "\(name.line), \(name.meta)")
        }
    }
}

/// The compact view of one chat (board §01): its workspace and tab over what it
/// is about, the host app's own icon, and the one button that gets him there.
/// Clicking the row plays that reply.
///
/// Not private: its two bands are the numbers the list's window is counted in,
/// and `AgentReplyPanelTests` holds the arithmetic to them.
struct AgentReplyRowView: View {
    let reply: AgentReply
    let isStarted: Bool
    let replies: AgentReplyController
    let chats: AgentChatNavigator
    @Binding var tip: AgentReplyTip?

    /// The board's row: 32 tall — the height the list's own window is counted
    /// in — as two bands, 18 for the names and the button and 13 for the line
    /// under them.
    static let height: CGFloat = 32
    static let nameBand: CGFloat = 18
    static let metaBand: CGFloat = 13
    /// The one left edge the rows and the card all start on (board §06): the
    /// row's own 8, the 12 pt gutter, and the column gap after it.
    static let leftEdge: CGFloat = 30
    static let rightEdge: CGFloat = 8

    var body: some View {
        AgentReplyChatLines(
            reply: reply, name: chats.name(for: reply), chats: chats, onCard: false,
            isStarted: isStarted, tip: $tip
        )
        .padding(EdgeInsets(top: 0, leading: Self.leftEdge, bottom: 0, trailing: Self.rightEdge))
        .frame(height: Self.height)
        // The row is the control: a click anywhere on it but the Go to / Open
        // button plays that reply.
        .contentShape(Rectangle())
        .onTapGesture { replies.playOrPause(replyID: reply.id) }
    }
}

/// The host app's icon and the one word beside it — "Go to" when the app runs
/// with the chat open, "Open" otherwise; the icon greys only while the app is
/// not running (#258). Always active, and read live: the destination comes from
/// the navigator's latest pass, and the click takes a reading of its own.
private struct AgentReplyGoButton: View {
    let reply: AgentReply
    let chats: AgentChatNavigator
    /// On the playing card the word carries the accent and the tooltip ends
    /// with the key that does the same thing.
    let onCard: Bool
    @Binding var tip: AgentReplyTip?

    /// Icon and pill both stand in the row's 18 pt name band (#267), so the
    /// line under them runs the row's whole width.
    private static let iconSide: CGFloat = 18

    var body: some View {
        // Nil is honest: a reply that named no app and holds no pane has no
        // chat to be taken to, so no button is drawn for it.
        if let destination = chats.destination(for: reply) {
            HStack(spacing: 6) {
                if let image = chats.icon(for: reply) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: Self.iconSide, height: Self.iconSide)
                        .grayscale(destination.isHostRunning ? 0 : 1)
                        .opacity(destination.isHostRunning ? 1 : 0.45)
                }
                Text(destination.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(onCard ? LoreTheme.Accent.blue : LoreTheme.TextColor.muted)
                    .padding(.horizontal, 9)
                    .frame(height: Self.iconSide)
                    .background(
                        Capsule().fill(onCard ? LoreTheme.Surface.line2 : LoreTheme.Surface.card3)
                    )
            }
            .contentShape(Rectangle())
            .onTapGesture { Task { await chats.open(reply) } }
            .loreTipReport(
                AgentReplyTipOwner.go(reply.id), destination.tooltip,
                keys: onCard ? HotkeyManager.AgentReplyChord.goToChat.caps : [],
                in: agentReplyTipSpace, tip: $tip
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                onCard
                    ? "\(destination.title), \(destination.tooltip), fn J"
                    : "\(destination.title), \(destination.tooltip)"
            )
            .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: - The reply being read

/// The expanded view of the same chat (board d): its header over the reply's
/// own words and how far reading has got.
///
/// Not private: the four-line cap and the room it needs are what the tests
/// hold the card to.
struct AgentReplyCardView: View {
    let reply: AgentReply
    let replies: AgentReplyController
    let chats: AgentChatNavigator
    @Binding var tip: AgentReplyTip?

    /// The board's card: the text stops at the fourth line and the rest
    /// scrolls inside the card (board §05, "reply text, four lines").
    static let textLines = 4
    private static let textSize: CGFloat = 12.5

    /// The room those four lines need, in the reply's own face.
    static var textHeight: CGFloat {
        let font = SystemFont.metrics(size: textSize)
        return CGFloat(textLines) * ceil(font.ascender - font.descender + font.leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            words
            progress
                .padding(.top, 3)
                .padding(Self.inset)
        }
        .padding(.top, 3)
        .padding(.bottom, 5)
        .background(
            LoreTheme.Surface.card3, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.card)
        )
        // The card is the control (#263): a click anywhere on it but the Go to /
        // Open button pauses the reply being read, and carries it on again.
        .contentShape(RoundedRectangle(cornerRadius: LoreTheme.Radius.card))
        .onTapGesture { replies.playOrPause(replyID: reply.id) }
        .padding(.vertical, 3)
    }

    /// The card's own left edge is the rows' (board §06): the title, the words
    /// and the progress row all start on it, so nothing in the list steps in or
    /// out. Its right is the rail the button and the header's × end on.
    private static let inset = EdgeInsets(
        top: 0, leading: AgentReplyRowView.leftEdge, bottom: 0,
        trailing: AgentReplyRowView.rightEdge
    )

    private var header: some View {
        AgentReplyChatLines(
            reply: reply, name: chats.name(for: reply), chats: chats, onCard: true, tip: $tip
        )
        .padding(Self.inset)
    }

    /// The reply itself: four lines of it, and the rest by scrolling inside the
    /// card — a reply is a paragraph, and truncating it at the fourth line left
    /// the end of a long one nowhere (#260 review).
    ///
    /// The one place on the card that names the action (#263): the title above
    /// it keeps the chat's own tooltip, as every row's does, so one thing is
    /// said in one place.
    private var words: some View {
        ScrollView(.vertical) {
            Text(reply.said.text)
                .font(.system(size: Self.textSize))
                .foregroundStyle(LoreTheme.TextColor.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Self.textHeight)
        .padding(Self.inset)
        .contentShape(Rectangle())
        .onTapGesture { replies.playOrPause(replyID: reply.id) }
        .loreTipReport(
            AgentReplyTipOwner.card(reply.id), replies.isSpeaking ? Self.pauseName : Self.resumeName,
            in: agentReplyTipSpace, tip: $tip
        )
    }

    /// The card's two words, in the board's copy table: what the click does to
    /// the reply being read, and to the one it stopped.
    static let pauseName = "Pause"
    static let resumeName = "Resume"

    /// The speaker glyph while the reply speaks, a pause glyph while it is
    /// stopped, then the reading row both players draw.
    private var progress: some View {
        let isSpeaking = replies.isSpeaking
        let total = reply.estimatedSeconds
        return PlayerProgressRow(
            elapsed: total * replies.progress, total: total, progress: replies.progress,
            fill: LoreTheme.Accent.blue, track: LoreTheme.Surface.line2
        ) {
            Image(systemName: isSpeaking ? "speaker.wave.2.fill" : "pause.fill")
                .font(.system(size: 9))
                .foregroundStyle(isSpeaking ? LoreTheme.Accent.blue : LoreTheme.TextColor.muted)
                .frame(width: 12, height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isSpeaking ? "Reading, \(Int(replies.progress * 100)) percent" : "Stopped"
        )
    }
}

extension AgentReply {
    /// What the card's clock figures are made of: the reply's own characters
    /// over the rate Read Aloud estimates with. The announcement in front of
    /// them is not counted (#267) — it is the same second or so whatever the
    /// reply is, and the share the speaker reports is the reply's alone, so
    /// the elapsed figure is this total times that share.
    var estimatedSeconds: Double {
        Double(said.text.count) / ReadAloudController.charsPerSecond
    }
}

// MARK: - The key strip

/// Every key the player answers to, in one line at its foot (board §07): `fn +`
/// at the head, the four letters it governs, then Esc — not one of them, and set
/// off by twice the gap, which is all the separation it needs. A legend, not a
/// control: the keys are the controls.
///
/// One row at 20 pt against the two rows and 52 pt that shipped — six chords
/// will not fit the panel with `fn` on each of them and both halves of every
/// pair, so the modifier is printed once for the run it governs and every word
/// is the one true at that moment.
///
/// Not private: the render tests measure it beside the board.
struct AgentReplyKeyStrip: View {
    let strip: AgentReplyStrip
    @Binding var tip: AgentReplyTip?

    /// The strip proper: the hairline, 5 of lead under it, and the 14 its caps
    /// stand in — 20, against the 52 the two rows took. The measured figure, and
    /// the one the board's prose is held to; `testTheKeyStripIsOneLine` renders
    /// the strip and reads it back, so a comment cannot drift from the drawing.
    static let height: CGFloat = 20
    /// The gap over the hairline, between the list and the rule.
    static let lead: CGFloat = 4
    /// How far it reaches past the plate's own padding on each side, and what it
    /// takes back inside that: the run starts under the rows' own words and Esc
    /// ends on the rail the Go to pill and the header's × end on. Not private:
    /// the plate's `ruleInset` is read off it (#289).
    static let bleed: CGFloat = 8
    private static let insets = EdgeInsets(top: 5, leading: 12, bottom: 0, trailing: 15)
    /// The least room between two entries; whatever the foot has over is spread
    /// evenly between them, so the line reads as one run of even gaps.
    ///
    /// A floor rather than the figure: the entries are `fixedSize`, so the six
    /// words and the head take all but a few points of the foot, and the spread
    /// settles around 4. Stated as the board's 9 it would be more than the foot
    /// has, and SwiftUI takes that difference out of a word — the first thing to
    /// go was the head's `+`, which `testTheKeyStripIsOneLine` now measures.
    static let gap: CGFloat = 3
    /// What Esc gets on top of the gap every entry gets: the board's own margin
    /// on the last entry, which is all the separation the key that is not a
    /// chord needs now the divider is gone.
    static let escapeMargin: CGFloat = 8

    /// The room before an entry. Esc closes the run and is the one entry with a
    /// margin of its own; stated here rather than inside the row so the rule can
    /// be read without a render.
    static func spacing(before key: AgentReplyStripKey, of strip: AgentReplyStrip) -> CGFloat {
        key == strip.keys.last ? gap + escapeMargin : gap
    }

    var body: some View {
        VStack(spacing: 0) {
            LoreTheme.Surface.line.frame(height: 1)
            HStack(spacing: 0) {
                head
                ForEach(strip.keys) { key in
                    Spacer(minLength: Self.spacing(before: key, of: strip))
                    entry(key)
                }
            }
            .frame(height: Self.height - Self.insets.top - 1)
            .padding(Self.insets)
        }
        .padding(.top, Self.lead)
        .padding(.horizontal, -Self.bleed)
    }

    /// The modifier the four letters after it are pressed with.
    private var head: some View {
        HStack(spacing: 3) {
            LoreKeycapRun(caps: [AgentReplyStrip.head], line: .strip)
            Text("+")
                .font(.system(size: Self.wordSize))
                .foregroundStyle(LoreTheme.TextColor.faint)
                .fixedSize()
        }
        .accessibilityHidden(true)
    }

    /// The words a step smaller and quieter than the rows above them, so the
    /// strip sits behind the content; the caps keep the muted ink, because the
    /// key is the part that has to stay legible.
    private static let wordSize: CGFloat = 9.5

    private func entry(_ key: AgentReplyStripKey) -> some View {
        HStack(spacing: 3) {
            LoreKeycapRun(caps: key.caps, line: .strip)
            Text(key.word)
                .font(.system(size: Self.wordSize))
                .foregroundStyle(LoreTheme.TextColor.faint)
                // Its own width, never a column's: a word shortened to "Unmu…"
                // has stopped saying what the key does.
                .fixedSize()
        }
        .loreTipReport(
            AgentReplyTipOwner.key(key.id), key.tooltip, keys: key.fullCaps,
            in: agentReplyTipSpace, tip: $tip
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(key.word), \(key.fullCaps.joined(separator: " "))")
    }
}

// MARK: - The capsule

/// The quiet capsule in the player's place (board f, g), under the dictation
/// bubble because the panel hangs lower than it does. Live: the panel's poll
/// puts it up and takes it down off the same reading the words come from.
struct AgentReplyWaitingView: View {
    let capsule: AgentReplyWaitingCapsule
    /// The capsule moves the window exactly as the player does (#267): it is
    /// the same window, and the place it is left at is the same place.
    var onDrag: ((BubbleDrag) -> Void)?

    @State private var tip: AgentReplyTip?

    var body: some View {
        VStack(spacing: 0) {
            words
            AgentReplyTipRow(tip: tip, width: AgentReplyPlayerView.plateWidth)
        }
        .frame(width: AgentReplyPlayerView.plateWidth)
        .coordinateSpace(.named(agentReplyTipSpace))
    }

    private var words: some View {
        HStack(spacing: 7) {
            if capsule.isMuted {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(LoreTheme.TextColor.muted)
            }
            Text(capsule.words)
                .font(.system(size: 12))
                .foregroundStyle(LoreTheme.TextColor.primary)
                .lineLimit(1)
            if !capsule.keys.isEmpty {
                LoreKeycapRun(caps: capsule.keys)
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, capsule.keys.isEmpty ? 13 : 6)
        .frame(height: 28)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(LoreTheme.Shadow.windowRim, lineWidth: 0.5))
        .loreTipReport(
            AgentReplyTipOwner.capsule, capsule.tooltip, keys: capsule.keys,
            in: agentReplyTipSpace, tip: $tip
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            capsule.isMuted
                ? "\(capsule.words), \(capsule.tooltip), fn M"
                : "\(capsule.words), \(capsule.tooltip)"
        )
        .gesture(BubbleDrag.gesture { onDrag?($0) })
    }
}

// MARK: - The tooltip lore draws for itself

/// The player's own coordinate space, so every element reports the pointer in
/// the numbers the card is placed in.
private let agentReplyTipSpace = "lore.replies.tip"

/// Which element of the player a line belongs to. Identity rather than the
/// line, for the reason `LoreTipLine` states.
enum AgentReplyTipOwner: Hashable, Sendable {
    /// The first line of a chat's name: the workspace and tab (#267).
    case row(UUID)
    /// …and the second, which cuts on its own and says its own whole line.
    case meta(UUID)
    /// The playing card's own text, which is where the click's word lives (#263).
    case card(UUID)
    case go(UUID)
    case key(String)
    /// The header's × (#263).
    case close
    case capsule
}

/// One line of the player's copy table (`LoreTipLine`, shared with the bubble's
/// own tooltip since #207 drew the first one).
typealias AgentReplyTip = LoreTipLine<AgentReplyTipOwner>

/// The room a line needs under the plate, kept whether one is showing or not —
/// so a tooltip appearing never resizes the window or moves the plate.
///
/// The card is the bubble's own (`BubbleTipCard`), with the plate's width as
/// its cap — the player's lines are whole sentences — and no arrow, because
/// this board draws the plain macOS tooltip under the pointer.
struct AgentReplyTipRow: View {
    let tip: AgentReplyTip?
    let width: CGFloat

    var body: some View {
        Color.clear
            .frame(width: width, height: BubbleTipCard.room)
            .overlay(alignment: .topLeading) {
                if let tip {
                    BubbleTipCard(
                        text: tip.text, pointerX: tip.pointerX, canvasWidth: width,
                        keys: tip.keys, widthCap: width, showsArrow: false
                    )
                    .padding(.top, BubbleTipCard.gap)
                }
            }
    }
}
