import AppKit
import IOKit
import os

@MainActor
final class HotkeyManager {
    private let log = Logger(subsystem: "com.lore.app", category: "HotkeyManager")
    private let hkLog = Logger(subsystem: "com.lore.app", category: "hotkey")
    /// Static logger for use inside the CGEvent tap C callback where instance properties are inaccessible.
    private static let hkLogStatic = Logger(subsystem: "com.lore.app", category: "hotkey")
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
    /// Tracks previous permission state to log only on transitions
    private var lastPermissionOK = true
    /// Tracks previous SecureInput state to log only on transitions
    private var lastSecureInputActive = false

    /// CGEvent tap for consuming Space/Esc when external apps are focused
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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
                if event.keyCode == 9 || event.keyCode == 17 { // V or T
                    Task { @MainActor in
                        self.handleKeyDown(event)
                    }
                    return nil
                }
            }

            // C or T while upgrade panel is showing → apply upgrade
            // Only match bare keypress (no Cmd/Ctrl/Option modifiers) to avoid eating Cmd+C etc.
            if self.isUpgradeShowingFlag,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let chars = event.characters?.lowercased() {
                var action: UpgradeAction?
                if chars == "c" { action = .cleanup }
                else if chars == "t" { action = .translate }
                if let action {
                    Task { @MainActor in
                        diagLog("[HOTKEY] \(action) key → apply upgrade")
                        await self.coordinator?.applyUpgradeByKey(action)
                    }
                    return nil
                }
            }

            // Esc while upgrade panel is showing → dismiss
            if event.keyCode == 53, self.isUpgradeShowingFlag {
                Task { @MainActor in
                    self.coordinator?.dismissUpgrades()
                    diagLog("[HOTKEY] Esc → dismiss upgrades")
                }
                return nil
            }

            // Space while recording or pre-buffering → lock (consume the event)
            if event.keyCode == 49,
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

        log.info("Hotkey manager installed")
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
        log.info("Hotkey manager uninstalled")
    }

    /// Update the upgrade-showing flag for the CGEvent tap (called from polling loop).
    func updateUpgradeShowingFlag(_ showing: Bool) {
        isUpgradeShowingFlag = showing
    }

    private var isEnabled: Bool {
        settings?.dictationEnabled ?? false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        lastEventTime = Date()
        let hotkeyKey = settings?.hotkeyKey ?? .fn
        let hotkeyPressed = hotkeyKey.matchesPress(event)

        let flags = event.modifierFlags.rawValue
        hkLog.info("[HK] flags=\(String(flags, radix: 16)) pressed=\(hotkeyPressed) fnDown=\(self.fnDown) locked=\(self.isLocked) enabled=\(self.isEnabled) hold=\(self.isHoldMode)")
        diagLog("[HK] flags=\(String(flags, radix: 16)) pressed=\(hotkeyPressed) fnDown=\(fnDown) locked=\(isLocked) enabled=\(isEnabled) hold=\(isHoldMode)")

        if hotkeyPressed && !fnDown {
            fnDown = true
            fnReleaseDebounce?.cancel() // Cancel any pending debounced release

            guard isEnabled else { return }

            if coordinator == nil {
                hkLog.error("[HK] coordinator is nil in handleFlagsChanged — events being dropped")
                diagLog("[HK] coordinator is nil in handleFlagsChanged")
            }

            if isLocked {
                // Don't stop yet — V/T chord may follow. Stop happens on Fn release.
                diagLog("[HOTKEY] hotkey pressed while locked → waiting for chord or release")
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
                diagLog("[HOTKEY] hold confirmed (150ms) → recording")
                self.coordinator?.confirmRecording()
            }
        } else if !hotkeyPressed && fnDown {
            fnDown = false
            fnTimer?.cancel()
            fnTimer = nil

            if isLocked {
                if fnHeldAtLock {
                    // First release after lock-while-holding — just continue recording
                    fnHeldAtLock = false
                    diagLog("[HOTKEY] hotkey released after lock → continues (initial release)")
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
                    diagLog("[HOTKEY] hotkey released while locked → stop + paste")
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
                    diagLog("[HOTKEY] hold mode release → stop + paste")
                    await self.coordinator?.stopRecording()
                }
                return
            }

            // Tap within 150ms — cancel pre-buffer (no debounce needed for taps)
            isPreBufferingFlag = false
            coordinator?.cancelPreBuffer()
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        lastEventTime = Date()
        guard isEnabled, let coordinator else {
            if coordinator == nil {
                hkLog.error("[HK] coordinator is nil in handleKeyDown — events being dropped")
                diagLog("[HK] coordinator is nil in handleKeyDown")
            }
            return
        }

        // Fn+V/T while recording → set pre-paste cleanup mode
        // Use event's own .function flag (reliable even when Fn modifier flickers)
        if event.modifierFlags.contains(.function) && (coordinator.state == .recording || coordinator.isPreBuffering) {
            if event.keyCode == 9 { // V
                coordinator.setPendingMode(.cleanup)
                if isLocked { fnHeldAtLock = true }
                diagLog("[HOTKEY] Fn+V → pending cleanup")
                return
            } else if event.keyCode == 17 { // T
                coordinator.setPendingMode(.translate)
                if isLocked { fnHeldAtLock = true }
                diagLog("[HOTKEY] Fn+T → pending translate")
                return
            }
        }

        // Esc while upgrade panel showing → dismiss
        if event.keyCode == 53, coordinator.isUpgradePanelVisible {
            coordinator.dismissUpgrades()
            diagLog("[HOTKEY] Esc → dismiss upgrades")
            return
        }

        // Space while recording or pre-buffering → confirm + lock
        if event.keyCode == 49 && (coordinator.state == .recording || coordinator.isPreBuffering) && !isLocked {
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
            diagLog("[HOTKEY] Space → confirm + locked")
            return
        }

        // Esc while locked → discard
        if event.keyCode == 53 && isLocked {
            isLocked = false
            isLockedFlag = false
            isRecordingFlag = false
            diagLog("[HOTKEY] Esc while locked → discard")
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
                    HotkeyManager.hkLogStatic.error("[HK] CGEvent tap was disabled, re-enabling")
                    diagLog("[HK] CGEvent tap was disabled, re-enabling")
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
                    if keyCode == 9 { // V
                        Task { @MainActor in
                            manager.coordinator?.setPendingMode(.cleanup)
                            if manager.isLocked { manager.fnHeldAtLock = true }
                            diagLog("[HOTKEY] Fn+V (CGEvent) → pending cleanup")
                        }
                        return nil
                    } else if keyCode == 17 { // T
                        Task { @MainActor in
                            manager.coordinator?.setPendingMode(.translate)
                            if manager.isLocked { manager.fnHeldAtLock = true }
                            diagLog("[HOTKEY] Fn+T (CGEvent) → pending translate")
                        }
                        return nil
                    }
                }

                // C or T while upgrade panel showing → apply upgrade
                // Check no modifiers (allow Cmd+C etc. through)
                let hasModifiers = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
                if manager.isUpgradeShowingFlag && !hasModifiers {
                    if let nsEvent = NSEvent(cgEvent: event),
                       let chars = nsEvent.characters?.lowercased() {
                        var action: UpgradeAction?
                        if chars == "c" { action = .cleanup }
                        else if chars == "t" { action = .translate }
                        if let action {
                            Task { @MainActor in
                                diagLog("[HOTKEY] \(action) key (CGEvent tap) → apply upgrade")
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
                        diagLog("[HOTKEY] Esc (CGEvent tap) → dismiss upgrades")
                    }
                    return nil
                }

                // Space while recording/pre-buffering and not locked → consume and lock
                if keyCode == 49 && (manager.isRecordingFlag || manager.isPreBufferingFlag) && !manager.isLockedFlag {
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
                        diagLog("[HOTKEY] Space (CGEvent tap) → confirm + locked")
                    }
                    return nil
                }

                // Esc while locked → consume and discard
                if keyCode == 53 && manager.isLockedFlag {
                    manager.isLockedFlag = false
                    manager.isRecordingFlag = false
                    Task { @MainActor in
                        manager.isLocked = false
                        manager.coordinator?.discardRecording()
                        diagLog("[HOTKEY] Esc (CGEvent tap) → discard")
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
            hkLog.info("[HK] CGEvent tap installed")
        } else {
            hkLog.error("[HK] Failed to create CGEvent tap")
            diagLog("[HK] Failed to create CGEvent tap")
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
        hkLog.error("[HK] Reinstalling CGEvent tap")
        diagLog("[HK] Reinstalling CGEvent tap")

        // If a recording was in progress, the tap death means we lost Fn tracking.
        // Stop the recording so it doesn't get orphaned.
        if fnDown || isHoldMode || isLocked {
            diagLog("[HK] tap died mid-recording, stopping")
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
    }

    // MARK: - Health Monitor

    private func runHealthCheck() {
        // 1. Tap alive check
        if let tap = eventTap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                hkLog.error("[HK] Health: event tap found disabled, attempting re-enable")
                diagLog("[HK] Health: event tap found disabled, attempting re-enable")
                CGEvent.tapEnable(tap: tap, enable: true)
                // Verify re-enable stuck
                if !CGEvent.tapIsEnabled(tap: tap) {
                    hkLog.error("[HK] Health: re-enable failed, reinstalling tap")
                    diagLog("[HK] Health: re-enable failed, reinstalling tap")
                    reinstallEventTap()
                }
            }
        } else {
            hkLog.error("[HK] Health: event tap is nil, reinstalling")
            diagLog("[HK] Health: event tap is nil, reinstalling")
            reinstallEventTap()
        }

        // 2. Permissions check (log only on transitions to avoid spam)
        let axOK = AXIsProcessTrusted()
        let inputOK = CGPreflightListenEventAccess()
        let permOK = axOK && inputOK
        if !permOK && lastPermissionOK {
            if !axOK {
                hkLog.error("[HK] Health: Accessibility permission lost (AXIsProcessTrusted = false)")
                diagLog("[HK] Health: Accessibility permission lost")
            }
            if !inputOK {
                hkLog.error("[HK] Health: Input Monitoring permission lost (CGPreflightListenEventAccess = false)")
                diagLog("[HK] Health: Input Monitoring permission lost")
            }
        } else if permOK && !lastPermissionOK {
            hkLog.info("[HK] Health: permissions restored")
            diagLog("[HK] Health: permissions restored")
        }
        lastPermissionOK = permOK

        // 3. SecureInput check (log only on transitions to avoid spam)
        let secureInput = checkSecureInput()
        if secureInput.active, let pid = secureInput.pid {
            if !lastSecureInputActive {
                let processName: String
                if let app = NSRunningApplication(processIdentifier: pid) {
                    processName = app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)"
                } else {
                    processName = "PID \(pid)"
                }
                hkLog.error("[HK] Health: SecureInput active — held by \(processName) (pid \(pid))")
                diagLog("[HK] Health: SecureInput active — held by \(processName) (pid \(pid))")
            }
            lastSecureInputActive = true
        } else if lastSecureInputActive {
            hkLog.info("[HK] Health: SecureInput cleared")
            diagLog("[HK] Health: SecureInput cleared")
            lastSecureInputActive = false
        }

        // 4. Event liveness — warning only
        let elapsed = Date().timeIntervalSince(lastEventTime)
        if elapsed > 30 {
            hkLog.warning("[HK] Health: no modifier events for \(Int(elapsed))s")
            diagLog("[HK] Health: no events received for \(Int(elapsed))s")
        }
    }

    /// Check if SecureInput is active via IOKit registry.
    private func checkSecureInput() -> (active: Bool, pid: Int32?) {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard let prop = IORegistryEntryCreateCFProperty(
            root, "kCGSSessionSecureInputPID" as CFString, kCFAllocatorDefault, 0
        ) else {
            IOObjectRelease(root)
            return (false, nil)
        }
        IOObjectRelease(root)
        if let pid = prop.takeRetainedValue() as? Int32, pid > 0 {
            return (true, pid)
        }
        return (false, nil)
    }
}
