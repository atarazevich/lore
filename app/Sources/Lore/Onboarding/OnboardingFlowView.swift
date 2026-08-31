import AppKit
import SwiftUI

/// The first-run flow (#150). Design authority:
/// `docs/design/prototypes/lore-onboarding.pen` — 660 × 540, dark only,
/// LoreTheme tokens, no app chrome behind it.
///
/// The board's fonts are Inter / JetBrains Mono stand-ins for SF Pro / Menlo,
/// which is what `LoreTheme.Typography` already resolves to.
struct OnboardingFlowView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(28)
        .frame(width: OnboardingWindowController.size.width,
               height: OnboardingWindowController.size.height)
        .background(LoreTheme.Surface.window)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: model.step)
        .animation(.easeInOut(duration: 0.2), value: model.expandedGrant)
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcomeStep
        case .permissions: permissionsStep
        case .fnKey: fnKeyStep
        case .tryIt: tryItStep
        case .ready: readyStep
        }
    }

    /// 1 · Welcome — value before ask. One button, no skip.
    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: LoreMark.chip)
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            Spacer().frame(height: 22)
            Text("Welcome to \(LoreTheme.wordmark)")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
            Spacer().frame(height: 10)
            Text("Speak anywhere text goes \u{2014} hold a key, talk, release.")
                .font(.system(size: 14))
                .foregroundStyle(LoreTheme.TextColor.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// 2 · Permissions — revealed in sequence. Grant one, the next expands;
    /// there is no Next to click.
    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeading(
                "Set up \(LoreTheme.wordmark)'s access",
                "Grant each one. \(LoreTheme.wordmark) reacts the moment you do \u{2014} there is no Next to click."
            )
            Spacer().frame(height: 20)
            VStack(spacing: 10) {
                ForEach(RequiredGrant.allCases) { grant in
                    PermissionCard(
                        grant: grant,
                        granted: model.permissions[grant],
                        expanded: model.expandedGrant == grant,
                        revealed: model.permissions.isRevealed(grant),
                        action: { model.requestGrant(grant) }
                    )
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 3 · Fn key — a permission-shaped system setting. Rendered only while it
    /// conflicts; the setting itself is the only exit, so there is no Continue.
    private var fnKeyStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeading(
                "One system setting is in the way",
                "macOS keeps the Fn key for its own features, so \(LoreTheme.wordmark) never sees your hold."
            )
            Spacer()
            FnKeyCard(
                action: model.fnAction,
                onOpenSettings: { model.openPane(.keyboard) }
            )
            Spacer()
        }
    }

    /// 4 · Try it — the guided first dictation, which doubles as the end-to-end
    /// verification of all three grants at once.
    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.tryIt == .tapDead {
                stepHeading("Nothing arrived",
                            "You held Fn, but no keystroke reached \(LoreTheme.wordmark).")
                Spacer()
                TapRecoveryCard(onRelaunch: { model.relaunchForDeadTap() })
                Spacer()
            } else if model.tryIt == .landed {
                stepHeading("That is the whole thing",
                            "Your words went in at the cursor. It works the same in Slack, Mail, or a terminal.")
                Spacer()
                tryItField
                Spacer()
            } else {
                stepHeading(
                    "Hold Fn and say anything",
                    model.tryIt == .recording
                        ? "Keep holding. Release Fn when you are done."
                        : "It types into the box below \u{2014} exactly the way it will type anywhere else."
                )
                // Something concrete to say, so the first hold is not a blank
                // page. It stays up through the hold — it is what the user is
                // reading aloud — and the sentence describes what it does the
                // moment it lands in the field. Never a requirement: success is
                // measured against what the pipeline pasted, not against this.
                Text("Try: \u{201C}My words land right where my cursor is.\u{201D}")
                    .font(LoreTheme.Typography.secondary)
                    .foregroundStyle(LoreTheme.TextColor.faint)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                tryItField
                Spacer()
            }
        }
    }

    private var tryItField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Try it here")
                    .font(LoreTheme.Typography.meta)
                    .foregroundStyle(LoreTheme.TextColor.faint)
                Spacer()
                if model.tryIt == .recording {
                    // Red is the recording domain and nothing else; the timer and
                    // the dot are the only two things wearing it here.
                    Text(model.recordingClock)
                        .font(LoreTheme.Typography.mono(11, weight: .semibold))
                        .foregroundStyle(LoreTheme.Accent.red)
                        .monospacedDigit()
                }
            }

            TryItTextField(text: $model.typedText)
                .frame(height: 92)
                .tryItFieldChrome(isRecording: model.tryIt == .recording)

            HStack {
                Spacer()
                switch model.tryIt {
                case .recording:
                    HStack(spacing: 10) {
                        LorePulsingDot(size: 7)
                        LoreLiveWaveform(level: model.audioLevel)
                            .frame(height: 16)
                        Text("Listening")
                            .font(LoreTheme.Typography.secondary)
                            .foregroundStyle(LoreTheme.TextColor.primary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(LoreTheme.Accent.red.opacity(0.12),
                                in: Capsule())
                case .landed:
                    HStack(spacing: 10) {
                        GrantedChip(title: "Pasted")
                        HStack(spacing: 6) {
                            Image(systemName: "shield")
                                .font(.system(size: 11))
                            Text("Microphone, key listener and text insertion all confirmed.")
                                .font(LoreTheme.Typography.meta)
                        }
                        .foregroundStyle(LoreTheme.TextColor.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .idle, .tapDead:
                    HStack(spacing: 10) {
                        keycap("fn")
                        Text("hold to talk")
                            .font(LoreTheme.Typography.secondary)
                            .foregroundStyle(LoreTheme.TextColor.muted)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .background(LoreTheme.Surface.card2, in: Capsule())
                }
                Spacer()
            }
        }
    }

    /// 5 · Ready — ends on a real success. No dots, no summary of what was
    /// granted; the cheat sheet is the only thing left to learn.
    private var readyStep: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle()
                    .fill(LoreTheme.Accent.green.opacity(0.18))
                    .frame(width: 54, height: 54)
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(LoreTheme.Accent.green)
            }
            Spacer().frame(height: 18)
            Text("You're ready")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
            Spacer().frame(height: 8)
            Text("\(LoreTheme.wordmark) waits in the menu bar. Hold Fn wherever you type.")
                .font(.system(size: 13))
                .foregroundStyle(LoreTheme.TextColor.muted)
            Spacer().frame(height: 18)
            cheatSheet
            Spacer().frame(height: 16)
            consentLine
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var cheatSheet: some View {
        VStack(alignment: .leading, spacing: 9) {
            cheatRow("fn", "hold to talk")
            cheatRow("Space", "lock it on, hands free")
            cheatRow("V", "clean up what you just said")
            cheatRow("T", "translate what you just said")
            cheatRow("\u{2303}\u{2318}V", "paste that take again")
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .background(LoreTheme.Surface.card2,
                    in: RoundedRectangle(cornerRadius: LoreTheme.Radius.card))
    }

    private func cheatRow(_ key: String, _ meaning: String) -> some View {
        HStack(spacing: 12) {
            keycap(key, minWidth: 44)
            Text(meaning)
                .font(LoreTheme.Typography.secondary)
                .foregroundStyle(LoreTheme.TextColor.muted)
            Spacer(minLength: 0)
        }
    }

    /// The obligations the retired consent sheet carried, at the one moment the
    /// user is committing to use the app. Ticking it is what completes setup —
    /// the old flow set the same flag without ever showing the text.
    private var consentLine: some View {
        Toggle(isOn: $model.acceptedRecordingObligations) {
            Text("Recording a conversation is on you: many places require everyone's consent first, and \(LoreTheme.wordmark) leaves that (and the law) in your hands.")
                .font(LoreTheme.Typography.meta)
                .foregroundStyle(LoreTheme.TextColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: 470)
    }

    // MARK: - Chrome

    private func stepHeading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(LoreTheme.TextColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            // Both appear on exactly the three middle steps, so neither can move
            // under the other as the flow advances.
            if model.canGoBack {
                backButton
            }
            if let dot = model.dotIndex {
                OnboardingDots(current: dot)
            }
            Spacer(minLength: 0)
            trailingFooter
        }
        .frame(height: 34)
        .padding(.top, 14)
    }

    /// The one user-driven way backwards. No chrome and no accent: it is an
    /// escape hatch, and it must never compete with the step's own action.
    private var backButton: some View {
        Button { model.back() } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Back")
                    .font(LoreTheme.Typography.secondary)
            }
            .foregroundStyle(LoreTheme.TextColor.muted)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trailingFooter: some View {
        switch model.step {
        case .welcome:
            VStack(spacing: 10) {
                LorePrimaryButton(title: "Continue") { model.advanceFromButton() }
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10))
                    Text("Transcription happens on this Mac. Your voice never leaves it.")
                        .font(LoreTheme.Typography.meta)
                }
                .foregroundStyle(LoreTheme.TextColor.faint)
            }
            .frame(maxWidth: .infinity)

        case .permissions:
            HStack(spacing: 14) {
                if model.permissions.allGranted {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11))
                        Text("All three granted")
                            .font(LoreTheme.Typography.meta)
                    }
                    .foregroundStyle(LoreTheme.Accent.green)
                }
                LorePrimaryButton(title: "Continue", enabled: model.permissions.allGranted) {
                    model.advanceFromButton()
                }
            }

        case .fnKey:
            // No Continue: the setting itself is the only exit, so nothing here
            // can be clicked past.
            HStack(spacing: 7) {
                Circle()
                    .fill(model.fnAction.conflictsWithHotkey
                          ? LoreTheme.TextColor.faint : LoreTheme.Accent.green)
                    .frame(width: 6, height: 6)
                Text(model.fnAction.conflictsWithHotkey
                     ? "Watching this setting. \(LoreTheme.wordmark) continues by itself."
                     : "Detected \u{2014} continuing\u{2026}")
                    .font(LoreTheme.Typography.meta)
                    .foregroundStyle(model.fnAction.conflictsWithHotkey
                                     ? LoreTheme.TextColor.muted : LoreTheme.Accent.green)
            }

        case .tryIt:
            HStack(spacing: 18) {
                Button("Skip this") { model.skipTryIt() }
                    .buttonStyle(.plain)
                    .font(LoreTheme.Typography.secondary)
                    .foregroundStyle(LoreTheme.TextColor.muted)
                if model.tryIt != .tapDead {
                    LorePrimaryButton(title: "Continue", enabled: model.tryIt == .landed) {
                        model.advanceFromButton()
                    }
                }
            }

        case .ready:
            LorePrimaryButton(
                title: "Start using \(LoreTheme.wordmark)",
                enabled: model.acceptedRecordingObligations
            ) {
                model.advanceFromButton()
            }
        }
    }

    /// The keycap chrome the Try-it hint and the Ready cheat sheet share.
    private func keycap(_ text: String, minWidth: CGFloat? = nil) -> some View {
        Text(text)
            .font(LoreTheme.Typography.mono(11, weight: .semibold))
            .foregroundStyle(LoreTheme.TextColor.primary)
            .padding(.vertical, 3)
            .padding(.horizontal, minWidth == nil ? 8 : 7)
            .frame(minWidth: minWidth, alignment: .center)
            .background(LoreTheme.Surface.card3,
                        in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button))
    }
}

