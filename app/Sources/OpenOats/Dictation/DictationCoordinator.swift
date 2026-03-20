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

    /// Loaded lazily on first dictation use. Separate instance from TranscriptionEngine's —
    /// sharing would require refactoring TranscriptionEngine's private model lifecycle.
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

        diagLog("[DICTATION] recording stopped, samples=\(samples.count)")

        guard samples.count > Self.minimumSpeechSamples else {
            log.info("Too short, ignoring")
            state = .idle
            return
        }

        // Lazy model loading on first use
        if !isModelLoaded {
            do {
                try await loadModel()
            } catch {
                log.error("Failed to load model: \(error.localizedDescription)")
                lastError = "Model loading failed: \(error.localizedDescription)"
                state = .idle
                return
            }
        }

        guard let asrManager else {
            log.error("AsrManager not available")
            state = .idle
            return
        }

        do {
            nonisolated(unsafe) let asr = asrManager
            let result = try await asr.transcribe(samples)
            var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            diagLog("[DICTATION] raw transcription: \(text.prefix(80))")

            guard !text.isEmpty else {
                state = .idle
                return
            }

            if let settings, !settings.openRouterApiKey.isEmpty {
                diagLog("[DICTATION] calling cleanup API...")
                let rawText = text
                let prompt = settings.dictationCleanupPrompt
                let apiKey = settings.openRouterApiKey
                let client = cleanupClient
                do {
                    text = try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask {
                            try await client.cleanup(
                                rawText: rawText,
                                prompt: prompt,
                                apiKey: apiKey
                            )
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(10))
                            throw CancellationError()
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                    diagLog("[DICTATION] cleaned: \(text.prefix(80))")
                } catch {
                    diagLog("[DICTATION] cleanup failed: \(error), using raw text")
                }
            }

            // Log to history
            let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedText: String? = (text != rawText) ? text : nil
            history.add(DictationHistoryEntry(rawText: rawText, cleanedText: cleanedText))

            diagLog("[DICTATION] pasting text: \(text.prefix(80))")
            lastTranscript = text
            TextInserter.paste(text)

            state = .done

            autoHideTask?.cancel()
            autoHideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, self.state == .done else { return }
                self.state = .idle
            }
        } catch {
            log.error("Transcription failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            state = .idle
        }
    }

    func pasteLastTranscript() {
        guard let text = lastTranscript else { return }
        TextInserter.paste(text)
    }

    // MARK: - Model Loading

    private func loadModel() async throws {
        // Dictation always uses Parakeet v3 — fastest and best quality from benchmarks
        diagLog("[DICTATION] loading model parakeetV3...")
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.initialize(models: models)
        self.asrManager = asr
        isModelLoaded = true
        diagLog("[DICTATION] model loaded")
    }
}
