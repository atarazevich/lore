import AppKit
import os

@MainActor
final class HotkeyManager {
    /// One logger, one category. Three of these existed (two sharing a category),
    /// so `log stream --predicate 'category == "Hotkey"'` missed half the file.
    /// Static so the CGEvent tap's C callback, where `self` is inaccessible, uses it too.
    private static let hkLog = Logger(subsystem: "com.lore.app", category: "Hotkey")
    private weak var coordinator: DictationCoordinator?
    private weak var settings: AppSettings?
    /// Read Aloud (#105): Fn+R reads the selection, Fn+Q enqueues it. Set by
    /// the dictation setup alongside `install`; nil simply disables the chords.
    weak var readAloudController: ReadAloudController?

    private var globalFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?

    private var fnDown = false
    private var fnTimer: Task<Void, Never>?
    /// Debounce timer for Fn release — Fn modifier flag flickers when other keys pressed
    private var fnReleaseDebounce: Task<Void, Never>?
    private var isHoldMode = false
    /// True when Fn was held at the moment Space locked. First Fn release after this should be ignored.
    private var fnHeldAtLock = false
    /// Locked = recording continues after Fn release; stopped by Fn or Esc
    private(set) var isLocked = false
    /// Set synchronously so the local monitor closure can check it without main actor hop
    nonisolated(unsafe) private var isRecordingFlag = false
    /// Synchronous mirror of isLocked for CGEvent tap callback
    nonisolated(unsafe) private var isLockedFlag = false
    /// Synchronous mirror: true when upgrade panel is showing
    nonisolated(unsafe) private var isUpgradeShowingFlag = false
    /// Synchronous mirror: true during pre-buffer phase (before hold confirmed)
    nonisolated(unsafe) private var isPreBufferingFlag = false

    /// Health monitor: periodic check of event tap, permissions, SecureInput
    private var healthMonitorTask: Task<Void, Never>?
    /// When our tap's own callback last received a key-down. Stamped **there and
    /// nowhere else** — that is the whole of #97 (see `runHealthCheck` step 4).
    private var lastTapKeyDown = Date()
    /// Previous permission state, tracked per permission so each carries its own edge
    private var lastAccessibilityOK = true
    private var lastInputMonitoringOK = true
    /// Tracks previous SecureInput state to log only on transitions
    private var lastSecureInputActive = false

    /// CGEvent tap for consuming Space/Esc when external apps are focused
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Read-only liveness of the existing tap, for the health panel (#83, #97).
    /// Never creates a tap — reports on the one this manager already owns, so the
    /// panel reads the same tap the hotkey uses rather than installing a second.
    ///
    /// Updated by `runHealthCheck` every 5 s. Carries both the enabled/existence
    /// fact and the measured starvation, because they are different questions: a
    /// tap can be enabled yet starved (the reported "Fn dead, all toggles on"
    /// incident), and only the pair is an honest verdict.
    private(set) var tapLiveness = TapLiveness()

    /// Enabled/existence only — NOT event flow. Feeds `TapLiveness.isAlive`.
    private var isEventTapAlive: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    func install(coordinator: DictationCoordinator, settings: AppSettings) {
        self.coordinator = coordinator
        self.settings = settings

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }

        // INVARIANT (#95): a global NSEvent monitor cannot consume — it has no
        // return value, and by the time its closure runs the keystroke has
        // already been delivered to the focused app. So it must never handle a
        // key that must be consumed. Every consumable key (Space lock, Esc,
        // Fn+V/T, C/T upgrades) is owned by the CGEvent tap, which can return
        // nil; this monitor is narrowed to the one chord it uniquely owns and
        // that may pass through: Ctrl+Cmd+V re-paste, which the tap does not
        // carry. Routing all keys here once made Space lock leak a literal
        // space into the user's document whenever the tap missed the event.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard HotkeyManager.isRepasteChord(event) else { return }
            Task { @MainActor in
                self?.handleKeyDown(event)
            }
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
            return event
        }

