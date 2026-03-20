import AppKit
import os

@MainActor
final class HotkeyManager {
    private let log = Logger(subsystem: "com.openoats", category: "HotkeyManager")
    private weak var coordinator: DictationCoordinator?
    private weak var settings: AppSettings?

    private var flagsMonitor: Any?
    private var keyMonitor: Any?

    private var fnDown = false
    private var fnTimer: Task<Void, Never>?
    private var isHoldMode = false

    func install(coordinator: DictationCoordinator, settings: AppSettings) {
        self.coordinator = coordinator
        self.settings = settings

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }

        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyDown(event)
            }
        }

        log.info("Hotkey manager installed")
    }

    func uninstall() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        flagsMonitor = nil
        keyMonitor = nil
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
            isHoldMode = false

            guard isEnabled else { return }

            // Start 50ms timer — if Space doesn't arrive, it's hold mode
            fnTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                self.isHoldMode = true
                self.coordinator?.startRecording()
            }
        } else if !fnPressed && fnDown {
            fnDown = false
            fnTimer?.cancel()
            fnTimer = nil

            if isHoldMode {
                isHoldMode = false
                Task { [weak self] in
                    await self?.coordinator?.stopRecording()
                }
            }
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard isEnabled, let coordinator else { return }

        // Fn+Space toggle mode (keyCode 49 = Space)
        if fnDown && event.keyCode == 49 {
            fnTimer?.cancel()
            fnTimer = nil
            isHoldMode = false

            if coordinator.state == .recording {
                Task { [weak self] in
                    await self?.coordinator?.stopRecording()
                }
            } else if coordinator.state == .idle {
                coordinator.startRecording()
            }
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
