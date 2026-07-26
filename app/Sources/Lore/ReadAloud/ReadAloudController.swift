import AVFoundation
import Foundation
import NaturalLanguage
import os

/// Read Aloud (#105): selected text → Speechify TTS → queued playback.
///
/// The unit of the queue is a *text* (one Fn+R/Fn+Q capture); `runTexts[0]`
/// is always the text being played, everything after it is the "Next up"
/// queue — reorderable, removable, jumpable (rev 3). Each text is split at
/// sentence boundaries into chunks — a small first chunk so speech starts
/// fast (measured: ~250 chars downloads in ~2.5 s, experiments/tts/), larger
/// ones after. Chunks are synthesized strictly in play order (order matters,
/// and rate limits exist) and written to temp MP3 files; only the current
/// text's chunks are enqueued on the `AVQueuePlayer`, so queue edits never
/// have to fish items back out of the player. Every item plays with
/// `.timeDomain` time-pitch: the 0.5x–3x rate never shifts pitch and never
/// re-bills synthesis.
@Observable
@MainActor
final class ReadAloudController {

    enum Status: Equatable, Sendable {
        case idle
        /// Session exists but no audio is ready to play (first chunk in
        /// flight, or playback starved the synthesis prefetch).
        case fetching
        case playing
        case paused
    }

    /// One captured text in the run. `audio` grows as its chunks synthesize.
    struct QueueText: Identifiable, Sendable {
        let id: UUID
        let text: String
        let snippet: String
        let chars: Int
        let chunks: [String]
        let voice: VoiceSelection
        var audio: [ChunkAudio] = []

        init(text: String, voice: VoiceSelection) {
            self.id = UUID()
            self.text = text
            self.snippet = ReadAloudController.snippet(of: text)
            self.chars = text.count
            self.chunks = ReadAloudController.chunk(text)
            self.voice = voice
        }

        var isFullySynthesized: Bool { audio.count >= chunks.count }
        var totalSeconds: Double? {
            isFullySynthesized ? audio.reduce(0) { $0 + $1.seconds } : nil
        }
    }

    struct ChunkAudio: Sendable {
        let url: URL
        let seconds: Double
    }

    /// The engine, voice, model and language a text will be synthesized
    /// with — resolved once at capture time from the detected language.
    struct VoiceSelection: Equatable, Sendable {
        let engine: ReadAloudEngine
        let voiceID: String
        let displayName: String
        let initial: String
        /// Speechify model name; "system" for the local engine.
        let model: String
        /// Speechify language pin (ru-RU), or the detected code the system
        /// engine's auto pick uses.
        let languageParam: String?
        let languageName: String
    }

    /// Languages with a dedicated voice setting; everything else carries its
    /// detected code for the system auto pick. The seam for more languages:
    /// one case + one settings field + one `resolveVoice` arm.
    enum TextLanguage: Equatable, Sendable {
        case russian
        case english
        case other(String?)
    }

    private(set) var status: Status = .idle
    /// Transient panel message (no text, over limit, API failure). Coexists
    /// with an active session — a failed Fn+Q must not hide the controls.
    private(set) var notice: String?
    /// Pitch-preserving playback rate. Seeded from Settings per session.
    private(set) var rate: Double = 1.0
    /// The run: `[0]` is playing (or fetching), the rest is "Next up".
    private(set) var runTexts: [QueueText] = []

    var isSessionActive: Bool { player != nil }
    var currentText: QueueText? { runTexts.first }
    var upcomingTexts: [QueueText] { Array(runTexts.dropFirst()) }
    /// Drives the queue chip (visible only when non-zero) and enables ⏭.
    var pendingCount: Int { max(0, runTexts.count - 1) }
    var currentSnippet: String? { currentText?.snippet }
    var currentVoice: VoiceSelection? { currentText?.voice }

    /// Seconds of the current text already spoken (content time — rate does
    /// not change it): completed chunks' real durations plus the playing
    /// chunk's position.
    var elapsedSeconds: Double {
        guard let player, let item = player.currentItem,
              let secondsBefore = itemStartSeconds[ObjectIdentifier(item)] else { return 0 }
        let t = item.currentTime().seconds
        return secondsBefore + (t.isFinite ? max(t, 0) : 0)
    }

