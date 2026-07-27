import SwiftUI

/// XMO Stage 1 shared primitives (D-031: additive only, not yet wired into
/// existing views). Each component mirrors a treatment that appears in two or
/// more designed screens — see `docs/design/xmo-stage1/handoff/screens/`.

// MARK: - Toggle (Settings `.tgl`, 42×24 pill)

/// 42×24 pill: off `rgba(255,255,255,.12)` → on green; 18px white knob,
/// left 3px → 21px. Renders the pill only — row layout (name + sub + toggle)
/// belongs to the screen.
struct XMOToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(configuration.isOn ? XMOTheme.Accent.green : Color.white.opacity(0.12))
                    .frame(width: 42, height: 24)
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .offset(x: configuration.isOn ? 21 : 3)
            }
        }
        .buttonStyle(.plain)
        .animation(
            reduceMotion ? nil : .easeOut(duration: XMOTheme.Motion.hoverDuration),
            value: configuration.isOn
        )
    }
}

// MARK: - Grouped card (Settings `.scard`)

/// Inset grouped-card container: `--card` fill, 7px radius, 1px `--line` inset border.
/// Stack rows inside and separate them with `XMODivider`.
struct XMOCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(XMOTheme.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: XMOTheme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: XMOTheme.Radius.card)
                    .strokeBorder(XMOTheme.Surface.line, lineWidth: 1)
            )
    }
}

// MARK: - Section label (Settings `.slabel`, day headers, popover headers)

/// Uppercase muted section label. Sizes in the design: 11 (settings
/// sections), 10.5 (day headers, .09em tracking), 9 (popover headers, mono).
struct XMOSectionLabel: View {
    let text: String
    var size: CGFloat = 10.5
    var mono = false
    /// Letter-spacing in em — CSS `.slabel`/popover headers use .08em, the
    /// dictation day headers .09em.
    var trackingEm: CGFloat = 0.08

    var body: some View {
        Text(text.uppercased())
            .font(mono ? XMOTheme.Typography.mono(size, weight: .semibold)
                       : .system(size: size, weight: .semibold))
            .tracking(size * trackingEm)
            .foregroundStyle(XMOTheme.TextColor.muted)
    }
}

// MARK: - Mono value button (Settings `.valbtn` / `.keybtn`)

/// The "Fn (Globe)" style: mono 12.5/600 text, `rgba(255,255,255,.06)` fill,
/// 6px radius. Pass `width` for the fixed-width key variant (`.keybtn`, 64px,
/// mono 12/600, `.08` fill). A nil `action` renders the same chip statically
/// (non-interactive) — used for key chips that are not remappable yet.
struct XMOMonoValueButton: View {
    let title: String
    var width: CGFloat?
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(XMOPressButtonStyle())
        } else {
            label
        }
    }

    private var label: some View {
        Text(title)
            .font(width == nil ? XMOTheme.Typography.monoControl
                               : XMOTheme.Typography.mono(12, weight: .semibold))
            .foregroundStyle(XMOTheme.TextColor.primary)
            .padding(.vertical, 6)
            .padding(.horizontal, width == nil ? 12 : 0)
            .frame(width: width)
            .background(
                Color.white.opacity(width == nil ? 0.06 : 0.08),
                in: RoundedRectangle(cornerRadius: XMOTheme.Radius.chip)
            )
    }
}

// MARK: - Icon button (dictation `.ibtn` row actions, copy buttons)

/// 30×30 icon button, 5px radius, `rgba(255,255,255,.07)` fill. Hover-reveal
/// (opacity 0 → 1 on row hover) is the parent row's responsibility.
struct XMOIconButton: View {
    let systemName: String
    /// Accessibility label — required, icon-only buttons say nothing otherwise.
    let label: String
    var tint: Color = XMOTheme.TextColor.muted
    /// Fill override — default `rgba(255,255,255,.07)`; the dictation rows use
    /// amber `.16` while a popover is open and red `.12` for the retry button.
    var background: Color = Color.white.opacity(0.07)
    let action: () -> Void

    /// Explicit colors defeat SwiftUI's automatic dimming, so a disabled
    /// icon button looked identical to an enabled one — a click that "does
    /// nothing" (#61). Dim it visibly instead.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(
                    background,
                    in: RoundedRectangle(cornerRadius: XMOTheme.Radius.button)
                )
        }
        .buttonStyle(XMOPressButtonStyle())
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

// MARK: - Copy button (dictation rows, meetings detail header)

