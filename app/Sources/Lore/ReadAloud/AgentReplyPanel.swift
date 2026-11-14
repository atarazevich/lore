import AppKit
import SwiftUI

/// The agent replies in the floating player (#260, #263, #264), drawn to the
/// approved board `docs/design/prototypes/agent-replies-player.html` (v5.2),
/// whose copy table is the contract for every word here.
///
/// Three surfaces, never two at once: the replies as one list with the open one
/// as a card (board a, b), the capsule that says how many replies came in
/// silently (d, e, f), and nothing at all. The decision is `AgentReplySurface`,
/// and both the view and the panel's poll read it from the live controller —
/// so the window and its content can never disagree (`no-false-positives.md`).
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
    /// The player is up when he opened the list with a hold (`isListOpen`), or
    /// while a reply is being read — speaking, paused, or the ten seconds after
    /// the last one (`isLingering`, #260 review) — unless he put it away during
    /// this very reply (`isHiddenUntilNextReply`, #285). A paused reply or the
    /// linger under a microphone keeps it out of the way: a dictation or a call
    /// is a moment he chose for something else. Speaking wins over that: a
    /// click in Quiet plays, and the words have to be readable.
    ///
    /// Otherwise, replies that came in silently and are not heard yet show the
    /// capsule (#354) — while he put the player away too, since he did not ask
    /// for that silence.
    static func decide(
        isEnabled: Bool, playback: AgentReplyController.Playback, isHeldByMicrophone: Bool,
        isListOpen: Bool = false, isLingering: Bool = false, isHiddenUntilNextReply: Bool = false,
        capsule: AgentReplyWaitingCapsule? = nil
    ) -> AgentReplySurface {
        guard isEnabled else { return .hidden }
        let reading = playback == .speaking
            || (!isHeldByMicrophone && (playback == .paused || isLingering))
        if isListOpen || (reading && !isHiddenUntilNextReply) { return .player }
        if let capsule, capsule.waiting > 0 { return .waiting(capsule) }
        return .hidden
    }

    /// The same decision off the live controller — the one call both the view
    /// and `ReadAloudPanelManager`'s poll make.
    @MainActor
    static func of(_ replies: AgentReplyController) -> AgentReplySurface {
        decide(
            isEnabled: replies.isEnabled, playback: replies.playback,
            isHeldByMicrophone: replies.isHeldByMicrophone, isListOpen: replies.isListOpen,
            isLingering: replies.isLingering,
            isHiddenUntilNextReply: replies.isHiddenUntilNextReply,
            capsule: AgentReplyWaitingCapsule(replies: replies)
        )
    }
}

/// The capsule in the list's place (board d, e, f): how many replies came in
/// silently, the reply key's cap, and — on hover — why they were silent and
/// the two gestures that act on them.
struct AgentReplyWaitingCapsule: Equatable, Sendable {
    let waiting: Int
    /// Why the newest of them was silent, and whether that still holds now.
    let reason: ReplyQuietReason
    let reasonHolds: Bool
    /// The reply key's cap: R⌥, R⌘, R⇧, R⌃.
    let keyCap: String

    /// "3 replies waiting" / "1 reply waiting".
    var words: String { waiting == 1 ? "1 reply waiting" : "\(waiting) replies waiting" }

    /// The tooltip's first line: the reason, in the present while it holds and
    /// in the past once it ended (board copy table, `quiet`).
    var reasonLine: String {
        switch (reason, reasonHolds) {
        case (.microphone, false): "Another app was using the microphone, so these came in silently."
        case (.game, false): "A game was in front, so these came in silently."
        case (.sound, false): "Another app was playing sound, so these came in silently."
        case (.dictation, false): "You were dictating, so these came in silently."
        case (.meeting, false): "You were recording a meeting, so these came in silently."
        case (.microphone, true): "Another app is using the microphone, so these come in silently."
        case (.game, true): "A game is in front, so these come in silently."
        case (.sound, true): "Another app is playing sound, so these come in silently."
        case (.dictation, true): "You are dictating, so these come in silently."
        case (.meeting, true): "You are recording a meeting, so these come in silently."
        // Only a newer build's event decodes to this; lore never files by it.
        case (.unknown, _): "These came in silently."
        }
    }

    /// The second line, always: the two gestures, with the key's cap in it.
    var gestureLine: [DictationHintPiece] {
        [
            .words("Click "), .key(keyCap),
            .words(waiting == 1 ? " to play it, hold it to show the list." : " to play them, hold it to show the list."),
        ]
    }