    /// Real duration of the current text — nil until all its chunks are
    /// synthesized (durations of unsynthesized chunks are unknowable).
    var totalSeconds: Double? { currentText?.totalSeconds }

    /// Progress through the current text: elapsed over the real total once
    /// every chunk is synthesized, over the ~17 chars/sec estimate until then.
    var currentProgress: Double {
        guard let current = currentText else { return 0 }
        let total = current.totalSeconds ?? Double(current.chars) / Self.charsPerSecond
        guard total > 0 else { return 0 }
        return min(max(elapsedSeconds / total, 0), 1)
    }

    var settings: AppSettings?
    private let speechifySynthesizer: any SpeechSynthesizing
    private let systemSynthesizer: any SpeechSynthesizing
    private let log = Logger(subsystem: "com.lore.app", category: "ReadAloud")

    // MARK: - Session state

    private var player: AVQueuePlayer?
    private var synthesisTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    /// Written once in init, read in deinit — `nonisolated(unsafe)` so the
    /// nonisolated deinit can remove it (NotificationCenter is thread-safe).
    @ObservationIgnored nonisolated(unsafe) private var endObserver: NSObjectProtocol?

    /// Seconds of the current text spoken before each live player item starts.
    private var itemStartSeconds: [ObjectIdentifier: Double] = [:]

    /// True when the synthesis loop found nothing left to synthesize and exited.
    private var synthesisDone = true
    /// Bumped on every teardown; async work from an older session must not land.
    private var sessionEpoch = 0
    /// Set when dictation paused playback — only that pause may auto-resume.
    private var pausedByDictation = false

