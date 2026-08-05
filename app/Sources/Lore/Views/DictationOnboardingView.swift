import SwiftUI
import AVFoundation
import ApplicationServices
import AppKit

struct DictationOnboardingView: View {
    @Bindable var settings: AppSettings
    @AppStorage("completedDictationOnboarding") private var completedDictationOnboarding = false
    @State private var currentStep = 0
    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    /// The user has been sent to the Input Monitoring pane at least once, so the
    /// row switches from "Open Settings" to the relaunch that makes the grant visible.
    @State private var inputMonitoringPaneOpened = false

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ScrollView {
                Group {
                    switch currentStep {
                    case 0: welcomeStep
                    case 1: permissionsStep
                    case 2: fnKeyStep
                    case 3: readyStep
                    default: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()

            XMOStepDots(count: totalSteps, current: currentStep)
                .padding(.bottom, 16)

            XMOOnboardingFooter(
                leadingTitle: currentStep > 0 ? "Back" : nil,
                leadingAction: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentStep -= 1
                    }
                },
                step: currentStep,
                count: totalSteps,
                advance: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentStep += 1
                    }
                },
                finish: finish
            )
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: 480)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Image(systemName: "waveform")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(XMOTheme.Accent.blue)
                .frame(height: 44)

            Spacer().frame(height: 14)

            Text("Welcome to \(XMOTheme.wordmark)")
                .font(XMOTheme.Typography.heading)
                .foregroundStyle(XMOTheme.TextColor.primary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 8)

            Text("Hold Fn, speak, release \u{2014} your words appear instantly.")
                .font(XMOTheme.Typography.body)
                .foregroundStyle(XMOTheme.TextColor.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 0) {
            Text("Permissions")
                .font(XMOTheme.Typography.heading)
                .foregroundStyle(XMOTheme.TextColor.primary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 14)

            VStack(alignment: .leading, spacing: 12) {
                permissionRow(
                    name: "Microphone",
                    granted: micStatus == .authorized,
                    need: "Required for dictation",
                    actionTitle: micStatus == .notDetermined ? "Grant Microphone" : "Open Settings",
                    action: micAction
                )

                permissionRow(
                    name: "Accessibility",
                    granted: accessibilityGranted,
                    need: "Required for global hotkey",
                    action: { openSettings(.accessibility) }
                )

                permissionRow(
                    name: "Input Monitoring",
                    granted: inputMonitoringGranted,
                    need: inputMonitoringPaneOpened
                        ? "After enabling, quit and reopen \(XMOTheme.wordmark)"
                        : "Required to feel the Fn key",
                    actionTitle: inputMonitoringPaneOpened ? "Restart \(XMOTheme.wordmark)" : "Open Settings",
                    action: inputMonitoringAction
                )
            }
            .padding(.horizontal, 8)

            Spacer().frame(height: 12)

            Text("You can grant these later in System Settings if you prefer.")
                .font(XMOTheme.Typography.meta)
                .foregroundStyle(XMOTheme.TextColor.faint)
                .multilineTextAlignment(.center)
        }
        .onAppear { refreshPermissions() }
        // Grants happen during a System Settings round trip, so re-read every time
        // the app comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    // MARK: - Step 3: Fn Key Setup

    private var fnKeyStep: some View {
        VStack(spacing: 0) {
            Text("Fn Key Setup")
                .font(XMOTheme.Typography.heading)
                .foregroundStyle(XMOTheme.TextColor.primary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 12)

            Text("To use Fn as your dictation key, set it to \u{201C}Do Nothing\u{201D} in System Settings.")
                .font(XMOTheme.Typography.body)
                .foregroundStyle(XMOTheme.TextColor.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 12)

            VStack(alignment: .leading, spacing: 4) {
                XMOBulletRow(text: "System Settings")
                XMOBulletRow(text: "Keyboard")
                XMOBulletRow(text: "\u{201C}Press \u{1F310} fn key to\u{201D} \u{2192} \u{201C}Do Nothing\u{201D}")
            }
            .padding(10)
            .background(XMOTheme.Surface.card3,
                        in: RoundedRectangle(cornerRadius: XMOTheme.Radius.card))

            Spacer().frame(height: 12)

            Button("Open Keyboard Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer().frame(height: 10)

            Text("You can also use Right Option as an alternative hotkey (configurable in Settings).")
                .font(XMOTheme.Typography.meta)
                .foregroundStyle(XMOTheme.TextColor.faint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 4: Ready

    private var readyStep: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(XMOTheme.Accent.green)
                .frame(height: 44)

            Spacer().frame(height: 14)

            Text("You\u{2019}re all set!")
                .font(XMOTheme.Typography.heading)
                .foregroundStyle(XMOTheme.TextColor.primary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 8)

            Text("Hold \(settings.hotkeyKey.displayName) and start speaking.")
                .font(XMOTheme.Typography.body)
                .foregroundStyle(XMOTheme.TextColor.muted)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 14)

            VStack(alignment: .leading, spacing: 6) {
                cheatSheetRow("Fn", "talk")
                cheatSheetRow("Space", "lock recording")
                cheatSheetRow("C", "cleanup")
                cheatSheetRow("T", "translate")
            }
            .padding(10)
            .background(XMOTheme.Surface.card3,
                        in: RoundedRectangle(cornerRadius: XMOTheme.Radius.card))

            Spacer().frame(height: 14)

            Text("If you just granted permissions, please quit (\u{2318}Q) and reopen \(XMOTheme.wordmark) for them to take full effect.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(XMOTheme.Accent.amber)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    /// One permission row: state icon, name, one-line why, and the button that
    /// gets it granted.
    private func permissionRow(
        name: String,
        granted: Bool,
        need: String,
        actionTitle: String = "Open Settings",
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(granted ? XMOTheme.Accent.green : XMOTheme.Accent.red)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(XMOTheme.TextColor.primary)
                Text(granted ? "Access granted" : need)
                    .font(XMOTheme.Typography.meta)
                    .foregroundStyle(XMOTheme.TextColor.muted)
            }

            Spacer()

            if !granted {
                Button(actionTitle, action: action)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func openSettings(_ pane: SettingsPane) {
        _ = pane.settingsURL.map { NSWorkspace.shared.open($0) }
    }

    private func cheatSheetRow(_ key: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(XMOTheme.Typography.mono(11, weight: .semibold))
                .foregroundStyle(XMOTheme.TextColor.primary)
                .frame(width: 50, alignment: .trailing)
            Text("=")
                .font(XMOTheme.Typography.meta)
                .foregroundStyle(XMOTheme.TextColor.faint)
            Text(action)
                .font(XMOTheme.Typography.meta)
                .foregroundStyle(XMOTheme.TextColor.muted)
        }
    }

    private func refreshPermissions() {
        micStatus = MicrophonePermission.status
        accessibilityGranted = AXIsProcessTrusted()
        // Same call as the hotkey health check and the inputMonitoring probe.
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }

    /// Undetermined is the only state the system prompt can still appear in;
    /// once denied it never shows again, so the button becomes the deep link.
    private func micAction() {
        guard micStatus == .notDetermined else {
            openSettings(.microphone)
            return
        }
        Task { @MainActor in
            let granted = await MicrophonePermission.request()
            micStatus = granted ? .authorized : .denied
        }
    }

    /// `CGPreflightListenEventAccess()` is answered once per process, so a grant
    /// made during the round trip cannot show up here — the row would stay red
    /// beside a green Accessibility and the step would loop. After the pane has
    /// been opened the row offers the relaunch the health panel's remedy performs.
    private func inputMonitoringAction() {
        if inputMonitoringPaneOpened {
            AppRelauncher.relaunch()
        } else {
            inputMonitoringPaneOpened = true
            openSettings(.inputMonitoring)
        }
    }

    private func finish() {
        settings.hasAcknowledgedRecordingConsent = true
        completedDictationOnboarding = true
    }
}
