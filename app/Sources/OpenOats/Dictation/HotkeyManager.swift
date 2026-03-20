import AppKit
import os

@MainActor
final class HotkeyManager {
    private let log = Logger(subsystem: "com.openoats", category: "HotkeyManager")
    private weak var coordinator: DictationCoordinator?
    private weak var settings: AppSettings?

    private var globalFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?

    private var fnDown = false
    private var fnTimer: Task<Void, Never>?
    private var isHoldMode = false
    /// Locked = recording continues after Fn release; stopped by Fn or Esc
    private(set) var isLocked = false
    /// Set synchronously so the local monitor closure can check it without main actor hop
    nonisolated(unsafe) private var isRecordingFlag = false
    /// Synchronous mirror of isLocked for CGEvent tap callback
    nonisolated(unsafe) private var isLockedFlag = false

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

        // Local key monitor — return nil to consume events we handle (Space lock, Esc discard)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Space while recording → lock (consume the event so it doesn't type into fields)
            if event.keyCode == 49,
               self.isRecordingFlag,
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

        // CGEvent tap — intercepts Space/Esc globally so they don't reach external apps
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                // If the tap is disabled by the system, re-enable it
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
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

                // Space while recording and not locked → consume and lock
                if keyCode == 49 && manager.isRecordingFlag && !manager.isLockedFlag {
                    manager.isLockedFlag = true
                    Task { @MainActor in
                        manager.isLocked = true
                        manager.fnTimer?.cancel()
                        manager.fnTimer = nil
                        manager.isHoldMode = false
                        diagLog("[HOTKEY] Space (CGEvent tap) → locked")
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

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil

        fnTimer?.cancel()
        fnTimer = nil
        coordinator = nil
        settings = nil
        log.info("Hotkey manager uninstalled")
    }

    private var isEnabled: Bool {
        settings?.dictationEnabled ?? false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let fnPressed = event.modifierFlags.contains(.function)

        if fnPressed && !fnDown {
            fnDown = true

            guard isEnabled else { return }

            if isLocked {
                isLocked = false
                isLockedFlag = false
                isRecordingFlag = false
                diagLog("[HOTKEY] Fn pressed while locked → stop + paste")
                Task { [weak self] in
                    await self?.coordinator?.stopRecording()
                }
                return
            }

            isHoldMode = false
            fnTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self else { return }
                self.isHoldMode = true
                self.isRecordingFlag = true
                diagLog("[HOTKEY] hold mode → start recording")
                self.coordinator?.startRecording()
            }
        } else if !fnPressed && fnDown {
            fnDown = false
            fnTimer?.cancel()
            fnTimer = nil

            if isLocked {
                diagLog("[HOTKEY] Fn released while locked → continues")
                return
            }

            if isHoldMode {
                isHoldMode = false
                isRecordingFlag = false
                diagLog("[HOTKEY] hold mode release → stop + paste")
                Task { [weak self] in
                    await self?.coordinator?.stopRecording()
                }
            }
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard isEnabled, let coordinator else { return }

        // Space while recording → lock
        if event.keyCode == 49 && coordinator.state == .recording && !isLocked {
            fnTimer?.cancel()
            fnTimer = nil
            isHoldMode = false
            isLocked = true
            isLockedFlag = true
            diagLog("[HOTKEY] Space while recording → locked")
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
}
