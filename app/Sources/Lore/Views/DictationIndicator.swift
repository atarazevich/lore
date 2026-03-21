import AppKit
import SwiftUI

struct DictationIndicatorView: View {
    let state: DictationState
    let audioLevel: Float
    var isLocked = false
    var showUpgradeButtons = false
    var hideCleanupButton = false
    var upgradeCountdown: Double?
    var onUpgrade: ((UpgradeAction) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            switch state {
            case .recording:
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    WaveformBars(level: audioLevel)
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            case .loadingModel:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading model...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            case .processing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            case .done:
                if showUpgradeButtons {
                    upgradeContent
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 14))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

            case .idle:
                EmptyView()
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .animation(.easeInOut(duration: 0.15), value: state)
    }

    @ViewBuilder
    private var upgradeContent: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color.green)
                    .font(.system(size: 14))
                if !hideCleanupButton {
                    upgradeButton(label: "[C] Cleanup", action: .cleanup)
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
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func upgradeButton(label: String, action: UpgradeAction) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundColor(Color.white.opacity(0.9))
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

private struct WaveformBars: View {
    let level: Float
    private let barCount = 5

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

/// Bridges DictationCoordinator's @Observable state to a SwiftUI-friendly model
/// that a single NSHostingView can observe without recreation.
@Observable
@MainActor
final class DictationIndicatorModel {
    var state: DictationState = .idle
    var audioLevel: Float = 0
    var isLocked = false
    var showUpgradeButtons = false
    var hideCleanupButton = false
    var upgradeCountdown: Double?
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
            showUpgradeButtons: model.showUpgradeButtons,
            hideCleanupButton: model.hideCleanupButton,
            upgradeCountdown: model.upgradeCountdown,
            onUpgrade: model.onUpgrade
        )
    }
}

@MainActor
final class DictationIndicatorManager {
    private var panel: OverlayPanel?
    private var observationTask: Task<Void, Never>?
    private let model = DictationIndicatorModel()

    func start(coordinator: DictationCoordinator, hotkeyManager: HotkeyManager) {
        // Create panel and hosting view once
        let screen = NSScreen.main
        let screenWidth = screen?.frame.width ?? 1440
        let panelWidth: CGFloat = 380
        let panelHeight: CGFloat = 120
        let x = (screenWidth - panelWidth) / 2
        // Position below menu bar / notch safe area
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
        // Force dark appearance at AppKit level so vibrancy doesn't wash out text/colors
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

        // Poll coordinator state and push into model (which SwiftUI observes reactively)
        observationTask = Task { [weak self, weak coordinator, weak hotkeyManager] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let coordinator else { break }

                let newState = coordinator.state
                let newLevel = coordinator.audioLevel

                self.model.state = newState
                self.model.audioLevel = newLevel
                self.model.isLocked = hotkeyManager?.isLocked ?? false
                self.model.showUpgradeButtons = coordinator.isUpgradePanelVisible
                self.model.hideCleanupButton = coordinator.cleanupAlreadyApplied
                self.model.upgradeCountdown = coordinator.upgradeCountdown

                // Keep CGEvent tap flag in sync for upgrade panel dismissal
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