/// Copy icon button with green ✓ feedback for ~1.4s (design `.ibtn` + the
/// prototype's `copied` flash). A rapid re-copy restarts the full window.
struct XMOCopyButton: View {
    var label: String = "Copy"
    /// Performs the actual copy (pasteboard write).
    let copy: () -> Void

    @State private var copied = false
    @State private var flashID = 0

    var body: some View {
        XMOIconButton(
            systemName: copied ? "checkmark" : "doc.on.doc",
            label: label,
            tint: copied ? XMOTheme.Accent.green : XMOTheme.TextColor.muted
        ) {
            copy()
            copied = true
            flashID += 1
        }
        .task(id: flashID) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled {
                copied = false
            }
        }
        .help("Copy to clipboard")
    }
}

// MARK: - Selectable row (sidebar nav items, meeting list rows)

/// Row treatment shared by the shell sidebar and the meetings list rail:
/// 9×11 padding, 6px radius, active fill, hover fill when inactive.
struct XMOSelectableRow: ViewModifier {
    var isActive: Bool
    /// Design: nav items use white .08, meeting list rows white .06.
    var activeFill: Color = Color.white.opacity(0.08)

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 9)
            .padding(.horizontal, 11)
            .contentShape(RoundedRectangle(cornerRadius: XMOTheme.Radius.chip))
            .background(
                isActive ? activeFill : Color.clear,
                in: RoundedRectangle(cornerRadius: XMOTheme.Radius.chip)
            )
            .xmoHoverFill(cornerRadius: XMOTheme.Radius.chip, enabled: !isActive)
    }
}

extension View {
    func xmoSelectableRow(
        isActive: Bool,
        activeFill: Color = Color.white.opacity(0.08)
    ) -> some View {
        modifier(XMOSelectableRow(isActive: isActive, activeFill: activeFill))
    }
}

// MARK: - Press feedback (CSS `:active { scale: .96 }`)

/// Scales to 0.96 while pressed; shared by all XMO buttons. No press scale
/// under Reduce Motion.
struct XMOPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed && !reduceMotion
                    ? XMOTheme.Motion.pressScale : 1
            )
            .animation(.easeOut(duration: XMOTheme.Motion.hoverDuration), value: configuration.isPressed)
    }
}

// MARK: - Popover chrome (dictation `.pop`, transform menu)

extension View {
    /// Popover container: `--popover` bg, 8px radius, 1px `--line` border,
    /// popover shadow, 5px content inset.
    func xmoPopoverChrome() -> some View {
        padding(5)
            .background(
                XMOTheme.Surface.popover,
                in: RoundedRectangle(cornerRadius: XMOTheme.Radius.popover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: XMOTheme.Radius.popover)
                    .strokeBorder(XMOTheme.Surface.line, lineWidth: 1)
            )
            .xmoShadow(XMOTheme.Shadow.popover)
    }
}

// MARK: - Hairline divider (`.hairline`, `.srow` borders)

/// 1px `--line` divider.
struct XMODivider: View {
    var body: some View {
        XMOTheme.Surface.line.frame(height: 1)
    }
}

// MARK: - Hover fill (CSS `:hover { background: ... }`)

/// Hover-reveal background fill: token ease-out (0.15s), static under Reduce
/// Motion. `onHoverChange` lets a parent that also needs the hover state
/// (e.g. the dictation row's action reveal) share this single tracker.
struct XMOHoverFill: ViewModifier {
    var fill: Color = XMOTheme.Surface.hover
    var cornerRadius: CGFloat = 0
    var enabled: Bool = true
    var onHoverChange: ((Bool) -> Void)?

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                enabled && isHovering ? fill : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .onHover { hovering in
                isHovering = hovering
                onHoverChange?(hovering)
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: XMOTheme.Motion.hoverDuration),
                value: isHovering
            )
    }
}

extension View {
    func xmoHoverFill(
        _ fill: Color = XMOTheme.Surface.hover,
        cornerRadius: CGFloat = 0,
        enabled: Bool = true,
        onHoverChange: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(XMOHoverFill(
            fill: fill,
            cornerRadius: cornerRadius,
            enabled: enabled,
            onHoverChange: onHoverChange
        ))
    }
}

// MARK: - Picker popover (dictation `.pop` method/language pickers)

