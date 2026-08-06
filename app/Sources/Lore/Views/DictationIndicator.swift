import AppKit
import SwiftUI

// MARK: - View

struct DictationIndicatorView: View {
    let state: DictationState
    let audioLevel: Float
    var isLocked = false
    var pendingMode: UpgradeAction?
    /// Fn+K armed or entry flagged (#122): shows the K badge while
    /// recording and fills the upgrade panel's K keycap after paste.
    var operatorAddressed = false
    var recordingSeconds: Int = 0
    var showUpgradeButtons = false
    var hideCleanupButton = false
    /// DSET-06: the C/T keycap hints disappear when the upgrade-keys modifier
    /// toggle is off; the buttons themselves stay clickable.
    var showUpgradeKeycaps = true
    var upgradeCountdown: Double?
    var lastError: String?
    var bluetoothRedirected = false
    var noSignal = false
    @State private var showBluetoothInfo = false
    var onUpgrade: ((UpgradeAction) -> Void)?
    /// Post-paste K toggle (#122) — same tap affordance as the C/T buttons.
    var onOperatorToggle: (() -> Void)?

    var body: some View {
        Group {
            switch state {
            case .recording:
                if let error = lastError {
                    // Mic stall surfaced by the first-frame watchdog — show it loudly
                    // instead of a normal-looking recording meter.
                    statusRow(icon: "xmark.circle.fill", iconColor: LoreTheme.Accent.red, text: error, wrap: true)
                } else {
                    recordingContent
                }
            case .loadingModel:
                statusRow(icon: "arrow.down.circle", text: "Downloading model...")
            case .processing:
                processingContent
            case .done:
                if showUpgradeButtons {
                    upgradeContent
                } else if let error = lastError {
                    statusRow(icon: "xmark.circle.fill", iconColor: LoreTheme.Accent.red, text: error, wrap: true)
                } else {
                    statusRow(icon: "checkmark.circle.fill", iconColor: LoreTheme.Accent.green, text: "Done")
                }
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Recording

    private var recordingContent: some View {
        HStack(spacing: 10) {
            Circle()
                // No-signal keeps its distinct dimmed look (not a token color
                // — it must read as "not recording red").
                .fill(noSignal ? Color.white.opacity(0.3) : LoreTheme.Accent.red)
                .frame(width: 8, height: 8)
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(LoreTheme.TextColor.muted)
            }
            waveform
            if noSignal {
                Text("No signal from microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LoreTheme.TextColor.muted)
            } else {
                Text(timerString)
                    .font(LoreTheme.Typography.mono(13))
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .monospacedDigit()
            }
            if bluetoothRedirected {
                Group {
                    if showBluetoothInfo {
                        Text("Using laptop mic — AirPods mic compresses audio below what speech recognition needs")
                            .font(LoreTheme.Typography.meta)
                            .foregroundStyle(LoreTheme.TextColor.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Image(systemName: "laptopcomputer.and.arrow.down")
                            .font(.system(size: 11))
                            .foregroundStyle(LoreTheme.TextColor.muted)
                    }
                }
                .onTapGesture { showBluetoothInfo.toggle() }
                .onHover { hovering in showBluetoothInfo = hovering }
            }
            if let mode = pendingMode {
                Text("+ \(mode == .cleanup ? "Cleanup" : "Translate")")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LoreTheme.TextColor.primary)
            }
            if operatorAddressed {
                // Fn+K armed (#122) — small keycap badge, same idiom as the
                // C/T keycaps in the upgrade panel.
                Text("K")
                    .font(LoreTheme.Typography.mono(11, weight: .semibold))
                    .foregroundStyle(LoreTheme.TextColor.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                            .fill(Color.white.opacity(0.07))
                    )
            }
        }
    }

    /// Shared Lore waveform while live; the no-signal state keeps its distinct
    /// flat dimmed bars. Fixed 18pt frame preserves the pre-Stage-H panel
    /// height (`.fixedSize()` sizing is load-bearing — see the manager).
    private var waveform: some View {
        Group {
            if noSignal {
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 2, height: 4)
                    }
                }
            } else {
                LoreLiveWaveform(level: audioLevel)
            }
        }
        .frame(height: 18)
    }