    var tooltip: [[DictationHintPiece]] { [[.words(reasonLine)], gestureLine] }
}

extension AgentReplyWaitingCapsule {
    /// The live capsule, or nil when nothing waits silently.
    @MainActor
    init?(replies: AgentReplyController) {
        let waiting = replies.silentWaitingCount
        guard waiting > 0, let silent = replies.silentReason else { return nil }
        self.init(waiting: waiting, reason: silent.reason, reasonHolds: silent.holds, keyCap: replies.keyCap)
    }
}

// MARK: - The keys, as the strip prints them

/// The strip at the player's foot (board §05): one shape holding the reply
/// key's cap and its three gestures — click, twice, hold — each with the word
/// it does now; Esc stands outside it.
///
/// Every word is read from state and none is stored — the strip says what the
/// key will do if it is pressed now, which is the same rule the tooltips and
/// Esc itself follow (`no-false-positives.md`).
struct AgentReplyStrip: Equatable, Sendable {
    /// The group's tooltip, the one line that teaches the key.
    static let keyTooltip = "Click to play or pause, twice for the next reply, hold to show or hide the list"
    /// The copy table's line for Esc, the one key that does two things (#263).
    static let escapeTooltip = "Pauses. Press again to hide the list."
    /// One act, one name: the hold, the second Esc and the × all hide the list.
    static let hideList = "Hide list"

    /// One gesture in the group: the faint word for how it is pressed, and
    /// what it does now.
    struct Gesture: Equatable, Sendable, Identifiable {
        let how: String
        let word: String
        /// Drawn dimmed: Next on the last reply, which has none after it.
        var isDimmed = false
        var id: String { how }
    }

    /// The reply key's cap at the group's head.
    let keyCap: String
    let gestures: [Gesture]
    /// What Esc does now: pause a reply that speaks, otherwise hide the list.
    let escapeWord: String

    init(keyCap: String, isSpeaking: Bool, canPlayNext: Bool) {
        self.keyCap = keyCap
        gestures = [
            Gesture(how: "click", word: isSpeaking ? "Pause" : "Play"),
            Gesture(how: "twice", word: "Next", isDimmed: !canPlayNext),
            Gesture(how: "hold", word: Self.hideList),
        ]
        escapeWord = isSpeaking ? "Pause" : Self.hideList
    }

