import AppKit
import DynamicNotchKit
import os
import SwiftUI

private let healthNotchLog = Logger(subsystem: "com.lore.app", category: "HealthNotch")

/// Raises the notch to summon the user when a user action just failed (#140,
/// design §6) — "Recording failed — microphone access is off / Fix it" — rather
/// than waiting for the panel to be found. A deliberately simpler surface than the meeting prompt
/// (`NotchPromptPresenter`): a single alert with one action and an auto-timeout,
/// always expanded (no compact/hover island), so it does not reuse that
/// presenter's meeting-shaped content and callbacks.
@MainActor
final class HealthNotchPresenter {
    /// Fired when the user clicks "Fix it" — opens the health panel.
    var onFix: (() -> Void)?

    private let timeout: Duration
    /// One `DynamicNotch` for the presenter's whole life — the full #141
    /// rationale for both notch surfaces (`DynamicNotchPromptWindow` points
    /// here): the library's init spawns an unstructured Task iterating
    /// screen-parameter notifications forever with a strong `self` capture, so
    /// no DynamicNotch ever deallocates. Per-present construction therefore
    /// accumulated an instance per summon, each rebuilding a ghost panel
    /// (`initializeWindow` + `orderFrontRegardless`) on every display change.
    /// Created lazily on the first summon; per-summon content flows through
    /// `model` instead. Accepted residual: the observer re-creates and fronts
    /// the one panel on display changes even while hidden — a steady count of
    /// one per surface (#141's criterion), not growth.
    private var notch: DynamicNotch<HealthNotchView, EmptyView, EmptyView>?
    private let model = HealthNotchModel()
    private var timeoutTask: Task<Void, Never>?
    /// Serializes expand/hide — see `NotchOpQueue` for the stranded
    /// continuation this prevents.
    private let windowOps = NotchOpQueue()
    /// Screen-parameter rebuild handling — live re-apply vs ghost order-out —
    /// lives in the shared `NotchScreenChangeSweeper`.
    private var screenChangeSweeper: NotchScreenChangeSweeper?

    /// The summon on screen, or `nil`. Also the re-summon guard: one notch at a
    /// time, first come first served — **except** that a failed user action
    /// displaces the launch migration notice (#135), which is advice, holds the
    /// notch for its full timeout, and goes up at exactly the moment failures
    /// caused by the stale grants start happening (the user has just been told
    /// to remove Lore from both permission panes).
    private(set) var onScreen: HealthSummon?

    /// The trigger whose copy `model` is currently holding — which outlives
    /// `onScreen` by the length of one hide animation, and is the whole reason a
    /// ghost can render something (#149). Internal so tests can see what a
    /// rebuild would have shown.
    private(set) var latchedTrigger: DiagEvent.SummonTrigger?

