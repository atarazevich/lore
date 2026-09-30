import AppKit
import SwiftUI

// MARK: - View

/// Floating Read Aloud panel (#105, rev 3 — Spotify mini-player idiom).
/// Non-activating panel: real SwiftUI `Button`s don't receive clicks there, so
/// every control is `.contentShape(Rectangle())` + `.onTapGesture` (drag
/// reorder uses a plain `DragGesture` — in-panel only, no NSItemProvider).
///
/// Reads the `@Observable` controller directly and calls its methods; the
/// clock/progress row re-evaluates on a `TimelineView` tick because playback
/// time lives in the `AVQueuePlayer`, outside observation.
///
/// Layout top-to-bottom: identity row (voice avatar · title/subtitle · close
/// pinned top-right, the only ✕ in the panel) → progress row (elapsed · bar ·
/// total) → transport row (speed | ⏮ ▶ ⏭ | queue chip) → expanded "Next up"
/// list (drag to reorder · ▶ play now · trash to remove) → optional notice.
struct ReadAloudPanelView: View {
    let controller: ReadAloudController

    /// View-only state: the queue chip toggles the expanded list.
    @State private var isQueueExpanded = false
    /// Drag-reorder state: which row is being dragged and how far.
    @State private var draggingID: UUID?
    @State private var dragOffset: CGFloat = 0

