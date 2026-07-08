import AppKit

extension NSWindow {
    /// Make a transient DynamicNotchKit panel visible over fullscreen apps.
    ///
    /// Upstream gap (DynamicNotchKit 1.1.0): `DynamicNotchPanel` sets
    /// `collectionBehavior = [.canJoinAllSpaces, .stationary]` — without
    /// `.fullScreenAuxiliary` the panel never appears over a fullscreen app
    /// (fullscreen Zoom is the primary case). Shared by the meeting prompt
    /// (`DynamicNotchPromptWindow`) and the health summon (`HealthNotchPresenter`)
    /// so the patch exists once. Reference config: NotchDrop's NotchWindow (MIT).
    ///
    /// Not used by `OverlayPanel`: that is a persistent indicator panel, not a
    /// transient over-fullscreen alert — it must not be `.stationary`/
    /// `.ignoresCycle` nor force-fronted at init (D-031).
    func applyFullscreenAuxiliaryVisibility() {
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        orderFrontRegardless()
    }
}
