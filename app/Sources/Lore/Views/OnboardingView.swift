import SwiftUI
import AVFoundation
import ApplicationServices
import AppKit

struct OnboardingView: View {
    @Bindable var settings: AppSettings
    @AppStorage("completedDictationOnboarding") private var completedDictationOnboarding = false
    @State private var currentStep = 0
    @State private var micPermission: MicPermissionStatus = .unknown
    @State private var accessibilityGranted = false

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

            // Dots
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Circle()
                        .fill(i == currentStep ? Color.accentTeal : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 16)

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentStep -= 1
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    if currentStep < totalSteps - 1 {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentStep += 1
                        }
                    } else {
                        finish()
                    }
                } label: {
                    Text(currentStep < totalSteps - 1 ? "Next" : "Get Started")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            Color.accentTeal,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: 480)
        .background(.ultraThinMaterial)
        .onAppear {
            refreshPermissions()
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Image(systemName: "waveform")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.accentTeal)
                .frame(height: 44)

            Spacer().frame(height: 14)

            Text("Welcome to Lore")
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)

            Spacer().frame(height: 8)

            Text("Hold Fn, speak, release \u{2014} your words appear instantly.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 0) {
            Text("Permissions")
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)

            Spacer().frame(height: 14)

            VStack(alignment: .leading, spacing: 12) {
                // Microphone
                HStack(spacing: 12) {
                    permissionIcon(granted: micPermission == .granted)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone")
                            .font(.system(size: 13, weight: .medium))
                        Text(micPermission == .granted ? "Access granted" : "Required for dictation")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if micPermission != .granted {
                        Button("Grant Microphone") {
                            requestMicPermission()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                // Accessibility
                HStack(spacing: 12) {
                    permissionIcon(granted: accessibilityGranted)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                            .font(.system(size: 13, weight: .medium))
                        Text(accessibilityGranted ? "Access granted" : "Required for global hotkey")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !accessibilityGranted {
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer().frame(height: 12)

            Text("You can grant these later in System Settings if you prefer.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .onAppear { refreshPermissions() }
    }

    // MARK: - Step 3: Fn Key Setup

    private var fnKeyStep: some View {
        VStack(spacing: 0) {
            Text("Fn Key Setup")
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)

            Spacer().frame(height: 12)

            Text("To use Fn as your dictation key, set it to \u{201C}Do Nothing\u{201D} in System Settings.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 12)

            VStack(alignment: .leading, spacing: 4) {
                instructionRow("System Settings")
                instructionRow("Keyboard")
                instructionRow("\u{201C}Press \u{1F310} fn key to\u{201D} \u{2192} \u{201C}Do Nothing\u{201D}")
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

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
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 4: Ready

    private var readyStep: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.accentTeal)
                .frame(height: 44)

            Spacer().frame(height: 14)

            Text("You\u{2019}re all set!")
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)

            Spacer().frame(height: 8)

            Text("Hold \(settings.hotkeyKey.displayName) and start speaking.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 14)

            VStack(alignment: .leading, spacing: 6) {
                cheatSheetRow("Fn", "talk")
                cheatSheetRow("Space", "lock recording")
                cheatSheetRow("C", "cleanup")
                cheatSheetRow("T", "translate")
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Spacer().frame(height: 14)

            Text("Please quit (\u{2318}Q) and reopen Lore for permissions to take full effect.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.orange)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func permissionIcon(granted: Bool) -> some View {
        Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.system(size: 20))
            .foregroundStyle(granted ? .green : .red)
    }

    private func instructionRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text("\u{2022}")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func cheatSheetRow(_ key: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 50, alignment: .trailing)
            Text("=")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(action)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func refreshPermissions() {
        let perm = AVAudioApplication.shared.recordPermission
        switch perm {
        case .granted:
            micPermission = .granted
        case .denied:
            micPermission = .denied
        case .undetermined:
            micPermission = .undetermined
        @unknown default:
            micPermission = .unknown
        }
        accessibilityGranted = AXIsProcessTrusted()
    }

    private func requestMicPermission() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                micPermission = granted ? .granted : .denied
            }
        }
    }

    private func finish() {
        settings.hasAcknowledgedRecordingConsent = true
        completedDictationOnboarding = true
    }
}

private enum MicPermissionStatus {
    case unknown, undetermined, granted, denied
}
