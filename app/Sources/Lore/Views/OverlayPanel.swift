import AppKit
import SwiftUI

/// A floating NSPanel that is invisible to screen sharing.
/// Used by the dictation indicator (DictationIndicatorManager).
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect, defaults: UserDefaults = .standard) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        sharingType = SettingsStore.screenSharingType(from: defaults)
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Remember position
        setFrameAutosaveName("OverlayPanel")
    }
}
