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
            if controller.status != .idle {
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                    .foregroundStyle(XMOTheme.TextColor.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(XMOTheme.TextColor.muted)
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
            .foregroundStyle(XMOTheme.TextColor.primary)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.1))
            )
            .accessibilityLabel("Voice \(controller.currentVoice?.displayName ?? "unknown")")
    }

    /// "Leonid · Russian · reading"
    private var subtitle: String {
        guard let voice = controller.currentVoice else { return statusWord }
        return "\(voice.displayName) \u{00B7} \(voice.languageName) \u{00B7} \(statusWord)"
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
            .foregroundStyle(XMOTheme.TextColor.muted)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onTapGesture { controller.stop() }
            .accessibilityLabel("Stop reading")
    }

    // MARK: Progress row (elapsed · bar · total)

    private var progressRow: some View {
        // Playback time advances outside observation — tick to stay honest.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            HStack(spacing: 8) {
                Text(ReadAloudController.timeLabel(controller.elapsedSeconds))
                    .monospacedDigit()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(Color.white.opacity(0.45))
                            .frame(width: max(3, geo.size.width * controller.currentProgress))
                    }
                }
                .frame(height: 3)
                .frame(maxWidth: .infinity)
                // Total firms up once every chunk of the current text is synthesized.
                Text(controller.totalSeconds.map(ReadAloudController.timeLabel) ?? "\u{2013}:\u{2013}\u{2013}")
                    .monospacedDigit()
            }
        }
        .font(XMOTheme.Typography.mono(10))
        .foregroundStyle(XMOTheme.TextColor.muted)
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
            .foregroundStyle(XMOTheme.TextColor.muted)
            .opacity(enabled ? 1 : 0.3)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .accessibilityLabel(label)
    }

    private var speedChip: some View {
        Text(ReadAloudController.speedLabel(controller.rate))
            .font(XMOTheme.Typography.mono(11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(XMOTheme.TextColor.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: XMOTheme.Radius.button)
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
                .font(XMOTheme.Typography.mono(11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(isQueueExpanded ? XMOTheme.TextColor.primary : XMOTheme.TextColor.muted)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: XMOTheme.Radius.button)
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
                .foregroundStyle(XMOTheme.TextColor.faint)
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
                .foregroundStyle(XMOTheme.TextColor.faint)
                .frame(width: 16, height: Self.queueRowHeight)
                .contentShape(Rectangle())
                .gesture(dragGesture(for: text.id, offset: offset))
                .accessibilityLabel("Reorder")
            Text(text.snippet)
                .font(.system(size: 11))
                .foregroundStyle(XMOTheme.TextColor.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(ReadAloudController.estimateLabel(chars: text.chars, rate: controller.rate))
                .font(XMOTheme.Typography.mono(10))
                .monospacedDigit()
                .foregroundStyle(XMOTheme.TextColor.faint)
            // Play now — stops the current text, this one leaves the queue.
            Image(systemName: "play.fill")
                .font(.system(size: 9))
                .foregroundStyle(XMOTheme.TextColor.muted)
                .frame(width: 18, height: Self.queueRowHeight)
                .contentShape(Rectangle())
                .onTapGesture { controller.playQueuedNow(id: text.id) }
                .accessibilityLabel("Read now")
            // Remove — trash, never ✕ (that's the panel close).
            Image(systemName: "trash")
                .font(.system(size: 9))
                .foregroundStyle(XMOTheme.TextColor.muted)
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
                .foregroundStyle(XMOTheme.Accent.red)
                .font(.system(size: 12))
            Text(text)
                .font(XMOTheme.Typography.body)
                .foregroundStyle(XMOTheme.TextColor.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Manager

/// Owns the shared `TopCenteredPanel` and polls the controller for
/// visibility and content-driven resize (which also covers queue expand/
/// collapse); everything else flows through observation — the view holds the
/// controller directly. Sits lower than the dictation indicator so the two
/// never overlap when both are visible.
@MainActor
final class ReadAloudPanelManager {
    private var panel: TopCenteredPanel<ReadAloudPanelView>?
    private var observationTask: Task<Void, Never>?

    /// Vertical clearance under the menu bar: the dictation indicator sits at
    /// 8pt; this panel starts 56pt lower.
    private static let topInset: CGFloat = 64

    func start(controller: ReadAloudController) {
        guard let panel = TopCenteredPanel(
            content: ReadAloudPanelView(controller: controller), topInset: Self.topInset
        ) else { return }
        self.panel = panel

        observationTask = Task { [weak self, weak controller] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let controller else { break }

                if controller.status != .idle || controller.notice != nil {
                    self.panel?.show()
                } else {
                    self.panel?.hide()
                }
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        panel?.hide()
    }
}
