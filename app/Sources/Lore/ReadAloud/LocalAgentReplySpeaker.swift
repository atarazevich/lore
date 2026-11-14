import AVFoundation
import Foundation
import LoreCore

/// One WAV played once: the seam over `AVAudioPlayer`, so the speaker is
/// tested without a sound.
@MainActor
protocol AgentReplyClipPlaying: AnyObject {
    /// The clip played to its end (never after `stop`).
    var onEnd: (@MainActor () -> Void)? { get set }
    /// The clip could not be decoded: its words were not heard (never after
    /// `stop`).
    var onFailure: (@MainActor () -> Void)? { get set }
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    /// Whether it started (or carried on after a pause).
    func play() -> Bool
    func pause()
    func stop()
}

@MainActor
final class AudioFileClipPlayer: NSObject, AgentReplyClipPlaying, AVAudioPlayerDelegate {
    var onEnd: (@MainActor () -> Void)?
    var onFailure: (@MainActor () -> Void)?
    private let player: AVAudioPlayer

    init?(url: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        self.player = player
        super.init()
        player.delegate = self
        player.prepareToPlay()
    }

    var isPlaying: Bool { player.isPlaying }
    var currentTime: TimeInterval { player.currentTime }
    func play() -> Bool { player.play() }
    func pause() { player.pause() }

    func stop() {
        onEnd = nil
        onFailure = nil
        player.stop()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onEnd?() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.onFailure?() }
    }
}

/// Agent replies in the local Silero voices (#351): the chat in its own
/// language's voice, half a second, then the reply sentence by sentence — the
/// first sentence plays while the rest are still being written.
///
/// Keeps every contract of `AgentReplySpeaker`. Wherever the local voice
/// cannot speak — the service is not installed, does not start, fails on a
/// sentence, or the language is not Russian or English — the system speaker
/// takes the reply from that point to its end, `onFinish` still fires once,
/// and the reason is traced. A sender's `-v` naming a system voice goes to the
/// system speaker as asked. A reply is never silent because of this engine.
@MainActor
final class LocalAgentReplySpeaker: AgentReplySpeaker {
    var onFinish: (@MainActor () -> Void)?
    var onProgress: (@MainActor (Double) -> Void)?

    /// One run of words the service makes one WAV of: the chat, or one
    /// sentence of the reply.
    private struct Part {
        let text: String
        let voice: SileroVoice
        let isReply: Bool
    }

    private enum Stage {
        /// The part at `position` has no WAV yet, or a pause holds it back.
        case waiting
        case playing
        /// The half-second after the chat.
        case gap
    }

    private let service: any LocalSpeechSynthesizing
    private let makePlayer: @MainActor (URL) -> (any AgentReplyClipPlaying)?
    private let makeFallback: @MainActor () -> any AgentReplySpeaker
    private let recordEvent: (DiagEvent) -> Void
    private let sleep: @MainActor (TimeInterval) async -> Void
    private let progressInterval: TimeInterval

    /// Bumped by every `stop`: a WAV, a clip's end or a gap belonging to an
    /// earlier generation is ignored, and its file deleted.
    private var generation = 0
    private var utterance: AgentReplyUtterance?
    private var parts: [Part] = []
    private var clips: [Int: LocalSpeechClip] = [:]
    private var failure: (index: Int, reason: DiagEvent.LocalVoiceFallback)?
    private var position = 0
    private var stage: Stage = .waiting
    private var isPaused = false
    private var player: (any AgentReplyClipPlaying)?
    /// The playing clip ran out under a pause, its end not yet in: resume
    /// waits for that end, and never plays the clip again.
    private var ranOut = false
    private var synthesis: Task<Void, Never>?
    private var gapTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    /// The reply's WAVs already played to their end, in seconds.
    private var replySecondsPlayed = 0.0
    /// The system speaker reading this reply, or the rest of it.
    private var delegated: (any AgentReplySpeaker)?
    private var builtFallback: (any AgentReplySpeaker)?
    /// `notInstalled` is traced once per launch, not on every reply of a Mac
    /// that never installed the service: the speaker lives as long as the app.
    private var notInstalledTraced = false

    init(
        service: any LocalSpeechSynthesizing = LocalSpeechService(),
        makePlayer: @escaping @MainActor (URL) -> (any AgentReplyClipPlaying)? = { AudioFileClipPlayer(url: $0) },
        makeFallback: @escaping @MainActor () -> any AgentReplySpeaker = { SystemAgentReplySpeaker() },
        recordEvent: @escaping (DiagEvent) -> Void = { DiagStore.record($0) },
        sleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        progressInterval: TimeInterval = 0.2
    ) {
        self.service = service
        self.makePlayer = makePlayer
        self.makeFallback = makeFallback
        self.recordEvent = recordEvent
        self.sleep = sleep
        self.progressInterval = progressInterval
    }

    // MARK: - AgentReplySpeaker

