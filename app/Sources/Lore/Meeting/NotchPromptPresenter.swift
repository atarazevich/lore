import AppKit
import Combine
import DynamicNotchKit
import os
import SwiftUI

private let notchLog = Logger(subsystem: "com.lore.app", category: "NotchPrompt")

/// Notch-anchored Dynamic-Island-style prompt for meeting detection (#79).
///
/// The sole delivery surface for the detection prompt (#80): Notification
/// Center was removed because it cannot deliver on dev-signed builds (the
/// authorization request fails without a provisioning profile). The prompt
/// renders as a DynamicNotchKit window under the hardware notch instead.

// MARK: - Prompt content

/// Content and button actions for one detection prompt window.
struct NotchPromptContent {
    /// Detected meeting app name; nil when detection came from audio activity alone.
    let appName: String?
    let onAccept: () -> Void
    let onNotAMeeting: () -> Void
    let onIgnoreApp: () -> Void
}

// MARK: - Window seam

/// Minimal seam between the presenter's timer/callback logic and the
/// DynamicNotchKit window, so the presenter is testable without a display.
/// One long-lived window per presenter (#141): `present(content:)` replaces
/// whatever is showing, `dismiss()` takes the panel down.
@MainActor
protocol NotchPromptWindow: AnyObject {
    func present(content: NotchPromptContent) async
    func dismiss() async
}

// MARK: - Presenter

/// Presents the meeting-detection prompt in the notch and owns its lifecycle:
/// 60-second auto-timeout, replace-on-re-present, once-only resolution.
/// Callbacks: onAccept / onNotAMeeting / onIgnoreApp / onTimeout, plus
/// `cancelPending()` to withdraw without firing.
@MainActor
final class NotchPromptPresenter {
    /// Called when the user clicks "Start transcribing".
    var onAccept: (() -> Void)?

    /// Called when the user clicks "Not a meeting".
    var onNotAMeeting: (() -> Void)?

    // Note: no onDismiss — DynamicNotchKit has no user-driven dismiss
    // affordance (no swipe-away, no close button; hover-away merely collapses
    // to compact). Add it back when the library grows one.

    /// Called when the user clicks "Ignore this app".
    var onIgnoreApp: (() -> Void)?

    /// Called when the prompt times out (60 seconds, no user action).
    var onTimeout: (() -> Void)?

    /// The master switch's live reading (#227), checked at the door of every
    /// `present()`. Defense in depth: today unreachable — `AppContainer`
    /// tears the whole detection pipeline down with the switch, so nothing
    /// calls `present()` while this would answer false — but a guard at a
    /// trust boundary is cheap. No default: a caller that forgets to wire
    /// this should not compile into "always enabled" by accident: better to
    /// see it fail than to trust a silent permissive default.
    var isMeetingsEnabled: () -> Bool

    private let timeout: Duration
    /// The one long-lived window (#141); tests substitute a fake. Defaults to
    /// the app-lifetime shared instance (#227) — see `DynamicNotchPromptWindow.shared`.
    private let window: NotchPromptWindow
    private var timeoutTask: Task<Void, Never>?
    /// True while a prompt is on screen and unresolved.
    private var promptLive = false
    /// Serializes present/dismiss — see `NotchOpQueue` for the stranded
    /// continuation this prevents.
    private let windowOps = NotchOpQueue()

    /// Identifies the live prompt: bumped on every present() so actions from
    /// a replaced prompt (still rendered mid content swap) can't resolve the
    /// new one.
    private var generation = 0

    /// - Parameters:
    ///   - timeout: auto-dismiss interval; injectable for tests.
    ///   - window: the surface's one window; tests substitute a stub.
    ///   - isMeetingsEnabled: required, no default — see the property's own
    ///     comment. Production wires the live settings read here; the test
    ///     factory below is where the permissive `{ true }` lives now.
    init(
        timeout: Duration = .seconds(60),
        window: NotchPromptWindow = DynamicNotchPromptWindow.shared,
        isMeetingsEnabled: @escaping () -> Bool
    ) {
        self.timeout = timeout
        self.window = window
        self.isMeetingsEnabled = isMeetingsEnabled
    }

