import SwiftUI

/// Stage 1 design tokens (D-031: visual = design wins, additive only).
///
/// Source of truth: `docs/design/xmo-stage1/handoff/README.md` ("Design tokens")
/// and `docs/design/xmo-stage1/handoff/screens/_shell.css`. Values mirror the
/// CSS exactly; comments cite the corresponding CSS variable.
enum LoreTheme {

    /// Brand wordmark. Single constant — every screen must reference this
    /// instead of hardcoding the name.
    static let wordmark = "lore"

    // MARK: - Surfaces

    enum Surface {
        /// `--window` rgba(28,28,30,.72) — frosted app window (pair with `.ultraThinMaterial`/blur).
        static let window = rgb(28, 28, 30, 0.72)
        /// `--sidebar` rgba(255,255,255,.045)
        static let sidebar = rgb(255, 255, 255, 0.045)
        /// `--popover` rgba(58,58,60,.97) — menus / popovers.
        static let popover = rgb(58, 58, 60, 0.97)
        /// `--card` rgba(255,255,255,.03)
        static let card = rgb(255, 255, 255, 0.03)
        /// `--card-2` rgba(255,255,255,.04)
        static let card2 = rgb(255, 255, 255, 0.04)
        /// `--card-3` rgba(255,255,255,.06)
        static let card3 = rgb(255, 255, 255, 0.06)
        /// `--hover` rgba(255,255,255,.05)
        static let hover = rgb(255, 255, 255, 0.05)
        /// `--line` rgba(255,255,255,.10) — hairline dividers & 1px borders.
        static let line = rgb(255, 255, 255, 0.10)
        /// `--line2` rgba(255,255,255,.12) — stronger hairline: the Dictation
        /// Activity pane's stat-quadrant dividers (dictation-heatmap.html v4).
        static let line2 = rgb(255, 255, 255, 0.12)
        /// `--line3` rgba(255,255,255,.25) — strongest hairline: the Activity
        /// pane's period-row rule, above the stat quadrant (dictation-heatmap.html v4).
        static let line3 = rgb(255, 255, 255, 0.25)
    }

    // MARK: - Text

    enum TextColor {
        /// `--txt` rgba(255,255,255,.85) — primary.
        static let primary = rgb(255, 255, 255, 0.85)
        /// `--mut` rgba(255,255,255,.55) — muted / secondary.
        static let muted = rgb(255, 255, 255, 0.55)
        /// `--faint` #6c717d — placeholder.
        static let faint = rgb(108, 113, 125)
        /// Sidebar inactive item #7c818c.
        static let sidebarInactive = rgb(124, 129, 140)
    }

    // MARK: - Meaning colors (one meaning per color)

    /// Fixed dark-appearance macOS system color values on purpose — Lore surfaces
    /// never render light, so do NOT reintroduce semantic `.red`/`.green`/etc.
    /// alongside these.
    enum Accent {
        /// `--blue` #0A84FF — focus & progress: timers, "You", play/start, primary Send/Export.
        static let blue = rgb(10, 132, 255)
        /// `--green` #32D74B — done / on: checkboxes, toggles, online dot, success (✓ Copied).
        static let green = rgb(50, 215, 75)
        /// `--red` #FF453A — live recording + destructive only.
        static let red = rgb(255, 69, 58)
        /// `--amber` #FF9F0A — the assistant's own output only: ✦ marks, badges (Stage-2 task suggestions later).
        static let amber = rgb(255, 159, 10)
    }

    // MARK: - Radii

    enum Radius {
        /// `--r-window` 11px.
        static let window: CGFloat = 11
        /// Cards 7px (`--r-card`).
        static let card: CGFloat = 7
        /// Buttons 5px (`--r-btn`).
        static let button: CGFloat = 5
        /// Chips 6px (`--r-chip`, also value/key buttons).
        static let chip: CGFloat = 6
        /// Popover 8px (`--r-pop`).
        static let popover: CGFloat = 8
    }

    // MARK: - Type scale
    // Scale: 22 wordmark / 15 heading / 13 body & controls / 12.5 secondary /
    // 11–11.5 meta / 10–10.5 section labels (.08em tracking) / 9 popover labels.
    // Weights: 600 titles/controls, 500 inactive nav, 400 body.

    enum Typography {
        static let wordmark = Font.system(size: 22, weight: .semibold)
        /// Screen heading (meeting name, 15px/600).
        static let heading = Font.system(size: 15, weight: .semibold)
        /// Body text (13px/400).
        static let body = Font.system(size: 13)
        /// Titles & controls (13px/600): toolbar title, active nav, setting names.
        static let control = Font.system(size: 13, weight: .semibold)
        /// Inactive nav item (13px/500).
        static let navInactive = Font.system(size: 13, weight: .medium)
        /// Secondary text (12.5px/400): subtitles, popover item names.
        static let secondary = Font.system(size: 12.5)
        /// Meta text (11px/400): setting subtext, source lines.
        static let meta = Font.system(size: 11)

        /// SF Mono — numbers, timers, kbd hints, timestamps, kind chips.
        static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        /// Mono meta (11px): version string, timestamps, entry counts.
        static let monoMeta = mono(11)
        /// Mono control (12.5px/600): REC pill, value buttons.
        static let monoControl = mono(12.5, weight: .semibold)
    }

    // MARK: - Shadows
    // CSS box-shadow blur maps to SwiftUI `.shadow(radius:)` ≈ blur / 2.

    struct ShadowSpec {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    enum Shadow {
        /// Window: `0 40px 90px -24px rgba(0,0,0,.55)`.
        static let window = ShadowSpec(color: .black.opacity(0.55), radius: 45, x: 0, y: 40)
        /// Window rim ring: `0 0 0 .5px rgba(255,255,255,.14)` — apply as a 0.5pt overlay stroke.
        static let windowRim = rgb(255, 255, 255, 0.14)
        /// Popover: `0 18px 44px -10px rgba(0,0,0,.6)`.
        static let popover = ShadowSpec(color: .black.opacity(0.6), radius: 22, x: 0, y: 18)
        /// Active Stop button: `0 6px 18px rgba(255,69,58,.35)`.
        static let redGlow = ShadowSpec(color: Accent.red.opacity(0.35), radius: 9, x: 0, y: 6)
    }

    // MARK: - Motion

    enum Motion {
        /// `pulse` 1.3s — live dots.
        static let pulseDuration: Double = 1.3
        /// `wave` ~0.55–0.89s, staggered per bar — recording waveform bars.
        static let waveDurationMin: Double = 0.55
        static let waveDurationMax: Double = 0.89
        /// `blink` 1s step-end — interim transcription caret.
        static let blinkDuration: Double = 1.0
        /// Hover/press transitions: CSS 0.12–0.15s.
        static let hoverDuration: Double = 0.15
        /// `:active` scale ~0.96.
        static let pressScale: CGFloat = 0.96
        /// `:hover` brightness ~1.14 (CSS multiplier; SwiftUI `.brightness` is
        /// additive, so apply as `.brightness(hoverBrightness - 1)`).
        static let hoverBrightness: Double = 1.14
    }
}

// MARK: - Helpers

extension View {
    /// Apply a token shadow (e.g. `LoreTheme.Shadow.popover`).
    func loreShadow(_ spec: LoreTheme.ShadowSpec) -> some View {
        shadow(color: spec.color, radius: spec.radius, x: spec.x, y: spec.y)
    }
}

/// 0–255 RGB components as in the CSS source, to avoid transcription errors.
private func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
    Color(red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}
