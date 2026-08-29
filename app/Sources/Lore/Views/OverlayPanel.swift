import AppKit
import SwiftUI

/// A floating NSPanel that is invisible to screen sharing.
/// Used by the dictation indicator and the Read Aloud player (#105), via
/// `TopCenteredPanel`.
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

// MARK: - Top-centered content-sized panel

/// The machinery shared by the floating top-centered panels (dictation
/// indicator, Read Aloud player): a configured non-activating `OverlayPanel`
/// wrapping an intrinsic-size `NSHostingView`, animated resize-to-content
/// pinned `topInset` points under the menu bar of the mouse's screen, and
/// show/hide. Managers keep their own polling loops and call `show`/`hide`/
/// `resizeToContent`.
@MainActor
final class TopCenteredPanel<Content: View> {
    private let panel: OverlayPanel
    private let hostingView: NSHostingView<Content>
    private let topInset: CGFloat
    private var lastPanelSize: NSSize = .zero
    private var currentScreen: NSScreen?

    /// Nil when no screen can be resolved for the mouse (headless edge case).
    init?(content: Content, topInset: CGFloat) {
        guard let screen = Self.screenForMouse() else { return nil }
        self.topInset = topInset
        currentScreen = screen

        // Initial off-screen 1×1 rect — the panel resizes to content.
        let rect = NSRect(
            x: screen.frame.origin.x + screen.frame.width / 2,
            y: screen.visibleFrame.maxY - 50, width: 1, height: 1
        )
        panel = OverlayPanel(contentRect: rect)
        panel.styleMask = [.nonactivatingPanel, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.setFrameAutosaveName("")

        hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = .intrinsicContentSize
        hostingView.appearance = NSAppearance(named: .darkAqua)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hostingView
    }

    /// Order front (if hidden) and fit the frame to the content.
    func show() {
        if !panel.isVisible {
            panel.orderFront(nil)
        }
        resizeToContent()
    }

    func hide() {
        panel.orderOut(nil)
        lastPanelSize = .zero
    }

    func resizeToContent() {
        guard let screen = Self.screenForMouse() else { return }
        hostingView.layoutSubtreeIfNeeded()
        // `fittingSize` is the *smallest* size the content can be pressed into,
        // not the size it wants: a panel sized from it squeezes its own
        // contents, which is how a 19-minute dictation's timer ended up broken
        // across two lines once another group joined the row (#192). The
        // hosting view's intrinsic size is the content's own ideal — the
        // content-driven number `.intrinsicContentSize` sizing exists to give.
        // The larger of the two, so no panel is ever smaller than it was.
        let ideal = hostingView.intrinsicContentSize
        let minimum = hostingView.fittingSize
        let size = NSSize(
            width: max(ideal.width, minimum.width),
            height: max(ideal.height, minimum.height)
        )
        guard size.width > 10 && size.height > 5 else { return }

        // Detect cross-screen move by identity, not dimensions
        let screenChanged = screen !== currentScreen
        if screenChanged {
            currentScreen = screen
        }

        // Only resize when dimensions actually change (avoid 20x/sec animation calls)
        let widthChanged = abs(size.width - lastPanelSize.width) > 1
        let heightChanged = abs(size.height - lastPanelSize.height) > 1
        guard widthChanged || heightChanged || screenChanged else { return }
        lastPanelSize = size

        let x = screen.frame.origin.x + (screen.frame.width - size.width) / 2
        let y = screen.visibleFrame.maxY - size.height - topInset
        let newFrame = NSRect(x: x, y: y, width: size.width, height: size.height)

        if screenChanged {
            // Snap instantly across screens — no sliding through the gap
            panel.setFrame(newFrame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        }
    }

    private static func screenForMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