    /// Present the detection prompt. A pending prompt is replaced in place —
    /// its timeout dies and its buttons go stale, but the panel is not taken
    /// down: the new content swaps in through the window's model, so at most
    /// one prompt is live and the notch never dips mid-replace.
    ///
    /// Refuses at the door while meetings is off (#227) — traced, since a
    /// refusal that never happens today should still be visible in the ring
    /// the day something upstream lets it through. Returns whether it
    /// actually proceeded: `MeetingDetectionController.handleMeetingDetected`
    /// records its own `.shown` disposition only when this says true, so the
    /// two traces can never contradict each other for the same moment.
    @discardableResult
    func present(appName: String?) -> Bool {
        guard isMeetingsEnabled() else {
            DiagStore.record(.promptWindow(.presentRefusedMeetingsOff))
            notchLog.debug("notch prompt refused — meetings are off")
            return false
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        generation += 1
        let gen = generation

        let content = NotchPromptContent(
            appName: appName,
            onAccept: { [weak self] in self?.resolve(gen, "accept", firing: self?.onAccept) },
            onNotAMeeting: { [weak self] in self?.resolve(gen, "not a meeting", firing: self?.onNotAMeeting) },
            onIgnoreApp: { [weak self] in self?.resolve(gen, "ignore this app", firing: self?.onIgnoreApp) }
        )
        promptLive = true
        windowOps.enqueue { [window] in await window.present(content: content) }
        notchLog.debug("notch prompt shown (\(appName ?? "unknown app", privacy: .private))")

        timeoutTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            notchLog.debug("notch prompt timed out (60s, no user action)")
            self.dismissWindow()
            self.onTimeout?()
        }
        return true
    }

    /// Withdraw any live prompt without firing callbacks.
    func cancelPending() {
        timeoutTask?.cancel()
        timeoutTask = nil
        dismissWindow()
    }

    /// One prompt resolves at most once: buttons of an already-resolved
    /// prompt (`promptLive == false`) or a superseded one (stale generation)
    /// no-op.
    private func resolve(_ gen: Int, _ action: String, firing callback: (() -> Void)?) {
        guard gen == generation, promptLive else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        dismissWindow()
        notchLog.debug("notch prompt action: \(action, privacy: .public)")
        callback?()
    }

    private func dismissWindow() {
        guard promptLive else { return }
        promptLive = false
        windowOps.enqueue { [window] in await window.dismiss() }
    }
}

// MARK: - DynamicNotchKit window

/// Real prompt window backed by DynamicNotchKit. Shows compact (icon + app
/// name beside the notch) on notched screens, expanding to the full prompt on
/// hover; screens without a notch get the expanded floating pill directly
/// (DynamicNotchKit's floating style has no compact state).
///
/// One `DynamicNotch` for the app's whole life, with per-prompt content
/// flowing through `model` (#141): the library's init spawns an unstructured
/// Task iterating screen-parameter notifications forever with a strong `self`
/// capture, so no DynamicNotch ever deallocates and per-present construction
/// accumulates an instance per prompt, each rebuilding a ghost panel on every
/// display change. Created lazily on the first prompt. Accepted residual: the
/// observer re-creates and fronts the one panel on display changes even while
/// hidden — a steady count of one, not growth (confirmed 2026-08-31 against
/// `DynamicNotch.swift:144-153`; `.shared` below is now the only door, so a
/// meetings-toggle cycle can never mint a second one, #227).
@MainActor
final class DynamicNotchPromptWindow: NotchPromptWindow {
    /// The app-lifetime instance (#227) and, outside of `makeForTesting()`
    /// below, the only way to get one — see the type's own doc comment for
    /// why a second instance is a second immortal ghost-generator.
    static let shared = DynamicNotchPromptWindow()

