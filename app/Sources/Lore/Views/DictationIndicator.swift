import AppKit
import SwiftUI

struct DictationIndicatorView: View {
    let state: DictationState
    let audioLevel: Float
    var isLocked = false
    var pendingMode: UpgradeAction?
    var recordingSeconds: Int = 0
    var showUpgradeButtons = false
    var hideCleanupButton = false
    var upgradeCountdown: Double?
    var lastError: String?
    var onUpgrade: ((UpgradeAction) -> Void)?

    var body: some View {
        Group {
            switch state {
            case .recording:
                recordingContent
            case .loadingModel:
                downloadingContent
            case .processing:
                processingContent
            case .done:
                if showUpgradeButtons {
                    upgradeContent
                } else if let error = lastError {
                    errorContent(error)
                } else {
                    doneContent
                }
            case .idle:
                EmptyView()
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.2), value: state)
        .animation(.spring(duration: 0.2), value: isLocked)
        .animation(.spring(duration: 0.2), value: pendingMode)
    }

    // MARK: - Recording

    private var recordingContent: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
            }
            WaveformBars(level: audioLevel)
            Text(timerString)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .monospacedDigit()
            if let mode = pendingMode {
                Text("+ \(mode == .cleanup ? "Cleanup" : "Translate")")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var timerString: String {
        let m = recordingSeconds / 60
        let s = recordingSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Processing

    private var processingContent: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Processing...")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Downloading

    private var downloadingContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
            Text("Downloading model...")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Done

    private var doneContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))
            Text("Done")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Error

    private func errorContent(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Upgrade

    @ViewBuilder
    private var upgradeContent: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
                Text("Pasted")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer().frame(width: 4)
                if !hideCleanupButton {
                    upgradeButton(label: "[V] Cleanup", action: .cleanup)
                }
                upgradeButton(label: "[T] Translate", action: .translate)
            }

            if let countdown = upgradeCountdown, countdown > 0 {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(red: 0.4, green: 0.6, blue: 1.0).opacity(0.6))
                        .frame(width: geo.size.width * (countdown / DictationCoordinator.upgradePanelDuration))
                }
                .frame(height: 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func upgradeButton(label: String, action: UpgradeAction) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .frame(minWidth: 110, minHeight: 32)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onUpgrade?(action)
            }
    }
}

// MARK: - Waveform

private struct WaveformBars: View {
    let level: Float
    private let barCount = 7

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.red.opacity(0.8))
                    .frame(width: 3, height: barHeight(for: index))
            }
        }
        .frame(height: 18)
        .animation(.easeInOut(duration: 0.1), value: level)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 4
        let maxExtra: CGFloat = 14
        let phase = CGFloat(index) / CGFloat(barCount)
        let variation = sin(phase * .pi + CGFloat(level) * .pi * 2)
        let normalized = CGFloat(level) * (0.5 + 0.5 * abs(variation))
        return base + maxExtra * normalized
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
    var recordingSeconds: Int = 0
    var showUpgradeButtons = false
    var hideCleanupButton = false
    var upgradeCountdown: Double?
    var lastError: String?
    var onUpgrade: ((UpgradeAction) -> Void)?
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
            recordingSeconds: model.recordingSeconds,
            showUpgradeButtons: model.showUpgradeButtons,
            hideCleanupButton: model.hideCleanupButton,
            upgradeCountdown: model.upgradeCountdown,
            lastError: model.lastError,
            onUpgrade: model.onUpgrade
        )
    }
}

// MARK: - Manager

@MainActor
final class DictationIndicatorManager {
    private var panel: OverlayPanel?
    private var observationTask: Task<Void, Never>?
    private let model = DictationIndicatorModel()
    private var recordingStartDate: Date?

    func start(coordinator: DictationCoordinator, hotkeyManager: HotkeyManager) {
        // Create panel and hosting view once
        let screen = NSScreen.main
        let screenWidth = screen?.frame.width ?? 1440
        let panelWidth: CGFloat = 380
        let panelHeight: CGFloat = 120
        let x = (screenWidth - panelWidth) / 2
        let visibleTop = screen?.visibleFrame.maxY ?? ((screen?.frame.height ?? 900) - 25)
        let y = visibleTop - panelHeight - 8
        let rect = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
        let p = OverlayPanel(contentRect: rect)
        p.styleMask = [.nonactivatingPanel, .fullSizeContentView]
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.hasShadow = false
        p.becomesKeyOnlyIfNeeded = true
        // Always visible in screenshots (override OverlayPanel's screen-share hiding)
        p.sharingType = .readOnly
        let hostingView = NSHostingView(rootView: DictationIndicatorHost(model: model))
        hostingView.appearance = NSAppearance(named: .darkAqua)
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentView = hostingView
        self.panel = p

        // Wire up upgrade callback
        model.onUpgrade = { [weak coordinator] action in
            Task { @MainActor in
                await coordinator?.applyUpgradeByKey(action)
            }
        }

        // Poll coordinator state and push into model
        observationTask = Task { [weak self, weak coordinator, weak hotkeyManager] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let coordinator else { break }

                let newState = coordinator.state

                // Track recording duration
                if newState == .recording && self.recordingStartDate == nil {
                    self.recordingStartDate = Date()
                } else if newState != .recording {
                    self.recordingStartDate = nil
                }

                self.model.state = newState
                self.model.audioLevel = coordinator.audioLevel
                self.model.isLocked = hotkeyManager?.isLocked ?? false
                self.model.pendingMode = coordinator.pendingCleanupMode
                self.model.showUpgradeButtons = coordinator.isUpgradePanelVisible
                self.model.hideCleanupButton = coordinator.cleanupAlreadyApplied
                self.model.upgradeCountdown = coordinator.upgradeCountdown
                self.model.lastError = coordinator.lastError

                if let start = self.recordingStartDate {
                    self.model.recordingSeconds = Int(Date().timeIntervalSince(start))
                } else {
                    self.model.recordingSeconds = 0
                }

                // Keep CGEvent tap flag in sync
                hotkeyManager?.updateUpgradeShowingFlag(coordinator.isUpgradePanelVisible)

                if newState == .idle {
                    self.panel?.orderOut(nil)
                } else {
                    if self.panel?.isVisible != true {
                        self.panel?.orderFront(nil)
                    }
                }
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        panel?.orderOut(nil)
    }
}
