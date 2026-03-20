import AppKit
import SwiftUI

struct DictationIndicatorView: View {
    let state: DictationState
    let audioLevel: Float
    var isLocked = false

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                WaveformBars(level: audioLevel)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            case .processing:
                ProgressView()
                    .controlSize(.small)
                Text("Processing...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
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
}

/// SwiftUI wrapper that reads the observable model.
private struct DictationIndicatorHost: View {
    @State var model: DictationIndicatorModel

    var body: some View {
        DictationIndicatorView(state: model.state, audioLevel: model.audioLevel, isLocked: model.isLocked)
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
        let panelWidth: CGFloat = 160
        let panelHeight: CGFloat = 40
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
        p.contentView = NSHostingView(rootView: DictationIndicatorHost(model: model))
        self.panel = p

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