    private init() {}

    #if DEBUG
    /// Test-only escape from `.shared` (#227): `NotchWindowVisibilityTests`
    /// needs a standalone instance so it can drive `present()`/`dismiss()`
    /// without perturbing the app-lifetime singleton every other test may
    /// already be observing. No production call site exists — the same
    /// boundary `MeetingDetectionController.injectDetectorForTesting` already
    /// draws, documentation- rather than compiler-enforced, since dev and
    /// release builds both compile in the debug configuration (`build.sh`).
    static func makeForTesting() -> DynamicNotchPromptWindow { DynamicNotchPromptWindow() }
    #endif

    private var notch: DynamicNotch<NotchPromptExpandedView, NotchPromptCompactIcon, NotchPromptCompactLabel>?
    private let model = NotchPromptModel()
    private var hoverObservation: AnyCancellable?
    /// Screen-parameter rebuild handling — live re-apply vs ghost order-out —
    /// lives in the shared `NotchScreenChangeSweeper`.
    private var screenChangeSweeper: NotchScreenChangeSweeper?
    /// True from present() until dismiss(): the sweeper's liveness signal — a
    /// hidden ghost is ordered out, never re-fronted.
    private var promptShowing = false

    /// Fences async work started for an earlier prompt: present() and the
    /// hover-driven state changes suspend in DynamicNotchKit's ~0.4s
    /// animations, and a continuation resuming after this prompt was replaced
    /// or dismissed must not re-front the panel (orderFrontRegardless) or
    /// re-arm the hover subscription. The presenter's queue already keeps
    /// present/dismiss from overlapping; this covers the hover Tasks, which
    /// run outside it.
    private var generation = 0

    func present(content: NotchPromptContent) async {
        generation += 1
        let gen = generation
        promptShowing = true
        model.content = content
        // Main screen (screens[0]) is where DynamicNotchKit presents by
        // default. Read per prompt — displays come and go across the app's life.
        let screenHasNotch = (NSScreen.screens.first?.safeAreaInsets.top ?? 0) > 0
        let notch = ensureNotch()
        if screenHasNotch {
            await notch.compact()
        } else {
            await notch.expand()
        }
        guard gen == generation else { return }
        applyFullscreenVisibilityPatch()
        observeHoverForExpansion(screenHasNotch: screenHasNotch)
    }

    func dismiss() async {
        generation += 1
        let gen = generation
        promptShowing = false
        hoverObservation = nil
        guard let notch else { return }
        await notch.hide()
        // Un-latch the content once the closing animation is done (the health
        // surface's #144 pattern): the library's screen-parameter rebuild must
        // have nothing to re-show. Skipped if a present slipped in behind the
        // hide — it bumps `generation`.
        if gen == generation { model.content = nil }
    }

    private func ensureNotch() -> DynamicNotch<NotchPromptExpandedView, NotchPromptCompactIcon, NotchPromptCompactLabel> {
        if let notch { return notch }
        // No `.keepVisible`: it makes `hide()` spin until the mouse leaves,
        // which would let a resolved prompt linger under the cursor.
        let notch = DynamicNotch(hoverBehavior: [.increaseShadow]) { [model] in
            NotchPromptExpandedView(model: model)
        } compactLeading: {
            NotchPromptCompactIcon()
        } compactTrailing: { [model] in
            NotchPromptCompactLabel(model: model)
        }
        notch.transitionConfiguration = .init(skipIntermediateHides: true)
        self.notch = notch
        screenChangeSweeper = NotchScreenChangeSweeper(
            isLive: { [weak self] in self?.promptShowing ?? false },
            window: { [weak self] in self?.notch?.windowController?.window },
            // The gap the ghost investigation hit (#227): a re-front nobody
            // asked for left no trace. Both branches now do.
            onSweep: { live in
                DiagStore.record(.promptWindow(live ? .sweepReaffirmedLive : .sweepOrderedGhostOut))
            }
        )
        return notch
    }