    /// One content width for every row — the panel never shifts as text,
    /// times or the speed label change.
    private static let contentWidth: CGFloat = 300
    /// Fixed queue-row height; the drag reorder divides by it.
    private static let queueRowHeight: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.showsControls {
                identityRow
                progressRow
                transportRow
                if isQueueExpanded && !controller.upcomingTexts.isEmpty {
                    queueList
                }
            }
            if let notice = controller.notice {
                noticeRow(notice)
            }
        }
        .frame(width: Self.contentWidth)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.panel))
        .fixedSize()
        .environment(\.colorScheme, .dark)
        .onChange(of: controller.pendingCount) { _, count in
            if count == 0 {
                isQueueExpanded = false
            }
        }
    }

    // MARK: Identity row (avatar · title/subtitle · close)

    private var identityRow: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.currentSnippet ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LoreTheme.TextColor.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Close pinned to the top-right corner — nothing is ever above
            // it, and this is the panel's only ✕.
            closeButton
        }
    }

    private var avatar: some View {
        Text(controller.currentVoice?.initial ?? "·")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(LoreTheme.TextColor.primary)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.1))
            )
            .accessibilityLabel("Voice \(controller.currentVoice?.displayName ?? "unknown")")
    }

    /// "Leonid · Russian · reading" ("· clipboard" appended when the text
    /// came from the clipboard fallback, #106 — a stale clipboard must
    /// never read as a mystery).
    private var subtitle: String {
        var parts = controller.currentVoice.map { [$0.displayName, $0.languageName] } ?? []
        parts.append(statusWord)
        if controller.currentText?.fromClipboard == true {
            parts.append("clipboard")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var statusWord: String {
        switch controller.status {
        case .playing: "reading"
        case .paused: "paused"
        case .fetching: "fetching\u{2026}"
        case .idle: ""
        }
    }

    private var closeButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(LoreTheme.TextColor.muted)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onTapGesture { controller.stop() }
            .accessibilityLabel("Stop reading")
    }

    // MARK: Progress row (elapsed · bar · total)

    private var progressRow: some View {
        // Playback time advances outside observation — tick to stay honest.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            // The total firms up once every chunk of the current text is
            // synthesized; until then the row says so.
            PlayerProgressRow(
                elapsed: controller.elapsedSeconds, total: controller.totalSeconds,
                progress: controller.currentProgress
            ) {
                EmptyView()
            }
        }
        .accessibilityLabel("Progress")
    }

    // MARK: Transport row (speed | ⏮ ▶ ⏭ | queue)

    private var transportRow: some View {
        ZStack {
            HStack {
                speedChip
                Spacer()
                if !controller.upcomingTexts.isEmpty {
                    queueChip
                }
            }
            HStack(spacing: 14) {
                transportIcon("backward.end.fill", label: "Restart", enabled: true) {
                    controller.restartCurrentText()
                }
                playPauseButton
                transportIcon(
                    "forward.end.fill", label: "Next", enabled: !controller.upcomingTexts.isEmpty
                ) {
                    controller.skipToNextText()
                }
            }
        }
    }

    private var playPauseButton: some View {
        Group {
            if controller.status == .fetching {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: controller.status == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: 28, height: 28)
                    )
            }
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
        .onTapGesture { controller.togglePlayPause() }
        .accessibilityLabel(controller.status == .playing ? "Pause" : "Play")
    }

    private func transportIcon(
        _ systemName: String, label: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(LoreTheme.TextColor.muted)
            .opacity(enabled ? 1 : 0.3)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .accessibilityLabel(label)
    }

    private var speedChip: some View {
        Text(ReadAloudController.speedLabel(controller.rate))
            .font(LoreTheme.Typography.mono(11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(LoreTheme.TextColor.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                    .fill(Color.white.opacity(0.07))
            )
            .contentShape(Rectangle())
            .onTapGesture { controller.cycleSpeed() }
            .accessibilityLabel("Playback speed \(ReadAloudController.speedLabel(controller.rate))")
    }

    private var queueChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "list.bullet")
                .font(.system(size: 9, weight: .semibold))
            Text("\(controller.pendingCount)")
                .font(LoreTheme.Typography.mono(11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(isQueueExpanded ? LoreTheme.TextColor.primary : LoreTheme.TextColor.muted)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                .fill(Color.white.opacity(isQueueExpanded ? 0.12 : 0.07))
        )
        .contentShape(Rectangle())
        .onTapGesture { isQueueExpanded.toggle() }
        .accessibilityLabel(
            "\(controller.pendingCount) queued, \(isQueueExpanded ? "expanded" : "collapsed")"
        )
    }

    // MARK: Expanded queue ("Next up": reorder · play now · remove)

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Next up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LoreTheme.TextColor.faint)
                .textCase(.uppercase)
                .padding(.top, 2)
                .padding(.bottom, 2)
            ForEach(Array(controller.upcomingTexts.enumerated()), id: \.element.id) { offset, text in
                queueRow(text, offset: offset)
            }
        }
    }

    private func queueRow(_ text: ReadAloudController.QueueText, offset: Int) -> some View {
        HStack(spacing: 6) {
            // Drag handle — reorder within the queue.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LoreTheme.TextColor.faint)
                .frame(width: 16, height: Self.queueRowHeight)
                .contentShape(Rectangle())
                .gesture(dragGesture(for: text.id, offset: offset))
                .accessibilityLabel("Reorder")
            Text(text.snippet)
                .font(.system(size: 11))
                .foregroundStyle(LoreTheme.TextColor.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(ReadAloudController.estimateLabel(chars: text.chars, rate: controller.rate))
                .font(LoreTheme.Typography.mono(10))
                .monospacedDigit()
                .foregroundStyle(LoreTheme.TextColor.faint)
            // Play now — stops the current text, this one leaves the queue.
            Image(systemName: "play.fill")
                .font(.system(size: 9))
                .foregroundStyle(LoreTheme.TextColor.muted)
                .frame(width: 18, height: Self.queueRowHeight)
                .contentShape(Rectangle())
                .onTapGesture { controller.playQueuedNow(id: text.id) }
                .accessibilityLabel("Read now")
            // Remove — trash, never ✕ (that's the panel close).
            Image(systemName: "trash")
                .font(.system(size: 9))
                .foregroundStyle(LoreTheme.TextColor.muted)
                .frame(width: 18, height: Self.queueRowHeight)
                .contentShape(Rectangle())
                .onTapGesture { controller.removeQueued(id: text.id) }
                .accessibilityLabel("Remove from queue")
        }
        .frame(height: Self.queueRowHeight)
        .offset(y: draggingID == text.id ? dragOffset : 0)
        .zIndex(draggingID == text.id ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: draggingID)
    }

    private func dragGesture(for id: UUID, offset: Int) -> some Gesture {
        DragGesture()
            .onChanged { value in
                draggingID = id
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let delta = Int((value.translation.height / Self.queueRowHeight).rounded())
                if delta != 0 {
                    controller.moveQueued(fromOffset: offset, toOffset: offset + delta)
                }
                draggingID = nil
                dragOffset = 0
            }
    }

    // MARK: Notice

    private func noticeRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(LoreTheme.Accent.red)
                .font(.system(size: 12))
            Text(text)
                .font(LoreTheme.Typography.body)
                .foregroundStyle(LoreTheme.TextColor.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - The reading row both players draw

/// elapsed · bar · total, on the mono face, with whatever glyph the caller puts
/// in front of it: the selected-text player's row (#105) and the replies card's
/// (#260) are the same row in two colours.
struct PlayerProgressRow<Leading: View>: View {
    let elapsed: Double
    /// Nil while the total is not known — the row says `–:––` rather than a
    /// figure it would have to guess.
    let total: Double?
    let progress: Double
    var fill: Color = Color.white.opacity(0.45)
    var track: Color = Color.white.opacity(0.12)
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Text(ReadAloudController.timeLabel(elapsed))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule()
                        .fill(fill)
                        .frame(width: max(3, geo.size.width * progress))
                }
            }
            .frame(height: 3)
            .frame(maxWidth: .infinity)
            Text(total.map(ReadAloudController.timeLabel) ?? "\u{2013}:\u{2013}\u{2013}")
        }
        .font(LoreTheme.Typography.mono(10))
        .monospacedDigit()
        .foregroundStyle(LoreTheme.TextColor.muted)
    }
}

