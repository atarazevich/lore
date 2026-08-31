import AppKit

extension NSWindow {
    /// Apply Lore's window policy to a transient DynamicNotchKit panel: visible
    /// over fullscreen apps, excluded from screen capture per the user setting.
    ///
    /// Upstream gap (DynamicNotchKit 1.1.0): `DynamicNotchPanel` sets
    /// `collectionBehavior = [.canJoinAllSpaces, .stationary]` — without
    /// `.fullScreenAuxiliary` the panel never appears over a fullscreen app
    /// (fullscreen Zoom is the primary case). It also never sets `sharingType`,
    /// so the panel stays at AppKit's captured default; the launch/key-window
    /// sweep can't reach it either — created lazily, never becomes key, and the
    /// library rebuilds it on every hide/show and screen change (#145). Used by
    /// the meeting prompt (`DynamicNotchPromptWindow`), the last notch surface
    /// left after #151 retired the health summon; applied on every show/re-show
    /// because each rebuild resets both properties. Reference config: NotchDrop's
    /// NotchWindow (MIT).
    ///
    /// Not used by `OverlayPanel`: that is a persistent indicator panel, not a
    /// transient over-fullscreen alert — it must not be `.stationary`/
    /// `.ignoresCycle` nor force-fronted at init (D-031); it sets its own
    /// `sharingType` once at init instead.
    ///
    /// Call sites read `.standard`; the uiTest per-run suite
    /// (`AppContainer.swift:88` seeds `hideFromScreenShare` into
    /// `com.lore.uitests.<runID>`) is not threaded here — bounded today because
    /// no UI test drives a notch.
    func applyFullscreenAuxiliaryVisibility(defaults: UserDefaults = .standard) {
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = SettingsStore.screenSharingType(from: defaults)
        orderFrontRegardless()
    }
}

/// Re-asserts the window policy after DynamicNotchKit's own screen-parameter
/// observer rebuilds its panel — the library re-creates it and
/// `orderFrontRegardless()`s it even while hidden (`DynamicNotch.swift:144`,
/// the #141 residual). The meeting prompt registers here; the helper owns the
/// notification token and the settle delay.
/// Live surface → the rebuilt panel carries the library's default window
/// properties, so the policy above is re-applied (#145). Hidden surface → the
/// re-fronted ghost is ordered back out (#144); it must never be raised.
/// Wrapper-side by design: the SPM checkout stays untouched.
///
/// The sweep runs **twice** per notification: once immediately, once after a
/// 500 ms settle. A ghost is content the user can read, so waiting out the
/// settle before dealing with one leaves a stale alert on screen for half a
/// second; the second pass catches a rebuild that lands inside the settle
/// (#149 — a stale "Recording failed" summon appeared on a healthy process
/// that had recorded no failure). Residual: a rebuild landing after the settle
/// waits for the next screen-parameter event or present/hover transition.
@MainActor
final class NotchScreenChangeSweeper {
    /// Written once in init, read only in deinit — never touched concurrently.
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - isLive: whether the surface currently has content on screen.
    ///   - window: the library panel, or nil before the first show.
    ///   - onSweep: fires once per actual sweep against a real window — `true`
    ///     for the live re-apply branch, `false` for the ghost order-out
    ///     (#227: a re-front nobody asked for used to leave no trace at all,
    ///     the gap that made the ghost invisible in events.json). Never called
    ///     when `window()` is nil — there is nothing to report yet. Required,
    ///     no default: a future caller of this shared seam must supply its
    ///     own trace or fail to compile, not inherit silence.
    init(
        isLive: @escaping @MainActor () -> Bool,
        window: @escaping @MainActor () -> NSWindow?,
        onSweep: @escaping @MainActor (Bool) -> Void
    ) {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                Self.sweep(isLive: isLive, window: window, onSweep: onSweep)
                try? await Task.sleep(for: .milliseconds(500))
                Self.sweep(isLive: isLive, window: window, onSweep: onSweep)
            }
        }
    }

    private static func sweep(
        isLive: @MainActor () -> Bool,
        window: @MainActor () -> NSWindow?,
        onSweep: @MainActor (Bool) -> Void
    ) {
        guard let window = window() else { return }
        guard isLive() else {
            window.orderOut(nil)
            onSweep(false)
            return
        }
        window.applyFullscreenAuxiliaryVisibility()
        onSweep(true)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