/// Generic picker popover: mono section header + item rows with hover fill
/// and a trailing amber ✓ on the active item. Consumers: dictation cleanup
/// method (224px) and translate language (180px).
struct XMOPickerPopover<Item: Identifiable, ItemLabel: View>: View {
    let header: String
    let items: [Item]
    let width: CGFloat
    let isActive: (Item) -> Bool
    let onSelect: (Item) -> Void
    @ViewBuilder let itemLabel: (Item) -> ItemLabel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            XMOSectionLabel(text: header, size: 9, mono: true)
                .padding(EdgeInsets(top: 6, leading: 9, bottom: 5, trailing: 9))
            ForEach(items) { item in
                Button {
                    onSelect(item)
                } label: {
                    HStack(spacing: 10) {
                        itemLabel(item)
                        Spacer(minLength: 0)
                        if isActive(item) {
                            Text("\u{2713}")
                                .font(.system(size: 12))
                                .foregroundStyle(XMOTheme.Accent.amber)
                        }
                    }
                    .padding(EdgeInsets(top: 8, leading: 9, bottom: 8, trailing: 9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .xmoHoverFill(cornerRadius: XMOTheme.Radius.chip)
            }
        }
        .frame(width: width)
        .xmoPopoverChrome()
    }
}

/// Default picker item label — plain title, 12.5/500, primary. Shared by
/// pickers whose rows have no subtitle or glyph (languages, models, devices).
struct XMOPickerItemLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(XMOTheme.TextColor.primary)
            .lineLimit(1)
    }
}

extension XMOPickerPopover where ItemLabel == XMOPickerItemLabel {
    /// Convenience for plain-text pickers: pass a title per item instead of a
    /// label view.
    init(
        header: String,
        items: [Item],
        width: CGFloat,
        isActive: @escaping (Item) -> Bool,
        onSelect: @escaping (Item) -> Void,
        title: @escaping (Item) -> String
    ) {
        self.init(
            header: header,
            items: items,
            width: width,
            isActive: isActive,
            onSelect: onSelect
        ) { item in
            XMOPickerItemLabel(title: title(item))
        }
    }
}

// MARK: - Screen header (meetings `.mhead`)

/// Meetings screen header: 15px/600 title over a 12.5px muted meta line,
/// trailing controls right-aligned. Shared by the review header (NotesView)
/// and the live header (ContentView). Meta gets the secondary/muted
/// treatment; inner fonts (e.g. a mono clock) still win.
/// The title slot is generic so the review header can swap in a rename
/// TextField (#61).
struct XMOScreenHeader<Title: View, Meta: View, Trailing: View>: View {
    @ViewBuilder let titleContent: Title
    @ViewBuilder let meta: Meta
    @ViewBuilder let trailing: Trailing

    init(
        @ViewBuilder titleContent: () -> Title,
        @ViewBuilder meta: () -> Meta,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.titleContent = titleContent()
        self.meta = meta()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                titleContent
                    .font(XMOTheme.Typography.heading)
                    .foregroundStyle(XMOTheme.TextColor.primary)
                    .lineLimit(1)
                meta
                    .font(XMOTheme.Typography.secondary)
                    .foregroundStyle(XMOTheme.TextColor.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.init(top: 14, leading: 26, bottom: 13, trailing: 26))
    }
}

// MARK: - Chat bubble (Ask XMO rail + review chat transcript)

/// One chat bubble, shared by the live Ask rail and the read-only review
/// chat (#60): user = blue .16 fill, right-aligned; assistant = white .05,
/// left-aligned. `inset` is the min spacer on the opposite side (the rail's
/// ~88% width cap uses 36; the wide review pane uses more).
struct XMOChatBubble: View {
    let text: String
    let isUser: Bool
    var inset: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: inset) }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(XMOTheme.TextColor.primary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.init(top: 9, leading: 12, bottom: 9, trailing: 12))
                .background(
                    isUser ? XMOTheme.Accent.blue.opacity(0.16) : Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            if !isUser { Spacer(minLength: inset) }
        }
    }
}

// MARK: - Start/Stop recording button (meetings `.startbtn`, MREC-01)