// MARK: - The one floating surface, two kinds of reading

/// What the floating panel holds (#260): the selected-text player (#105) and
/// the agent replies (#236), each drawn only when it has something to say.
///
/// The two never clobber each other. They are separate plates in one window, so
/// a reading of selected text that was already running when the feature's
/// switch went on keeps its own controls while the replies keep their list —
/// and in ordinary use only one of them exists at a time, because the selection
/// has no keys while the switch is on (#259).
struct PlayerPanelView: View {
    let controller: ReadAloudController
    let replies: AgentReplyController
    let chats: AgentChatNavigator
    /// Both reply plates move the one window they share (#267).
    var onDrag: ((BubbleDrag) -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            if controller.isPanelVisible {
                ReadAloudPanelView(controller: controller)
            }
            switch AgentReplySurface.of(replies) {
            case .hidden:
                EmptyView()
            case .waiting(let capsule):
                AgentReplyWaitingView(capsule: capsule, onDrag: onDrag)
            case .player:
                AgentReplyPlayerView(
                    replies: replies, chats: chats, mark: LoreMark.chip, onDrag: onDrag
                )
            }
        }
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Manager

/// Owns the shared `TopCenteredPanel` and polls the controllers for
/// visibility and content-driven resize (which also covers queue expand/
/// collapse); everything else flows through observation — the view holds the
/// controllers directly. Sits lower than the dictation indicator so the two
/// never overlap when both are visible, which is also where the board puts the
/// waiting capsule: under the bubble — until it is dragged somewhere else, and
/// then it opens there again for good (#267).
@MainActor
final class ReadAloudPanelManager {
    private var panel: TopCenteredPanel<PlayerPanelView>?
    private var observationTask: Task<Void, Never>?
    /// Whether the capsule is on screen, for the two events its appearance owes
    /// (`no-false-positives.md`: every fire and clear leaves a trace). A
    /// changing count is the same report, so what it says is not kept here.
    private var isCapsuleShown = false
    /// Whether the window is up, so the place it was left at is put back once
    /// per showing rather than twenty times a second (#267).
    private var isWindowShown = false
    /// Where the place lives across launches; nil in a test with no settings.
    private weak var settings: AppSettings?

    /// Vertical clearance under the menu bar: the dictation indicator sits at
    /// 8pt; this panel starts 56pt lower.
    private static let topInset: CGFloat = 64

    func start(
        controller: ReadAloudController, replies: AgentReplyController,
        chats: AgentChatNavigator, settings: AppSettings?
    ) {
        self.settings = settings
        guard let panel = TopCenteredPanel(
            content: PlayerPanelView(
                controller: controller, replies: replies, chats: chats,
                onDrag: { [weak self] phase in self?.drag(phase) }
            ),
            topInset: Self.topInset
        ) else { return }
        self.panel = panel

        observationTask = Task { [weak self, weak controller, weak replies] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let controller, let replies else { break }

                let surface = AgentReplySurface.of(replies)
                self.trace(surface)
                if controller.isPanelVisible || surface != .hidden {
                    self.restorePlaceOnce()
                    self.panel?.show()
                } else {
                    self.isWindowShown = false
                    self.panel?.hide()
                }
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        panel?.hide()
        isCapsuleShown = false
        isWindowShown = false
    }

    /// A drag on either plate. The window does the moving; the end of one is
    /// what is worth remembering and worth a trace.
    private func drag(_ phase: BubbleDrag) {
        guard let panel else { return }
        panel.drag(phase)
        guard phase == .ended else { return }
        settings?.agentReplyPlayerPlace = panel.placedTopLeft
        DiagStore.record(.agentReplyPlayerMoved)
    }

    /// Puts the window back where it was left, once per showing, and judged
    /// against the screens there are now: a place on a display that has been
    /// unplugged is ignored rather than clamped onto whatever is left, and the
    /// window opens where it always did.
    ///
    /// Ignored, never erased: the display comes back, and with it the place he
    /// chose. Nothing about a monitor being unplugged is his decision to undo.
    private func restorePlaceOnce() {
        guard !isWindowShown else { return }
        isWindowShown = true
        panel?.place(at: TopCenteredFrame.remembered(
            settings?.agentReplyPlayerPlace, visibleFrames: NSScreen.screens.map(\.visibleFrame)
        ))
    }

    /// One event when the capsule appears and one when it withdraws — a
    /// changing count is the same report, not a new one.
    private func trace(_ surface: AgentReplySurface) {
        if case .waiting(let capsule) = surface {
            guard !isCapsuleShown else { return }
            isCapsuleShown = true
            DiagStore.record(
                .agentReplyWaitingShown(muted: capsule.isMuted, waiting: capsule.waiting)
            )
        } else if isCapsuleShown {
            isCapsuleShown = false
            DiagStore.record(.agentReplyWaitingWithdrawn)
        }
    }
}
