import AppKit
import SwiftUI

/// The agent replies in the floating player (#260, #263, #264), drawn to the
/// approved board `docs/design/prototypes/agent-replies-player.html` (v4.0),
/// whose copy table is the contract for every word here.
///
/// Three surfaces, never two at once: the replies as one list with the open one
/// as a card (board a, b), the quiet capsule that says how many replies wait
/// while a microphone is in use or mute is on (d, e), and nothing at all.
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
    /// R is not among them since #278: its word would have to be Pause while a
    /// reply speaks — the same act as the Esc beside it. Settings lists it, and
    /// the card's own button carries its name (board v4.0).
    static let stripOrder: [Self] = [.previous, .next, .goToChat, .mute]
}

/// One entry of the key strip: the key as its cap prints it, the word that is
/// true right now, and the line it says on hover.
struct AgentReplyStripKey: Equatable, Sendable, Identifiable {
    /// The whole chord, for the tooltip and for VoiceOver: neither of them has a
    /// head to read the `fn` from.
    let fullCaps: [String]
    /// What this key does at this moment: "Mute" or "Unmute", "Pause" or "Hide".
    let word: String
    /// The copy table's line for it; the chords keep the pair Settings names, so
    /// the two never disagree about the key.
    let tooltip: String
    /// Drawn dimmed: J while the reply in the player has no chat to go to
    /// (board v4.0 §02, "No place to go to").
    var isDimmed = false

    /// The cap of this entry alone — the letter for a chord, since the strip
    /// prints `fn` once at its head, and `esc` for the key that is not one.
    /// The last of the chord either way, never a second field to keep in step
    /// with the first.
    var cap: String { fullCaps.last ?? "" }

    var id: String { fullCaps.joined() }
}

/// The strip at the player's foot, as the board prints it: `fn +` at the head
/// of one shape holding the four chords it governs, then Esc outside it.
///
/// Every word is read from state and none is stored — the strip says what the
/// key will do if it is pressed now, which is the same rule the tooltips and
/// Esc itself follow (`no-false-positives.md`).
struct AgentReplyStrip: Equatable, Sendable {
    /// The head: the modifier the four letters after it are pressed with.
    static let head = "fn"
    /// The copy table's line for Esc, the one key that does two things (#263).
    static let escapeTooltip = "Pauses. Press again to hide the player."

    /// The four chords the head governs, in reading order.
    let chords: [AgentReplyStripKey]
    /// Esc, which is not one of them and stands outside their shape.
    let escape: AgentReplyStripKey

    /// - Parameters:
    ///   - goToWord: the word on the card's own button — "Go to" for a chat
    ///     that is open, "Open" for one that is not. One action, one name. Nil
    ///     when the card's reply has no chat to go to: J keeps its word and is
    ///     drawn dimmed.
    ///   - isSpeaking: what the next Esc does: pause a reply that speaks,
    ///     otherwise put the player away.
    init(isMuted: Bool, isSpeaking: Bool, goToWord: String?) {
        chords = HotkeyManager.AgentReplyChord.stripOrder.map { chord in
            let word: String = switch chord {
            case .goToChat: goToWord ?? "Go to"
            case .mute: isMuted ? "Unmute" : "Mute"
            // The two whose word is the whole of what the key does: the copy
            // table names them once, in `name`, and the strip reads it. R is
            // not in `stripOrder`.
            case .previous, .next, .playOrPause: chord.name
            }
            return AgentReplyStripKey(
                fullCaps: chord.caps, word: word, tooltip: chord.name,
                isDimmed: chord == .goToChat && goToWord == nil
            )
        }
        escape = AgentReplyStripKey(
            fullCaps: ["esc"], word: isSpeaking ? "Pause" : "Hide", tooltip: Self.escapeTooltip
        )
    }

    /// The live strip: the words come from the same reading the keys act on.
    @MainActor
    init(replies: AgentReplyController, chats: AgentChatNavigator) {
        self.init(
            isMuted: replies.isMuted, isSpeaking: replies.isSpeaking,
            goToWord: replies.openReply.flatMap { chats.destination(for: $0)?.title }
        )
    }
}

// MARK: - When a reply arrived

