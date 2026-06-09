@preconcurrency import AVFoundation
import os

enum DictationState: Sendable, Equatable {
    case idle
    case recording
    case loadingModel
    case processing
    case done
}

enum UpgradeAction: Sendable {
    case cleanup
    case translate
}

@Observable
@MainActor
final class DictationCoordinator {
    private(set) var state: DictationState = .idle
    private(set) var audioLevel: Float = 0
    private(set) var lastTranscript: String?
    private(set) var lastError: String?
    /// Whether the upgrade panel (C/T buttons) is visible after initial paste.
    private(set) var isUpgradePanelVisible = false
    /// Whether cleanup was already applied (hides [C] button, only shows [T]).
    private(set) var cleanupAlreadyApplied = false
    /// Countdown remaining for upgrade auto-dismiss (seconds). Nil when not showing.
    private(set) var upgradeCountdown: Double?
    /// Pre-paste cleanup mode set during recording via Fn+V/Fn+T.
    private(set) var pendingCleanupMode: UpgradeAction?
    /// True while audio is being buffered before hold is confirmed (pre-buffer phase).
    private(set) var isPreBuffering = false
    /// True when a wireless default input was detected and capture redirected to built-in mic.
    private(set) var bluetoothMicRedirected = false
    /// True when the audio bus reports zero signal (dead mic input).
    private(set) var noSignal = false

    private let log = Logger(subsystem: "com.lore.app", category: "DictationCoordinator")
    private var busConsumerID: UUID?
    private var recordingTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    private var autoHideTask: Task<Void, Never>?
    private var upgradeDismissTask: Task<Void, Never>?
    private var accumulatedSamples: [Float] = []
    private var converter: AVAudioConverter?
    private let cleanupClient = CleanupClient()

    private static let minimumSpeechSamples = 8000
    private static let maxChunkSamples = 480_000
    static let upgradePanelDuration: Double = 3.0

    /// Shared audio bus — set by AppDelegate during dictation setup.
    var audioBus: AudioBus?

    /// Shared backend cache — set by AppDelegate during dictation setup.
    var backendCache: SharedBackendCache?

    /// Private backend instance for dictation transcription.
    /// Separate from the shared cache to avoid concurrent decoder state mutation
    /// when TranscriptionEngine also transcribes via the shared backend.
    private var ownBackend: (any TranscriptionBackend)?
    private var ownBackendModel: TranscriptionModel?

    /// The current history entry being processed (needed for upgrades).
    private var currentEntryID: UUID?

    let history = DictationHistory()
    var settings: AppSettings?

    /// Start capturing audio silently before hold is confirmed (pre-buffer phase).
    /// State stays .idle — indicator does not show yet.
    func startPreBuffer() {
        guard !isPreBuffering else { return }
        guard state == .idle || state == .done else { return }
        if settings == nil {
            diagLog("[DICTATION] WARNING: settings not wired — dictation disabled")
        }
        guard let settings, settings.dictationEnabled else { return }

        autoHideTask?.cancel()
        autoHideTask = nil
        upgradeDismissTask?.cancel()
        upgradeDismissTask = nil
        isUpgradePanelVisible = false
        upgradeCountdown = nil
        currentEntryID = nil
        pendingCleanupMode = nil

        lastError = nil
        accumulatedSamples.removeAll()
        converter = nil
        isPreBuffering = true

        startMicCapture()
        diagLog("[DICTATION] pre-buffering started")
    }

    /// Confirm that the hold gesture was detected — transition to visible recording.
    func confirmRecording() {
        guard isPreBuffering else { return }
        isPreBuffering = false
        state = .recording
        diagLog("[DICTATION] recording confirmed (pre-buffer kept)")
    }

    /// Cancel pre-buffer (user tapped instead of holding).
    func cancelPreBuffer() {
        guard isPreBuffering else { return }
        isPreBuffering = false
        stopMicCapture()
        accumulatedSamples.removeAll()
        diagLog("[DICTATION] pre-buffer discarded (tap)")
    }