        // Local key monitor — return nil to consume events we handle
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Fn+R (read aloud) / Fn+Q (enqueue) → consume (#105). Mirror of
            // the CGEvent tap branch for when the tap is dead and Lore itself
            // is focused; when both are live the tap consumes first. With no
            // controller wired the chord is fully inert — not even consumed.
            if event.modifierFlags.contains(.function),
               event.keyCode == 15 || event.keyCode == 12,
               self.readAloudController != nil {
                let enqueue = event.keyCode == 12
                Task { @MainActor in
                    self.handleReadAloudChord(enqueue: enqueue)
                }
                return nil
            }

            // Fn+V/T while recording → consume (use event's own Fn flag, not tracked flag)
            if event.modifierFlags.contains(.function) && self.isRecordingFlag {
                if (event.keyCode == 9 && self.modifierOn({ $0.modifierCleanupEnabled }))
                    || (event.keyCode == 17 && self.modifierOn({ $0.modifierTranslateEnabled })) { // V or T
                    Task { @MainActor in
                        self.handleKeyDown(event)
                    }
                    return nil
                }
            }

            // C or T while upgrade panel is showing → apply upgrade
            // Only match bare keypress (no Cmd/Ctrl/Option modifiers) to avoid eating Cmd+C etc.
            if self.isUpgradeShowingFlag,
               self.modifierOn({ $0.modifierUpgradeKeysEnabled }),
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let chars = event.characters?.lowercased() {
                var action: UpgradeAction?
                if chars == "c" { action = .cleanup }
                else if chars == "t" { action = .translate }
                if let action {
                    Task { @MainActor in
                        HotkeyManager.hkLog.debug("[HOTKEY] \(String(describing: action), privacy: .public) key → apply upgrade")
                        await self.coordinator?.applyUpgradeByKey(action)
                    }
                    return nil
                }
            }

            // Esc while upgrade panel is showing → dismiss
            if event.keyCode == 53, self.isUpgradeShowingFlag {
                Task { @MainActor in
                    self.coordinator?.dismissUpgrades()
                    HotkeyManager.hkLog.debug("[HOTKEY] Esc → dismiss upgrades")
                }
                return nil
            }

            // Space while recording or pre-buffering → lock (consume the event)
            if event.keyCode == 49,
               self.modifierOn({ $0.modifierLockEnabled }),
               (self.isRecordingFlag || self.isPreBufferingFlag),
               !self.isLocked {
                Task { @MainActor in
                    self.handleKeyDown(event)
                }
                return nil // swallow the Space
            }

            // Esc while locked → discard (consume)
            if event.keyCode == 53, self.isLocked {
                Task { @MainActor in
                    self.handleKeyDown(event)
                }
                return nil // swallow the Esc
            }

            // All other keys pass through normally
            Task { @MainActor in
                self.handleKeyDown(event)
            }
            return event
        }