    /// The live strip: the words come from the same reading the key acts on.
    @MainActor
    init(replies: AgentReplyController) {
        self.init(keyCap: replies.keyCap, isSpeaking: replies.isSpeaking, canPlayNext: replies.canPlayNext)
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
            AgentReplyKeyStrip(strip: AgentReplyStrip(replies: replies), tip: $tip)
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
/// hold of the reply key does (#354), and never the speech.
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

    /// The ×'s own line, in the board's copy table: what it does, and the
    /// gesture that does the same — one act, one name.
    static let hideName = "Hide the list"

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
                AgentReplyTipOwner.close, "\(Self.hideName), hold",
                keys: [replies.keyCap],
                in: agentReplyTipSpace, tip: $tip
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.hideName)
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
        // The copy table's names for the button: the same word the strip
        // prints after click.
        let word = isSpeaking ? "Pause" : "Play"
        return HStack(spacing: 8) {
            Image(systemName: isSpeaking ? "pause.fill" : "play.fill")
                .font(.system(size: 12))
                .foregroundStyle(LoreTheme.TextColor.primary)
                .frame(width: Self.buttonSide, height: Self.buttonSide)
                .contentShape(Rectangle())
                .onTapGesture { replies.playOrPause(replyID: reply.id) }
                .loreTipReport(
                    AgentReplyTipOwner.play(reply.id), word, keys: [replies.keyCap],
                    in: agentReplyTipSpace, tip: $tip
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(word)
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
                    in: agentReplyTipSpace, tip: $tip
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(destination.title), \(destination.tooltip)")
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

/// The reply key in one line at the player's foot (board §05): one shape —
/// `--card3` at the chip radius — holding the key's cap and its three gestures,
/// and Esc outside it, ending on the rail. A legend, not a control: the key is
/// the control.
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
    /// The group: 22 tall, 3 before the cap and 8 after the last word, 10
    /// between its entries.
    private static let groupHeight: CGFloat = 22
    private static let groupInsets = EdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 8)
    private static let entryGap: CGFloat = 10
    /// Between a keycap or a gesture's word and the word after it.
    private static let capGap: CGFloat = 4

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: Self.entryGap) {
                Self.keycap(strip.keyCap, outside: false)
                ForEach(strip.gestures) { gesture($0) }
            }
            .padding(Self.groupInsets)
            .frame(height: Self.groupHeight)
            .background(
                LoreTheme.Surface.card3, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.chip)
            )
            .contentShape(Rectangle())
            .loreTipReport(
                AgentReplyTipOwner.key("reply"), AgentReplyStrip.keyTooltip,
                in: agentReplyTipSpace, tip: $tip
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                ([strip.keyCap] + strip.gestures.map { "\($0.how) \($0.word)" }).joined(separator: ", ")
            )
            .accessibilityHint(AgentReplyStrip.keyTooltip)
            Spacer(minLength: 0)
            escape
        }
        .padding(Self.insets)
        .frame(height: Self.height)
        .overlay(alignment: .top) {
            LoreTheme.Surface.line.frame(height: 0.5)
        }
    }

    private func gesture(_ gesture: AgentReplyStrip.Gesture) -> some View {
        HStack(spacing: Self.capGap) {
            Text(gesture.how)
                .foregroundStyle(gesture.isDimmed ? LoreTheme.TextColor.muted : LoreTheme.TextColor.faint)
            Text(gesture.word)
                .foregroundStyle(LoreTheme.TextColor.muted)
        }
        .font(LoreTheme.Typography.meta)
        // Its own width, never a column's: a word cut short has stopped saying
        // what the key does.
        .fixedSize()
        .opacity(gesture.isDimmed ? 0.45 : 1)
    }

    private var escape: some View {
        HStack(spacing: Self.capGap) {
            Self.keycap("esc", outside: true)
            Text(strip.escapeWord)
                .font(LoreTheme.Typography.meta)
                .foregroundStyle(LoreTheme.TextColor.muted)
                .fixedSize()
        }
        .loreTipReport(
            AgentReplyTipOwner.key("esc"), AgentReplyStrip.escapeTooltip,
            in: agentReplyTipSpace, tip: $tip
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(strip.escapeWord), esc")
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

/// The capsule in the list's place (board d, e, f), under the dictation bubble
/// because the panel hangs lower than it does. Live: the panel's poll puts it
/// up and takes it down off the same reading the words come from. The pointer
/// on it reads the outside for the tooltip's tense, and the tooltip names why
/// the replies were silent and the two gestures that act on them.
struct AgentReplyWaitingView: View {
    let capsule: AgentReplyWaitingCapsule
    let replies: AgentReplyController
    /// The capsule moves the window exactly as the player does (#267): it is
    /// the same window, and the place it is left at is the same place.
    var onDrag: ((BubbleDrag) -> Void)?

    @State private var isPointerOn = false
    @State private var pointerX: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            words
            Color.clear
                .frame(width: AgentReplyPlayerView.plateWidth, height: BubbleTipCard.room)
                .overlay(alignment: .topLeading) {
                    if isPointerOn {
                        BubbleTipCard(
                            text: "", pointerX: pointerX, canvasWidth: AgentReplyPlayerView.plateWidth,
                            widthCap: AgentReplyPlayerView.plateWidth, showsArrow: false,
                            sentence: capsule.tooltip
                        )
                        .padding(.top, BubbleTipCard.gap)
                    }
                }
        }
        .frame(width: AgentReplyPlayerView.plateWidth)
        .coordinateSpace(.named(agentReplyTipSpace))
        .onDisappear { replies.endTooltipReading() }
    }

    private var words: some View {
        HStack(spacing: 7) {
            Text(capsule.words)
                .font(.system(size: 12))
                .foregroundStyle(LoreTheme.TextColor.primary)
                .lineLimit(1)
            LoreKeycapRun(caps: [capsule.keyCap])
                .padding(.leading, 4)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(LoreTheme.Shadow.windowRim, lineWidth: 0.5))
        .onContinuousHover(coordinateSpace: .named(agentReplyTipSpace)) { phase in
            switch phase {
            case .active(let location):
                guard !isPointerOn else { return }
                isPointerOn = true
                pointerX = location.x
                replies.readSurroundingsForTooltip()
            case .ended:
                isPointerOn = false
                replies.endTooltipReading()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(capsule.words), \(capsule.keyCap)")
        .accessibilityHint(capsule.tooltip.plain)
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
