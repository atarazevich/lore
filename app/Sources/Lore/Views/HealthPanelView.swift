import AppKit
import LoreCore
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
        // The panel is an on-open fact sheet (#140): probes run when it opens,
        // not on a background cycle. On screen is also the only moment a probe
        // may read a TCC-protected folder (#148) — hence `refreshForPanel`.
        .onAppear { monitor.refreshForPanel() }
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
                Text("\(LoreBrand.wordmark) \(monitor.snapshot.marketingVersion) · build \(monitor.snapshot.build)")
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
        action.perform(monitor: monitor, openLoreSettings: onOpenSettings)
    }
}

extension HealthRemedyAction {
    /// What each remedy button does — the one dispatch the panel and the menu
    /// bar's blocked-condition message share (#338).
    @MainActor func perform(monitor: HealthMonitor?, openLoreSettings: () -> Void = {}) {
        switch self {
        case .openSettings(let pane):
            pane.open()
        case .restartApp:
            AppRelauncher.relaunch()
        case .openLoreSettings:
            openLoreSettings()
        case .testNow(let id):
            Task { await monitor?.testNow(id) }
        case .revealInFinder(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .fixPermissions:
            Task { await monitor?.fixPermissions() }
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
    /// "Do it by hand" is open (#338).
    @State private var showsManualSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: item.remedy == nil ? 0 : 8) {
            HStack(spacing: 10) {
                // A row the blocked condition explains reads neutral (#338):
                // no verdict of its own, so no colour of its own.
                if item.isDependent {
                    Circle().fill(LoreTheme.Surface.line3).frame(width: 8, height: 8)
                } else {
                    HealthStatusDot(status: item.status)
                }
                Text(item.title)
                    .font(LoreTheme.Typography.body)
                    .foregroundStyle(item.isDependent ? LoreTheme.TextColor.muted : LoreTheme.TextColor.primary)
                Spacer(minLength: 8)
                Text(item.detail)
                    .font(LoreTheme.Typography.meta)
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(item.remedy == nil ? 1 : nil)
            }

            if let remedy = item.remedy {
                VStack(alignment: .leading, spacing: 4) {
                    // The hedged cause sits a step quieter than the step to take (#341).
                    if let cause = remedy.cause {
                        Text(cause)
                            .foregroundStyle(LoreTheme.TextColor.faint)
                    }
                    Text(remedy.instruction)
                        .foregroundStyle(LoreTheme.TextColor.muted)
                }
                .font(LoreTheme.Typography.meta)
                .fixedSize(horizontal: false, vertical: true)
                if !remedy.actions.isEmpty {
                    if remedy.manualSteps.isEmpty {
                        actionButtons(remedy)
                    } else {
                        // The same fix by hand, behind the disclosure beside
                        // the primary button (#338).
                        DisclosureGroup(isExpanded: $showsManualSteps) {
                            manualStepsList(remedy.manualSteps)
                        } label: {
                            actionButtons(remedy)
                        }
                        .disclosureGroupStyle(ManualStepsDisclosureStyle())
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func actionButtons(_ remedy: Remedy) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(remedy.actions.enumerated()), id: \.offset) { _, action in
                if action == .fixPermissions {
                    // The one primary action (#338), in the focus accent.
                    LorePrimaryButton(title: action.buttonLabel, size: .compact) { perform(action) }
                } else {
                    Button(action.buttonLabel) { perform(action) }
                        .buttonStyle(HealthActionButtonStyle())
                        .disabled(isTesting)
                }
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

    /// The same fix by hand, numbered, in the row's muted meta type.
    private func manualStepsList(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                    Text(step)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(LoreTheme.Typography.meta)
        .foregroundStyle(LoreTheme.TextColor.muted)
        .padding(.leading, 16)
    }
}

/// "Do it by hand" as the board draws it (#338): the row's buttons, then a
/// muted chevron and label 14 pt past them, and the steps under the whole row.
private struct ManualStepsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                configuration.label
                Button {
                    configuration.isExpanded.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(Remedy.manualStepsLabel)
                            .font(LoreTheme.Typography.meta)
                    }
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Remedy.manualStepsLabel)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            }
            if configuration.isExpanded { configuration.content }
        }
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

/// Small filled button matching the notch prompt's action style; also the
/// iPhone notes line's "Open System Settings" (#309).
struct HealthActionButtonStyle: ButtonStyle {
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
///
/// The new copy can only start once this one is gone: LaunchServices starts
/// no second instance while one runs, and one that started anyway would find
/// `instance.lock` held and defer (#193). So a shell outside this process waits
/// for it to exit, then opens this same bundle (#336). The shell is started at
/// `applicationWillTerminate`, when the quit is certain, so a quit cancelled at
/// the recording alert leaves nothing waiting.
@MainActor
enum AppRelauncher {
    private(set) static var isRequested = false

    static func relaunch() {
        isRequested = true
        NSApp.terminate(nil)
    }

    /// The quit was cancelled, or a SIGTERM ends the process: no relaunch.
    static func cancel() {
        isRequested = false
    }

    /// From `applicationWillTerminate`, before the event ring's last flush.
    static func startIfRequested() {
        guard isRequested else { return }
        let waiter = waiter(for: ProcessInfo.processInfo.processIdentifier, thenOpen: Bundle.main.bundleURL)
        DiagStore.record(.appRelaunch(waiterStarted: (try? waiter.run()) != nil))
    }

    /// Waits for `pid` to exit, then opens `bundle` through LaunchServices.
    nonisolated static func waiter(for pid: Int32, thenOpen bundle: URL) -> Process {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = [
            "-c", #"while kill -0 "$0" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open "$1""#,
            String(pid), bundle.path,
        ]
        return shell
    }
}