    func stopRecording() async {
        guard state == .recording else { return }

        // Audio tail: keep recording 300ms to capture trailing speech
        try? await Task.sleep(for: .milliseconds(300))

        // Re-check state — may have been discarded during the tail
        guard state == .recording else { return }

        stopMicCapture()

        let samples = accumulatedSamples
        accumulatedSamples.removeAll()

        let durationSeconds = Double(samples.count) / 16000.0
        diagLog("[DICTATION] recording stopped, samples=\(samples.count), duration=\(String(format: "%.1f", durationSeconds))s")

        guard samples.count > Self.minimumSpeechSamples else {
            log.info("Too short, ignoring")
            state = .idle
            return
        }

        // STEP 1: Save audio to disk FIRST — never lose the recording
        let audioFilename = DictationHistory.saveAudio(samples)
        var entry = DictationHistoryEntry(durationSeconds: durationSeconds, audioFilename: audioFilename)
        history.add(entry)
        currentEntryID = entry.id
        diagLog("[DICTATION] audio saved: \(audioFilename ?? "FAILED")")

        // STEP 2: Transcribe
        await transcribeEntry(&entry, samples: samples)

        guard entry.status == .transcribed, let rawText = entry.rawText else {
            // Transcription failed — update history, go to done briefly
            history.update(entry)
            state = .done
            scheduleAutoHide()
            return
        }

        // STEP 3: Determine cleanup action (pre-paste mode > defaults) and run
        let pending = pendingCleanupMode
        pendingCleanupMode = nil
        let cleanupEnabled = settings?.cleanupByDefault ?? false
        let translateEnabled = settings?.translationByDefault ?? false
        let hasApiKey = !(settings?.openaiApiKey.isEmpty ?? true)
        let didCleanup: Bool

        if let pending, hasApiKey {
            // Pre-paste mode set via Fn+V/Fn+T during recording — overrides defaults
            let basePrompt = settings?.activeCleanupPrompt ?? CleanupMode.cleanPrompt
            switch pending {
            case .cleanup:
                await cleanupEntry(&entry, rawText: rawText, prompt: basePrompt)
                entry.cleanupModeName = "Cleanup"
            case .translate:
                let prompt = basePrompt + CleanupMode.translateSuffix
                await cleanupEntry(&entry, rawText: rawText, prompt: prompt)
                entry.cleanupModeName = "Translate"
            }
            didCleanup = (entry.status == .cleaned)
        } else if translateEnabled && hasApiKey {
            // Default: cleanup + translate
            let basePrompt = settings?.activeCleanupPrompt ?? CleanupMode.cleanPrompt
            let prompt = basePrompt + CleanupMode.translateSuffix
            await cleanupEntry(&entry, rawText: rawText, prompt: prompt)
            entry.cleanupModeName = "Translate"
            didCleanup = (entry.status == .cleaned)
        } else if cleanupEnabled && hasApiKey {
            // Default: cleanup only
            let prompt = settings?.activeCleanupPrompt ?? CleanupMode.cleanPrompt
            await cleanupEntry(&entry, rawText: rawText, prompt: prompt)
            entry.cleanupModeName = "Cleanup"
            didCleanup = (entry.status == .cleaned)
        } else {
            didCleanup = false
        }

        // Paste immediately (always paste the best version)
        if let text = entry.cleanedText ?? entry.rawText {
            lastTranscript = text
            TextInserter.paste(text)
            diagLog("[DICTATION] pasted: \(text.prefix(80))")
        }

        history.update(entry)
        state = .done

        // STEP 4: Show upgrade options — skip if user explicitly chose a pre-paste mode
        if pending != nil {
            scheduleAutoHide()
        } else {
            showUpgradeOptions(didCleanup: didCleanup)
        }
    }

    // MARK: - Upgrade Panel

