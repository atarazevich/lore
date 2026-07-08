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
        // The popover content renders on XMO dark tokens; force the system chrome
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
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: XMOTheme.wordmark)
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
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

    private func updateIcon() {
        let symbolName = coordinator.isRecording ? "waveform.circle.fill" : "waveform.circle"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: XMOTheme.wordmark
        )
        statusItem.button?.image?.isTemplate = true
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
