import AppKit
import SwiftUI

/// The window the exclusive setup state lives in (#150). AppKit rather than a
/// second SwiftUI `Window` scene because that scene's `NSWindow` is materialized
/// at launch whether or not it is ordered in, so its content would evaluate
/// (doc, The flow).
///
/// Close, ⌘W and Esc are inert until the required set is complete: the
/// `.closable` bit is absent and `windowShouldClose` refuses besides.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {

    /// Board: 660 × 540, exclusive, no app chrome behind it.
    static let size = CGSize(width: 660, height: 540)

    private var window: NSWindow?
    private var isClosable = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    /// Setup finished normally, so a close is the flow's own teardown rather
    /// than the user walking away from it.
    private var didComplete = false

    /// Closed before setup completed. Nothing else exists to fall back to, so
    /// the app quits and the next launch resumes the flow.
    var onAbandon: (() -> Void)?

    func present(model: OnboardingModel) {
        guard window == nil else {
            front()
            return
        }

        let hosting = NSHostingView(rootView: OnboardingFlowView(model: model))
        hosting.frame = CGRect(origin: .zero, size: Self.size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        // Same screen-share decision every other Lore window carries (#145);
        // `applyScreenShareVisibility` re-applies it on each key change.
        window.sharingType = SettingsStore.screenSharingType(from: defaults)
        self.window = window

        front()
    }

    /// Ice's pattern: a grant lands while System Settings has focus, so the flow
    /// has to come back on its own rather than leave the user to dig it out.
    func front() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The required set is complete — the close button becomes live.
    func setClosable(_ closable: Bool) {
        isClosable = closable
        if closable {
            window?.styleMask.insert(.closable)
        } else {
            window?.styleMask.remove(.closable)
        }
    }

    /// Setup completed — take the surface down without quitting.
    func dismiss() {
        didComplete = true
        window?.orderOut(nil)
        window?.delegate = nil
        window = nil
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        isClosable
    }

    func windowWillClose(_ notification: Notification) {
        guard !didComplete else { return }
        window = nil
        onAbandon?()
    }
}