/// Idle: neutral white .07 fill, primary text, 9px red round dot. Recording:
/// red fill, white text, dot morphs to a 2px-radius square, red glow.
/// `compact` is the meetings-toolbar `.rec-btn` variant (#107 prototype):
/// card-3 fill with a 1px line border, 6px radius, 12.5/600 label, 8px dot.
struct XMOStartStopButton: View {
    var isRecording = false
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 7 : 8) {
                RoundedRectangle(cornerRadius: isRecording ? 2 : (compact ? 4 : 4.5))
                    .fill(isRecording ? Color.white : XMOTheme.Accent.red)
                    .frame(width: compact ? 8 : 9, height: compact ? 8 : 9)
                Text(isRecording ? "Stop recording" : "Start recording")
                    .font(compact ? .system(size: 12.5, weight: .semibold)
                                  : XMOTheme.Typography.control)
                    .foregroundStyle(isRecording ? Color.white : XMOTheme.TextColor.primary)
            }
            .padding(.vertical, compact ? 6 : 10)
            .padding(.horizontal, compact ? 12 : 16)
            .background(
                isRecording ? XMOTheme.Accent.red
                            : (compact ? XMOTheme.Surface.card3 : Color.white.opacity(0.07)),
                in: RoundedRectangle(cornerRadius: compact ? XMOTheme.Radius.chip
                                                           : XMOTheme.Radius.button)
            )
            .overlay(
                RoundedRectangle(cornerRadius: XMOTheme.Radius.chip)
                    .strokeBorder(compact && !isRecording ? XMOTheme.Surface.line : .clear, lineWidth: 1)
            )
            .shadow(
                color: isRecording ? XMOTheme.Shadow.redGlow.color : .clear,
                radius: XMOTheme.Shadow.redGlow.radius,
                x: XMOTheme.Shadow.redGlow.x,
                y: XMOTheme.Shadow.redGlow.y
            )
        }
        .buttonStyle(XMOPressButtonStyle())
    }
}

// MARK: - Transcript speaker row (meetings live + review, MREC-11/MREV-13)

/// 64px speaker-label column ("You" blue, diarized remotes keep the current
/// palette via `Speaker.xmoColor`) + free-form text content. The content slot
/// carries the per-screen divergence: live volatile caret, review
/// cleaning/original dimming.
struct XMOSpeakerRow<Content: View>: View {
    let speaker: Speaker
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(speaker.displayLabel)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(speaker.xmoColor)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 1)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Onboarding scaffold (Stage H — shared by OnboardingView,
// DictationOnboardingView, RecordingConsentView)

/// Step-progress dots: 6px circles, active blue, inactive white .25.
struct XMOStepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? XMOTheme.Accent.blue
                                       : Color.white.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// Onboarding footer: leading plain text button (Skip/Back/Cancel — hidden
/// when `leadingTitle` is nil) + trailing filled primary button. Prominent =
/// blue Next/Get-Started; non-prominent = the consent sheet's neutral white
/// fill, dimmed and disabled until `primaryEnabled`.
struct XMOOnboardingFooter: View {
    var leadingTitle: String?
    let leadingAction: () -> Void
    let primaryTitle: String
    var primaryEnabled = true
    var primaryProminent = true
    let primaryAction: () -> Void

    var body: some View {
        HStack {
            if let leadingTitle {
                Button(leadingTitle, action: leadingAction)
                    .buttonStyle(.plain)
                    .font(XMOTheme.Typography.secondary)
                    .foregroundStyle(XMOTheme.TextColor.muted)
            }

            Spacer()

            Button(action: primaryAction) {
                Text(primaryTitle)
                    .font(XMOTheme.Typography.control)
                    .foregroundStyle(
                        primaryProminent ? .white
                            : primaryEnabled ? XMOTheme.TextColor.primary
                                             : XMOTheme.TextColor.muted
                    )
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        primaryProminent ? XMOTheme.Accent.blue
                            : Color.white.opacity(primaryEnabled ? 0.12 : 0.05),
                        in: RoundedRectangle(cornerRadius: XMOTheme.Radius.button)
                    )
            }
            .buttonStyle(XMOPressButtonStyle())
            .disabled(!primaryEnabled)
        }
    }
}

extension XMOOnboardingFooter {
    /// Paged convenience: "Next" advancing until the last step, then
    /// "Get Started" finishing.
    init(
        leadingTitle: String?,
        leadingAction: @escaping () -> Void,
        step: Int,
        count: Int,
        advance: @escaping () -> Void,
        finish: @escaping () -> Void
    ) {
        let isLast = step >= count - 1
        self.init(
            leadingTitle: leadingTitle,
            leadingAction: leadingAction,
            primaryTitle: isLast ? "Get Started" : "Next",
            primaryAction: { isLast ? finish() : advance() }
        )
    }
}