    /// Show upgrade panel if API key is available.
    private func showUpgradeOptions(didCleanup: Bool) {
        let hasApiKey = !(settings?.openaiApiKey.isEmpty ?? true)

        guard hasApiKey else {
            // No upgrades possible — just auto-hide after brief checkmark
            scheduleAutoHide()
            return
        }

        isUpgradePanelVisible = true
        cleanupAlreadyApplied = didCleanup
        upgradeCountdown = Self.upgradePanelDuration

        // Start countdown timer for auto-dismiss
        upgradeDismissTask?.cancel()
        upgradeDismissTask = Task { [weak self] in
            let steps = 30
            let stepDuration = Self.upgradePanelDuration / Double(steps)
            for i in 1...steps {
                do {
                    try await Task.sleep(for: .milliseconds(Int(stepDuration * 1000)))
                } catch {
                    return // Cancelled
                }
                guard let self, self.isUpgradePanelVisible else { return }
                self.upgradeCountdown = Self.upgradePanelDuration - (Double(i) * stepDuration)
            }
            guard let self, self.isUpgradePanelVisible else { return }
            self.dismissUpgrades()
        }
    }

    /// Called when user selects an upgrade via hotkey or button.
    func applyUpgradeByKey(_ action: UpgradeAction) async {
        guard isUpgradePanelVisible else { return }

        let mode: CleanupMode
        switch action {
        case .cleanup:
            let prompt = settings?.activeCleanupPrompt ?? CleanupMode.cleanPrompt
            mode = CleanupMode(name: "Cleanup", prompt: prompt)
        case .translate:
            let basePrompt = settings?.activeCleanupPrompt ?? CleanupMode.cleanPrompt
            let prompt = basePrompt + CleanupMode.translateSuffix
            mode = CleanupMode(name: "Translate", prompt: prompt)
        }

        await applyUpgrade(mode)
    }

    /// Called when user clicks an upgrade button.
    func applyUpgrade(_ mode: CleanupMode) async {
        upgradeDismissTask?.cancel()
        upgradeDismissTask = nil
        isUpgradePanelVisible = false
        upgradeCountdown = nil

        guard let entryID = currentEntryID,
              var entry = history.entries.first(where: { $0.id == entryID }),
              let rawText = entry.rawText else {
            diagLog("[DICTATION] upgrade failed: no entry or raw text")
            scheduleAutoHide()
            return
        }

        state = .processing
        diagLog("[DICTATION] applying upgrade: \(mode.name)")

        // Run cleanup on the raw text with the upgrade mode's prompt
        await cleanupEntry(&entry, rawText: rawText, prompt: mode.prompt)
        entry.cleanupModeName = mode.name

        // Undo previous paste, then paste upgraded text
        if let text = entry.cleanedText ?? entry.rawText {
            lastTranscript = text
            TextInserter.undoAndPaste(text)
            diagLog("[DICTATION] upgrade pasted (undo+paste): \(text.prefix(80))")
        }

        history.update(entry)
        state = .done
        scheduleAutoHide()
    }

