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
    var bluetoothRedirected = false
    var noSignal = false
    @State private var showBluetoothInfo = false
    var onUpgrade: ((UpgradeAction) -> Void)?

    var body: some View {
        Group {
            switch state {
            case .recording:
                if let error = lastError {
                    // Mic stall surfaced by the first-frame watchdog — show it loudly
                    // instead of a normal-looking recording meter.
                    statusRow(icon: "xmark.circle.fill", iconColor: .red, text: error)
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
            if noSignal {
                Circle()
                    .fill(.white.opacity(0.3))
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
            }
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
            WaveformBars(level: audioLevel, noSignal: noSignal)
            if noSignal {
                Text("No signal from microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Text(timerString)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()
            }
            if bluetoothRedirected {
                Group {
                    if showBluetoothInfo {
                        Text("Using laptop mic — AirPods mic compresses audio below what speech recognition needs")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Image(systemName: "laptopcomputer.and.arrow.down")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .onTapGesture { showBluetoothInfo.toggle() }
                .onHover { hovering in showBluetoothInfo = hovering }
            }
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
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Text("Pasted")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 14)

                if !hideCleanupButton {
                    upgradeButton(label: "C", subtitle: "Cleanup", action: .cleanup)
                }
                upgradeButton(label: "T", subtitle: "Translate", action: .translate)
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
    private func upgradeButton(label: String, subtitle: String, action: UpgradeAction) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(0.07))
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
    var noSignal = false
    private let barCount = 7

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(noSignal ? .white.opacity(0.3) : .red.opacity(0.8))
                    .frame(width: noSignal ? 2 : 3, height: noSignal ? 4 : barHeight(for: index))
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
    var bluetoothRedirected = false
    var noSignal = false
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
            bluetoothRedirected: model.bluetoothRedirected,
            noSignal: model.noSignal,
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
    private var currentScreen: NSScreen?

    func start(coordinator: DictationCoordinator, hotkeyManager: HotkeyManager) {
        guard let screen = screenForMouse() else { return }
        currentScreen = screen

        // Initial off-screen rect — panel resizes to content dynamically
        let screenOrigin = screen.frame.origin
        let rect = NSRect(x: screenOrigin.x + screen.frame.width / 2, y: screen.visibleFrame.maxY - 50, width: 1, height: 1)
        let p = OverlayPanel(contentRect: rect)
        p.styleMask = [.nonactivatingPanel, .fullSizeContentView]
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.hasShadow = false
        p.becomesKeyOnlyIfNeeded = true
        p.setFrameAutosaveName("")

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
                if newSeconds != self.model.recordingSeconds {
                    self.model.recordingSeconds = newSeconds
                }
                self.model.showUpgradeButtons = coordinator.isUpgradePanelVisible
                self.model.hideCleanupButton = coordinator.cleanupAlreadyApplied
                self.model.upgradeCountdown = coordinator.upgradeCountdown
                self.model.lastError = coordinator.lastError
                self.model.bluetoothRedirected = coordinator.bluetoothMicRedirected
                self.model.noSignal = coordinator.noSignal

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
        guard let screen = screenForMouse() else { return }
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard size.width > 10 && size.height > 5 else { return }

        // Detect cross-screen move by identity, not dimensions
        let screenChanged = screen !== currentScreen
        if screenChanged {
            currentScreen = screen
        }

        // Only resize when dimensions actually change (avoid 20x/sec animation calls)
        let widthChanged = abs(size.width - lastPanelSize.width) > 1
        let heightChanged = abs(size.height - lastPanelSize.height) > 1
        guard widthChanged || heightChanged || screenChanged else { return }
        lastPanelSize = size

        let screenOrigin = screen.frame.origin
        let x = screenOrigin.x + (screen.frame.width - size.width) / 2
        let y = screen.visibleFrame.maxY - size.height - 8
        let newFrame = NSRect(x: x, y: y, width: size.width, height: size.height)

        if screenChanged {
            // Snap instantly across screens — no sliding through the gap
            panel.setFrame(newFrame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        }
    }

    private func screenForMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        panel?.orderOut(nil)
    }
}
