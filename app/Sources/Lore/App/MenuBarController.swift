import AppKit
import Observation
import SwiftUI

/// What the mark's reserved bead slot (#137) carries. The slot holds one thing,
/// so the two claims on it are ordered here rather than at either call site.
enum MenuBarBead: Equatable, Sendable {
    case none
    /// The pulsing red dot — a recording is running.
    case recording
    /// The quiet amber dot (#151) — a health failure has stood past
    /// `HealthMonitor.sustainedFailureDelay`.
    case health

    /// Recording wins: it is the rarer and the time-critical of the two, and the
    /// one the user is actively watching. Losing the slot is not losing the
    /// condition — it keeps its own clock, so amber returns when recording ends.
    static func resolve(recording: Bool, sustainedFailure: Bool) -> MenuBarBead {
        recording ? .recording : (sustainedFailure ? .health : .none)
    }
}

/// The bead itself. One hosting view for both states so the slot's geometry has
/// a single owner and the letter cannot hop between them.
struct MenuBarBeadView: View {
    let bead: MenuBarBead

    var body: some View {
        switch bead {
        case .none:
            EmptyView()
        case .recording:
            LorePulsingDot(size: LoreMarkGeometry.beadSize)
        case .health:
            LorePulsingDot(color: LoreTheme.Accent.amber,
                           size: LoreMarkGeometry.beadSize,
                           pulses: false)
        }
    }
}

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let coordinator: AppCoordinator
    private let settings: AppSettings
    private var iconUpdateTask: Task<Void, Never>?
    /// The bead, hosted so the recording state is literally the same view as the
    /// REC pill's dot — same 1.3s cycle, same glow, same Reduce Motion
    /// behaviour. A template image could not carry it: macOS repaints every
    /// pixel of one with the bar's label colour, and an `NSImage` cannot
    /// animate — nor could it hold the amber the label colour would overwrite.
    private var beadView: BeadHost?

    var onShowMainWindow: (() -> Void)?
    /// Routes to the Meetings destination of the unified window (used when a
    /// popover Start is blocked by the recording-consent gate).
    var onShowMeetings: (() -> Void)?
    /// The route from the dot to the gauge (#151): fronts the window with the
    /// health panel up. Same shape as `onShowMeetings` — the menu bar names a
    /// destination and the scene, which owns the shell, presents it.
    var onShowHealth: (() -> Void)?
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
            onShowHealth: { [weak self] in
                self?.popover.performClose(nil)
                self?.onShowHealth?()
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
            // resizes the button — `updateIcon` just swaps which bead it draws.
            let bead = BeadHost(rootView: MenuBarBeadView(bead: .none))
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
                        // Both the arrival of the monitor (it is built after this
                        // controller) and every amber transition it publishes.
                        _ = self.coordinator.healthMonitor?.hasSustainedFailure
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// The glyph never changes — only the bead comes and goes. Its slot is already
    /// reserved inside `LoreMarkGeometry.statusBox`, so the letter does not shift.
    ///
    /// Derived on every read (#151): recomputed from the monitor's live state
    /// rather than latched here, so the dot vanishes on the pass after the
    /// condition clears.
    private func updateIcon() {
        let standing = coordinator.healthMonitor?.sustainedSubjects ?? []
        let bead = MenuBarBead.resolve(recording: coordinator.isRecording,
                                       sustainedFailure: !standing.isEmpty)
        guard let button = statusItem.button else { return }
        let label = Self.label(for: bead, standing: standing)
        // On the button, not on the image: the image is a shared instance.
        button.setAccessibilityLabel(label)
        // One string for both, so what the dot means cannot differ between
        // VoiceOver and the pointer — an unexplained amber dot is a puzzle.
        button.toolTip = bead == .health ? label : nil
        beadView?.rootView = MenuBarBeadView(bead: bead)
    }

    /// Names the *subject* that needs a look, never a diagnosis — a proxy may
    /// summon a check but not an accusation (`no-false-positives` §3), and the
    /// panel is where "what" lives. Two subjects at once are counted rather than
    /// ranked: a set has no order worth arbitrating over.
    static func label(for bead: MenuBarBead, standing: Set<DiagEvent.HealthTrigger>) -> String {
        switch bead {
        case .none: return LoreTheme.wordmark
        case .recording: return "\(LoreTheme.wordmark) \u{2014} recording"
        case .health:
            let what = standing.count == 1
                ? "\(standing.first!.subject) needs a look"
                : "\(standing.count) things need a look"
            return "\(LoreTheme.wordmark) \u{2014} \(what)"
        }
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

/// Hosts the bead inside the status-item button. Two overrides earn the
/// subclass:
///
/// - `hitTest` returns nil so the bead is invisible to the mouse. Its padded
///   12.8pt frame covers most of the 22pt button's right half, and a hosting
///   view answers hit tests for its own bounds — measured, it swallowed clicks
///   on the whole right half while recording. The tooltip still works: it is set
///   on the button, which keeps the whole area.
/// - the frame is placed here rather than in `updateIcon`, once on insertion and
///   again only if the bar ever resizes the button.
private final class BeadHost: NSHostingView<MenuBarBeadView> {

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