        installEventTap()

        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { break }
                self.runHealthCheck()
            }
        }

        HotkeyManager.hkLog.info("Hotkey manager installed")
    }

    func uninstall() {
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalFlagsMonitor = nil
        globalKeyMonitor = nil
        localFlagsMonitor = nil
        localKeyMonitor = nil

        healthMonitorTask?.cancel()
        healthMonitorTask = nil

        teardownEventTap()

        fnTimer?.cancel()
        fnTimer = nil
        fnReleaseDebounce?.cancel()
        fnReleaseDebounce = nil
        coordinator = nil
        settings = nil
        HotkeyManager.hkLog.info("Hotkey manager uninstalled")
    }

    /// Update the upgrade-showing flag for the CGEvent tap (called from polling loop).
    func updateUpgradeShowingFlag(_ showing: Bool) {
        isUpgradeShowingFlag = showing
    }

    /// Modifier enable toggle lookup (DSET-05/06): Space lock, Fn+V cleanup,
    /// Fn+T translate, and the post-paste C/T upgrade keys each gate on one
    /// SettingsStore flag; absent settings default to enabled. The NSEvent
    /// monitors and the CGEvent tap callback all run on the main thread (the
    /// tap source is added to CFRunLoopGetMain — see the Space path's
    /// assumeIsolated precedent), so this is a cheap cached-property read in
    /// the event path. Esc is not a modifier and is never gated.
    nonisolated private func modifierOn(_ read: @MainActor (AppSettings) -> Bool) -> Bool {
        MainActor.assumeIsolated {
            guard let settings else { return true }
            return read(settings)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let hotkeyKey = settings?.hotkeyKey ?? .fn
        let hotkeyPressed = hotkeyKey.matchesPress(event)

        let flags = event.modifierFlags.rawValue
        HotkeyManager.hkLog.info("[HK] flags=\(String(flags, radix: 16)) pressed=\(hotkeyPressed) fnDown=\(self.fnDown) locked=\(self.isLocked) hold=\(self.isHoldMode)")

        if hotkeyPressed && !fnDown {
            fnDown = true
            fnReleaseDebounce?.cancel() // Cancel any pending debounced release

            if coordinator == nil {
                HotkeyManager.hkLog.error("[HK] coordinator is nil in handleFlagsChanged — events being dropped")
            }

            if isLocked {
                // Don't stop yet — V/T chord may follow. Stop happens on Fn release.
                HotkeyManager.hkLog.debug("[HOTKEY] hotkey pressed while locked → waiting for chord or release")
                return
            }

            // Start pre-buffering immediately (audio capture before hold confirmed)
            isPreBufferingFlag = true
            coordinator?.startPreBuffer()

            isHoldMode = false
            fnTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                self.isHoldMode = true
                self.isRecordingFlag = true
                self.isPreBufferingFlag = false
                HotkeyManager.hkLog.debug("[HOTKEY] hold confirmed (150ms) → recording")
                self.coordinator?.confirmRecording()
            }
        } else if !hotkeyPressed && fnDown {
            fnDown = false
            fnTimer?.cancel()
            fnTimer = nil

            if isLocked {
                if fnHeldAtLock {
                    // First release after lock-while-holding — just continue recording.
                    // Still a genuine Fn release: clear any sticky mic error (no-op when none
                    // is showing). The `.sticky` hide path leaves autoHideTask nil, so without
                    // this an error reached through this branch would never clear.
                    fnHeldAtLock = false
                    HotkeyManager.hkLog.debug("[HOTKEY] hotkey released after lock → continues (initial release)")
                    coordinator?.dismissMicErrorAfterRelease()
                    return
                }
                // Subsequent release — stop recording (with debounce for Fn flag flicker)
                fnReleaseDebounce?.cancel()
                fnReleaseDebounce = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(30))
                    guard !Task.isCancelled, let self, !self.fnDown else { return }
                    self.isLocked = false
                    self.isLockedFlag = false
                    self.isRecordingFlag = false
                    HotkeyManager.hkLog.debug("[HOTKEY] hotkey released while locked → stop + paste")
                    // Genuine release (past the 30ms flag-flicker debounce): if a sticky
                    // mic error is showing, begin its grace hide; otherwise stop normally.
                    // stopRecording only spawns the coordinator-owned pipeline (#104):
                    // the next Fn press cancels this debounce Task, and the in-flight
                    // transcription must not die with it.
                    self.coordinator?.dismissMicErrorAfterRelease()
                    self.coordinator?.stopRecording()
                }
                return
            }

            if isHoldMode {
                // Debounce hold-to-talk release too (same Fn flag flickering issue)
                fnReleaseDebounce?.cancel()
                fnReleaseDebounce = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(30))
                    guard !Task.isCancelled, let self, !self.fnDown else { return }
                    self.isHoldMode = false
                    self.isRecordingFlag = false
                    HotkeyManager.hkLog.debug("[HOTKEY] hold mode release → stop + paste")
                    // Genuine release (past the 30ms flag-flicker debounce): if a sticky
                    // mic error is showing, begin its grace hide; otherwise stop normally.
                    // As above, stopRecording spawns the pipeline elsewhere (#104).
                    self.coordinator?.dismissMicErrorAfterRelease()
                    self.coordinator?.stopRecording()
                }
                return
            }

            // Tap within 150ms — cancel pre-buffer (no debounce needed for taps).
            // A sticky mic error can surface on a tap too (synchronous .denied path), so
            // start its grace hide here; startPreBuffer cancels it if Fn is pressed again.
            isPreBufferingFlag = false
            coordinator?.cancelPreBuffer()
            coordinator?.dismissMicErrorAfterRelease()
        }
    }

    /// Callers: the local key monitor and the global monitor's Ctrl+Cmd+V chord
    /// only — invariant at the global monitor's installation (#95). The local
    /// monitor is meant to consume Space / Esc / Fn+V/T itself before routing
    /// here; known exception: during pre-buffer its narrower `isRecordingFlag`
    /// guard lets Fn+V/T fall through to its unconsuming fallthrough, so the
    /// keystroke lands in Lore's own field while the branch below still applies
    /// the mode.
    private func handleKeyDown(_ event: NSEvent) {
        guard let coordinator else {
            HotkeyManager.hkLog.error("[HK] coordinator is nil in handleKeyDown — events being dropped")
            return
        }

        // Fn+V/T while recording → set pre-paste cleanup mode
        // Use event's own .function flag (reliable even when Fn modifier flickers)
        if event.modifierFlags.contains(.function) && (coordinator.state == .recording || coordinator.isPreBuffering) {
            if event.keyCode == 9, modifierOn({ $0.modifierCleanupEnabled }) { // V
                coordinator.setPendingMode(.cleanup)
                if isLocked { fnHeldAtLock = true }
                HotkeyManager.hkLog.debug("[HOTKEY] Fn+V → pending cleanup")
                return
            } else if event.keyCode == 17, modifierOn({ $0.modifierTranslateEnabled }) { // T
                coordinator.setPendingMode(.translate)
                if isLocked { fnHeldAtLock = true }
                HotkeyManager.hkLog.debug("[HOTKEY] Fn+T → pending translate")
                return
            }
        }

        // Esc while upgrade panel showing → dismiss
        if event.keyCode == 53, coordinator.isUpgradePanelVisible {
            coordinator.dismissUpgrades()
            HotkeyManager.hkLog.debug("[HOTKEY] Esc → dismiss upgrades")
            return
        }

        // Space while recording or pre-buffering → confirm + lock
        if event.keyCode == 49 && modifierOn({ $0.modifierLockEnabled })
            && (coordinator.state == .recording || coordinator.isPreBuffering) && !isLocked {
            fnTimer?.cancel()
            fnTimer = nil
            isHoldMode = false
            isPreBufferingFlag = false
            fnHeldAtLock = fnDown  // Track: if Fn held at lock, first release should continue
            if coordinator.isPreBuffering {
                coordinator.confirmRecording()
            }
            isLocked = true
            isLockedFlag = true
            isRecordingFlag = true
            HotkeyManager.hkLog.debug("[HOTKEY] Space → confirm + locked")
            return
        }

        // Esc while locked → discard
        if event.keyCode == 53 && isLocked {
            isLocked = false
            isLockedFlag = false
            isRecordingFlag = false
            HotkeyManager.hkLog.debug("[HOTKEY] Esc while locked → discard")
            coordinator.discardRecording()
            return
        }

        // Ctrl+Cmd+V to re-paste last transcript
        if HotkeyManager.isRepasteChord(event) {
            coordinator.pasteLastTranscript()
        }
    }

    /// Fn+R (read now) / Fn+Q (enqueue) — Read Aloud (#105). Reading and
    /// recording are mutually exclusive gestures on the same modifier, so any
    /// dictation gesture in flight (pre-buffer, hold, locked) aborts before
    /// the selection capture runs; unlike Fn+V/T nothing "pending" is set.
    /// The subsequent Fn release then falls through the tap path as a no-op
    /// (timer cancelled, flags cleared here).
    private func handleReadAloudChord(enqueue: Bool) {
        // No controller wired → fully inert: no gesture teardown, no discard.
        guard let readAloudController else { return }
        HotkeyManager.hkLog.debug("[HOTKEY] Fn+\(enqueue ? "Q" : "R", privacy: .public) → read aloud")
        fnTimer?.cancel()
        fnTimer = nil
        fnReleaseDebounce?.cancel()
        fnReleaseDebounce = nil
        isHoldMode = false
        fnHeldAtLock = false
        isLocked = false
        isLockedFlag = false
        isRecordingFlag = false
        isPreBufferingFlag = false
        // Abort only a live capture gesture — never a `.processing` transcription
        // of an earlier dictation, which discardRecording would also kill.
        if let coordinator, coordinator.isPreBuffering || coordinator.state == .recording {
            coordinator.discardRecording()
        }
        Task { @MainActor in
            if enqueue {
                await readAloudController.enqueueSelection()
            } else {
                await readAloudController.readSelectionNow()
            }
        }
    }

    /// Ctrl+Cmd+V exactly — a superset like Ctrl+Cmd+Shift+V is someone else's
    /// shortcut. The one chord the global keyDown monitor may handle (see the
    /// invariant at its installation, #95).
    private static func isRepasteChord(_ event: NSEvent) -> Bool {
        event.keyCode == 9
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.control, .command]
    }

    // MARK: - Event Tap Lifecycle

    /// Create the CGEvent tap and attach it to the main run loop.
    private func installEventTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        // SAFETY: self must outlive the event tap. Currently guaranteed because
        // HotkeyManager is owned by AppDelegate for the app's entire lifetime.
        // If ownership changes, this must become passRetained + release in teardown.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                // If the tap is disabled by the system, re-enable it
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    DiagStore.record(.tapDisabledByOS)
                    HotkeyManager.hkLog.error("[HK] CGEvent tap was disabled, re-enabling")
                    if let refcon {
                        let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                        if let tap = mgr.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passRetained(event)
                }

                guard let refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

                // The one place `lastTapKeyDown` is stamped (#97). `eventsOfInterest`
                // is key-down only and the tap-disabled control events returned above,
                // so reaching here *is* "our tap received a key-down" — the fact the
                // health check exists to measure and never did.
                //
                // The tap's source is on CFRunLoopGetMain (see below), so this runs on
                // the main thread: the same assumption `modifierOn` and the Space path
                // already make, and why no `nonisolated(unsafe)` mirror is needed.
                MainActor.assumeIsolated { manager.lastTapKeyDown = Date() }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags

                // Fn+V/T while recording → set pre-paste mode
                // Use the EVENT's own Fn flag (reliable) instead of tracked fnDown (flickers)
                let fnHeld = flags.contains(.maskSecondaryFn)
                if fnHeld && manager.isRecordingFlag {
                    if keyCode == 9, manager.modifierOn({ $0.modifierCleanupEnabled }) { // V
                        Task { @MainActor in
                            manager.coordinator?.setPendingMode(.cleanup)
                            if manager.isLocked { manager.fnHeldAtLock = true }
                            HotkeyManager.hkLog.debug("[HOTKEY] Fn+V (CGEvent) → pending cleanup")
                        }
                        return nil
                    } else if keyCode == 17, manager.modifierOn({ $0.modifierTranslateEnabled }) { // T
                        Task { @MainActor in
                            manager.coordinator?.setPendingMode(.translate)
                            if manager.isLocked { manager.fnHeldAtLock = true }
                            HotkeyManager.hkLog.debug("[HOTKEY] Fn+T (CGEvent) → pending translate")
                        }
                        return nil
                    }
                }

                // C or T while upgrade panel showing → apply upgrade
                // Check no modifiers (allow Cmd+C etc. through)
                let hasModifiers = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
                if manager.isUpgradeShowingFlag && manager.modifierOn({ $0.modifierUpgradeKeysEnabled }) && !hasModifiers {
                    if let nsEvent = NSEvent(cgEvent: event),
                       let chars = nsEvent.characters?.lowercased() {
                        var action: UpgradeAction?
                        if chars == "c" { action = .cleanup }
                        else if chars == "t" { action = .translate }
                        if let action {
                            Task { @MainActor in
                                HotkeyManager.hkLog.debug("[HOTKEY] \(String(describing: action), privacy: .public) key (CGEvent tap) → apply upgrade")
                                await manager.coordinator?.applyUpgradeByKey(action)
                            }
                            return nil
                        }
                    }
                }

                // Fn+R (read aloud) / Fn+Q (enqueue) → consume (#105). Unlike
                // Fn+V/T these fire regardless of recording state — the chord
                // handler aborts any dictation gesture itself (reading and
                // recording are mutually exclusive on the same modifier).
                // With no controller wired the chord passes through untouched.
                // The tap source is on CFRunLoopGetMain (see `lastTapKeyDown`
                // above), so assumeIsolated is valid here.
                if fnHeld && (keyCode == 15 || keyCode == 12),
                   MainActor.assumeIsolated({ manager.readAloudController != nil }) {
                    let enqueue = keyCode == 12
                    manager.isRecordingFlag = false
                    manager.isPreBufferingFlag = false
                    manager.isLockedFlag = false
                    Task { @MainActor in
                        manager.handleReadAloudChord(enqueue: enqueue)
                    }
                    return nil
                }

                // Esc while upgrade panel showing → dismiss
                if keyCode == 53 && manager.isUpgradeShowingFlag {
                    Task { @MainActor in
                        manager.coordinator?.dismissUpgrades()
                        HotkeyManager.hkLog.debug("[HOTKEY] Esc (CGEvent tap) → dismiss upgrades")
                    }
                    return nil
                }

                // Space while recording/pre-buffering and not locked → consume and lock
                if keyCode == 49 && manager.modifierOn({ $0.modifierLockEnabled }) && !manager.isLockedFlag {
                    // Consult the coordinator's live state, not just the sync flags: a failed
                    // pre-buffer parks in `.done` but leaves isPreBufferingFlag stale, which
                    // would phantom-lock onto a recording that never started. The tap is added
                    // to the main run loop (CFRunLoopGetMain), so the callback runs on the main
                    // thread and assumeIsolated is valid here. Mirrors the keyDown Space path,
                    // which guards on `coordinator.state == .recording || coordinator.isPreBuffering`.
                    let recordingLive = MainActor.assumeIsolated {
                        manager.coordinator.map { $0.state == .recording || $0.isPreBuffering } ?? false
                    }
                    if recordingLive {
                        manager.isLockedFlag = true
                        manager.isPreBufferingFlag = false
                        manager.isRecordingFlag = true
                        Task { @MainActor in
                            if manager.coordinator?.isPreBuffering == true {
                                manager.coordinator?.confirmRecording()
                            }
                            manager.fnHeldAtLock = manager.fnDown
                            manager.isLocked = true
                            manager.fnTimer?.cancel()
                            manager.fnTimer = nil
                            manager.isHoldMode = false
                            HotkeyManager.hkLog.debug("[HOTKEY] Space (CGEvent tap) → confirm + locked")
                        }
                        return nil
                    }
                }

                // Esc while locked → consume and discard
                if keyCode == 53 && manager.isLockedFlag {
                    manager.isLockedFlag = false
                    manager.isRecordingFlag = false
                    Task { @MainActor in
                        manager.isLocked = false
                        manager.coordinator?.discardRecording()
                        HotkeyManager.hkLog.debug("[HOTKEY] Esc (CGEvent tap) → discard")
                    }
                    return nil
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: userInfo
        )

        if let eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            DiagStore.record(.tapCreate(outcome: .ok, osStatus: nil))
            HotkeyManager.hkLog.info("[HK] CGEvent tap installed")
        } else {
            // CGEvent.tapCreate reports no OSStatus — the nil is the honest answer.
            DiagStore.record(.tapCreate(outcome: .failed, osStatus: nil))
            HotkeyManager.hkLog.error("[HK] Failed to create CGEvent tap")
        }
        // The health loop sleeps before its first tick, so without this the panel
        // could be opened in the first 5 s and read the default rather than a tap.
        tapLiveness.isAlive = isEventTapAlive
    }

    /// Remove the CGEvent tap from the run loop and release resources.
    private func teardownEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Tear down and recreate the CGEvent tap from scratch.
    private func reinstallEventTap() {
        HotkeyManager.hkLog.error("[HK] Reinstalling CGEvent tap")

        // If a recording was in progress, the tap death means we lost Fn tracking.
        // Stop the recording so it doesn't get orphaned.
        if fnDown || isHoldMode || isLocked {
            DiagStore.record(.tapDiedDuringRecording)
            fnDown = false
            isHoldMode = false
            isLocked = false
            isLockedFlag = false
            isRecordingFlag = false
            isPreBufferingFlag = false
            fnTimer?.cancel()
            fnTimer = nil
            coordinator?.stopRecording()
        }

        teardownEventTap()
        installEventTap()
        // installEventTap() already recorded the tapCreate attempt; this records
        // whether the *reinstall* as a whole left us with a live tap.
        DiagStore.record(.tapReinstall(outcome: .init(success: eventTap != nil)))
    }

    // MARK: - Health Monitor

    private func runHealthCheck() {
        // 1. Tap alive check
        if let tap = eventTap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                DiagStore.record(.tapDisabledByOS)
                HotkeyManager.hkLog.error("[HK] Health: event tap found disabled, attempting re-enable")
                CGEvent.tapEnable(tap: tap, enable: true)
                // Verify re-enable stuck
                if !CGEvent.tapIsEnabled(tap: tap) {
                    HotkeyManager.hkLog.error("[HK] Health: re-enable failed, reinstalling tap")
                    reinstallEventTap()
                }
            }
        } else {
            HotkeyManager.hkLog.error("[HK] Health: event tap is nil, reinstalling")
            reinstallEventTap()
        }

        // 2. Permissions check. Each permission carries its own edge: a combined
        //    `permOK` flag reported both as restored when only one had dropped, and
        //    went deaf to the second one dropping while the first was already down.
        let axOK = AXIsProcessTrusted()
        let inputOK = CGPreflightListenEventAccess()
        if axOK != lastAccessibilityOK {
            DiagStore.record(.permissionTransition(permission: .accessibility, granted: axOK))
            if axOK {
                HotkeyManager.hkLog.info("[HK] Health: Accessibility permission restored")
            } else {
                HotkeyManager.hkLog.error("[HK] Health: Accessibility permission lost (AXIsProcessTrusted = false)")
            }
            lastAccessibilityOK = axOK
        }
        if inputOK != lastInputMonitoringOK {
            DiagStore.record(.permissionTransition(permission: .inputMonitoring, granted: inputOK))
            if inputOK {
                HotkeyManager.hkLog.info("[HK] Health: Input Monitoring permission restored")
            } else {
                HotkeyManager.hkLog.error("[HK] Health: Input Monitoring permission lost (CGPreflightListenEventAccess = false)")
            }
            lastInputMonitoringOK = inputOK
        }

        // 3. SecureInput check (record only on transitions to avoid spam). The
        //    flag alone decides the edge: a holder pid is decoration the registry
        //    often cannot supply, and gating on it is what kept this event from
        //    ever firing (#93).
        let secureInput = SecureInput.read()
        if secureInput.active {
            if !lastSecureInputActive {
                DiagStore.record(.secureInputChanged(active: true, holderPID: secureInput.pid))
                // The holder's *name* identifies software the user runs — os.Logger only.
                HotkeyManager.hkLog.error("[HK] Health: SecureInput active — associated with \(secureInput.name ?? "an unnamed process", privacy: .private) (pid \(secureInput.pid.map(String.init) ?? "none", privacy: .public))")
            }
            lastSecureInputActive = true
        } else if lastSecureInputActive {
            DiagStore.record(.secureInputChanged(active: false, holderPID: nil))
            HotkeyManager.hkLog.info("[HK] Health: SecureInput cleared")
            lastSecureInputActive = false
        }

        // 4. Tap liveness. "We saw no key events for 30s" is not a fault — the user
        //    was reading. The fault is "the session received key-downs and our tap
        //    did not", and both halves of that are now measured from the same
        //    vantage: `lastTapKeyDown` is stamped by the tap's own callback, against
        //    the session's key-downs *alone*. Neither held before (#97) — our side
        //    was stamped by the NSEvent monitors, which starve alongside the tap and
        //    are reset by Fn, and the session side min'd in flagsChanged, an event
        //    type `eventsOfInterest` (`installEventTap`) never asks for, so it could
        //    never have a counterpart on our side and could only ever fabricate
        //    starvation. Secure input, read at step 3, makes that comparison
        //    unmeasurable rather than false — see `TapLiveness.observe`.
        //    Only the transitions are recorded; the verdict latches in `TapLiveness`.
        let edge = tapLiveness.observe(
            isAlive: isEventTapAlive,
            tapSilent: Date().timeIntervalSince(lastTapKeyDown),
            sessionSilent: CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: .keyDown
            ),
            secureInputActive: secureInput.active
        )
        switch edge {
        case .stalled:
            DiagStore.record(.tapEventsStalled(seconds: tapLiveness.tapSilentSeconds))
            HotkeyManager.hkLog.error("[HK] Health: the session received key-downs and our tap did not, for \(self.tapLiveness.tapSilentSeconds)s")
        case .resumed:
            DiagStore.record(.tapEventsResumed)
            HotkeyManager.hkLog.info("[HK] Health: our tap is receiving key-downs again")
        case nil:
            break
        }
    }
}