/// The time on every row (board v4.0 §03): minutes while a reply is fresh, then
/// the clock, so the list reads like the evening it came from.
enum AgentReplyTime {
    /// `now` under a minute; `N min` under ten, whole minutes rounded down; the
    /// clock the same day; `Yesterday` and the clock; the weekday and the clock
    /// within a week; the day, the month and the clock before that.
    ///
    /// One language, the UI's: the words, the weekday and the month are
    /// English whatever the Mac's language, while the clock keeps the Mac's own
    /// hour cycle and its region's order of day and month — `01:39` on a
    /// 24-hour Mac, `1:39 AM` on a 12-hour one.
    ///
    /// Pure: the caller hands it the moment to draw from.
    static func label(
        arrived: Date, now: Date,
        calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> String {
        let seconds = now.timeIntervalSince(arrived)
        if seconds < 60 { return "now" }
        if seconds < 600 { return "\(Int(seconds / 60)) min" }
        var english = Locale.Components(locale: locale)
        english.languageComponents = Locale.Language.Components(
            languageCode: .english, script: nil, region: locale.language.region
        )
        english.hourCycle = locale.hourCycle
        let style = Date.FormatStyle(
            locale: Locale(components: english), calendar: calendar, timeZone: calendar.timeZone
        )
        let clock = arrived.formatted(style.hour().minute())
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: arrived), to: calendar.startOfDay(for: now)
        ).day ?? 0
        switch days {
        case ...0: return clock
        case 1: return "Yesterday \(clock)"
        case 2...6: return "\(arrived.formatted(style.weekday(.abbreviated))) \(clock)"
        default: return "\(arrived.formatted(style.day().month(.abbreviated))) \(clock)"
        }
    }
}

// MARK: - The list, as the player draws it

/// What the player draws and in which order (board v4.0 §01): every reply the
/// store keeps, in arrival order — oldest at the top, newest at the bottom —
/// which never changes. One reply is open as the card; every other is a row.
///
/// One list drawn by one loop, and every reply is in it: the window is how much
/// of it shows, and the rest is reached by scrolling (board Notes), so a reply
/// can never become unreachable by sitting too far from the card.
struct AgentReplyListLayout: Equatable, Sendable {
    /// One drawn thing: a reply's row or the card.
    enum Entry: Equatable, Sendable, Identifiable {
        /// `isNew`: reading has not begun on it, so it carries the dot.
        /// `ruleBelow`: the next entry is a row too — no rule touches the card.
        case row(index: Int, isNew: Bool, ruleBelow: Bool)
        case card(index: Int, isNew: Bool)

        static let cardID = "card"

        var id: String {
            switch self {
            case .row(let index, _, _): "row\(index)"
            case .card: Self.cardID
            }
        }
    }

    let entries: [Entry]

    /// - Parameters:
    ///   - card: the queue's `openIndex` — the one being read, or with nothing
    ///     playing the one that will be; past the last reply, the last one, whose
    ///     Go to is how the chat that just spoke is answered for the ten seconds
    ///     the player stays (board Notes, "The last ten seconds").
    ///   - started: the queue's `startedIndices`. Every other reply is one not
    ///     heard yet: that set is the only mark the queue keeps (#266), and a
    ///     reply started and left carries no dot.
    init(count: Int, card: Int?, started: Set<Int>) {
        entries = (0..<count).map { index in
            let isNew = !started.contains(index)
            guard index != card else { return .card(index: index, isNew: isNew) }
            return .row(index: index, isNew: isNew, ruleBelow: index + 1 < count && index + 1 != card)
        }
    }
}

// MARK: - The player

