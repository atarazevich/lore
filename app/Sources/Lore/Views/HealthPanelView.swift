import AppKit
import SwiftUI

/// The diagnostics health panel (#83, design §6): the readiness chain rendered
/// top to bottom, each healthy link collapsed to one line and each failing link
/// expanded with its detail, a failure-specific remedy, and buttons that perform
/// it. The header surfaces both version fields — the marketing version and the
/// `CFBundleVersion` that maps this build to an exact commit ("the machine is
/// the record"). Dark-only, LoreTheme tokens (D-031).
struct HealthPanelView: View {
    let monitor: HealthMonitor
    /// Navigate the shell to its Settings destination (the `openLoreSettings`
    /// remedy — there is no System Settings URL for the in-app OpenAI key).
    var onOpenSettings: () -> Void
    /// Open the "Report a problem" flow (#84) — the escape hatch when the chain
    /// looks fine but something is still wrong.
    var onReportProblem: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            LoreDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(HealthSection.allCases, id: \.self) { section in
                        sectionView(section)
                    }
                    reportProblemRow
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: 580)
        .background(LoreTheme.Surface.window)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    HealthStatusDot(status: monitor.summary.status)
                    Text(monitor.summary.text)
                        .font(LoreTheme.Typography.control)
                        .foregroundStyle(LoreTheme.TextColor.primary)
                }
                Text("\(LoreTheme.wordmark) \(monitor.snapshot.marketingVersion) · build \(monitor.snapshot.build)")
                    .font(LoreTheme.Typography.monoMeta)
                    .foregroundStyle(LoreTheme.TextColor.muted)
            }
            Spacer()
            LoreIconButton(systemName: "xmark", label: "Close health panel", action: onClose)
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    // MARK: - Report a problem (#84)

    /// Bottom-of-panel escape hatch: the chain can read all-green and the app
    /// still misbehave, so offer to send a diagnostic report rather than dead-end.
    private var reportProblemRow: some View {
        Button(action: onReportProblem) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Something still wrong?")
                        .font(LoreTheme.Typography.control)
                        .foregroundStyle(LoreTheme.TextColor.primary)
                    Text("Report a problem — send a diagnostic report")
                        .font(LoreTheme.Typography.meta)
                        .foregroundStyle(LoreTheme.TextColor.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LoreTheme.TextColor.muted)
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(LoreTheme.Surface.card, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Something still wrong? Report a problem")
    }

    // MARK: - Section

    @ViewBuilder
    private func sectionView(_ section: HealthSection) -> some View {
        let items = monitor.items.filter { $0.section == section }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                LoreSectionLabel(text: section.title)
                LoreCard {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { LoreDivider() }
                            HealthRowView(item: item, isTesting: monitor.testing.contains(item.id), perform: perform)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Remedy actions

    private func perform(_ action: HealthRemedyAction) {
        switch action {
        case .openSettings(let pane):
            if let url = pane.settingsURL { NSWorkspace.shared.open(url) }
        case .restartApp:
            AppRelauncher.relaunch()
        case .openLoreSettings:
            onOpenSettings()
        case .testNow(let id):
            Task { await monitor.testNow(id) }
        }
    }
}

// MARK: - Row

/// One probe. Healthy → a single line (title + muted detail + green dot).
/// Failing → expands with the detail, the remedy instruction, and its buttons.
private struct HealthRowView: View {
    let item: HealthItem
    /// This probe's expensive Test-now is running: show a spinner + "Testing…"
    /// and disable its button for the ~2s the test takes (#88).
    let isTesting: Bool
    let perform: (HealthRemedyAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: item.remedy == nil ? 0 : 8) {
            HStack(spacing: 10) {
                HealthStatusDot(status: item.status)
                Text(item.title)
                    .font(LoreTheme.Typography.body)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                Spacer(minLength: 8)
                Text(item.detail)
                    .font(LoreTheme.Typography.meta)
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(item.remedy == nil ? 1 : nil)
            }

            if let remedy = item.remedy {
                Text(remedy.instruction)
                    .font(LoreTheme.Typography.meta)
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if !remedy.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(remedy.actions.enumerated()), id: \.offset) { _, action in
                            Button(action.buttonLabel) { perform(action) }
                                .buttonStyle(HealthActionButtonStyle())
                                .disabled(isTesting)
                        }
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                            Text("Testing…")
                                .font(LoreTheme.Typography.meta)
                                .foregroundStyle(LoreTheme.TextColor.muted)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Status dot

/// The 8×8 health dot, shared by the panel header, each panel row, and the
/// sidebar footer so the status→colour map lives in exactly one place.
struct HealthStatusDot: View {
    let status: HealthStatus

    var body: some View {
        Circle()
            .fill(status.dotColor)
            .frame(width: 8, height: 8)
            .shadow(color: status.dotColor.opacity(0.6), radius: 3)
    }
}

extension HealthStatus {
    var dotColor: Color {
        switch self {
        case .ok: return LoreTheme.Accent.green
        case .warning: return LoreTheme.Accent.amber
        case .failed: return LoreTheme.Accent.red
        }
    }
}

// MARK: - Action button

/// Small filled button matching the notch prompt's action style.
private struct HealthActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LoreTheme.Typography.secondary)
            .foregroundStyle(LoreTheme.TextColor.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(LoreTheme.Surface.card3, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? LoreTheme.Motion.pressScale : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: LoreTheme.Motion.hoverDuration),
                       value: configuration.isPressed)
    }
}

// MARK: - Relaunch

/// Relaunch the app in place — the common remedy when macOS has stopped
/// recognizing a permission grant and only a fresh process picks it up.
enum AppRelauncher {
    @MainActor
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
