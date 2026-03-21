@preconcurrency import AVFoundation
import FluidAudio
import os

enum DictationState: Sendable, Equatable {
    case idle
    case recording
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

    private let log = Logger(subsystem: "com.lore.app", category: "DictationCoordinator")
    private var mic: MicCapture?
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

    private var asrManager: AsrManager?
    private var isModelLoaded = false

    /// The current history entry being processed (needed for upgrades).
    private var currentEntryID: UUID?

    let history = DictationHistory()
    var settings: AppSettings?

    func startRecording() {
        // Allow starting a new recording from .done state (cancels any upgrade panel)
        guard state == .idle || state == .done else { return }
        guard let settings, settings.dictationEnabled else { return }

        autoHideTask?.cancel()
        autoHideTask = nil
        upgradeDismissTask?.cancel()
        upgradeDismissTask = nil
        isUpgradePanelVisible = false
        upgradeCountdown = nil
        currentEntryID = nil

        state = .recording
        lastError = nil
        accumulatedSamples.removeAll()
        converter = nil

        let capture = MicCapture()
        self.mic = capture

        let deviceID = settings.inputDeviceID
        let stream = capture.bufferStream(deviceID: deviceID > 0 ? deviceID : nil)

        audioLevelTask = Task { [weak self, weak capture] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let capture else { break }
                self.audioLevel = capture.audioLevel
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

        diagLog("[DICTATION] recording started")
    }

    func stopRecording() async {
        guard state == .recording else { return }

        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevel = 0

        mic?.stop()
        await recordingTask?.value
        recordingTask = nil
        mic = nil

        let samples = accumulatedSamples
        accumulatedSamples.removeAll()

        let durationSeconds = Double(samples.count) / 16000.0
        diagLog("[DICTATION] recording stopped, samples=\(samples.count), duration=\(String(format: "%.1f", durationSeconds))s")

        guard samples.count > Self.minimumSpeechSamples else {
            log.info("Too short, ignoring")
            state = .idle
            return
        }

        state = .processing

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

        // STEP 3: Determine default action and paste immediately
        let cleanupEnabled = settings?.cleanupByDefault ?? false
        let translateEnabled = settings?.translationByDefault ?? false
        let hasApiKey = !(settings?.openaiApiKey.isEmpty ?? true)
        let didCleanup: Bool

        if translateEnabled && hasApiKey {
            // Run cleanup + translate
            let basePrompt = settings?.dictationCleanupPrompt ?? CleanupMode.defaultCleanup.prompt
            let prompt = basePrompt + "\n\nAlso translate the result to English. Output only the final English text."
            await cleanupEntry(&entry, rawText: rawText, prompt: prompt)
            didCleanup = (entry.status == .cleaned)
        } else if cleanupEnabled && hasApiKey {
            // Run default cleanup only
            let prompt = settings?.dictationCleanupPrompt ?? CleanupMode.defaultCleanup.prompt
            await cleanupEntry(&entry, rawText: rawText, prompt: prompt)
            didCleanup = (entry.status == .cleaned)
        } else {
            didCleanup = false
        }

        // Paste immediately
        if let text = entry.finalText {
            lastTranscript = text
            TextInserter.paste(text)
            diagLog("[DICTATION] pasted: \(text.prefix(80))")
        }

        history.update(entry)
        state = .done

        // STEP 4: Show upgrade options (modes that differ from what was just applied)
        showUpgradeOptions(didCleanup: didCleanup)
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
            let prompt = settings?.dictationCleanupPrompt ?? CleanupMode.defaultCleanup.prompt
            mode = CleanupMode(name: "Cleanup", prompt: prompt)
        case .translate:
            let basePrompt = settings?.dictationCleanupPrompt ?? CleanupMode.defaultCleanup.prompt
            let prompt = basePrompt + "\n\nAlso translate the result to English. Output only the final English text."
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

        // Undo previous paste, then paste upgraded text
        if let text = entry.finalText {
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
        guard state == .recording else { return }
        diagLog("[DICTATION] recording discarded")
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevel = 0
        mic?.stop()
        recordingTask?.cancel()
        recordingTask = nil
        mic = nil
        accumulatedSamples.removeAll()
        state = .idle
    }

    func pasteLastTranscript() {
        guard let text = lastTranscript else { return }
        TextInserter.paste(text)
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
    }

    // MARK: - Transcription

    private func transcribeEntry(_ entry: inout DictationHistoryEntry, samples: [Float]) async {
        if !isModelLoaded {
            do {
                try await loadModel()
            } catch {
                entry.status = .failed
                entry.errorMessage = "Model loading failed: \(error.localizedDescription)"
                lastError = entry.errorMessage
                history.update(entry)
                return
            }
        }

        guard let asrManager else {
            entry.status = .failed
            entry.errorMessage = "AsrManager not available"
            history.update(entry)
            return
        }

        nonisolated(unsafe) let asr = asrManager

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
                let result = try await asr.transcribe(chunk)
                let segment = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            effectivePrompt = settings.dictationCleanupPrompt
        } else {
            return
        }

        diagLog("[DICTATION] calling cleanup API...")
        let apiKey = settings.openaiApiKey

        do {
            let cleaned = try await cleanupClient.cleanup(rawText: rawText, prompt: effectivePrompt, apiKey: apiKey)
            entry.cleanedText = cleaned
            entry.status = .cleaned
            diagLog("[DICTATION] cleaned: \(cleaned.prefix(80))")
        } catch {
            diagLog("[DICTATION] cleanup failed: \(error), using raw text")
        }
    }

    /// Run cleanup on an existing history entry with a specific mode (retroactive cleanup).
    func cleanupHistoryEntry(entryID: UUID, mode: CleanupMode) async {
        guard var entry = history.entries.first(where: { $0.id == entryID }),
              let text = entry.rawText ?? entry.cleanedText else {
            diagLog("[DICTATION] retroactive cleanup: no text for entry")
            return
        }
        guard !mode.isRawPaste else { return }

        await cleanupEntry(&entry, rawText: text, prompt: mode.prompt)
        history.update(entry)
    }

    // MARK: - Model Loading

    private func loadModel() async throws {
        diagLog("[DICTATION] loading model parakeetV3...")
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.initialize(models: models)
        self.asrManager = asr
        isModelLoaded = true
        diagLog("[DICTATION] model loaded")
    }
}
