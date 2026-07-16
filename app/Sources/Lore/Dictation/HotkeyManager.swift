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
    /// Timestamp of last received modifier event (for liveness tracking)
    private var lastEventTime = Date()
    /// Previous permission state, tracked per permission so each carries its own edge
    private var lastAccessibilityOK = true
    private var lastInputMonitoringOK = true
    /// Tracks previous SecureInput state to log only on transitions
    private var lastSecureInputActive = false
    /// Tracks previous event-liveness state to record only on transitions
    private var lastEventsStalled = false

    /// CGEvent tap for consuming Space/Esc when external apps are focused
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Read-only liveness of the existing tap, for the health panel (#83). Never
    /// creates a tap — reports on the one this manager already owns, so the panel
    /// reads the same tap the hotkey uses rather than installing a second.
    ///
    /// This is enabled/existence only — NOT event flow. A tap can be enabled yet
    /// starved (the reported "Fn dead, all toggles on" incident); pair this with
    /// `isEventTapStalled` for the honest verdict.
    var isEventTapAlive: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    /// Read-only: the enabled-but-starved verdict the 5-second monitor already
    /// computes (`tapEventsStalled` — "the OS delivered key events to everyone
    /// else and not to us"). `isEventTapAlive` reads such a tap as healthy, so
    /// the health panel's critical `tap` probe must consult this too, or the
    /// notch never summons in the one scenario it exists for (#83).
    var isEventTapStalled: Bool { lastEventsStalled }

    func install(coordinator: DictationCoordinator, settings: AppSettings) {
        self.coordinator = coordinator
        self.settings = settings

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        lastEventTime = Date()
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
                    self.coordinator?.dismissMicErrorAfterRelease()
                    await self.coordinator?.stopRecording()
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
                    self.coordinator?.dismissMicErrorAfterRelease()
                    await self.coordinator?.stopRecording()
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

    private func handleKeyDown(_ event: NSEvent) {
        lastEventTime = Date()
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
        if event.keyCode == 9
            && event.modifierFlags.contains(.control)
            && event.modifierFlags.contains(.command) {
            coordinator.pasteLastTranscript()
        }
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
            Task { [weak self] in
                await self?.coordinator?.stopRecording()
            }
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

        // 4. Event liveness. "We saw no key events for 30s" is not a fault — the user
        //    was reading. The fault is "the OS delivered key events to everyone else
        //    and not to us", so the edge is gated on machine input, not on our silence.
        //    The health loop ticks every 5s; only the transitions are recorded.
        let elapsed = Date().timeIntervalSince(lastEventTime)
        let tapLooksDead = elapsed > 30 && Self.secondsSinceSystemKeyInput() < 30
        if tapLooksDead {
            if !lastEventsStalled {
                lastEventsStalled = true
                DiagStore.record(.tapEventsStalled(seconds: Int(elapsed)))
            }
            HotkeyManager.hkLog.error("[HK] Health: OS saw key input but our tap did not, for \(Int(elapsed))s")
        } else if lastEventsStalled {
            lastEventsStalled = false
            DiagStore.record(.tapEventsResumed)
        }
    }

    /// Seconds since the *system* last saw a key-down or modifier change, from any
    /// process. Compared against our own last event, this separates "the user is idle"
    /// from "our tap is dead" — the two states the old 30-second warning conflated.
    private static func secondsSinceSystemKeyInput() -> CFTimeInterval {
        let sinceKeyDown = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .keyDown
        )
        let sinceFlagsChanged = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .flagsChanged
        )
        return min(sinceKeyDown, sinceFlagsChanged)
    }
}
