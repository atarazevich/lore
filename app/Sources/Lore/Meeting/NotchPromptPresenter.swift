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

    private let timeout: Duration
    /// The one long-lived window (#141); tests substitute a fake.
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
    init(
        timeout: Duration = .seconds(60),
        window: NotchPromptWindow = DynamicNotchPromptWindow()
    ) {
        self.timeout = timeout
        self.window = window
    }

    /// Present the detection prompt. A pending prompt is replaced in place —
    /// its timeout dies and its buttons go stale, but the panel is not taken
    /// down: the new content swaps in through the window's model, so at most
    /// one prompt is live and the notch never dips mid-replace.
    func present(appName: String?) {
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
/// flowing through `model` (#141) — full rationale and the accepted residual
/// on `HealthNotchPresenter.notch`. Created lazily on the first prompt.
@MainActor
final class DynamicNotchPromptWindow: NotchPromptWindow {
    private var notch: DynamicNotch<NotchPromptExpandedView, NotchPromptCompactIcon, NotchPromptCompactLabel>?
    private let model = NotchPromptModel()
    private var hoverObservation: AnyCancellable?
    private var screenChangeObserver: (any NSObjectProtocol)?
    /// True from present() until dismiss(): gates the screen-change re-apply,
    /// which must never `orderFrontRegardless()` a hidden panel.
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
        promptShowing = false
        hoverObservation = nil
        guard let notch else { return }
        await notch.hide()
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
        observeScreenChanges()
        return notch
    }

    /// The library re-creates its panel on `didChangeScreenParametersNotification`
    /// (display plug/unplug while a prompt is live) with default window
    /// properties — captured by screen recordings and invisible over fullscreen
    /// apps. Re-apply the patch after the library's rebuild settles (#145;
    /// same delay rationale as `HealthNotchPresenter.sweepGhostPanel`). While
    /// no prompt is showing, do nothing: the patch fronts the panel, and a
    /// hidden ghost must not be raised.
    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.promptShowing else { return }
                self.applyFullscreenVisibilityPatch()
            }
        }
    }

    /// Upstream gap (DynamicNotchKit 1.1.0): `DynamicNotchPanel` sets
    /// `collectionBehavior = [.canJoinAllSpaces, .stationary]` — without
    /// `.fullScreenAuxiliary` the prompt never appears over fullscreen apps
    /// (fullscreen Zoom is the primary use case) — and no `sharingType`, so
    /// screen recordings capture it against the user's setting (#145). The
    /// library exposes its `windowController` publicly for exactly this kind
    /// of adjustment, so we patch the panel after each present/state change
    /// (the panel is recreated from hidden state) and after screen-parameter
    /// rebuilds (`observeScreenChanges`). Reference config: NotchDrop's
    /// NotchWindow (MIT). Panel level stays at the library's `.screenSaver`
    /// default, which is already above fullscreen content.
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
/// observed model rather than freshly built views. `nil` only before the first
/// prompt, when the notch has never been shown.
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