    func speak(_ utterance: AgentReplyUtterance) {
        stop()
        guard let voice = utterance.reply.localVoice else {
            // No local voice: a system voice asked for by name is not a
            // fallback; a language neither voice reads is.
            let language = ReadAloudController.TextLanguage(code: utterance.reply.languageCode ?? "")
            if SileroVoice(language) == nil {
                recordEvent(.agentReplyLocalVoiceFellBack(reason: .languageUnsupported))
            }
            hand(utterance, from: 0)
            return
        }
        guard service.isInstalled else {
            if !notInstalledTraced {
                notInstalledTraced = true
                recordEvent(.agentReplyLocalVoiceFellBack(reason: .notInstalled))
            }
            hand(utterance, from: 0)
            return
        }
        self.utterance = utterance
        parts = (utterance.announcement.map {
            [Part(text: $0.text, voice: $0.localVoice ?? .en116, isReply: false)]
        } ?? []) + Self.sentences(utterance.reply.text).map { Part(text: $0, voice: voice, isReply: true) }
        synthesize(parts, generation: generation)
    }

    func pause() -> Bool {
        if let delegated { return delegated.pause() }
        guard utterance != nil else { return false }
        if isPaused { return true }
        switch stage {
        case .waiting:
            isPaused = true
            return true
        case .gap:
            // The reply not yet begun is held at its first word; resume
            // starts it there, the chat not said again (#277).
            gapTask?.cancel()
            gapTask = nil
            position += 1
            stage = .waiting
            isPaused = true
            return true
        case .playing:
            if player?.isPlaying == true {
                player?.pause()
                isPaused = true
                return true
            }
            // The clip ran out and its end is on its way. The reply's last
            // one: the finish is coming, nothing to stop. Any other: the
            // next part waits for resume.
            guard position < parts.count - 1 else { return false }
            isPaused = true
            ranOut = true
            return true
        }
    }

    var canPause: Bool {
        if let delegated { return delegated.canPause }
        guard utterance != nil else { return false }
        switch stage {
        case .waiting, .gap: return true
        case .playing: return isPaused || player?.isPlaying == true || position < parts.count - 1
        }
    }

    func resume() {
        if let delegated {
            delegated.resume()
            return
        }
        guard utterance != nil, isPaused else { return }
        isPaused = false
        guard stage == .playing else {
            proceed()
            return
        }
        // A clip that ran out is never played again: its end, on its way,
        // moves on to the next part.
        if !ranOut { _ = player?.play() }
    }

    func stop() {
        generation += 1
        delegated?.stop()
        reset()
    }

    // MARK: - Synthesis

    /// Sentence by sentence, in order, one request at a time: the first WAV
    /// plays as soon as it exists.
    private func synthesize(_ parts: [Part], generation: Int) {
        let service = self.service
        synthesis = Task { [weak self] in
            for (index, part) in parts.enumerated() {
                if Task.isCancelled { return }
                do throws(DiagEvent.LocalVoiceFallback) {
                    let clip = try await service.synthesize(part.text, voice: part.voice)
                    guard let self else {
                        try? FileManager.default.removeItem(at: clip.url)
                        return
                    }
                    self.arrived(clip, at: index, generation: generation)
                } catch {
                    self?.failed(error, at: index, generation: generation)
                    return
                }
            }
        }
    }

    private func arrived(_ clip: LocalSpeechClip, at index: Int, generation: Int) {
        guard generation == self.generation, utterance != nil else {
            // A WAV for a reply stopped meanwhile: inert.
            try? FileManager.default.removeItem(at: clip.url)
            return
        }
        clips[index] = clip
        if stage == .waiting, position == index { proceed() }
    }

    private func failed(_ reason: DiagEvent.LocalVoiceFallback, at index: Int, generation: Int) {
        guard generation == self.generation, utterance != nil else { return }
        failure = (index, reason)
        if stage == .waiting, position == index { proceed() }
    }

    // MARK: - Playback

    /// Plays the part at `position` if its WAV is there, hands the rest to the
    /// system speaker if its synthesis failed, and otherwise waits.
    private func proceed() {
        stage = .waiting
        guard !isPaused else { return }
        if let clip = clips[position] {
            play(clip)
        } else if let failure, failure.index == position {
            fallBack(failure.reason)
        }
    }

    private func play(_ clip: LocalSpeechClip) {
        guard let player = makePlayer(clip.url) else {
            fallBack(.requestFailed)
            return
        }
        let index = position
        let generation = self.generation
        player.onEnd = { [weak self] in self?.ended(index, generation: generation) }
        player.onFailure = { [weak self] in self?.undecodable(index, generation: generation) }
        guard player.play() else {
            player.stop()
            fallBack(.requestFailed)
            return
        }
        self.player = player
        ranOut = false
        stage = .playing
        if parts[index].isReply { startTicker() }
    }

