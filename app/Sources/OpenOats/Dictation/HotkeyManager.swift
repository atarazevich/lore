import AppKit
import os

@MainActor
final class HotkeyManager {
    private let log = Logger(subsystem: "com.openoats", category: "HotkeyManager")
    private weak var coordinator: DictationCoordinator?
    private weak var settings: AppSettings?

    // Global monitors (events to other apps)
    private var globalFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    // Local monitors (events to our app)
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?

    private var fnDown = false
    private var fnTimer: Task<Void, Never>?
    private var isHoldMode = false
    /// Locked = recording continues after Fn release; stopped by Fn or Esc
    private var isLocked = false

    func install(coordinator: DictationCoordinator, settings: AppSettings) {
        self.coordinator = coordinator
        self.settings = settings

        // Global monitors — events going to other apps
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

        // Local monitors — events when our app is focused
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
            return event
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyDown(event)
            }
            return event
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

            // If locked recording is active, Fn press stops and pastes
            if isLocked {
                isLocked = false
                diagLog("[HOTKEY] Fn pressed while locked → stop + paste")
                Task { [weak self] in
                    await self?.coordinator?.stopRecording()
                }
                return
            }

            // Start hold-mode timer (80ms to distinguish from Fn+Space)
            isHoldMode = false
            fnTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self else { return }
                self.isHoldMode = true
                diagLog("[HOTKEY] hold mode → start recording")
                self.coordinator?.startRecording()
            }
        } else if !fnPressed && fnDown {
            fnDown = false
            fnTimer?.cancel()
            fnTimer = nil

            // If locked, do nothing — recording continues
            if isLocked {
                diagLog("[HOTKEY] Fn released while locked → continues")
                return
            }

            if isHoldMode {
                isHoldMode = false
                diagLog("[HOTKEY] hold mode release → stop + paste")
                Task { [weak self] in
                    await self?.coordinator?.stopRecording()
                }
            }
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard isEnabled, let coordinator else { return }

        // Space while recording (Fn may or may not be held) → lock
        if event.keyCode == 49 && coordinator.state == .recording && !isLocked {
            fnTimer?.cancel()
            fnTimer = nil
            isHoldMode = false
            isLocked = true
            diagLog("[HOTKEY] Space while recording → locked")
            return
        }

        // Esc while locked → discard
        if event.keyCode == 53 && isLocked {
            isLocked = false
            diagLog("[HOTKEY] Esc while locked → discard")
            coordinator.discardRecording()
            return
        }

        // Ctrl+Cmd+V to re-paste last transcript (keyCode 9 = V)
        if event.keyCode == 9
            && event.modifierFlags.contains(.control)
            && event.modifierFlags.contains(.command) {
            coordinator.pasteLastTranscript()
        }
    }
}
