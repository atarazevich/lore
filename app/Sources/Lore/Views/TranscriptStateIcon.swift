import SwiftUI

/// Transcript state of a meeting (#109): assembled from ~10s live chunks
/// (chunked), rebuilt from the whole audio (whole), or a rebuild in flight.
enum TranscriptState: Equatable {
    case whole
    /// `canRebuild`: audio to rebuild from is findable — the icon is
    /// clickable; otherwise it renders dimmed and inert.
    case chunked(canRebuild: Bool)
    /// Batch/import progress (0–1) when the engine reports one.
    case rebuilding(progress: Double?)
}

/// Mini-waveform indicator (#109, approved prototype V1 in
/// `docs/design/prototypes/transcript-quality-indicator.html`): five 2.5pt
/// bars. Gray even bars = whole transcript; amber torn bars (extra gaps) =
/// chunked, clickable to start a rebuild when audio is available, dimmed to
/// 45% when not; blue staggered-pulsing bars = rebuilding. The label lives
/// in the tooltip only.
struct TranscriptStateIcon: View {
    let state: TranscriptState
    /// Starts a rebuild; only wired up for `.chunked(canRebuild: true)`.
    var rebuildAction: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Group {
            if case .chunked(canRebuild: true) = state, let rebuildAction {
                Button(action: rebuildAction) {
                    bars.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                bars
            }
        }
        .help(label)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .whole:
            return "Whole transcript"
        case .chunked(canRebuild: true):
            return "Chunked transcript \u{00B7} rebuild from audio"
        case .chunked(canRebuild: false):
            return "Chunked \u{00B7} audio not available"
        case .rebuilding(let progress):
            if let progress, progress > 0 {
                return "Rebuilding\u{2026} \(Int(progress * 100))%"
            }
            return "Rebuilding\u{2026}"
        }
    }

    /// Prototype `.tq`: bar heights per state; chunked adds 3pt tears after
    /// the 2nd and 4th bar.
    private var heights: [CGFloat] {
        switch state {
        case .whole: [5, 9, 7, 9, 5]
        case .chunked: [4, 8, 6, 3, 7]
        case .rebuilding: [4, 8, 6, 8, 4]
        }
    }

    private var barColor: Color {
        switch state {
        case .whole: LoreTheme.TextColor.faint
        case .chunked: LoreTheme.Accent.amber.opacity(0.85)
        case .rebuilding: LoreTheme.Accent.blue
        }
    }

    private var bars: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor)
                    .frame(width: 2.5, height: heights[i])
                    .padding(.trailing, isChunked && (i == 1 || i == 3) ? 3 : 0)
                    .opacity(barOpacity)
                    .animation(barAnimation(index: i), value: pulsing)
            }
        }
        .frame(height: 10)
        .opacity(isDisabledChunked ? 0.45 : 1)
        .onAppear {
            if case .rebuilding = state { pulsing = true }
        }
        .onChange(of: state) { _, newState in
            if case .rebuilding = newState { pulsing = true } else { pulsing = false }
        }
    }

    private var isChunked: Bool {
        if case .chunked = state { return true }
        return false
    }

    private var isDisabledChunked: Bool {
        if case .chunked(canRebuild: false) = state { return true }
        return false
    }

    /// CSS `pulse`: opacity .35↔1, 1.1s alternate; the per-bar stagger lives
    /// in `barAnimation`'s delay. Static at full opacity when Reduce Motion
    /// is on.
    private var barOpacity: Double {
        guard case .rebuilding = state, !reduceMotion else { return 1 }
        return pulsing ? 1 : 0.35
    }

    private func barAnimation(index: Int) -> Animation? {
        guard case .rebuilding = state, !reduceMotion else { return nil }
        return .easeInOut(duration: 0.55)
            .repeatForever(autoreverses: true)
            .delay(Double(index) * 0.12)
    }
}
