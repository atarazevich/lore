import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

/// Notch-anchored Dynamic-Island-style prompt for meeting detection (#79).
///
/// Primary delivery surface for the detection prompt: Notification Center
/// cannot deliver on dev-signed builds (`requestAuthorization` fails without
/// a provisioning profile), so the prompt renders as a DynamicNotchKit window
/// under the hardware notch instead. Mirrors `NotificationService`'s callback
/// contract exactly so `MeetingDetectionController` wires both surfaces to
/// the same handlers.

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
@MainActor
protocol NotchPromptWindow: AnyObject {
    func present() async
    func dismiss() async
}

// MARK: - Presenter

/// Presents the meeting-detection prompt in the notch and owns its lifecycle:
/// 60-second auto-timeout, replace-on-re-present, once-only resolution.
/// Callback contract matches `NotificationService` (onAccept / onNotAMeeting /
/// onIgnoreApp / onTimeout + `cancelPending()`).
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
    private let makeWindow: @MainActor (NotchPromptContent) -> NotchPromptWindow
    private var window: NotchPromptWindow?
    private var timeoutTask: Task<Void, Never>?

    /// Identifies the live prompt: bumped on every present() so actions from
    /// a replaced window (mid hide animation) can't resolve the new prompt.
    private var generation = 0

    /// - Parameters:
    ///   - timeout: auto-dismiss interval; injectable for tests.
    ///   - makeWindow: window factory; tests substitute a stub.
    init(
        timeout: Duration = .seconds(60),
        makeWindow: @escaping @MainActor (NotchPromptContent) -> NotchPromptWindow = {
            DynamicNotchPromptWindow(content: $0)
        }
    ) {
        self.timeout = timeout
        self.makeWindow = makeWindow
    }

    /// Present the detection prompt. A pending prompt is replaced (its window
    /// dismissed, its timeout cancelled) so at most one prompt is live.
    func present(appName: String?) {
        cancelPending()
        generation += 1
        let gen = generation

        let content = NotchPromptContent(
            appName: appName,
            onAccept: { [weak self] in self?.resolve(gen, "accept", firing: self?.onAccept) },
            onNotAMeeting: { [weak self] in self?.resolve(gen, "not a meeting", firing: self?.onNotAMeeting) },
            onIgnoreApp: { [weak self] in self?.resolve(gen, "ignore this app", firing: self?.onIgnoreApp) }
        )
        let window = makeWindow(content)
        self.window = window
        Task { await window.present() }
        diagLog("[DETECT] notch prompt shown (\(appName ?? "unknown app"))")

        timeoutTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            diagLog("[DETECT] notch prompt timed out (60s, no user action)")
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
    /// window (`window == nil`) or a superseded one (stale generation) no-op.
    private func resolve(_ gen: Int, _ action: String, firing callback: (() -> Void)?) {
        guard gen == generation, window != nil else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        dismissWindow()
        diagLog("[DETECT] notch prompt action: \(action)")
        callback?()
    }

    private func dismissWindow() {
        guard let window else { return }
        self.window = nil
        Task { await window.dismiss() }
    }
}

// MARK: - DynamicNotchKit window

/// Real prompt window backed by DynamicNotchKit. Shows compact (icon + app
/// name beside the notch) on notched screens, expanding to the full prompt on
/// hover; screens without a notch get the expanded floating pill directly
/// (DynamicNotchKit's floating style has no compact state).
@MainActor
final class DynamicNotchPromptWindow: NotchPromptWindow {
    private let notch: DynamicNotch<NotchPromptExpandedView, NotchPromptCompactIcon, NotchPromptCompactLabel>
    private let screenHasNotch: Bool
    private var hoverObservation: AnyCancellable?

    /// Set once dismiss() runs. present() and the hover-driven state changes
    /// suspend in DynamicNotchKit's ~0.4s animations; on a rapid replace a
    /// suspended continuation can resume after dismiss() completed and would
    /// otherwise re-front the dead panel (orderFrontRegardless) or re-arm the
    /// hover subscription — so every await is followed by a dismissed check.
    private var dismissed = false

    init(content: NotchPromptContent) {
        // Main screen (screens[0]) is where DynamicNotchKit presents by default.
        screenHasNotch = (NSScreen.screens.first?.safeAreaInsets.top ?? 0) > 0

        // No `.keepVisible`: it makes `hide()` spin until the mouse leaves,
        // which would let a resolved prompt linger under the cursor.
        let notch = DynamicNotch(hoverBehavior: [.increaseShadow]) {
            NotchPromptExpandedView(content: content)
        } compactLeading: {
            NotchPromptCompactIcon()
        } compactTrailing: {
            NotchPromptCompactLabel(appName: content.appName)
        }
        notch.transitionConfiguration = .init(skipIntermediateHides: true)
        self.notch = notch
    }

