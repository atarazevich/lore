import AppKit
import Observation
import SwiftUI

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let coordinator: AppCoordinator
    private let settings: AppSettings
    private var iconUpdateTask: Task<Void, Never>?
    /// The recording bead, hosted so it is literally the same view as the REC
    /// pill's dot — same 1.3s cycle, same glow, same Reduce Motion behaviour.
    /// A template image could not carry it: macOS repaints every pixel of one
    /// with the bar's label colour, and an `NSImage` cannot animate.
    private var beadView: BeadHost?

    var onShowMainWindow: (() -> Void)?
    /// Routes to the Meetings destination of the unified window (used when a
    /// popover Start is blocked by the recording-consent gate).
    var onShowMeetings: (() -> Void)?
    var onQuitApp: (() -> Void)?

    init(
        coordinator: AppCoordinator,
        settings: AppSettings,
        onCheckForUpdates: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.settings = settings

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 160)
        popover.behavior = .transient
        popover.animates = true
        // The popover content renders on Lore dark tokens; force the system chrome
        // (arrow + material) dark so it matches instead of adapting to the OS
        // appearance (D-031: visual redesign only).
        popover.appearance = NSAppearance(named: .darkAqua)

        let popoverView = MenuBarPopoverView(
            coordinator: coordinator,
            settings: settings,
            onShowMainWindow: { [weak self] in
                self?.popover.performClose(nil)
                self?.onShowMainWindow?()
            },
            onShowMeetings: { [weak self] in
                self?.popover.performClose(nil)
                self?.onShowMeetings?()
            },
            onCheckForUpdates: { [weak self] in
                self?.popover.performClose(nil)
                onCheckForUpdates()
            },
            onQuit: { [weak self] in
                self?.popover.performClose(nil)
                self?.onQuitApp?()
            }
        )
        popover.contentViewController = NSHostingController(rootView: popoverView)

        if let button = statusItem.button {
            button.image = LoreMark.statusItem
            button.target = self
            button.action = #selector(togglePopover(_:))

            // Placed once, by the host itself, and re-placed only if the bar ever
            // resizes the button — `updateIcon` just shows and hides it.
            let bead = BeadHost(rootView: LorePulsingDot(size: LoreMarkGeometry.beadSize))
            bead.isHidden = true
            button.addSubview(bead)
            beadView = bead
        }

        applyScreenShareVisibility()
        startObservation()
    }

    deinit {
        iconUpdateTask?.cancel()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // The popover's window is created by `show`; apply the sharing type
            // now so an open popover honors hide-from-screen-share too.
            applyScreenShareVisibility()
        }
    }

    private func startObservation() {
        iconUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                updateIcon()
                applyScreenShareVisibility()
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.coordinator.isRecording
                        _ = self.settings.hideFromScreenShare
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// The glyph never changes — only the bead comes and goes. Its slot is already
    /// reserved inside `LoreMarkGeometry.statusBox`, so the letter does not shift.
    private func updateIcon() {
        let recording = coordinator.isRecording
        guard let button = statusItem.button else { return }
        // On the button, not on the image: the image is a shared instance.
        button.setAccessibilityLabel(
            recording ? "\(LoreTheme.wordmark) \u{2014} recording" : LoreTheme.wordmark)
        beadView?.isHidden = !recording
    }

    /// The status-bar button lives in a system-owned `NSStatusBarWindow` that is
    /// not in `NSApp.windows`, so `SettingsStore.applyScreenShareVisibility()`
    /// never reaches it — the icon (and an open popover) would leak into a
    /// screen share. Apply the same `sharingType` here so the menu bar affordance
    /// honors the hide-from-screen-share setting (`.none` = excluded from capture
    /// only; the user still sees it).
    private func applyScreenShareVisibility() {
        let type = settings.screenSharingType
        statusItem.button?.window?.sharingType = type
        popover.contentViewController?.view.window?.sharingType = type
    }
}

/// Hosts the recording bead inside the status-item button. Two overrides earn
/// the subclass:
///
/// - `hitTest` returns nil so the bead is invisible to the mouse. Its padded
///   12.8pt frame covers most of the 22pt button's right half, and a hosting
///   view answers hit tests for its own bounds — measured, it swallowed clicks
///   on the whole right half while recording.
/// - the frame is placed here rather than in `updateIcon`, once on insertion and
///   again only if the bar ever resizes the button.
private final class BeadHost: NSHostingView<LorePulsingDot> {

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        place()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        place()
    }

    private func place() {
        guard let superview else { return }
        frame = LoreMark.beadFrame(in: superview.bounds, flipped: superview.isFlipped)
    }
}
