import AppKit
import SwiftUI

/// The diagnostics health panel (#83, design §6): the readiness chain rendered
/// top to bottom, each healthy link collapsed to one line and each failing link
/// expanded with its detail, a failure-specific remedy, and buttons that perform
/// it. The header surfaces both version fields — the marketing version and the
/// `CFBundleVersion` that maps this build to an exact commit ("the machine is
/// the record"). Dark-only, XMOTheme tokens (D-031).
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
            XMODivider()
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
        .background(XMOTheme.Surface.window)
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
                        .font(XMOTheme.Typography.control)
                        .foregroundStyle(XMOTheme.TextColor.primary)
                }
                Text("\(XMOTheme.wordmark) \(monitor.snapshot.marketingVersion) · build \(monitor.snapshot.build)")
                    .font(XMOTheme.Typography.monoMeta)
                    .foregroundStyle(XMOTheme.TextColor.muted)
            }
            Spacer()
            XMOIconButton(systemName: "xmark", label: "Close health panel", action: onClose)
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
                        .font(XMOTheme.Typography.control)
                        .foregroundStyle(XMOTheme.TextColor.primary)
                    Text("Report a problem — send a diagnostic report")
                        .font(XMOTheme.Typography.meta)
                        .foregroundStyle(XMOTheme.TextColor.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(XMOTheme.TextColor.muted)
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(XMOTheme.Surface.card, in: RoundedRectangle(cornerRadius: XMOTheme.Radius.card))
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
                XMOSectionLabel(text: section.title)
                XMOCard {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { XMODivider() }
                            HealthRowView(item: item, perform: perform)
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
    let perform: (HealthRemedyAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: item.remedy == nil ? 0 : 8) {
            HStack(spacing: 10) {
                HealthStatusDot(status: item.status)
                Text(item.title)
                    .font(XMOTheme.Typography.body)
                    .foregroundStyle(XMOTheme.TextColor.primary)
                Spacer(minLength: 8)
                Text(item.detail)
                    .font(XMOTheme.Typography.meta)
                    .foregroundStyle(XMOTheme.TextColor.muted)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(item.remedy == nil ? 1 : nil)
            }

            if let remedy = item.remedy {
                Text(remedy.instruction)
                    .font(XMOTheme.Typography.meta)
                    .foregroundStyle(XMOTheme.TextColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if !remedy.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(remedy.actions.enumerated()), id: \.offset) { _, action in
                            Button(action.buttonLabel) { perform(action) }
                                .buttonStyle(HealthActionButtonStyle())
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
        case .ok: return XMOTheme.Accent.green
        case .warning: return XMOTheme.Accent.amber
        case .failed: return XMOTheme.Accent.red
        }
    }
}

// MARK: - Action button

/// Small filled button matching the notch prompt's action style.
private struct HealthActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(XMOTheme.Typography.secondary)
            .foregroundStyle(XMOTheme.TextColor.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(XMOTheme.Surface.card3, in: RoundedRectangle(cornerRadius: XMOTheme.Radius.button))
            .scaleEffect(configuration.isPressed && !reduceMotion ? XMOTheme.Motion.pressScale : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: XMOTheme.Motion.hoverDuration),
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
