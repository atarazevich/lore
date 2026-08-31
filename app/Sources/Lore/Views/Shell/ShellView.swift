import SwiftUI
import Sparkle

/// Unified Lore window: 216px sidebar + main pane with a 52px toolbar
/// (SHELL-01/02/06/13). Dark-only frosted per D-031; destination views are
/// kept alive across switches so per-view state persists and the meeting
/// polling loop in ContentView never cancels (SHELL-16).
struct ShellView: View {
    @Bindable var settings: AppSettings
    let updater: SPUUpdater
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(ShellModel.self) private var shell
    @State private var showProblemReport = false

    var body: some View {
        // The health panel's presentation lives on the shared model so the menu
        // bar can open it too (#151); `@Bindable` is what turns the observable
        // property into the `isPresented` binding.
        @Bindable var shell = shell
        return HStack(spacing: 0) {
            ShellSidebar(
                activeDestination: shell.destination,
                isMeetingRecording: coordinator.isRecording,
                isMeetingPaused: coordinator.isPaused,
                isDictationLocked: coordinator.dictationIndicator.model.isLocked,
                healthMonitor: coordinator.healthMonitor,
                onSelect: { shell.destination = $0 },
                onOpenHealth: { shell.presentsHealthPanel = true }
            )
            mainPane
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(LoreTheme.Surface.window)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        // The toolbar's "N recorded" subtitle needs the index at launch;
        // afterwards session end / batch completion keep it fresh.
        .task { await coordinator.loadHistory() }
        .sheet(isPresented: $shell.presentsHealthPanel) {
            if let monitor = coordinator.healthMonitor {
                HealthPanelView(
                    monitor: monitor,
                    onOpenSettings: {
                        shell.presentsHealthPanel = false
                        shell.destination = .settings
                    },
                    onReportProblem: {
                        shell.presentsHealthPanel = false
                        // Next runloop: presenting one sheet as another dismisses
                        // conflicts on macOS.
                        DispatchQueue.main.async { showProblemReport = true }
                    },
                    onClose: { shell.presentsHealthPanel = false }
                )
            }
        }
        .sheet(isPresented: $showProblemReport) {
            if let monitor = coordinator.healthMonitor {
                ProblemReportView(healthMonitor: monitor, onClose: { showProblemReport = false })
            }
        }
    }

    // MARK: - Main pane

    private var mainPane: some View {
        VStack(spacing: 0) {
            toolbar
            LoreDivider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 52px toolbar: destination title left (+ Meetings subtitle, MREV-06),
    /// REC pill right (SHELL-13/14). The whole strip drags the window (#71);
    /// the REC pill button takes hit-testing priority over the drag gesture.
    private var toolbar: some View {
        let paused = coordinator.isPaused
        return HStack(spacing: 12) {
            Text(shell.destination.title)
                .font(LoreTheme.Typography.control)
                .foregroundStyle(LoreTheme.TextColor.primary)
            if shell.destination == .meetings {
                Text(meetingsSubtitle(paused: paused))
                    .font(LoreTheme.Typography.monoMeta)
                    .foregroundStyle(paused ? LoreTheme.Accent.amber : LoreTheme.TextColor.muted)
            }
            Spacer()
            if let startedAt = recordingStartedAt, showRecPill {
                ShellRecPill(startedAt: startedAt, isPaused: paused) {
                    shell.destination = .meetings
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private func meetingsSubtitle(paused: Bool) -> String {
        if paused { return "paused" }
        if coordinator.isRecording { return "recording\u{2026}" }
        return "\(coordinator.sessionHistory.count) recorded"
    }

    /// True session start so the clock is correct when the pill appears
    /// mid-recording (SHELL-15). Covers `.paused` too (#153) — the pill is how
    /// the other destinations know a meeting is open, and a pause must not
    /// make it vanish as if the meeting had ended.
    private var recordingStartedAt: Date? {
        guard coordinator.state.isLive else { return nil }
        return coordinator.state.metadata?.startedAt
    }

    /// SET-11/50: pill shows only while recording (caller guards), the
    /// "Recording status in toolbar" setting is on, and the current view is
    /// not Meetings. Sidebar live dots are unconditional (SET-52).
    private var showRecPill: Bool {
        settings.recPillEnabled && shell.destination != .meetings
    }

    /// All destinations stay mounted; the inactive ones are hidden, not
    /// destroyed (SHELL-16). ContentView's `.task` polling loop depends on it.
    private var content: some View {
        ZStack {
            DictationDestination(
                settings: settings,
                isActive: shell.destination == .dictation
            )
            .shellKeepAlive(isActive: shell.destination == .dictation)

            MeetingsDestination(settings: settings)
                .shellKeepAlive(isActive: shell.destination == .meetings)

            StatsDestination(isActive: shell.destination == .stats)
                .shellKeepAlive(isActive: shell.destination == .stats)

            SettingsDestination(
                settings: settings,
                updater: updater,
                isActive: shell.destination == .settings
            )
            .shellKeepAlive(isActive: shell.destination == .settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Keep-alive hide for shell destinations/sections (SHELL-16): the view
    /// stays mounted (state and tasks survive) but is invisible, ignores
    /// clicks, is skipped by accessibility, and — via `.disabled` — cannot
    /// take Tab focus or trigger `.keyboardShortcut` buttons while hidden.
    func shellKeepAlive(isActive: Bool) -> some View {
        opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .disabled(!isActive)
            .accessibilityHidden(!isActive)
    }
}

// MARK: - Sidebar (SHELL-06…12)

private struct ShellSidebar: View {
    let activeDestination: ShellDestination
    let isMeetingRecording: Bool
    let isMeetingPaused: Bool
    let isDictationLocked: Bool
    let healthMonitor: HealthMonitor?
    let onSelect: (ShellDestination) -> Void
    let onOpenHealth: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Traffic-light zone — the real window controls render here
            // (hidden title bar, SHELL-03). CSS: 15px top + 12px dots.
            // Together with the brand row it drags the window (#71); the
            // traffic lights are system NSViews layered above the gesture.
            VStack(spacing: 0) {
                Color.clear.frame(height: 27)
                brandRow
            }
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            navList
            Spacer(minLength: 0)
            footer
        }
        .frame(width: 216)
        .frame(maxHeight: .infinity)
        .background(LoreTheme.Surface.sidebar)
        .overlay(alignment: .trailing) {
            LoreTheme.Surface.line.frame(width: 1)
        }
    }

    /// 28px mark + wordmark (SHELL-07). The chip is the icon's own artwork, not
    /// a typeset initial: a bare lowercase `l` in SF Pro is the ambiguous glyph
    /// the mark was drawn in Menlo to avoid.
    private var brandRow: some View {
        HStack(spacing: 10) {
            Image(nsImage: LoreMark.chip)
                .accessibilityHidden(true)
            Text(LoreTheme.wordmark)
                .font(LoreTheme.Typography.control)
                .kerning(-0.13) // CSS `.brand .name` letter-spacing -.01em at 13px
                .foregroundStyle(LoreTheme.TextColor.primary)
            Spacer(minLength: 0)
        }
        .padding(.init(top: 16, leading: 16, bottom: 12, trailing: 16))
    }

    private var navList: some View {
        VStack(spacing: 2) {
            ForEach(ShellModel.enabledDestinations) { destination in
                ShellNavItem(
                    title: destination.title,
                    icon: destination == .meetings && (isMeetingRecording || isMeetingPaused)
                        ? "video.fill" : destination.icon,
                    isActive: destination == activeDestination,
                    isLive: isLive(destination),
                    liveTint: destination == .meetings && isMeetingPaused
                        ? LoreTheme.Accent.amber : LoreTheme.Accent.red,
                    livePulses: !(destination == .meetings && isMeetingPaused),
                    badgeCount: nil, // SHELL-11 slot; Tasks uses it in Stage 2
                    action: { onSelect(destination) }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    /// Red pulsing dot: Meetings while recording, Dictation while Space-locked
    /// (SHELL-10, prototype dc.html:689). A paused meeting keeps the dot —
    /// the session is still open — in steady amber (#153).
    private func isLive(_ destination: ShellDestination) -> Bool {
        switch destination {
        case .meetings: return isMeetingRecording || isMeetingPaused
        case .dictation: return isDictationLocked
        default: return false
        }
    }

    /// Health readiness readout in the slot the decorative "Online" badge
    /// vacated (#73 → #83): a status dot + "All systems ready" / "N issues —
    /// <first issue>", click opens the panel. Falls back to the version string
    /// when no monitor is wired (UI-test mode).
    @ViewBuilder
    private var footer: some View {
        if let healthMonitor {
            ShellHealthFooter(summary: healthMonitor.summary, action: onOpenHealth)
        } else {
            Text(versionString)
                .font(LoreTheme.Typography.monoMeta)
                .foregroundStyle(LoreTheme.TextColor.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.init(top: 13, leading: 16, bottom: 13, trailing: 16))
                .overlay(alignment: .top) { LoreDivider() }
        }
    }

    private var versionString: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return "v" + (version ?? "0.0")
    }
}

/// Sidebar footer health row (SHELL-12 slot, #83): dot + summary line, whole row
/// clickable to open the health panel.
private struct ShellHealthFooter: View {
    let summary: HealthSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HealthStatusDot(status: summary.status)
                Text(summary.text)
                    .font(LoreTheme.Typography.meta)
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.init(top: 13, leading: 16, bottom: 13, trailing: 16))
            .overlay(alignment: .top) { LoreDivider() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("System health: \(summary.text)")
    }
}

/// Nav item: 9×11 padding, radius 6, 20px icon slot, 12px gap; active =
/// white-8% bg + 600, inactive = #7c818c/500, hover token (SHELL-08).
private struct ShellNavItem: View {
    let title: String
    let icon: String
    let isActive: Bool
    let isLive: Bool
    var liveTint: Color = LoreTheme.Accent.red
    var livePulses = true
    let badgeCount: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20, height: 20)
                Text(title)
                    .font(isActive ? LoreTheme.Typography.control
                                   : LoreTheme.Typography.navInactive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isLive {
                    LorePulsingDot(color: liveTint, pulses: livePulses)
                }
                if let badgeCount, badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0x1A / 255, green: 0x14 / 255, blue: 0x08 / 255))
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18)
                        .frame(height: 18)
                        .background(LoreTheme.Accent.amber,
                                    in: RoundedRectangle(cornerRadius: LoreTheme.Radius.chip))
                }
            }
            .foregroundStyle(isActive ? Color.white : LoreTheme.TextColor.sidebarInactive)
            .loreSelectableRow(isActive: isActive)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - REC pill (SHELL-14/15)

/// Red mono "REC m:ss" pill with pulsing dot; clicking navigates to Meetings.
/// Paused (#153) is the same pill in amber, with a steady dot and the word
/// "PAUSED" where the running clock was — a clock still ticking beside a
/// paused meeting is the one thing this surface must not imply.
private struct ShellRecPill: View {
    let startedAt: Date
    var isPaused = false
    let action: () -> Void

    private var tint: Color { isPaused ? LoreTheme.Accent.amber : LoreTheme.Accent.red }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                LorePulsingDot(color: tint, pulses: !isPaused)
                if isPaused {
                    Text("PAUSED")
                } else {
                    Text("REC ") + Text(startedAt, style: .timer)
                }
            }
            .font(LoreTheme.Typography.monoControl)
            .foregroundStyle(tint)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(
                tint.opacity(0.14),
                in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
            )
        }
        .buttonStyle(LorePressButtonStyle())
        .accessibilityLabel(isPaused ? "Meeting paused — show Meetings"
                                     : "Recording — show Meetings")
    }
}

// MARK: - Pulsing dot (SHELL-10/31)

/// 8px red dot with glow; CSS `pulse` 1.3s opacity .25↔1. Static at full
/// opacity when Reduce Motion is on ("calm" mode, SHELL-31) — and when
/// `pulses` is false, which is how a paused meeting shows itself (#153): the
/// pulse is the "capturing right now" signal, so a paused surface keeps the
/// dot's shape and glow and drops only its heartbeat.
struct LorePulsingDot: View {
    var color: Color = LoreTheme.Accent.red
    var size: CGFloat = 8
    /// Off for a *standing* state rather than a live one — the menu bar's amber
    /// health bead (#151) and a paused meeting (#153), both facts rather than
    /// live activity. Pulsing at either would be the interruption that surface
    /// replaced. The glow rule stays here either way, so every bead keeps one
    /// definition.
    var pulses = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // CSS `drop-shadow(0 0 <diameter>)`: a blur equal to the dot's own
        // size, and SwiftUI's radius is half the CSS blur. Proportional, not
        // the literal 4, so the 3.2pt menu-bar bead glows like the 8pt one.
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color, radius: size / 2)
            .phaseAnimator([1.0, 0.25]) { view, phase in
                view.opacity(pulses && !reduceMotion ? phase : 1)
            } animation: { _ in
                .easeInOut(duration: LoreTheme.Motion.pulseDuration / 2)
            }
    }
}