/// The "• promise" row under "lore needs this to:", on the permission cards and
/// on the Fn card.
private func onboardingBullet(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
        Text("\u{2022}")
            .foregroundStyle(LoreTheme.TextColor.faint)
        Text(text)
            .foregroundStyle(LoreTheme.TextColor.primary)
    }
    .font(LoreTheme.Typography.secondary)
}

// MARK: - Step dots

/// The board's four: Permissions, Fn, Try it, Ready — never a number, never
/// "step N of M". The current one is a short bar, and the ones behind it stay
/// brighter than the ones ahead, so a step passed in zero time still reads as
/// passed.
private struct OnboardingDots: View {
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<OnboardingModel.Step.dotted.count, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(
                        index == current ? 0.75 : index < current ? 0.4 : 0.18
                    ))
                    .frame(width: index == current ? 16 : 5, height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Permission card

/// Board card anatomy: icon tile, name, "lore needs this to:" + two concrete
/// bullets, one button, live status. Granted turns the tile and the chip green
/// and the button drops out of hit-testing in place.
private struct PermissionCard: View {
    let grant: RequiredGrant
    let granted: Bool
    let expanded: Bool
    let revealed: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded || granted {
                Spacer().frame(height: 12)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(LoreTheme.wordmark) needs this to:")
                        .font(LoreTheme.Typography.meta)
                        .foregroundStyle(LoreTheme.TextColor.faint)
                    ForEach(grant.reasons, id: \.self) { reason in
                        onboardingBullet(reason)
                    }
                }
                if expanded, !granted, let caption = grant.caption {
                    Spacer().frame(height: 12)
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                        Text(caption)
                            .font(LoreTheme.Typography.meta)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LoreTheme.Surface.card2,
                                in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            granted ? LoreTheme.Accent.green.opacity(0.06) : LoreTheme.Surface.card2,
            in: RoundedRectangle(cornerRadius: LoreTheme.Radius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LoreTheme.Radius.card)
                .strokeBorder(
                    granted ? LoreTheme.Accent.green.opacity(0.28) : LoreTheme.Surface.line,
                    lineWidth: 1
                )
        )
        // Unreached cards are collapsed stubs at half opacity: scope is visible,
        // complexity is not.
        .opacity(revealed ? 1 : 0.5)
        .allowsHitTesting(revealed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(grant.title): \(granted ? "granted" : "not granted")")
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                    .fill(granted ? LoreTheme.Accent.green.opacity(0.16)
                                  : LoreTheme.Surface.card3)
                    .frame(width: 28, height: 28)
                Image(systemName: granted ? "checkmark" : grant.icon)
                    .font(.system(size: 13, weight: granted ? .semibold : .regular))
                    .foregroundStyle(granted ? LoreTheme.Accent.green
                                             : LoreTheme.TextColor.muted)
            }
            Text(grant.title)
                .font(LoreTheme.Typography.control)
                .foregroundStyle(revealed ? LoreTheme.TextColor.primary
                                          : LoreTheme.TextColor.muted)
            Spacer(minLength: 0)
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if granted {
            GrantedChip(title: "Granted")
        } else if expanded {
            // The microphone's label stays "Allow" whichever tier it fires; the
            // caption underneath is what tells the truth.
            LorePrimaryButton(
                title: grant == .microphone ? "Allow" : "Open Settings",
                size: .compact,
                action: action
            )
        } else {
            Image(systemName: "lock")
                .font(.system(size: 11))
                .foregroundStyle(LoreTheme.TextColor.faint)
        }
    }
}