    /// Upstream gap, rationale, and reference config live at the seam:
    /// `NSWindow.applyFullscreenAuxiliaryVisibility` (#145). Re-applied after
    /// every present/state change because the panel is recreated from hidden.
    private func applyFullscreenVisibilityPatch() {
        notch?.windowController?.window?.applyFullscreenAuxiliaryVisibility()
    }

    /// DynamicNotchKit publishes hover but does not act on it: drive the
    /// Dynamic-Island interaction ourselves — hover expands to the button row,
    /// hover-away collapses back to compact (not a dismissal; the prompt lives
    /// until a button or the presenter's timeout resolves it). Skipped on
    /// non-notch screens, where `compact()` would hide the floating window.
    private func observeHoverForExpansion(screenHasNotch: Bool) {
        guard screenHasNotch, let notch else { return }
        let gen = generation
        hoverObservation = notch.$isHovering
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] hovering in
                guard let self else { return }
                Task { @MainActor in
                    guard gen == self.generation else { return }
                    if hovering {
                        await notch.expand()
                    } else {
                        await notch.compact()
                    }
                    guard gen == self.generation else { return }
                    // State transitions from hidden recreate the panel with
                    // the library's default behavior — re-apply.
                    self.applyFullscreenVisibilityPatch()
                }
            }
    }
}

/// The reusable notch's one mutable input (#141): DynamicNotchKit captures its
/// content views once at init, so per-prompt content has to flow through an
/// observed model rather than freshly built views. `nil` while no prompt is
/// live — before the first prompt, and cleared again on dismiss so the
/// library's screen-parameter rebuild has nothing to re-show (#144 pattern).
@MainActor
final class NotchPromptModel: ObservableObject {
    @Published var content: NotchPromptContent?
}

// MARK: - Prompt views (dark by design — notch content is always dark)

struct NotchPromptCompactIcon: View {
    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LoreTheme.Accent.blue)
    }
}

struct NotchPromptCompactLabel: View {
    @ObservedObject var model: NotchPromptModel

    var body: some View {
        Text(model.content?.appName ?? "Meeting?")
            .font(LoreTheme.Typography.secondary)
            .foregroundStyle(LoreTheme.TextColor.primary)
            .lineLimit(1)
    }
}

struct NotchPromptExpandedView: View {
    @ObservedObject var model: NotchPromptModel

    var body: some View {
        if let content = model.content {
            VStack(spacing: 10) {
                Text("Meeting detected — start transcribing?")
                    .font(LoreTheme.Typography.control)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                HStack(spacing: 8) {
                    NotchPromptButton(
                        title: "Start transcribing",
                        isPrimary: true,
                        action: content.onAccept
                    )
                    NotchPromptButton(title: "Not a meeting", action: content.onNotAMeeting)
                    // No attribution — nothing "this app" could refer to, and
                    // ignoring would be a guaranteed no-op (#101).
                    if content.appName != nil {
                        NotchPromptButton(title: "Ignore this app", action: content.onIgnoreApp)
                    }
                }
            }
            .padding(.vertical, 4)
            .fixedSize()
        }
    }
}

private struct NotchPromptButton: View {
    let title: String
    var isPrimary = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(LoreTheme.Typography.secondary)
                .foregroundStyle(isPrimary ? .white : LoreTheme.TextColor.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isPrimary ? LoreTheme.Accent.blue : LoreTheme.Surface.card3,
                    in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                )
                .brightness(hovering ? LoreTheme.Motion.hoverBrightness - 1 : 0)
        }
        .buttonStyle(LorePressButtonStyle())
        .onHover { hovering = $0 }
        // Hover brighten switches statically under Reduce Motion (same
        // convention as LoreHoverFill).
        .animation(
            reduceMotion ? nil : .easeOut(duration: LoreTheme.Motion.hoverDuration),
            value: hovering
        )
    }
}
