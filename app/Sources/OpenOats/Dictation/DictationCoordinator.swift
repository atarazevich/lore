@preconcurrency import AVFoundation
import FluidAudio
import os

enum DictationState: Sendable {
    case idle
    case recording
    case processing
    case done
}

@Observable
@MainActor
final class DictationCoordinator {
    private(set) var state: DictationState = .idle
    private(set) var audioLevel: Float = 0
    private(set) var lastTranscript: String?
    private(set) var lastError: String?

    private let log = Logger(subsystem: "com.openoats", category: "DictationCoordinator")
    private var mic: MicCapture?
    private var recordingTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    private var autoHideTask: Task<Void, Never>?
    private var accumulatedSamples: [Float] = []
    private var converter: AVAudioConverter?
    private let cleanupClient = CleanupClient()

    private static let minimumSpeechSamples = 8000
    private static let maxChunkSamples = 480_000

    private var asrManager: AsrManager?
    private var isModelLoaded = false

    let history = DictationHistory()
    var settings: AppSettings?

    func startRecording() {
        guard state == .idle else { return }
        guard let settings, settings.dictationEnabled else { return }

        autoHideTask?.cancel()
        autoHideTask = nil

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
        state = .processing

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

        // STEP 1: Save audio to disk FIRST — never lose the recording
        let audioFilename = DictationHistory.saveAudio(samples)
        var entry = DictationHistoryEntry(durationSeconds: durationSeconds, audioFilename: audioFilename)
        history.add(entry)
        diagLog("[DICTATION] audio saved: \(audioFilename ?? "FAILED")")

        // STEP 2: Transcribe
        await transcribeEntry(&entry, samples: samples)

        // STEP 3: Cleanup (if enabled)
        if entry.status == .transcribed, let text = entry.rawText {
            await cleanupEntry(&entry, rawText: text)
        }

        // STEP 4: Paste result
        if let text = entry.finalText {
            lastTranscript = text
            TextInserter.paste(text)
            diagLog("[DICTATION] pasted: \(text.prefix(80))")
        }

        // Update history with final state
        history.update(entry)

        state = .done
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

    private func cleanupEntry(_ entry: inout DictationHistoryEntry, rawText: String) async {
        guard let settings, settings.dictationCleanupEnabled, !settings.openaiApiKey.isEmpty else { return }

        diagLog("[DICTATION] calling cleanup API...")
        let prompt = settings.dictationCleanupPrompt
        let apiKey = settings.openaiApiKey

        do {
            let cleaned = try await cleanupClient.cleanup(rawText: rawText, prompt: prompt, apiKey: apiKey)
            entry.cleanedText = cleaned
            entry.status = .cleaned
            diagLog("[DICTATION] cleaned: \(cleaned.prefix(80))")
        } catch {
            diagLog("[DICTATION] cleanup failed: \(error), using raw text")
        }
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