    private var timerString: String {
        let m = recordingSeconds / 60
        let s = recordingSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Status rows (processing, downloading, done, error)

    private var processingContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Processing...")
                .font(LoreTheme.Typography.body)
                .foregroundStyle(LoreTheme.TextColor.primary)
        }
    }

    private func statusRow(icon: String, iconColor: Color = LoreTheme.TextColor.muted, text: String, wrap: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.system(size: 14))
            // Errors can carry a longer message — wrap at a capped width instead of stretching
            // the panel into one wide line. The panel is `.fixedSize()`, so the width must be
            // constrained BEFORE `.fixedSize(vertical:)` measures height — otherwise the text is
            // measured at unbounded width (one line), that 1-line height is locked in, and the
            // later wrap clips vertically. A definite `.frame(width:)` is proposed to the Text so
            // it wraps; `fixedSize(vertical:)` then reports the true multi-line height the panel
            // grows to. No line limit on wrap so the full message always shows.
            Text(text)
                .font(LoreTheme.Typography.body)
                .foregroundStyle(LoreTheme.TextColor.primary)
                .lineLimit(wrap ? nil : 1)
                .multilineTextAlignment(.leading)
                .frame(width: wrap ? 260 : nil, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Upgrade

    @ViewBuilder
    private var upgradeContent: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                // A failed cleanup/translate must not render as success (#50):
                // red row states what happened; C/T stay available as retry.
                if let error = lastError {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LoreTheme.Accent.red)
                        .font(.system(size: 12))
                    Text(error)
                        .font(LoreTheme.Typography.body)
                        .foregroundStyle(LoreTheme.TextColor.primary)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LoreTheme.Accent.green)
                        .font(.system(size: 12))
                    Text("Pasted")
                        .font(LoreTheme.Typography.body)
                        .foregroundStyle(LoreTheme.TextColor.muted)
                }

                LoreTheme.Surface.line
                    .frame(width: 1, height: 14)

                if !hideCleanupButton {
                    upgradeButton(label: "C", subtitle: "Cleanup") { onUpgrade?(.cleanup) }
                }
                upgradeButton(label: "T", subtitle: "Translate") { onUpgrade?(.translate) }
                // Fn+K (#122): filled while the entry is flagged — the bare-K
                // press's visual feedback; tap toggles like the keycap does.
                upgradeButton(label: "K", subtitle: "Operator",
                              highlighted: operatorAddressed) { onOperatorToggle?() }
            }

            if let countdown = upgradeCountdown, countdown > 0 {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: geo.size.width * (countdown / DictationCoordinator.upgradePanelDuration))
                }
                .frame(height: 2)
            }
        }
    }

    @ViewBuilder
    private func upgradeButton(
        label: String, subtitle: String, highlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            if showUpgradeKeycaps {
                Text(label)
                    .font(LoreTheme.Typography.mono(11, weight: .semibold))
                    .foregroundStyle(highlighted ? LoreTheme.TextColor.primary : LoreTheme.TextColor.muted)
            }
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LoreTheme.TextColor.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            // Design `.ibtn` fill — same white .07 as LoreIconButton; the
            // highlighted (flagged) state fills with the selection accent.
            RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                .fill(highlighted ? LoreTheme.Accent.blue.opacity(0.35) : Color.white.opacity(0.07))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

// MARK: - Model

@Observable
@MainActor
final class DictationIndicatorModel {
    var state: DictationState = .idle
    var audioLevel: Float = 0
    var isLocked = false
    var pendingMode: UpgradeAction?
    var operatorAddressed = false
    var recordingSeconds: Int = 0
    var showUpgradeButtons = false
    var hideCleanupButton = false
    var showUpgradeKeycaps = true
    var upgradeCountdown: Double?
    var lastError: String?
    var bluetoothRedirected = false
    var noSignal = false
    var onUpgrade: ((UpgradeAction) -> Void)?
    var onOperatorToggle: (() -> Void)?
}

/// SwiftUI wrapper that reads the observable model.
private struct DictationIndicatorHost: View {
    @State var model: DictationIndicatorModel

    var body: some View {
        DictationIndicatorView(
            state: model.state,
            audioLevel: model.audioLevel,
            isLocked: model.isLocked,
            pendingMode: model.pendingMode,
            operatorAddressed: model.operatorAddressed,
            recordingSeconds: model.recordingSeconds,
            showUpgradeButtons: model.showUpgradeButtons,
            hideCleanupButton: model.hideCleanupButton,
            showUpgradeKeycaps: model.showUpgradeKeycaps,
            upgradeCountdown: model.upgradeCountdown,
            lastError: model.lastError,
            bluetoothRedirected: model.bluetoothRedirected,
            noSignal: model.noSignal,
            onUpgrade: model.onUpgrade,
            onOperatorToggle: model.onOperatorToggle
        )
    }
}

// MARK: - Manager (dynamic sizing)

@MainActor
final class DictationIndicatorManager {
    private var panel: TopCenteredPanel<DictationIndicatorHost>?
    private var observationTask: Task<Void, Never>?
    /// Observable dictation state mirror; the shell reads `model.isLocked`
    /// for the Dictation nav live dot (SHELL-10).
    let model = DictationIndicatorModel()
    private var recordingStartDate: Date?

    func start(coordinator: DictationCoordinator, hotkeyManager: HotkeyManager) {
        guard let panel = TopCenteredPanel(
            content: DictationIndicatorHost(model: model), topInset: 8
        ) else { return }
        self.panel = panel

        // Wire up upgrade callback
        model.onUpgrade = { [weak coordinator] action in
            Task { @MainActor in
                await coordinator?.applyUpgradeByKey(action)
            }
        }
        model.onOperatorToggle = { [weak coordinator] in
            Task { @MainActor in
                coordinator?.toggleOperatorAddressedByKey()
            }
        }

        // Poll coordinator state and push into model
        observationTask = Task { [weak self, weak coordinator, weak hotkeyManager] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let coordinator else { break }

                let newState = coordinator.state

                // Track recording duration from pre-buffer start (when audio actually begins)
                let isCapturing = newState == .recording || coordinator.isPreBuffering
                if isCapturing && self.recordingStartDate == nil {
                    self.recordingStartDate = Date()
                } else if !isCapturing {
                    self.recordingStartDate = nil
                }
                let newSeconds: Int
                if let start = self.recordingStartDate {
                    newSeconds = Int(Date().timeIntervalSince(start))
                } else {
                    newSeconds = 0
                }

                // Push to model
                self.model.state = newState
                self.model.audioLevel = coordinator.audioLevel
                self.model.isLocked = hotkeyManager?.isLocked ?? false
                self.model.pendingMode = coordinator.pendingCleanupMode
                self.model.operatorAddressed = coordinator.operatorAddressedDisplayed
                if newSeconds != self.model.recordingSeconds {
                    self.model.recordingSeconds = newSeconds
                }
                self.model.showUpgradeButtons = coordinator.isUpgradePanelVisible
                self.model.hideCleanupButton = coordinator.cleanupAlreadyApplied
                self.model.showUpgradeKeycaps =
                    coordinator.settings?.modifierUpgradeKeysEnabled ?? true
                self.model.upgradeCountdown = coordinator.upgradeCountdown
                self.model.lastError = coordinator.lastError
                self.model.bluetoothRedirected = coordinator.bluetoothMicRedirected
                self.model.noSignal = coordinator.noSignal

                // Keep CGEvent tap flag in sync
                hotkeyManager?.updateUpgradeShowingFlag(coordinator.isUpgradePanelVisible)

                // Show/hide and resize
                if newState == .idle {
                    self.panel?.hide()
                } else {
                    self.panel?.show()
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