/// The green "✓ Granted" / "✓ Pasted" chip. Its own chrome rather than
/// `loreChipChrome`, which draws the neutral `Surface.line` border.
private struct GrantedChip: View {
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(LoreTheme.Accent.green)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(LoreTheme.Accent.green.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button))
        .overlay(
            RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                .strokeBorder(LoreTheme.Accent.green.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Fn key card

private struct FnKeyCard: View {
    let action: FnKeyAction
    let onOpenSettings: () -> Void

    private var resolved: Bool { !action.conflictsWithHotkey }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                        .fill(resolved ? LoreTheme.Accent.green.opacity(0.16)
                                       : LoreTheme.Surface.card3)
                        .frame(width: 28, height: 28)
                    Image(systemName: resolved ? "checkmark" : "slider.horizontal.3")
                        .font(.system(size: 13, weight: resolved ? .semibold : .regular))
                        .foregroundStyle(resolved ? LoreTheme.Accent.green
                                                  : LoreTheme.TextColor.muted)
                }
                Text("Fn key behavior")
                    .font(LoreTheme.Typography.control)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                Spacer(minLength: 0)
                if resolved {
                    GrantedChip(title: "Set to Do Nothing")
                } else {
                    LorePrimaryButton(
                        title: SettingsPane.keyboard.buttonLabel,
                        size: .compact,
                        action: onOpenSettings
                    )
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Change this so \(LoreTheme.wordmark) can:")
                    .font(LoreTheme.Typography.meta)
                    .foregroundStyle(LoreTheme.TextColor.faint)
                onboardingBullet("Start recording the instant you press Fn.")
                onboardingBullet("Stop macOS from opening Dictation or the emoji picker instead.")
            }

            pathChip
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            resolved ? LoreTheme.Accent.green.opacity(0.06) : LoreTheme.Surface.card2,
            in: RoundedRectangle(cornerRadius: LoreTheme.Radius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LoreTheme.Radius.card)
                .strokeBorder(
                    resolved ? LoreTheme.Accent.green.opacity(0.28) : LoreTheme.Surface.line,
                    lineWidth: 1
                )
        )
    }

    /// The breadcrumb the user is about to walk, plus the live readout of what
    /// lore currently sees — a reading, never a stored verdict.
    private var pathChip: some View {
        HStack(spacing: 8) {
            crumb("Keyboard")
            chevron
            crumb("Press \u{1F310} fn key to")
            chevron
            Text("Do Nothing")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(resolved ? LoreTheme.Accent.green : LoreTheme.TextColor.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    resolved ? LoreTheme.Accent.green.opacity(0.16) : Color.white.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                )
            Spacer(minLength: 12)
            Text("\(LoreTheme.wordmark) sees: \(action.label)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(resolved ? LoreTheme.Accent.green : LoreTheme.Accent.amber)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(LoreTheme.Surface.card, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button))
    }

    private func crumb(_ text: String) -> some View {
        Text(text)
            .font(LoreTheme.Typography.secondary)
            .foregroundStyle(LoreTheme.TextColor.muted)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9))
            .foregroundStyle(LoreTheme.TextColor.faint)
    }
}