/// Bullet row (• + muted 12px text) shared by the dictation onboarding
/// instructions and the recording-consent obligations.
struct XMOBulletRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\u{2022}")
                .font(XMOTheme.Typography.body)
                .foregroundStyle(XMOTheme.TextColor.muted)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(XMOTheme.TextColor.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Live waveform (recording banner, MREC-10; Stage H indicator)

/// 5 red bars. Bars oscillate at the design's wave timings (0.55–0.89s,
/// staggered 0.08s per bar) with their amplitude driven by the real audio
/// level passed by the host — `TranscriptionEngine.audioLevel` in the meeting
/// banner, `DictationCoordinator.audioLevel` (polled at 50ms) in the dictation
/// indicator — so silence shows near-flat bars and speech makes them swing
/// fully. Under Reduce Motion the wave oscillation is dropped but bar height
/// still maps directly to the current level (instant, unanimated) — the
/// live-level information stays.
struct XMOLiveWaveform: View {
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barCount = 5
    private static let staggerPerBar: Double = 0.08

    var body: some View {
        if reduceMotion {
            bars(scales: Array(
                repeating: CGFloat(0.35 + 0.65 * envelope),
                count: Self.barCount
            ))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                bars(scales: (0..<Self.barCount).map { scale(bar: $0, time: t) })
            }
        }
    }

    private func bars(scales: [CGFloat]) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(XMOTheme.Accent.red)
                    .frame(width: 3, height: 13)
                    .scaleEffect(y: scales[index], anchor: .center)
            }
        }
        .accessibilityHidden(true)
    }

    /// Level envelope compressing the bars toward the floor when quiet.
    private var envelope: Double {
        min(1, Double(level) * 2.5)
    }

    /// CSS `wave` scales 0.35 ↔ 1.0; the level envelope compresses that
    /// swing toward the floor when the room is quiet. Duration cycle per the
    /// prototype: `0.55 + (i % 3) * 0.17` → waveDurationMin…waveDurationMax.
    private func scale(bar index: Int, time: Double) -> CGFloat {
        let duration = XMOTheme.Motion.waveDurationMin + Double(index % 3) * 0.17
        let delay = Double(index) * Self.staggerPerBar
        let phase = sin(2 * .pi * (time - delay) / duration) * 0.5 + 0.5
        return CGFloat(0.35 + phase * 0.65 * envelope)
    }
}

// MARK: - Previews

#Preview("XMO components") {
    struct PreviewHost: View {
        @State private var on = true
        @State private var off = false

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                XMOSectionLabel(text: "General", size: 11)

                XMOCard {
                    HStack {
                        Text("Launch at login")
                            .font(XMOTheme.Typography.control)
                            .foregroundStyle(XMOTheme.TextColor.primary)
                        Spacer()
                        Toggle("", isOn: $on).toggleStyle(XMOToggleStyle()).labelsHidden()
                    }
                    .padding(.init(top: 13, leading: 16, bottom: 13, trailing: 16))
                    XMODivider()
                    HStack {
                        Text("Hotkey")
                            .font(XMOTheme.Typography.control)
                            .foregroundStyle(XMOTheme.TextColor.primary)
                        Spacer()
                        XMOMonoValueButton(title: "Fn (Globe)") {}
                    }
                    .padding(.init(top: 13, leading: 16, bottom: 13, trailing: 16))
                    XMODivider()
                    HStack {
                        XMOMonoValueButton(title: "Space", width: 64) {}
                        Text("Lock")
                            .font(XMOTheme.Typography.control)
                            .foregroundStyle(XMOTheme.TextColor.primary)
                        Spacer()
                        Toggle("", isOn: $off).toggleStyle(XMOToggleStyle()).labelsHidden()
                    }
                    .padding(.init(top: 13, leading: 16, bottom: 13, trailing: 16))
                }
                .frame(width: 420)

                HStack(spacing: 6) {
                    XMOIconButton(systemName: "doc.on.doc", label: "Copy") {}
                    XMOIconButton(systemName: "sparkles", label: "Clean up", tint: XMOTheme.Accent.amber) {}
                    XMOIconButton(systemName: "globe", label: "Translate", tint: XMOTheme.Accent.amber) {}
                }

                VStack(alignment: .leading, spacing: 2) {
                    XMOSectionLabel(text: "Cleanup method", size: 9, mono: true)
                        .padding(.init(top: 6, leading: 9, bottom: 5, trailing: 9))
                    Text("Standard")
                        .font(XMOTheme.Typography.secondary)
                        .foregroundStyle(XMOTheme.TextColor.primary)
                        .padding(.init(top: 8, leading: 9, bottom: 8, trailing: 9))
                }
                .frame(width: 214, alignment: .leading)
                .xmoPopoverChrome()
            }
            .padding(40)
            .background(XMOTheme.Surface.window)
            .background(Color(red: 0.12, green: 0.13, blue: 0.17))
        }
    }
    return PreviewHost()
}
