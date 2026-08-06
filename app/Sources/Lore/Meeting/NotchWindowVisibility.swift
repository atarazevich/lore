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
    /// library rebuilds it on every hide/show and screen change (#145). Shared
    /// by the meeting prompt (`DynamicNotchPromptWindow`) and the health summon
    /// (`HealthNotchPresenter`) so the patch exists once, applied on every
    /// show/re-show because each rebuild resets both properties. Reference
    /// config: NotchDrop's NotchWindow (MIT).
    ///
    /// Not used by `OverlayPanel`: that is a persistent indicator panel, not a
    /// transient over-fullscreen alert — it must not be `.stationary`/
    /// `.ignoresCycle` nor force-fronted at init (D-031); it sets its own
    /// `sharingType` once at init instead.
    func applyFullscreenAuxiliaryVisibility(defaults: UserDefaults = .standard) {
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = SettingsStore.screenSharingType(from: defaults)
        orderFrontRegardless()
    }
}