    private func ended(_ index: Int, generation: Int) {
        guard generation == self.generation, stage == .playing, index == position else { return }
        // Silenced as well as dropped: a clip ended is never heard again.
        player?.stop()
        player = nil
        ranOut = false
        if let clip = clips.removeValue(forKey: index) {
            try? FileManager.default.removeItem(at: clip.url)
            if parts[index].isReply { replySecondsPlayed += clip.seconds }
        }
        if index == parts.count - 1 {
            finish()
            return
        }
        if !parts[index].isReply, !isPaused {
            stage = .gap
            gapTask = Task { [weak self, sleep = self.sleep] in
                await sleep(LocalAgentReplySpeaker.announcementPause)
                self?.gapEnded(generation: generation)
            }
            return
        }
        position += 1
        proceed()
    }

    /// A WAV that does not decode is a sentence not heard: the system voice
    /// reads from it on.
    private func undecodable(_ index: Int, generation: Int) {
        guard generation == self.generation, stage == .playing, index == position else { return }
        fallBack(.requestFailed)
    }

    private func gapEnded(generation: Int) {
        guard generation == self.generation, stage == .gap, !isPaused else { return }
        gapTask = nil
        position += 1
        proceed()
    }

    private func finish() {
        reset()
        onProgress?(1)
        onFinish?()
    }

    // MARK: - The system voice takes over

    /// The local voice failed at `position`: the system speaker reads from
    /// there to the reply's end — the chat too, if it was not yet said.
    private func fallBack(_ reason: DiagEvent.LocalVoiceFallback) {
        guard let utterance else { return }
        recordEvent(.agentReplyLocalVoiceFellBack(reason: reason))
        hand(utterance, from: position)
    }

    /// `utterance` read by the system speaker from part `index` on (0: all of
    /// it). Progress continues from the share of the reply already heard, and
    /// its finish is this speaker's, once.
    private func hand(_ utterance: AgentReplyUtterance, from index: Int) {
        let replyParts = parts.filter(\.isReply)
        let rest = parts.indices.filter { $0 >= index && parts[$0].isReply }.map { parts[$0].text }
        let total = replyParts.reduce(0) { $0 + $1.text.count }
        let restCount = rest.reduce(0) { $0 + $1.count }
        let before = index == 0 || total == 0 ? 0 : Double(total - restCount) / Double(total)
        let announcement = index == 0 ? utterance.announcement : nil
        let reply = index == 0 ? utterance.reply : AgentReplyVoicedText(
            text: rest.joined(separator: " "),
            voiceID: utterance.reply.voiceID,
            languageCode: utterance.reply.languageCode
        )
        let wasPaused = isPaused
        let generation = self.generation
        reset()
        let fallback = builtFallback ?? makeFallback()
        builtFallback = fallback
        fallback.onFinish = { [weak self] in
            guard let self, self.generation == generation, self.delegated != nil else { return }
            self.delegated = nil
            self.onProgress?(1)
            self.onFinish?()
        }
        fallback.onProgress = { [weak self] share in
            guard let self, self.generation == generation, share < 1 else { return }
            self.onProgress?(before + share * (1 - before))
        }
        delegated = fallback
        fallback.speak(AgentReplyUtterance(announcement: announcement, reply: reply))
        if wasPaused { _ = fallback.pause() }
    }

    // MARK: - Progress

    /// Time-based: the reply's seconds heard over its seconds in all — the
    /// sentences not yet written are estimated from the ones that are.
    private func startTicker() {
        ticker?.cancel()
        let generation = self.generation
        let interval = progressInterval
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == generation else { return }
                self.reportProgress()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func reportProgress() {
        guard stage == .playing, parts[position].isReply, let player else { return }
        var known = 0.0
        var knownCharacters = 0
        var unknownCharacters = 0
        for (index, part) in parts.enumerated() where part.isReply {
            if let clip = clips[index] {
                known += clip.seconds
                knownCharacters += part.text.count
            } else if index > position {
                unknownCharacters += part.text.count
            }
        }
        let perCharacter = knownCharacters > 0 ? known / Double(knownCharacters) : 0.065
        let total = replySecondsPlayed + known + Double(unknownCharacters) * perCharacter
        guard total > 0 else { return }
        onProgress?(min((replySecondsPlayed + player.currentTime) / total, 0.99))
    }

    // MARK: - Helpers

    /// Forgets the current reply: tasks cancelled, the player silenced and
    /// every WAV of it deleted. Not the generation — `stop` bumps that.
    private func reset() {
        synthesis?.cancel()
        synthesis = nil
        gapTask?.cancel()
        gapTask = nil
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        ranOut = false
        for clip in clips.values { try? FileManager.default.removeItem(at: clip.url) }
        clips = [:]
        utterance = nil
        parts = []
        failure = nil
        position = 0
        stage = .waiting
        isPaused = false
        replySecondsPlayed = 0
        delegated = nil
    }

    static let announcementPause = SystemAgentReplySpeaker.announcementPause

    /// The reply cut into sentences, each one WAV — Read Aloud's cut; a blank
    /// reply is still one part, so it finishes.
    nonisolated static func sentences(_ text: String) -> [String] {
        let sentences = ReadAloudController.sentences(text)
        return sentences.isEmpty ? [text] : sentences
    }
}