    nonisolated static let speedSteps: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]
    nonisolated static let defaultCharLimit = 20_000
    /// Speech averages ~17 chars/sec at 1x — the queue rows' estimate.
    nonisolated static let charsPerSecond = 17.0

    /// Both engines are injectable (mirrors DictationCoordinator's cleanupClient).
    init(
        synthesizer: any SpeechSynthesizing = SpeechifyClient(),
        systemSynthesizer: any SpeechSynthesizing = SystemSpeechSynthesizer()
    ) {
        self.speechifySynthesizer = synthesizer
        self.systemSynthesizer = systemSynthesizer
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            // Deferred a tick so AVQueuePlayer has advanced past the ended item.
            // Foreign players (NotesController audio) also land here; the state
            // check below is a no-op for them.
            Task { @MainActor in self?.playerAdvanced() }
        }
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    // MARK: - Hotkey entry points

    /// Fn+R: stop the current reading, clear the queue, read the new
    /// selection. A failed capture leaves the current session playing —
    /// a miss must not destroy what the user is listening to.
    func readSelectionNow() async {
        let captured = await TextInserter.copySelection()
        let validation = validateCaptured(captured)
        switch validation {
        case .ok(let text):
            startSession(with: text)
        case .empty, .unreadable, .overLimit:
            showNotice(Self.validationNotice(for: validation))
        }
    }

    /// Fn+Q: append the selection to the queue; identical to read-now when
    /// no session is active.
    func enqueueSelection() async {
        let captured = await TextInserter.copySelection()
        let validation = validateCaptured(captured)
        switch validation {
        case .ok(let text):
            if isSessionActive {
                if let queueText = admit(text) {
                    runTexts.append(queueText)
                    ensureSynthesisLoop()
                }
            } else {
                startSession(with: text)
            }
        case .empty, .unreadable, .overLimit:
            showNotice(Self.validationNotice(for: validation))
        }
    }

    // MARK: - Panel controls

    func togglePlayPause() {
        guard let player else { return }
        pausedByDictation = false
        switch status {
        case .playing:
            player.pause()
            status = .paused
        case .paused:
            player.rate = Float(rate)
            status = .playing
        case .idle, .fetching:
            break
        }
    }

    func cycleSpeed() {
        rate = Self.nextSpeed(after: rate)
        // The panel's speed *is* the persisted default — one knob, no drift.
        settings?.readAloudSpeed = rate
        if status == .playing {
            player?.rate = Float(rate)
        }
    }

    /// ⏮ — restart the current text from its first chunk. Playing keeps
    /// playing, paused stays paused (parked at the start).
    func restartCurrentText() {
        loadCurrentTextIntoPlayer(startPlaying: status == .playing || status == .fetching)
    }

    /// ⏭ — skip to the next queued text. No-op when nothing is queued
    /// (the panel disables the control).
    func skipToNextText() {
        guard runTexts.count > 1 else { return }
        playQueuedNow(id: runTexts[1].id)
    }

    /// ▶ on a queue row: abandon the current text, promote this one, play.
    func playQueuedNow(id: UUID) {
        guard let position = runTexts.firstIndex(where: { $0.id == id }), position > 0 else { return }
        let target = runTexts.remove(at: position)
        let abandoned = runTexts.removeFirst()
        deleteAudioFiles(of: abandoned)
        runTexts.insert(target, at: 0)
        loadCurrentTextIntoPlayer(startPlaying: true)
        ensureSynthesisLoop()
    }

    /// Trash on a queue row: drop a queued text (never the playing one).
    func removeQueued(id: UUID) {
        guard let position = runTexts.firstIndex(where: { $0.id == id }), position > 0 else { return }
        let removed = runTexts.remove(at: position)
        deleteAudioFiles(of: removed)
    }

    /// Drag-handle reorder within "Next up". Offsets are positions inside
    /// `upcomingTexts` (0-based); out-of-range targets clamp.
    func moveQueued(fromOffset: Int, toOffset: Int) {
        let upcoming = runTexts.count - 1
        guard upcoming > 1, fromOffset >= 0, fromOffset < upcoming else { return }
        let clampedTo = min(max(toOffset, 0), upcoming - 1)
        guard clampedTo != fromOffset else { return }
        let item = runTexts.remove(at: fromOffset + 1)
        runTexts.insert(item, at: clampedTo + 1)
    }

    /// Close button / end of queue: drop the session. A notice (if showing)
    /// survives so the panel can finish saying what went wrong.
    func stop() {
        teardownSession()
        status = .idle
    }

    // MARK: - Dictation interplay (#105)

    /// Dictation capture is about to open the mic (pre-buffer start) — pause
    /// before any TTS output can enter the buffer.
    func pauseForDictation() {
        guard status == .playing else { return }
        player?.pause()
        status = .paused
        pausedByDictation = true
    }

    /// Dictation capture ended. Auto-resume only from this controller's own
    /// pause (never a manual one). A `cancelled` gesture (Fn tap under 150 ms
    /// — the recording was never confirmed) is not a dictation, so it always
    /// resumes; a real dictation end resumes only when the setting opts in.
    func dictationEnded(cancelled: Bool) {
        let shouldResume = pausedByDictation
            && (cancelled || (settings?.readAloudResumeAfterDictation ?? false))
        pausedByDictation = false
        guard shouldResume, status == .paused, let player else { return }
        player.rate = Float(rate)
        status = .playing
    }

    // MARK: - Session lifecycle

    private func startSession(with text: String) {
        teardownSession()
        guard let settings else {
            log.error("settings not wired — read aloud disabled")
            return
        }
        guard let queueText = admit(text) else { return }

        let storedSpeed = settings.readAloudSpeed
        rate = Self.speedSteps.contains { abs($0 - storedSpeed) < 0.001 } ? storedSpeed : 1.0

        let player = AVQueuePlayer()
        player.actionAtItemEnd = .advance
        self.player = player
        status = .fetching
        runTexts = [queueText]
        ensureSynthesisLoop()
    }

    /// Build a QueueText from a validated capture: chunking plus the
    /// language → voice resolution (free-first: no key means system voices),
    /// frozen at capture time.
    private func admit(_ text: String) -> QueueText? {
        guard let settings else { return nil }
        let voice = Self.resolveVoice(
            for: text,
            mode: settings.readAloudVoiceMode,
            ru: settings.readAloudVoiceRu,
            en: settings.readAloudVoiceEn,
            other: settings.readAloudVoiceOther,
            single: settings.readAloudVoiceSingle,
            hasSpeechifyKey: !settings.speechifyApiKey.isEmpty
        )
        return QueueText(text: text, voice: voice)
    }

    private func teardownSession() {
        sessionEpoch += 1
        synthesisTask?.cancel()
        synthesisTask = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        itemStartSeconds.removeAll()
        for text in runTexts {
            deleteAudioFiles(of: text)
        }
        runTexts = []
        synthesisDone = true
        pausedByDictation = false
    }

    private func deleteAudioFiles(of text: QueueText) {
        for chunk in text.audio {
            try? FileManager.default.removeItem(at: chunk.url)
        }
    }

    // MARK: - Synthesis loop

    /// One sequential loop, one chunk per iteration, always the earliest
    /// text in play order with unsynthesized chunks — never fanned out
    /// (order matters, and so do Speechify rate limits). Re-evaluating per
    /// chunk is what makes reorder / remove / play-now naturally reprioritize
    /// synthesis. Restarted by Fn+Q when a previous loop drained.
    private func ensureSynthesisLoop() {
        guard synthesisDone else { return } // a live loop re-evaluates anyway
        guard let settings else { return }
        synthesisDone = false
        let epoch = sessionEpoch
        let apiKey = settings.speechifyApiKey

        synthesisTask = Task { [weak self] in
            while true {
                guard let self, self.sessionEpoch == epoch, !Task.isCancelled else { return }
                guard let work = self.runTexts.first(where: { !$0.isFullySynthesized }) else { break }
                let chunkText = work.chunks[work.audio.count]
                do {
                    let url = try await self.synthesizeWithDiagnostics(
                        chunkText, voice: work.voice, apiKey: apiKey
                    )
                    guard self.sessionEpoch == epoch, !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: url)
                        return
                    }
                    await self.registerAudio(url, for: work.id)
                    guard self.sessionEpoch == epoch, !Task.isCancelled else { return }
                } catch {
                    guard self.sessionEpoch == epoch else { return }
                    self.log.error("synthesis failed: \(error.localizedDescription, privacy: .public)")
                    self.showNotice(Self.failureNotice(for: error))
                    // Stop synthesizing; keep playing whatever audio exists
                    // rather than going silent mid-word.
                    self.synthesisDone = true
                    if self.player?.items().isEmpty != false, self.status == .fetching {
                        // Nothing ever reached the player — no playback is coming.
                        self.stop()
                    }
                    return
                }
            }
            guard let self, self.sessionEpoch == epoch else { return }
            self.synthesisDone = true
        }
    }

    /// Speechify: retried per #103's transient discipline, one `apiCall`
    /// event per attempt (retries show as failed→ok sequences). The system
    /// engine is local — no network, no retries, no API-call diagnostics.
    private func synthesizeWithDiagnostics(
        _ text: String, voice: VoiceSelection, apiKey: String
    ) async throws -> URL {
        guard voice.engine == .speechify else {
            return try await systemSynthesizer.synthesize(
                text: text, voice: voice.voiceID, model: voice.model,
                language: voice.languageParam, apiKey: ""
            )
        }
        return try await DictationCoordinator.withRetries(
            attempts: DictationCoordinator.retryAttempts,
            backoff: [.milliseconds(500), .seconds(1)],
            isTransient: SpeechifyClient.isTransient
        ) {
            let startedAt = Date()
            do {
                let url = try await speechifySynthesizer.synthesize(
                    text: text,
                    voice: voice.voiceID,
                    model: voice.model,
                    language: voice.languageParam,
                    apiKey: apiKey
                )
                DiagStore.record(.apiCall(
                    endpoint: .readAloud,
                    outcome: .ok,
                    httpStatus: nil,
                    ms: Int(Date().timeIntervalSince(startedAt) * 1000)
                ))
                return url
            } catch {
                DiagStore.record(.apiCall(
                    endpoint: .readAloud,
                    outcome: .failed,
                    httpStatus: SpeechifyClient.httpStatus(from: error),
                    ms: Int(Date().timeIntervalSince(startedAt) * 1000)
                ))
                throw error
            }
        }
    }

    // MARK: - Playback plumbing

    /// Measure the synthesized file's real duration, attach it to its text
    /// and — when that text is the current one — enqueue it on the player.
    /// A text that left the queue while the duration loaded just drops the
    /// file; the synthesis loop re-evaluates.
    private func registerAudio(_ url: URL, for textID: UUID) async {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let seconds = duration.isFinite ? max(duration, 0) : 0

        // Re-resolve after the awaits: the text may have been removed or the
        // session torn down while the duration loaded.
        guard let index = runTexts.firstIndex(where: { $0.id == textID }) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let audio = ChunkAudio(url: url, seconds: seconds)
        runTexts[index].audio.append(audio)

        guard index == 0, let player else { return }

        let earlier = runTexts[0].audio.dropLast()
        insertItem(
            for: audio, startSeconds: earlier.reduce(0) { $0 + $1.seconds }, into: player
        )

        switch status {
        case .fetching:
            // First audio of the session, or recovery from starvation.
            status = .playing
            player.playImmediately(atRate: Float(rate))
        case .playing where player.rate == 0:
            // The queue drained between chunks while nominally playing.
            player.playImmediately(atRate: Float(rate))
        default:
            break
        }
    }

    private func insertItem(
        for audio: ChunkAudio, startSeconds: Double, into player: AVQueuePlayer
    ) {
        let item = AVPlayerItem(url: audio.url)
        // Pitch-preserving rate — the whole point of client-side speed.
        item.audioTimePitchAlgorithm = .timeDomain
        itemStartSeconds[ObjectIdentifier(item)] = startSeconds
        player.insert(item, after: nil)
    }

    /// Rebuild the player from the current text's synthesized chunks —
    /// the one primitive behind ⏮, ⏭, and queue-row play-now.
    private func loadCurrentTextIntoPlayer(startPlaying: Bool) {
        guard let player, let current = runTexts.first else { return }
        player.pause()
        player.removeAllItems()
        itemStartSeconds.removeAll()

        var secondsBefore = 0.0
        for audio in current.audio {
            insertItem(for: audio, startSeconds: secondsBefore, into: player)
            secondsBefore += audio.seconds
        }

        if player.items().isEmpty {
            // Target text has no audio yet — the loop's next register starts it.
            status = .fetching
        } else if startPlaying {
            status = .playing
            player.playImmediately(atRate: Float(rate))
        }
        // Otherwise paused stays paused, parked at the start.
    }

    /// After an item ends: keep the rate applied across item transitions and
    /// detect the end of the current text / the whole run.
    private func playerAdvanced() {
        guard let player else { return }
        if player.currentItem != nil {
            if status == .playing, player.rate == 0 {
                player.rate = Float(rate)
            }
        } else if status == .playing || status == .fetching {
            guard let current = runTexts.first else {
                stop()
                return
            }
            if current.isFullySynthesized {
                advanceToNextText()
            } else if synthesisDone {
                // The loop exited on failure with chunks remaining — no more
                // audio is coming, so end cleanly instead of parking at
                // `.fetching` forever (the failure notice already showed).
                stop()
            } else {
                status = .fetching // starved the prefetch; next chunk restarts
            }
        }
    }

    /// The current text finished — drop it (and its files) and promote the
    /// next queued text, or end the session when the run is done.
    private func advanceToNextText() {
        guard !runTexts.isEmpty else {
            stop()
            return
        }
        let finished = runTexts.removeFirst()
        deleteAudioFiles(of: finished)
        guard !runTexts.isEmpty else {
            stop()
            return
        }
        loadCurrentTextIntoPlayer(startPlaying: true)
    }

    // MARK: - Notices

    private func showNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func validateCaptured(_ captured: String?) -> TextValidation {
        Self.validate(captured, limit: settings?.readAloudCharLimit ?? Self.defaultCharLimit)
    }

    // MARK: - Language → voice (nonisolated for tests)

    /// Dominant-language detection over the first ~1000 chars. Russian and
    /// English have dedicated voice settings; everything else carries its
    /// detected code for the "Other languages" voice (system auto pick).
    nonisolated static func detectLanguage(_ text: String) -> TextLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1000)))
        switch recognizer.dominantLanguage {
        case .some(.russian): return .russian
        case .some(.english): return .english
        case .some(let language): return .other(language.rawValue)
        case nil: return .other(nil)
        }
    }

    /// Pick the configured voice for the text's language, then harden it:
    /// free-first means a Speechify choice without a key degrades to the
    /// system auto voice instead of failing (#105 tiering). Speechify model
    /// rules: Russian → simba-multilingual pinned to ru-RU (it misdetects
    /// Russian otherwise); English → simba-english; other / single-voice →
    /// simba-multilingual, no pin.
    nonisolated static func resolveVoice(
        for text: String,
        mode: ReadAloudVoiceMode,
        ru: ReadAloudVoiceChoice,
        en: ReadAloudVoiceChoice,
        other: ReadAloudVoiceChoice,
        single: ReadAloudVoiceChoice,
        hasSpeechifyKey: Bool
    ) -> VoiceSelection {
        let language = detectLanguage(text)
        let configured: ReadAloudVoiceChoice
        switch mode {
        case .singleVoice:
            configured = single
        case .perLanguage:
            switch language {
            case .russian: configured = ru
            case .english: configured = en
            case .other: configured = other
            }
        }
        let choice = (configured.engine == .speechify && !hasSpeechifyKey)
            ? .systemAuto : configured
        return selection(for: choice, language: language, forceMultilingual: mode == .singleVoice)
    }

    private nonisolated static func selection(
        for choice: ReadAloudVoiceChoice, language: TextLanguage, forceMultilingual: Bool
    ) -> VoiceSelection {
        let languageName: String
        let code: String?
        switch language {
        case .russian:
            languageName = "Russian"
            code = "ru"
        case .english:
            languageName = "English"
            code = "en"
        case .other(let detected):
            languageName = Self.languageDisplayName(detected)
            code = detected
        }

        switch choice.engine {
        case .system:
            return VoiceSelection(
                engine: .system,
                voiceID: choice.id,
                displayName: choice.name,
                initial: ReadAloudVoices.avatarInitial(for: choice),
                model: "system",
                languageParam: code,
                languageName: languageName
            )
        case .speechify:
            let model: String
            let param: String?
            if forceMultilingual {
                model = "simba-multilingual"
                param = language == .russian ? "ru-RU" : nil
            } else {
                switch language {
                case .russian:
                    model = "simba-multilingual"
                    param = "ru-RU"
                case .english:
                    model = "simba-english"
                    param = nil
                case .other:
                    model = "simba-multilingual"
                    param = nil
                }
            }
            return VoiceSelection(
                engine: .speechify,
                voiceID: choice.id,
                displayName: choice.name,
                initial: ReadAloudVoices.avatarInitial(for: choice),
                model: model,
                languageParam: param,
                languageName: languageName
            )
        }
    }

    nonisolated static func languageDisplayName(_ code: String?) -> String {
        guard let code,
              let name = Locale(identifier: "en_US").localizedString(forLanguageCode: code)
        else { return "Other" }
        return name.capitalized
    }

    // MARK: - Text validation (nonisolated for tests)

    enum TextValidation: Equatable, Sendable {
        case ok(String)
        /// Nothing was captured at all (no selection, or ⌘C ignored).
        case empty
        /// Captured, but no letter or digit survives trimming — nothing to speak.
        case unreadable
        /// Over the hard limit — never truncated, never sent, never billed.
        case overLimit(count: Int, limit: Int)
    }

    nonisolated static func validate(_ text: String?, limit: Int) -> TextValidation {
        guard let text else { return .empty }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return .unreadable }
        guard trimmed.count <= limit else { return .overLimit(count: trimmed.count, limit: limit) }
        return .ok(trimmed)
    }

    nonisolated static func validationNotice(for validation: TextValidation) -> String {
        switch validation {
        case .ok:
            return ""
        case .empty:
            return "No text selected"
        case .unreadable:
            return "No readable text"
        case .overLimit(let count, _):
            // Pinned locale: the UI is English, so grouping is a comma
            // regardless of the machine's region format.
            let grouped = count.formatted(.number.locale(Locale(identifier: "en_US")))
            return "Text too long (\(grouped) characters)"
        }
    }

    nonisolated static func failureNotice(for error: any Error) -> String {
        if let code = SpeechifyClient.httpStatus(from: error) {
            switch code {
            case 401: return "Speechify rejected the API key (401)"
            case 402: return "Speechify: out of credits (402)"
            default: return "Speechify error (HTTP \(code))"
            }
        }
        if error is SystemSpeechSynthesizer.SystemSpeechError {
            return "System voice failed"
        }
        return "Speechify request failed \u{2014} check your connection"
    }

    // MARK: - Chunking (nonisolated for tests)

    /// Split text into sentence-aligned chunks. The first chunk is small
    /// (~`firstTarget` chars ≈ 2.5 s to synthesize) so speech starts fast;
    /// later chunks are larger so the prefetch stays comfortably ahead of
    /// playback. Sentences (`enumerateSubstrings(.bySentences)`) pack into
    /// each chunk up to its limit; an oversized sentence falls back to
    /// whitespace cuts, and only an unbroken run of `limit` non-whitespace
    /// characters is hard-cut.
    nonisolated static func chunk(
        _ text: String, firstTarget: Int = 300, target: Int = 1500
    ) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var sentences: [String] = []
        trimmed.enumerateSubstrings(
            in: trimmed.startIndex..., options: .bySentences
        ) { piece, _, _, _ in
            if let piece = piece?.trimmingCharacters(in: .whitespacesAndNewlines),
               !piece.isEmpty {
                sentences.append(piece)
            }
        }
        if sentences.isEmpty { sentences = [trimmed] }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            var rest = Substring(sentence)
            while !rest.isEmpty {
                let limit = chunks.isEmpty ? firstTarget : target
                let space = current.isEmpty ? limit : limit - current.count - 1
                if rest.count <= space {
                    current = current.isEmpty ? String(rest) : current + " " + rest
                    break
                }
                if !current.isEmpty {
                    // Doesn't fit next to what's packed — close the chunk and
                    // retry against a fresh one (whose limit may be larger).
                    chunks.append(current)
                    current = ""
                    continue
                }
                // A single sentence over the whole limit: cut at whitespace,
                // hard-cut only an unbroken run.
                let cut = fallbackCutIndex(in: rest, limit: limit)
                let piece = rest[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    chunks.append(piece)
                }
                rest = rest[cut...].drop(while: \.isWhitespace)
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// Cut point for an oversized sentence: the last whitespace at or before
    /// `limit` characters, else exactly `limit`.
    private nonisolated static func fallbackCutIndex(
        in text: Substring, limit: Int
    ) -> Substring.Index {
        let hardEnd = text.index(text.startIndex, offsetBy: limit)
        var lastWhitespace: Substring.Index?
        var i = text.startIndex
        while i < hardEnd {
            if text[i].isWhitespace {
                lastWhitespace = i
            }
            i = text.index(after: i)
        }
        return lastWhitespace ?? hardEnd
    }

    // MARK: - Display helpers (nonisolated: Settings and the panel use them)

    nonisolated static func nextSpeed(after rate: Double) -> Double {
        guard let index = speedSteps.firstIndex(where: { abs($0 - rate) < 0.001 }) else {
            return 1.0 // stored value drifted off the ladder — reset
        }
        return speedSteps[(index + 1) % speedSteps.count]
    }

    nonisolated static func speedLabel(_ rate: Double) -> String {
        String(format: "%g\u{00D7}", rate)
    }

    /// First words of a text for the title line and queue rows — a display
    /// cap only; the ellipsizing is the view's job.
    nonisolated static func snippet(of text: String, max maxLength: Int = 80) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.prefix(while: { !$0.isNewline })
        return String(firstLine.prefix(maxLength))
    }

    /// "m:ss" clock label for the progress row.
    nonisolated static func timeLabel(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// Queue-row duration estimate from character count, adjusted by the
    /// playback rate (~17 chars/sec at 1x).
    nonisolated static func estimateLabel(chars: Int, rate: Double) -> String {
        let seconds = Double(chars) / charsPerSecond / max(rate, 0.1)
        return "~" + timeLabel(seconds)
    }
}