    func present() async {
        if screenHasNotch {
            await notch.compact()
        } else {
            await notch.expand()
        }
        guard !dismissed else { return }
        applyFullscreenVisibilityPatch()
        observeHoverForExpansion()
    }

    func dismiss() async {
        dismissed = true
        hoverObservation = nil
        await notch.hide()
    }

    /// Upstream gap (DynamicNotchKit 1.1.0): `DynamicNotchPanel` sets
    /// `collectionBehavior = [.canJoinAllSpaces, .stationary]` — without
    /// `.fullScreenAuxiliary` the prompt never appears over fullscreen apps
    /// (fullscreen Zoom is the primary use case). The library exposes its
    /// `windowController` publicly for exactly this kind of adjustment, so we
    /// patch the panel after each present/state change (the panel is recreated
    /// from hidden state). Reference config: NotchDrop's NotchWindow (MIT).
    /// Panel level stays at the library's `.screenSaver` default, which is
    /// already above fullscreen content.
    ///
    /// Known residual gap: the library also re-creates its panel on
    /// `didChangeScreenParametersNotification` (display plug/unplug while a
    /// prompt is live), which bypasses this patch until the next state
    /// change. Accepted for v1 — a prompt lives at most 60 seconds.
    private func applyFullscreenVisibilityPatch() {
        guard let panel = notch.windowController?.window else { return }
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.orderFrontRegardless()
    }

    /// DynamicNotchKit publishes hover but does not act on it: drive the
    /// Dynamic-Island interaction ourselves — hover expands to the button row,
    /// hover-away collapses back to compact (not a dismissal; the prompt lives
    /// until a button or the presenter's timeout resolves it). Skipped on
    /// non-notch screens, where `compact()` would hide the floating window.
    private func observeHoverForExpansion() {
        guard screenHasNotch else { return }
        hoverObservation = notch.$isHovering
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] hovering in
                guard let self else { return }
                Task { @MainActor in
                    guard !self.dismissed else { return }
                    if hovering {
                        await self.notch.expand()
                    } else {
                        await self.notch.compact()
                    }
                    guard !self.dismissed else { return }
                    // State transitions from hidden recreate the panel with
                    // the library's default behavior — re-apply.
                    self.applyFullscreenVisibilityPatch()
                }
            }
    }
}

// MARK: - Prompt views (dark by design — notch content is always dark)

struct NotchPromptCompactIcon: View {
    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(XMOTheme.Accent.blue)
    }
}

struct NotchPromptCompactLabel: View {
    let appName: String?

    var body: some View {
        Text(appName ?? "Meeting?")
            .font(XMOTheme.Typography.secondary)
            .foregroundStyle(XMOTheme.TextColor.primary)
            .lineLimit(1)
    }
}

struct NotchPromptExpandedView: View {
    let content: NotchPromptContent

    var body: some View {
        VStack(spacing: 10) {
            Text("Meeting detected — start transcribing?")
                .font(XMOTheme.Typography.control)
                .foregroundStyle(XMOTheme.TextColor.primary)
            HStack(spacing: 8) {
                NotchPromptButton(
                    title: "Start transcribing",
                    isPrimary: true,
                    action: content.onAccept
                )
                NotchPromptButton(title: "Not a meeting", action: content.onNotAMeeting)
                NotchPromptButton(title: "Ignore this app", action: content.onIgnoreApp)
            }
        }
        .padding(.vertical, 4)
        .fixedSize()
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
                .font(XMOTheme.Typography.secondary)
                .foregroundStyle(isPrimary ? .white : XMOTheme.TextColor.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isPrimary ? XMOTheme.Accent.blue : XMOTheme.Surface.card3,
                    in: RoundedRectangle(cornerRadius: XMOTheme.Radius.button)
                )
                .brightness(hovering ? XMOTheme.Motion.hoverBrightness - 1 : 0)
        }
        .buttonStyle(XMOPressButtonStyle())
        .onHover { hovering = $0 }
        // Hover brighten switches statically under Reduce Motion (same
        // convention as XMOHoverFill).
        .animation(
            reduceMotion ? nil : .easeOut(duration: XMOTheme.Motion.hoverDuration),
            value: hovering
        )
    }
}
