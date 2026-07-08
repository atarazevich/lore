import SwiftUI
import Sparkle

/// Unified XMO window: 216px sidebar + main pane with a 52px toolbar
/// (SHELL-01/02/06/13). Dark-only frosted per D-031; destination views are
/// kept alive across switches so per-view state persists and the meeting
/// polling loop in ContentView never cancels (SHELL-16).
struct ShellView: View {
    @Bindable var settings: AppSettings
    let updater: SPUUpdater
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(ShellModel.self) private var shell
    @State private var showHealthPanel = false
    @State private var showProblemReport = false

    var body: some View {
        HStack(spacing: 0) {
            ShellSidebar(
                activeDestination: shell.destination,
                isMeetingRecording: coordinator.isRecording,
                isDictationLocked: coordinator.dictationIndicator.model.isLocked,
                healthMonitor: coordinator.healthMonitor,
                onSelect: { shell.destination = $0 },
                onOpenHealth: { showHealthPanel = true }
            )
            mainPane
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(XMOTheme.Surface.window)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        // The toolbar's "N recorded" subtitle needs the index at launch;
        // afterwards session end / batch completion keep it fresh.
        .task { await coordinator.loadHistory() }
        // The notch self-summon (#83) raises the panel through this signal.
        .onChange(of: shell.wantsHealthPanel) { _, wants in
            if wants {
                showHealthPanel = true
                shell.wantsHealthPanel = false
            }
        }
        .sheet(isPresented: $showHealthPanel) {
            if let monitor = coordinator.healthMonitor {
                HealthPanelView(
                    monitor: monitor,
                    onOpenSettings: {
                        showHealthPanel = false
                        shell.destination = .settings
                    },
                    onReportProblem: {
                        showHealthPanel = false
                        // Next runloop: presenting one sheet as another dismisses
                        // conflicts on macOS.
                        DispatchQueue.main.async { showProblemReport = true }
                    },
                    onClose: { showHealthPanel = false }
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
            XMODivider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 52px toolbar: destination title left (+ Meetings subtitle, MREV-06),
    /// REC pill right (SHELL-13/14). The whole strip drags the window (#71);
    /// the REC pill button takes hit-testing priority over the drag gesture.
    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(shell.destination.title)
                .font(XMOTheme.Typography.control)
                .foregroundStyle(XMOTheme.TextColor.primary)
            if shell.destination == .meetings {
                Text(coordinator.isRecording
                     ? "recording\u{2026}"
                     : "\(coordinator.sessionHistory.count) recorded")
                    .font(XMOTheme.Typography.monoMeta)
                    .foregroundStyle(XMOTheme.TextColor.muted)
            }
            Spacer()
            if let startedAt = recordingStartedAt, showRecPill {
                ShellRecPill(startedAt: startedAt) {
                    shell.destination = .meetings
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    /// True recording start so the clock is correct when the pill appears
    /// mid-recording (SHELL-15).
    private var recordingStartedAt: Date? {
        if case .recording(let metadata) = coordinator.state {
            return metadata.startedAt
        }
        return nil
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
        .background(XMOTheme.Surface.sidebar)
        .overlay(alignment: .trailing) {
            XMOTheme.Surface.line.frame(width: 1)
        }
    }

    /// 28px blue rounded mark + wordmark (SHELL-07). Single-constant brand
    /// so the pending app rename is one change (app-shell.md Q4).
    private var brandRow: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: XMOTheme.Radius.chip)
                    .fill(XMOTheme.Accent.blue)
                    .frame(width: 28, height: 28)
                    .xmoShadow(XMOTheme.Shadow.blueGlow)
                Text(String(XMOTheme.wordmark.prefix(1)))
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(-0.26)
                    .foregroundStyle(.white)
            }
            Text(XMOTheme.wordmark)
                .font(XMOTheme.Typography.control)
                .kerning(-0.13) // CSS `.brand .name` letter-spacing -.01em at 13px
                .foregroundStyle(XMOTheme.TextColor.primary)
            Spacer(minLength: 0)
        }
        .padding(.init(top: 16, leading: 16, bottom: 12, trailing: 16))
    }

    private var navList: some View {
        VStack(spacing: 2) {
            ForEach(ShellModel.enabledDestinations) { destination in
                ShellNavItem(
                    title: destination.title,
                    icon: destination == .meetings && isMeetingRecording
                        ? "video.fill" : destination.icon,
                    isActive: destination == activeDestination,
                    isLive: isLive(destination),
                    badgeCount: nil, // SHELL-11 slot; Tasks uses it in Stage 2
                    action: { onSelect(destination) }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    /// Red pulsing dot: Meetings while recording, Dictation while Space-locked
    /// (SHELL-10, prototype dc.html:689).
    private func isLive(_ destination: ShellDestination) -> Bool {
        switch destination {
        case .meetings: return isMeetingRecording
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
                .font(XMOTheme.Typography.monoMeta)
                .foregroundStyle(XMOTheme.TextColor.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.init(top: 13, leading: 16, bottom: 13, trailing: 16))
                .overlay(alignment: .top) { XMODivider() }
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
                    .font(XMOTheme.Typography.meta)
                    .foregroundStyle(XMOTheme.TextColor.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.init(top: 13, leading: 16, bottom: 13, trailing: 16))
            .overlay(alignment: .top) { XMODivider() }
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
    let badgeCount: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20, height: 20)
                Text(title)
                    .font(isActive ? XMOTheme.Typography.control
                                   : XMOTheme.Typography.navInactive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isLive {
                    XMOPulsingDot()
                }
                if let badgeCount, badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0x1A / 255, green: 0x14 / 255, blue: 0x08 / 255))
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18)
                        .frame(height: 18)
                        .background(XMOTheme.Accent.amber,
                                    in: RoundedRectangle(cornerRadius: XMOTheme.Radius.chip))
                }
            }
            .foregroundStyle(isActive ? Color.white : XMOTheme.TextColor.sidebarInactive)
            .xmoSelectableRow(isActive: isActive)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - REC pill (SHELL-14/15)

/// Red mono "REC m:ss" pill with pulsing dot; clicking navigates to Meetings.
private struct ShellRecPill: View {
    let startedAt: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                XMOPulsingDot()
                Text("REC ") + Text(startedAt, style: .timer)
            }
            .font(XMOTheme.Typography.monoControl)
            .foregroundStyle(XMOTheme.Accent.red)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(
                XMOTheme.Accent.red.opacity(0.14),
                in: RoundedRectangle(cornerRadius: XMOTheme.Radius.button)
            )
        }
        .buttonStyle(XMOPressButtonStyle())
        .accessibilityLabel("Recording — show Meetings")
    }
}

// MARK: - Pulsing dot (SHELL-10/31)

/// 8px red dot with glow; CSS `pulse` 1.3s opacity .25↔1. Static at full
/// opacity when Reduce Motion is on ("calm" mode, SHELL-31).
struct XMOPulsingDot: View {
    var color: Color = XMOTheme.Accent.red
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color, radius: 4)
            .phaseAnimator([1.0, 0.25]) { view, phase in
                view.opacity(reduceMotion ? 1 : phase)
            } animation: { _ in
                .easeInOut(duration: XMOTheme.Motion.pulseDuration / 2)
            }
    }
}
