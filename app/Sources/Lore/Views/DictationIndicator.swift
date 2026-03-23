import AppKit
import SwiftUI

// MARK: - View

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
                statusRow(icon: "arrow.down.circle", text: "Downloading model...")
            case .processing:
                processingContent
            case .done:
                if showUpgradeButtons {
                    upgradeContent
                } else if let error = lastError {
                    statusRow(icon: "xmark.circle.fill", iconColor: .red, text: error)
                } else {
                    statusRow(icon: "checkmark.circle.fill", iconColor: .green, text: "Done")
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
                .fill(.red)
                .frame(width: 8, height: 8)
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
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
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func statusRow(icon: String, iconColor: Color = .white.opacity(0.7), text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.system(size: 14))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
    }

    // MARK: - Upgrade

    @ViewBuilder
    private var upgradeContent: some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 13))
                    Text("Pasted")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                }

                HStack(spacing: 8) {
                    if !hideCleanupButton {
                        upgradeButton(label: "[C] Cleanup", action: .cleanup)
                    }
                    upgradeButton(label: "[T] Translate", action: .translate)
                }
            }

            if let countdown = upgradeCountdown, countdown > 0 {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: geo.size.width * (countdown / DictationCoordinator.upgradePanelDuration))
                }
                .frame(height: 3)
            }
        }
    }

    @ViewBuilder
    private func upgradeButton(label: String, action: UpgradeAction) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
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

// MARK: - Manager (dynamic sizing)

@MainActor
final class DictationIndicatorManager {
    private var panel: OverlayPanel?
    private var hostingView: NSHostingView<DictationIndicatorHost>?
    private var observationTask: Task<Void, Never>?
    private let model = DictationIndicatorModel()
    private var recordingStartDate: Date?
    private var lastPanelSize: NSSize = .zero
    private var screenWidth: CGFloat = 1440
    private var visibleTop: CGFloat = 900

    func start(coordinator: DictationCoordinator, hotkeyManager: HotkeyManager) {
        let screen = NSScreen.main
        screenWidth = screen?.frame.width ?? 1440
        visibleTop = screen?.visibleFrame.maxY ?? ((screen?.frame.height ?? 900) - 25)

        // Initial off-screen rect — panel resizes to content dynamically
        let rect = NSRect(x: screenWidth / 2, y: visibleTop - 50, width: 1, height: 1)
        let p = OverlayPanel(contentRect: rect)
        p.styleMask = [.nonactivatingPanel, .fullSizeContentView]
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.hasShadow = false
        p.becomesKeyOnlyIfNeeded = true
        p.sharingType = .readOnly

        let hv = NSHostingView(rootView: DictationIndicatorHost(model: model))
        if #available(macOS 13.0, *) {
            hv.sizingOptions = .intrinsicContentSize
        }
        hv.appearance = NSAppearance(named: .darkAqua)
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentView = hv
        self.panel = p
        self.hostingView = hv

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

                // Track recording duration (update only when seconds change)
                if newState == .recording && self.recordingStartDate == nil {
                    self.recordingStartDate = Date()
                } else if newState != .recording {
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
                if newSeconds != self.model.recordingSeconds {
                    self.model.recordingSeconds = newSeconds
                }
                self.model.showUpgradeButtons = coordinator.isUpgradePanelVisible
                self.model.hideCleanupButton = coordinator.cleanupAlreadyApplied
                self.model.upgradeCountdown = coordinator.upgradeCountdown
                self.model.lastError = coordinator.lastError

                // Keep CGEvent tap flag in sync
                hotkeyManager?.updateUpgradeShowingFlag(coordinator.isUpgradePanelVisible)

                // Show/hide and resize
                if newState == .idle {
                    self.panel?.orderOut(nil)
                    self.lastPanelSize = .zero
                } else {
                    if self.panel?.isVisible != true {
                        self.panel?.orderFront(nil)
                    }
                    self.resizePanelToContent()
                }
            }
        }
    }

    private func resizePanelToContent() {
        guard let panel, let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard size.width > 10 && size.height > 5 else { return }

        // Only resize when dimensions actually change (avoid 20x/sec animation calls)
        let widthChanged = abs(size.width - lastPanelSize.width) > 1
        let heightChanged = abs(size.height - lastPanelSize.height) > 1
        guard widthChanged || heightChanged else { return }
        lastPanelSize = size

        let x = (screenWidth - size.width) / 2
        let y = visibleTop - size.height - 8
        let newFrame = NSRect(x: x, y: y, width: size.width, height: size.height)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        panel?.orderOut(nil)
    }
}