    /// Dismiss upgrade panel without action.
    func dismissUpgrades() {
        upgradeDismissTask?.cancel()
        upgradeDismissTask = nil
        isUpgradePanelVisible = false
        upgradeCountdown = nil
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, self.state == .done else { return }
            self.state = .idle
        }
    }

    func discardRecording() {
        if isPreBuffering {
            cancelPreBuffer()
            return
        }
        guard state == .recording || state == .loadingModel || state == .processing else { return }
        diagLog("[DICTATION] discarded from state: \(state)")
        stopMicCapture()
        accumulatedSamples.removeAll()
        pendingCleanupMode = nil
        state = .idle
    }

    // MARK: - Mic Helpers

    private func startMicCapture() {
        guard let bus = audioBus else {
            diagLog("[DICTATION] WARNING: audioBus not wired")
            return
        }

        // One device selection per recording, via transport allowlist on a fresh
        // enumeration (#39). The result is pinned — no mid-recording switching.
        let requestedDevice = settings?.inputDeviceID ?? 0
        let selection = AudioBus.resolveBestInputDevice(requested: requestedDevice)
        bluetoothMicRedirected = selection?.redirectedToBuiltIn ?? false

        let (id, stream) = bus.subscribe(deviceID: selection?.deviceID)
        busConsumerID = id

        audioLevelTask = Task { [weak self, weak bus] in
            var everHadSignal = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let bus else { break }
                self.audioLevel = bus.audioLevel

                if bus.hasSignal { everHadSignal = true }

                // Show "no audio" indicator if we've captured frames but never had signal
                // (truly dead mic), or if the bus reports a capture failure (pinned device
                // died mid-recording and retries are failing/exhausted). Don't show it for
                // normal silence gaps — voice isolation produces digital silence between
                // speech, which is not a mic problem.
                // The device stays pinned — warn honestly, never hop devices (#39).
                let shouldShowNoSignal = (bus.hasCapturedFrames && !everHadSignal)
                    || bus.captureError != nil
                if self.noSignal != shouldShowNoSignal {
                    self.noSignal = shouldShowNoSignal
                }
            }
        }

        recordingTask = Task { [weak self] in
            for await buffer in stream {
                guard let self, !Task.isCancelled else { break }
                if let samples = AudioUtils.extractSamples(buffer, converter: &self.converter) {
                    self.accumulatedSamples.append(contentsOf: samples)
                }
            }
        }
    }

    private func stopMicCapture() {
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevel = 0
        if let id = busConsumerID {
            audioBus?.unsubscribe(id)
            busConsumerID = nil
        }
        recordingTask?.cancel()
        recordingTask = nil
        bluetoothMicRedirected = false
        noSignal = false
    }

    /// Toggle pre-paste cleanup mode during recording.
    /// Same action twice → off. Different action → replaces.
    func setPendingMode(_ action: UpgradeAction) {
        guard state == .recording else { return }
        if pendingCleanupMode == action {
            pendingCleanupMode = nil
        } else {
            pendingCleanupMode = action
        }
        diagLog("[DICTATION] pending mode: \(pendingCleanupMode.map { "\($0)" } ?? "none")")
    }

    func pasteLastTranscript() {
        // Respect activeVersion of the most recent entry
        if let entry = history.entries.first, let text = entry.displayText {
            TextInserter.paste(text)
        } else if let text = lastTranscript {
            TextInserter.paste(text)
        }
    }

    /// Retry transcription for a failed or audio-only entry
    func retryTranscription(entryID: UUID) async {
        guard var entry = history.entries.first(where: { $0.id == entryID }),
              let filename = entry.audioFilename,
              let samples = DictationHistory.loadAudio(filename: filename) else {
            diagLog("[DICTATION] retry failed: no audio for entry")
            return
        }

        entry.status = .audioSaved
        entry.rawText = nil
        entry.cleanedText = nil
        entry.errorMessage = nil
        history.update(entry)

        await transcribeEntry(&entry, samples: samples)

        if entry.status == .transcribed, let text = entry.rawText {
            await cleanupEntry(&entry, rawText: text)
        }

        history.update(entry)

        if entry.status == .transcribed || entry.status == .cleaned {
            state = .done
            scheduleAutoHide()
        } else {
            state = .idle
        }
    }

    // MARK: - Transcription

    private func transcribeEntry(_ entry: inout DictationHistoryEntry, samples: [Float]) async {
        let model = settings?.transcriptionModel ?? .parakeetV3
        let locale = settings?.locale ?? .current

        // Ensure the shared cache has downloaded model files (fast no-op if already cached)
        if let cache = backendCache {
            do {
                try await cache.prepare(model: model) { [weak self] status in
                    Task { @MainActor in self?.state = .loadingModel }
                }
            } catch {
                entry.status = .failed
                entry.errorMessage = "Model loading failed: \(error.localizedDescription)"
                lastError = entry.errorMessage
                history.update(entry)
                return
            }
        } else {
            diagLog("[DICTATION] backendCache nil — dictation setup may not have run")
        }

        // Use a private backend instance to avoid sharing mutable decoder state
        // with TranscriptionEngine's backend from the shared cache.
        // Creating a fresh backend when model files are already on disk is fast (~1s).
        if ownBackend == nil || ownBackendModel != model {
            diagLog("[DICTATION] creating private backend for \(model.rawValue)")
            let fresh = model.makeBackend()
            do {
                try await fresh.prepare(onStatus: { _ in }, onProgress: { _ in })
            } catch {
                entry.status = .failed
                entry.errorMessage = "Backend prepare failed: \(error.localizedDescription)"
                lastError = entry.errorMessage
                history.update(entry)
                return
            }
            ownBackend = fresh
            ownBackendModel = model
        }

        guard let backend = ownBackend else {
            entry.status = .failed
            entry.errorMessage = "Backend not available after prepare"
            history.update(entry)
            return
        }

        state = .processing

        // Build chunks, merging short tails into the previous chunk
        var chunks: [[Float]] = []
        for start in stride(from: 0, to: samples.count, by: Self.maxChunkSamples) {
            let end = min(start + Self.maxChunkSamples, samples.count)
            let chunk = Array(samples[start..<end])
            if chunk.count < Self.minimumSpeechSamples && !chunks.isEmpty {
                chunks[chunks.count - 1].append(contentsOf: chunk)
            } else {
                chunks.append(chunk)
            }
        }

        diagLog("[DICTATION] transcribing \(chunks.count) chunk(s), total \(samples.count) samples")
        var segments: [String] = []

        for (i, chunk) in chunks.enumerated() {
            do {
                let segment = try await backend.transcribe(chunk, locale: locale, previousContext: nil)
                if !segment.isEmpty {
                    segments.append(segment)
                    diagLog("[DICTATION] chunk \(i+1)/\(chunks.count): \(segment.prefix(60))")
                }
            } catch {
                diagLog("[DICTATION] chunk \(i+1)/\(chunks.count) failed: \(error), skipping")
            }
        }

        let text = segments.joined(separator: " ")
        if text.isEmpty {
            entry.status = .failed
            entry.errorMessage = "Transcription produced empty result"
        } else {
            entry.status = .transcribed
            entry.rawText = text
            diagLog("[DICTATION] raw transcription: \(text)")
        }
    }

    private func cleanupEntry(_ entry: inout DictationHistoryEntry, rawText: String, prompt: String? = nil) async {
        guard let settings, !settings.openaiApiKey.isEmpty else { return }

        let effectivePrompt: String
        if let prompt, !prompt.isEmpty {
            effectivePrompt = prompt
        } else if settings.cleanupByDefault {
            effectivePrompt = settings.activeCleanupPrompt
        } else {
            return
        }

        diagLog("[DICTATION] calling cleanup API...")
        let apiKey = settings.openaiApiKey

        do {
            let cleaned = try await cleanupClient.cleanup(rawText: rawText, prompt: effectivePrompt, apiKey: apiKey)
            entry.cleanedText = cleaned
            entry.status = .cleaned
            entry.activeVersion = .cleaned
            diagLog("[DICTATION] cleaned: \(cleaned.prefix(80))")
        } catch {
            diagLog("[DICTATION] cleanup failed: \(error), using raw text")
        }
    }

    /// Run cleanup on an existing history entry with a specific mode (retroactive cleanup).
    /// Always cleans from the raw transcription to preserve the original.
    func cleanupHistoryEntry(entryID: UUID, mode: CleanupMode) async {
        guard var entry = history.entries.first(where: { $0.id == entryID }),
              let text = entry.rawText else {
            diagLog("[DICTATION] retroactive cleanup: no raw text for entry")
            return
        }
        guard !mode.isRawPaste else { return }

        await cleanupEntry(&entry, rawText: text, prompt: mode.prompt)
        entry.cleanupModeName = mode.name
        history.update(entry)
    }

}