    init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    func present(_ summon: HealthSummon) {
        if let onScreen {
            guard summon.isCritical, !onScreen.isCritical else { return }
            // Displacement takes the migration notice down: record its exit so
            // every fired summon has a matching withdrawal in events.json (#144).
            DiagStore.record(.healthSummonWithdrawn(trigger: onScreen.trigger, reason: .displaced))
        }
        let alreadyUp = onScreen != nil
        onScreen = summon
        // Content is derived here and only here, every time — never carried over
        // from the last summon (#149).
        latchedTrigger = summon.trigger
        model.title = summon.title
        // The summon's observable trace (#140): before these, events.json held
        // no record that a summon ever fired, so history was unrecoverable.
        DiagStore.record(.healthSummonFired(trigger: summon.trigger))

        timeoutTask?.cancel()
        let notch = ensureNotch()
        // Displacement is a pure content swap: the notch is already expanded,
        // so only a hidden notch needs the raise.
        if !alreadyUp {
            windowOps.enqueue { [weak self] in
                await notch.expand()
                // Dismissed mid-animation: don't re-front a panel the library
                // is about to close.
                guard self?.onScreen != nil else { return }
                notch.windowController?.window?.applyFullscreenAuxiliaryVisibility()
            }
        }
        healthNotchLog.debug("health notch summoned: \(summon.trigger.rawValue, privacy: .public)")

        timeoutTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.dismiss(reason: .timedOut)
        }
    }

    private func fix() {
        dismiss()
        onFix?()
    }

    func dismiss(reason: DiagEvent.SummonWithdrawal = .dismissed) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let summon = onScreen else { return }
        onScreen = nil
        DiagStore.record(.healthSummonWithdrawn(trigger: summon.trigger, reason: reason))
        guard let notch else { return }
        // The reference is deliberately kept (see `notch`): `hide()` closes the
        // library's panel only at the end of its animation, so the presenter
        // must not forget the window before that completes.
        windowOps.enqueue { [weak self] in
            await notch.hide()
            // Un-latch the content once the closing animation is done (#144): a
            // later screen-parameter rebuild must have nothing to re-show.
            // Skipped when a new summon was presented behind this hide.
            if self?.onScreen == nil { self?.dropLatchedContent() }
        }
    }

    /// Self-clear (#144, #149): the condition behind the summon on screen just
    /// cleared, so its claim is stale and it withdraws itself. Only the matching
    /// summon goes — every other one reports its own condition, not this one.
    /// Driven by facts: the signing ledger's acknowledge for `.identityMigration`,
    /// and the recovery half of `HealthMonitor.summonSignal` for the rest.
    func clearSummon(trigger: DiagEvent.SummonTrigger) {
        guard onScreen?.trigger == trigger else { return }
        dismiss(reason: .recovered)
    }

    /// Forget what a rebuild could re-show. Cheap and idempotent — the sweeper
    /// calls it twice per screen-parameter notification.
    private func dropLatchedContent() {
        latchedTrigger = nil
        model.title = ""
    }

    /// The library re-fronted a panel nobody presented (#149). The window is
    /// ordered out by the sweeper; this drops the content first, so a rebuild
    /// landing after the sweep has nothing to render either — and leaves the
    /// trace that made this diagnosable at all (no-false-positives §5), since a
    /// ghost otherwise shows a summon with no `healthSummonFired` behind it.
    private func sweepGhostContent() {
        guard let trigger = latchedTrigger else { return }
        DiagStore.record(.healthSummonWithdrawn(trigger: trigger, reason: .sweptGhost))
        healthNotchLog.error(
            "swept a ghost health notch: \(trigger.rawValue, privacy: .public) had no live summon"
        )
        dropLatchedContent()
    }

    private func ensureNotch() -> DynamicNotch<HealthNotchView, EmptyView, EmptyView> {
        if let notch { return notch }
        let notch = DynamicNotch(hoverBehavior: [.increaseShadow]) { [model] in
            HealthNotchView(model: model) { [weak self] in
                self?.fix()
            } onClose: { [weak self] in
                self?.dismiss()
            }
        } compactLeading: {
            EmptyView()
        } compactTrailing: {
            EmptyView()
        }
        notch.transitionConfiguration = .init(skipIntermediateHides: true)
        self.notch = notch
        screenChangeSweeper = NotchScreenChangeSweeper(
            isLive: { [weak self] in self?.onScreen != nil },
            window: { [weak self] in self?.notch?.windowController?.window },
            onGhost: { [weak self] in self?.sweepGhostContent() }
        )
        return notch
    }
}

/// The reusable notch's one mutable input (#141): DynamicNotchKit captures its
/// content view once at init, so per-summon content has to flow through an
/// observed model rather than a freshly built view.
@MainActor
final class HealthNotchModel: ObservableObject {
    @Published var title = ""
}

/// The expanded alert content. Dark by design — notch content is always dark.
struct HealthNotchView: View {
    @ObservedObject var model: HealthNotchModel
    let onFix: () -> Void
    let onClose: () -> Void

    var body: some View {
        // A cleared model renders nothing (#144): the library's screen-change
        // rebuild re-fronts its panel even while hidden, and that ghost must
        // carry no summon.
        if !model.title.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LoreTheme.Accent.red)
                Text(model.title)
                    .font(LoreTheme.Typography.control)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                Button("Fix it", action: onFix)
                    .buttonStyle(HealthNotchButtonStyle())
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(LoreTheme.TextColor.muted)
                        .padding(5)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .fixedSize()
        }
    }
}

private struct HealthNotchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LoreTheme.Typography.secondary)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(LoreTheme.Accent.blue, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