/// The title bar with its ? and ×, the replies as one list with the open one as
/// a card, the one-line key strip — and, under all of it, the room one tooltip
/// line needs (`AgentReplyTipRow`).
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
    /// The whole list as it came out, so a list shorter than the window takes
    /// only the room it needs. Nil until it has been laid out, which is the
    /// window itself — never more.
    @State private var listHeight: CGFloat?

    /// The board's plate (v4.0): 384 across, one grid through it.
    static let plateWidth: CGFloat = 384
    /// The list inside the plate: 6 from each side — the edge the card's fill,
    /// the rules and the ?'s card span — and 4 above and below.
    static let listInset = EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
    /// What the list shows before it scrolls: frame a's list — eight rows, the
    /// six rules between them, and the card holding a four-line reply with its
    /// air. The plate is as tall as its rows up to this, 596 with the title bar
    /// and the strip, and past it the list scrolls (board Notes).
    static let window: CGFloat =
        listInset.top + listInset.bottom + 8 * AgentReplyRowView.height + 6 * AgentReplyRowView.rule
            + 2 * AgentReplyCardView.air + AgentReplyCardView.height(lines: 4)

    private var layout: AgentReplyListLayout {
        AgentReplyListLayout(
            count: replies.queue.replies.count,
            card: replies.queue.openIndex,
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
        // The card's chat state, read live for as long as the player is up: at
        // once when it appears, then on its own cadence (#258, #260 review —
        // the button used to open missing for a tick).
        .task { await chats.readWhileShown() }
    }

    private var plate: some View {
        VStack(spacing: 0) {
            AgentReplyTitleBar(replies: replies, mark: mark, tip: $tip)
            list
            AgentReplyKeyStrip(strip: AgentReplyStrip(replies: replies, chats: chats), tip: $tip)
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

    /// Every reply in one scroll, the window's worth of it showing.
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
            // Put on the card whenever the list changes: its top at the top of
            // the window, which the scroll's own bounds turn into "at the
            // bottom" whenever the card sits in the list's last window — the
            // newest reply is then in view, and a card further up is shown
            // with what plays after it.
            .task(id: layout) {
                proxy.scrollTo(AgentReplyListLayout.Entry.cardID, anchor: .top)
            }
        }
    }
}

/// The plate's title bar (board v4.0, #289): 30 tall, `--card2` over the plate,
/// its rule the plate's full width, one axis through its middle carrying lore's
/// mark centred on the rows' slot, the title, the ? after it and the × on the
/// right.
///
/// Neither the mark nor the title is a control: pressed and dragged, they move
/// the plate like any bare part of it. The × withdraws the player exactly as a
/// tap of fn does (#278), and never the speech, which is what its line says.
///
/// Its own view so the render tests can put it over the list drawn flat.
struct AgentReplyTitleBar: View {
    let replies: AgentReplyController
    let mark: NSImage
    @Binding var tip: AgentReplyTip?

    /// Where the ?'s centre stands across the plate, which is where the card's
    /// caret goes — measured, since it follows the title's own width.
    @State private var helpMarkX: CGFloat = 0

    static let height: CGFloat = 30
    /// The mark at the 16 of a title-bar icon, centred on the rows' 20 pt slot.
    private static let markSide: CGFloat = 16
    private static let leading =
        AgentReplyPlayerView.listInset.leading + (AgentReplyRowView.slot - markSide) / 2
    /// Between the mark and the title.
    private static let gap: CGFloat = 7
    /// questionmark.circle in a 13 pt box, 8.5 after the title: the board's 7
    /// and the ?'s own margin of 1.5.
    private static let helpSide: CGFloat = 13
    private static let helpGap: CGFloat = 8.5
    /// The ×'s glyph draws 5.5 inside its 20 pt box, so the box's 10 of
    /// trailing puts the glyph's own edge on the rail the times end on.
    private static let closeSide: CGFloat = 20
    private static let trailing: CGFloat = 10

    /// The ×'s own line, in the board's copy table: what it does, in the words
    /// the strip's esc uses when nothing speaks — one action, one name.
    static let hideName = "Hide the player"