// MARK: - Recovery card

/// The only recovery affordance in the flow, and the only place a relaunch is
/// ever named. Amber, because red is reserved for recording.
private struct TapRecoveryCard: View {
    let onRelaunch: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                    .fill(LoreTheme.Accent.amber.opacity(0.16))
                    .frame(width: 28, height: 28)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(LoreTheme.Accent.amber)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text("The key listener didn't wake up")
                        .font(LoreTheme.Typography.control)
                        .foregroundStyle(LoreTheme.TextColor.primary)
                    Spacer(minLength: 12)
                    LorePrimaryButton(
                        title: "Relaunch \(LoreTheme.wordmark)",
                        size: .compact,
                        action: onRelaunch
                    )
                }
                Text("\(LoreTheme.wordmark) holds every permission it asked for, but its event tap is not receiving keys. Relaunching rebuilds the tap. Nothing you granted is lost and nothing is asked for twice.")
                    .font(LoreTheme.Typography.secondary)
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoreTheme.Accent.amber.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: LoreTheme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: LoreTheme.Radius.card)
                .strokeBorder(LoreTheme.Accent.amber.opacity(0.45), lineWidth: 1)
        )
    }
}

// MARK: - Try-it field

/// A real, focused text field — not a picture of one. It has to be first
/// responder for `TextInserter`'s synthetic ⌘V to land in it, which is exactly
/// the thing this step verifies.
private struct TryItTextField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.delegate = context.coordinator
        view.isEditable = true
        view.isRichText = false
        view.drawsBackground = true
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 13)
        view.textColor = .white
        view.insertionPointColor = NSColor(LoreTheme.Accent.blue)
        view.textContainerInset = NSSize(width: 10, height: 10)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.string != text { view.string = text }
        // Keep it first responder across step re-renders: losing focus would
        // send the paste somewhere else and the step would never verify.
        if view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

/// Field chrome — a blue ring while recording, a hairline otherwise.
private extension View {
    func tryItFieldChrome(isRecording: Bool) -> some View {
        background(LoreTheme.Surface.card, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: LoreTheme.Radius.card)
                    .strokeBorder(
                        isRecording ? LoreTheme.Accent.blue : LoreTheme.Surface.line,
                        lineWidth: isRecording ? 2 : 1
                    )
            )
    }
}