    var body: some View {
        HStack(spacing: 0) {
            Image(nsImage: mark)
                .resizable()
                .frame(width: Self.markSide, height: Self.markSide)
                // The title says whose panel this is.
                .accessibilityHidden(true)
            title
                .padding(.leading, Self.gap)
            helpMark
                .padding(.leading, Self.helpGap)
            Spacer(minLength: 0)
            closeMark
        }
        .padding(.leading, Self.leading)
        .padding(.trailing, Self.trailing)
        .frame(height: Self.height)
        .background(
            LoreTheme.Surface.card2,
            in: UnevenRoundedRectangle(
                topLeadingRadius: LoreTheme.Radius.panel,
                topTrailingRadius: LoreTheme.Radius.panel
            )
        )
        .overlay(alignment: .bottom) {
            LoreTheme.Surface.line.frame(height: 0.5)
        }
        .onDisappear { replies.help.reset() }
    }

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
            .font(.system(size: 11.5))
            .foregroundStyle(help.isOpen ? LoreTheme.TextColor.primary : LoreTheme.TextColor.muted)
            .frame(width: Self.helpSide, height: Self.helpSide)
            // The pointer gets 2 more on every side.
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
            .frame(width: Self.closeSide, height: Self.closeSide)
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
}

/// The entries as they are drawn: every reply in arrival order, the open one as
/// the card, the rules between rows — one list in one loop.
///
/// Its own view, and not private, because a `ScrollView`'s content draws as
/// nothing in an `ImageRenderer`: this is what the render tests put beside the
/// board, while the plate wraps the same thing in the scroll.
struct AgentReplyListView: View {
    let layout: AgentReplyListLayout
    let replies: AgentReplyController
    let chats: AgentChatNavigator
    /// The moment the times are drawn from in a render; nil follows the clock.
    var now: Date?
    @Binding var tip: AgentReplyTip?

    /// How often the times are drawn again while the player is up: "now" is
    /// gone within ten seconds of the minute, and nothing else moves faster.
    static let timeTick: TimeInterval = 10

    var body: some View {
        // Who each reply is from does not move with the clock, so it is read
        // once per change of the list, outside the timeline.
        let list = replies.queue.replies
        let names = list.map(chats.name(for:))
        let workspaces = AgentChatName.workspacesShown(for: names)
        TimelineView(.periodic(from: .now, by: Self.timeTick)) { context in
            let heading = { (index: Int, isNew: Bool) in
                AgentReplyHeading(
                    title: names[index].title, workspace: workspaces[index],
                    time: AgentReplyTime.label(arrived: list[index].receivedAt, now: now ?? context.date),
                    isNew: isNew
                )
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(layout.entries) { entry in
                    switch entry {
                    case .row(let index, let isNew, let ruleBelow):
                        AgentReplyRowView(reply: list[index], heading: heading(index, isNew), replies: replies)
                        if ruleBelow {
                            LoreTheme.Surface.line
                                .frame(height: AgentReplyRowView.rule)
                                .padding(.leading, AgentReplyRowView.slot)
                        }
                    case .card(let index, let isNew):
                        AgentReplyCardView(
                            reply: list[index], heading: heading(index, isNew), replies: replies,
                            chats: chats, tip: $tip
                        )
                    }
                }
            }
        }
        .padding(AgentReplyPlayerView.listInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - A reply as a row

/// What the first line of a row or the card says: which chat, its workspace
/// when another chat in the list shares its name, when the reply arrived, and
/// whether it has been heard.
struct AgentReplyHeading: Equatable {
    let title: String
    let workspace: String?
    let time: String
    let isNew: Bool

    /// The copy table's VoiceOver line: the name, then "Not heard yet" on a row
    /// that carries the dot.
    var spoken: String {
        [title, workspace, isNew ? "Not heard yet" : nil, time]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// The first line of a row and of the card (board v4.0 §02): a fixed 20 pt slot
/// for the dot or the speaker, the chat's name — semibold while not heard and
/// on the card, medium once heard — its workspace small and muted when shown,
/// and the time ending on the rail.
private struct AgentReplyNameLine: View {
    let heading: AgentReplyHeading
    /// The reply is speaking: the speaker takes the dot's slot.
    var isSpeaking = false
    let isBold: Bool

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if isSpeaking {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(LoreTheme.Typography.meta)
                        .foregroundStyle(LoreTheme.Accent.blue)
                        .frame(width: 15, height: 15)
                } else if heading.isNew {
                    Circle()
                        .fill(LoreTheme.Accent.blue)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: AgentReplyRowView.slot)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(heading.title)
                    .font(isBold ? LoreTheme.Typography.control : LoreTheme.Typography.body.weight(.medium))
                    .foregroundStyle(LoreTheme.TextColor.primary)
                    .lineLimit(1)
                if let workspace = heading.workspace {
                    Text(workspace)
                        .font(LoreTheme.Typography.meta)
                        .foregroundStyle(LoreTheme.TextColor.muted)
                        .fixedSize()
                        .padding(.leading, 6)
                }
                Spacer(minLength: 10)
                Text(heading.time)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .fixedSize()
            }
        }
        .frame(height: AgentReplyRowView.nameLine)
    }
}

/// One reply as a row (board v4.0 §02): the chat and the time over the first
/// line of what it said. Clicking the row plays that reply from the beginning.
///
/// Not private: its height is what the list's window is counted in, and
/// `AgentReplyPanelTests` holds the arithmetic to the drawing.
struct AgentReplyRowView: View {
    let reply: AgentReply
    let heading: AgentReplyHeading
    let replies: AgentReplyController

    /// The one grid (board Notes): a 20 pt slot for the dot or the speaker,
    /// every name, first line and card text starting after it, and 10 from the
    /// time's end to the list's edge — the rail every time, the card's Go to
    /// and esc end on.
    static let slot: CGFloat = 20
    static let trailing: CGFloat = 10
    /// The row: 6 above, the name's line at 17, 1, the first line at 16, 7
    /// below — 47 — and a 0.5 rule to the next row.
    static let nameLine: CGFloat = 17
    static let lineGap: CGFloat = 1
    static let previewLine: CGFloat = 16
    static let insets = EdgeInsets(top: 6, leading: 0, bottom: 7, trailing: trailing)
    static let height = insets.top + nameLine + lineGap + previewLine + insets.bottom
    static let rule: CGFloat = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: Self.lineGap) {
            AgentReplyNameLine(heading: heading, isBold: heading.isNew)
            Text(reply.firstLine)
                .font(LoreTheme.Typography.secondary)
                .foregroundStyle(LoreTheme.TextColor.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: Self.previewLine, maxHeight: Self.previewLine, alignment: .leading)
                .padding(.leading, Self.slot)
        }
        .padding(Self.insets)
        .frame(height: Self.height)
        // The row is the control: a click anywhere on it plays that reply.
        .contentShape(Rectangle())
        .onTapGesture { replies.playOrPause(replyID: reply.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(heading.spoken), \(reply.firstLine)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - The reply open

/// The one reply open (board v4.0 §01): the one being read, or with nothing
/// playing the one that will be. Its name's line as on a row, the whole reply —
/// never cut, it grows — then play or pause, time gone, the bar, time left, and
/// the button to its chat.
///
/// Not private: its height is part of what the list's window is counted in.
struct AgentReplyCardView: View {
    let reply: AgentReply
    let heading: AgentReplyHeading
    let replies: AgentReplyController
    let chats: AgentChatNavigator
    @Binding var tip: AgentReplyTip?

    /// 8 above, 9 below, the rows' 10 at the trailing edge, and 2 of air above
    /// and below the fill.
    static let insets = EdgeInsets(top: 8, leading: 0, bottom: 9, trailing: AgentReplyRowView.trailing)
    static let air: CGFloat = 2
    /// The reply at 13 (`Typography.body`) on a 19 pt line, 4 under the
    /// name's line.
    private static let textSize: CGFloat = 13
    private static let textLine: CGFloat = 19
    private static let textGap: CGFloat = 4
    /// The control line: 9 under the words, 22 tall — the button to the chat.
    private static let controlsGap: CGFloat = 9
    private static let controlsHeight: CGFloat = 22
    /// The play button's 20 pt box starts 5 before the words, so its glyph
    /// stands on their edge.
    private static let buttonSide: CGFloat = 20
    private static let buttonOutdent: CGFloat = 5

    /// The card around `lines` lines of the reply, its air not counted.
    static func height(lines: Int) -> CGFloat {
        insets.top + AgentReplyRowView.nameLine + textGap + CGFloat(lines) * textLine
            + controlsGap + controlsHeight + insets.bottom
    }

    /// What SwiftUI adds between two of the face's own lines to make them 19;
    /// half of it again above the first and below the last, as a line box has.
    private static var lineSpacing: CGFloat {
        let font = SystemFont.metrics(size: textSize)
        return textLine - ceil(font.ascender - font.descender + font.leading)
    }

    /// This reply is the one the queue is on, and reading has begun on it.
    private var isOn: Bool {
        replies.currentReply?.id == reply.id && replies.playback != .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentReplyNameLine(heading: heading, isSpeaking: isOn && replies.isSpeaking, isBold: true)
            Text(reply.said.text)
                .font(LoreTheme.Typography.body)
                .foregroundStyle(LoreTheme.TextColor.primary)
                .lineSpacing(Self.lineSpacing)
                .padding(.vertical, Self.lineSpacing / 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Self.textGap)
                .padding(.leading, AgentReplyRowView.slot)
            controls
                .padding(.top, Self.controlsGap)
                .padding(.leading, AgentReplyRowView.slot - Self.buttonOutdent)
        }
        .padding(Self.insets)
        .background(
            LoreTheme.Surface.card3, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.card)
        )
        // The card is the control (#263): a click on it but its buttons pauses
        // the reply being read, and carries it on again.
        .contentShape(RoundedRectangle(cornerRadius: LoreTheme.Radius.card))
        .onTapGesture { replies.playOrPause(replyID: reply.id) }
        .padding(.vertical, Self.air)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(heading.spoken)
    }

    /// Play or pause, time gone, the bar, time left with a minus sign as Voice
    /// Memos shows it, and the button to the chat — or the bar running to the
    /// rail when the reply has no chat to go to.
    private var controls: some View {
        let isSpeaking = isOn && replies.isSpeaking
        let share = isOn ? replies.progress : 0
        // Whole seconds on both sides, so gone and left always add up to the
        // reply's length.
        let total = Int(reply.estimatedSeconds)
        let gone = min(Int(reply.estimatedSeconds * share), total)
        // The copy table's names for the button: one action, one name with
        // Settings' Play / Pause.
        let word = isSpeaking ? "Pause" : "Play"
        return HStack(spacing: 8) {
            Image(systemName: isSpeaking ? "pause.fill" : "play.fill")
                .font(.system(size: 12))
                .foregroundStyle(LoreTheme.TextColor.primary)
                .frame(width: Self.buttonSide, height: Self.buttonSide)
                .contentShape(Rectangle())
                .onTapGesture { replies.playOrPause(replyID: reply.id) }
                .loreTipReport(
                    AgentReplyTipOwner.play(reply.id), word,
                    keys: HotkeyManager.AgentReplyChord.playOrPause.caps,
                    in: agentReplyTipSpace, tip: $tip
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(word), fn R")
                .accessibilityAddTraits(.isButton)
            Text(ReadAloudController.timeLabel(Double(gone)))
            PlayerProgressBar(progress: share, fill: LoreTheme.Accent.blue, track: LoreTheme.Surface.line2)
                .accessibilityHidden(true)
            Text("\u{2212}" + ReadAloudController.timeLabel(Double(total - gone)))
            AgentReplyGoButton(reply: reply, chats: chats, tip: $tip)
        }
        .font(LoreTheme.Typography.meta)
        .monospacedDigit()
        .foregroundStyle(LoreTheme.TextColor.muted)
        .frame(height: Self.controlsHeight)
    }
}

/// The card's button to its chat (board v4.0): "Go to" when the app runs with
/// the chat open, "Open" otherwise (#258) — a neutral capsule, and nothing at
/// all when the reply has no chat to go to. Read live: the destination comes
/// from the navigator's latest pass, and the click takes a reading of its own.
private struct AgentReplyGoButton: View {
    let reply: AgentReply
    let chats: AgentChatNavigator
    @Binding var tip: AgentReplyTip?

    var body: some View {
        // Nil is honest: a reply that named no app and holds no pane has no
        // chat to be taken to, so no button is drawn for it.
        if let destination = chats.destination(for: reply) {
            Text(destination.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LoreTheme.TextColor.primary)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(LoreTheme.Surface.line2, in: Capsule())
                .contentShape(Capsule())
                .onTapGesture { Task { await chats.open(reply) } }
                .loreTipReport(
                    AgentReplyTipOwner.go(reply.id), destination.tooltip,
                    keys: HotkeyManager.AgentReplyChord.goToChat.caps,
                    in: agentReplyTipSpace, tip: $tip
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(destination.title), \(destination.tooltip), fn J")
                .accessibilityAddTraits(.isButton)
        }
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

    /// The row's second line: the reply's first line of words, cut to the
    /// row's width where it is drawn — the bound is only what a row can ever
    /// show.
    var firstLine: String {
        ReadAloudController.snippet(of: said.text, max: 200)
    }
}

// MARK: - The key strip

/// Every key the player answers to, in one line at its foot (board v4.0): one
/// shape — `--card3` at the chip radius — holding `fn +` and the four chords
/// pressed with it, and Esc outside it, ending on the rail. A legend, not a
/// control: the keys are the controls.
///
/// Not private: the render tests measure it beside the board.
struct AgentReplyKeyStrip: View {
    let strip: AgentReplyStrip
    @Binding var tip: AgentReplyTip?

    /// 30 tall under a 0.5 rule the plate's full width.
    static let height: CGFloat = 30
    /// The group starts on the list's edge; Esc ends on the rail.
    private static let insets = EdgeInsets(
        top: 0, leading: AgentReplyPlayerView.listInset.leading, bottom: 0,
        trailing: AgentReplyPlayerView.listInset.trailing + AgentReplyRowView.trailing
    )
    /// The group: 22 tall, 3 before `fn` and 8 after the last word, 10
    /// between its entries.
    private static let groupHeight: CGFloat = 22
    private static let groupInsets = EdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 8)
    private static let entryGap: CGFloat = 10
    /// The gap when the board's does not fit: muted while a reply speaks,
    /// Unmute and Pause together want 5 pt more than the plate has at 10.
    private static let tightGap: CGFloat = 8
    /// Between a keycap and its word.
    private static let capGap: CGFloat = 4

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(gap: Self.entryGap)
            line(gap: Self.tightGap)
        }
        .frame(height: Self.height)
        .overlay(alignment: .top) {
            LoreTheme.Surface.line.frame(height: 0.5)
        }
    }

    private func line(gap: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: gap) {
                head
                ForEach(strip.chords) { entry($0, outside: false) }
            }
            .padding(Self.groupInsets)
            .frame(height: Self.groupHeight)
            .background(
                LoreTheme.Surface.card3, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.chip)
            )
            Spacer(minLength: 0)
            entry(strip.escape, outside: true)
        }
        .padding(Self.insets)
    }

    /// The modifier the four letters after it are pressed with.
    private var head: some View {
        HStack(spacing: Self.capGap) {
            Self.keycap(AgentReplyStrip.head, outside: false)
            Text("+")
                .font(.system(size: 12))
                .foregroundStyle(LoreTheme.TextColor.muted)
                .fixedSize()
        }
        .accessibilityHidden(true)
    }

    private func entry(_ key: AgentReplyStripKey, outside: Bool) -> some View {
        HStack(spacing: Self.capGap) {
            Self.keycap(key.cap, outside: outside)
            Text(key.word)
                .font(LoreTheme.Typography.meta)
                .foregroundStyle(LoreTheme.TextColor.muted)
                // Its own width, never a column's: a word shortened to "Unmu…"
                // has stopped saying what the key does.
                .fixedSize()
        }
        .opacity(key.isDimmed ? 0.45 : 1)
        .loreTipReport(
            AgentReplyTipOwner.key(key.id), key.tooltip, keys: key.fullCaps,
            in: agentReplyTipSpace, tip: $tip
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(key.word), \(key.fullCaps.joined(separator: " "))")
    }

    /// The bubble's own keycap at the strip's size (#235), on `--line2` inside
    /// the group and on `--card3` (white at 0.06) for Esc outside it: each one
    /// step up from the ground it stands on.
    private static func keycap(_ cap: String, outside: Bool) -> some View {
        DictationIndicatorView.BubblePill.keycap(bright: true, .strip, plate: outside ? 0.06 : nil)
            .label(cap)
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
    /// The card's play or pause button, which names the click (board v4.0).
    case play(UUID)
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
