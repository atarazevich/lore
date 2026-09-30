import AppKit
import Foundation
import Observation

/// Agent replies (#236, core #256): one queue with a position, read aloud one
/// at a time — the chat announced on its own first, then the reply (#267) —
/// held while a microphone is in use.
///
/// Sits beside `ReadAloudController` rather than inside it: selected text plays
/// `runTexts[0]` and deletes what it played, which is exactly what previous and
/// next cannot have. The two share the voice choice (`resolveVoice`) and the
/// system voices, never the queue.
///
/// Everything here is behind `AppSettings.agentRepliesEnabled`, off by default.
/// Off, the controller holds no replies, runs no microphone observer and
/// records no events; every entry point returns at once.
@Observable
@MainActor
final class AgentReplyController {

    enum Playback: Equatable, Sendable {
        case idle
        case speaking
        case paused
    }

    private(set) var isEnabled = false
    private(set) var queue = AgentReplyQueue()
    private(set) var playback: Playback = .idle
    /// Why the current reply is paused; nil unless `playback == .paused`.
    private(set) var pauseReason: DiagEvent.ReplyPauseReason?
    /// Reading is held by a microphone: another app runs one (a call), or
    /// lore itself is recording — a dictation past the talk key's decision, or
    /// a meeting (#279). Lore's microphone opening is not in it: the talk
    /// key's pre-buffer opens it on every press, a tap included.
    private(set) var isHeldByMicrophone = false
    /// Not persisted: a relaunch starts unmuted.
    private(set) var isMuted = false
    /// The owner put the player away (#263) — a tap of the talk key (#278), the
    /// header's × or the Esc after a pause. Visibility and nothing else: replies keep arriving, keep
    /// being read, and every key still works while it is true. Only an explicit
    /// show clears it, and it is not persisted: a relaunch opens as usual. A
    /// reply being read shows the player over it (#285) without clearing it.
    private(set) var isPlayerHidden = false
    /// Put away during the reply being read, or since the last one (#285):
    /// every hide sets it and a reply beginning clears it. While it is false a
    /// reply speaking — and the linger after — shows the player over
    /// `isPlayerHidden`; the surface's decision is where that is read.
    private(set) var isHiddenUntilNextReply = false
    /// Share of the current reply spoken, 0...1.
    private(set) var progress: Double = 0
    /// When reading last ran out — the last reply ended and nothing followed.
    /// The player stays up for `lingerWindow` after it, so the Go to of the
    /// reply just read is still there to click (#260 review). Nil whenever
    /// something is being read or waiting.
    private(set) var quietSince: Date?

    var currentReply: AgentReply? { queue.current }
    /// What is still to be read: the queue's waiting replies, and the current
    /// one while it is paused — a reply stopped mid-word is one to come back
    /// to, and the cue, the capsule and the trace all have to say so together.
    var waitingCount: Int { queue.waitingCount + (playback == .paused ? 1 : 0) }
    var isSpeaking: Bool { playback == .speaking }
    /// A reply is speaking and Esc would really stop it (#277): its chat, the
    /// gap after it, or its words are sounding. In the moment after the last
    /// word, before the finish arrives, the speaker has nothing to pause — and
    /// an Esc taken there would stop nothing and reach no app.
    var canStopSpeech: Bool { isSpeaking && builtSpeaker?.canPause == true }

    /// Whether a key's control would change anything right now — each the same
    /// reading its own action below takes, kept here because this is the object
    /// that owns the reading. A key asks before it ends the dictation gesture
    /// it arrived under: the Fn that carried the letter has a microphone open
    /// under it, and a key with nothing to act on must not cost the recording
    /// (#259).

    /// Fn+R plays or pauses the reply at the position (#278): any reply there
    /// is enough. Past the last one there is nothing to play, and the key stays
    /// a dead one so it cannot cost a dictation.
    var canPlayOrPause: Bool { isEnabled && queue.current != nil }
    /// Previous plays the reply before the current one, or the current one
    /// again when it is the first — so any reply at all is enough.
    var canPlayPrevious: Bool { isEnabled && !queue.replies.isEmpty }
    var canPlayNext: Bool { isEnabled && queue.current != nil }
    /// Whether an Esc lore did not take has anything to report: a reply an
    /// earlier Esc stopped, still inside the window. Read by the event paths
    /// before they cross to the main actor, because Esc is pressed all day long
    /// with nothing of lore's happening.
    var escapeRepeatIsWorthRecording: Bool {
        guard isEnabled, let stoppedAt = escapeStopAt else { return false }
        return now().timeIntervalSince(stoppedAt) <= Self.escapeRepeatWindow
    }

    /// Whether the player is inside the window it stays up for after the last
    /// reply ended. Read at presentation time, never stored (#260 review).
    var isLingering: Bool {
        guard let quietSince else { return false }
        return now().timeIntervalSince(quietSince) < Self.lingerWindow
    }

    /// Whether the player's plate is drawn right now — the same reading the
    /// window and the view take, never a flag of its own, so what Esc does and
    /// what is on screen cannot disagree (`no-false-positives.md`).
    var isPlayerShowing: Bool { AgentReplySurface.of(self) == .player }
    /// …and whether anything of the feature is drawn at all, the waiting capsule
    /// included. The talk key's tap governs the whole surface — hidden means
    /// nothing is drawn (#263) — while Esc answers only for the plate, which is
    /// the surface whose strip says what the key does.
    var isAnythingShowing: Bool { AgentReplySurface.of(self) != .hidden }

    /// The ?'s card in the player's title bar (#289): open on hover, pinned by
    /// a click. Kept here because Esc is read here.
    let help = AgentReplyHelp()
    /// The card is pinned on a player that is on screen — Esc's first claim
    /// while it is (#289). Read with the plate, never the pin alone, so a card
    /// that went with its player cannot keep the key.
    var isHelpPinned: Bool { help.isPinned && isPlayerShowing }

    /// Voice settings (per-language system voices). Set by `start(settings:)`.
    @ObservationIgnored var settings: AppSettings?

    /// Where the chat a reply came from is read from (#267). The announcement
    /// takes the labels of the navigator's last reading — never a call of its
    /// own, because a herdr that is slow or absent must not hold the first
    /// word. With no reading yet, the reply is announced by the labels its own
    /// shell put on the wire, which is what the very first reply of a launch
    /// is announced by.
    @ObservationIgnored weak var chats: AgentChatNavigator?

    /// Whether lore itself is recording (#279): a dictation from the moment
    /// the talk key's decision makes it one, or a meeting. Wired at launch and
    /// followed by observation while the switch is on, so the dictation's
    /// decision is what pauses a reply — never the microphone its pre-buffer
    /// opened at the key-down.
    @ObservationIgnored var isLoreRecording: @MainActor () -> Bool = { false }
    /// A second Esc this soon after an Esc that stopped a reply is recorded.
    nonisolated static let escapeRepeatWindow: TimeInterval = 2.0
    /// How long the player stays up after the last reply ended.
    nonisolated static let lingerWindow: TimeInterval = 10.0

    @ObservationIgnored private let makeSpeaker: () -> any AgentReplySpeaker
    @ObservationIgnored private let store: AgentReplyStore
    @ObservationIgnored private let makeMicrophone: () -> any AudioSignalSource
    @ObservationIgnored private let playCue: @MainActor () -> Void
    @ObservationIgnored private let recordEvent: (DiagEvent) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let installedVoices: () -> [ReadAloudVoiceChoice]

    @ObservationIgnored private var builtSpeaker: (any AgentReplySpeaker)?
    @ObservationIgnored private var microphone: (any AudioSignalSource)?
    @ObservationIgnored private var microphoneTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    @ObservationIgnored private var escapeStopAt: Date?
    /// The two things that hold reading, kept apart so each edge can be told
    /// from the other; `isHeldByMicrophone` is their sum.
    @ObservationIgnored private var anotherAppHoldsMicrophone = false
    @ObservationIgnored private var loreRecording = false
    /// The reply speaking was paused by lore's own recording alone — the pause
    /// a chord that discards that recording lifts again (#279).
    @ObservationIgnored private var pausedByLoreRecording = false

    init(
        makeSpeaker: @escaping () -> any AgentReplySpeaker = { SystemAgentReplySpeaker() },
        store: AgentReplyStore = AgentReplyStore(),
        makeMicrophone: @escaping () -> any AudioSignalSource = {
            CoreAudioSignalSource(purpose: .microphoneHold)
        },
        playCue: @escaping @MainActor () -> Void = { AgentReplyController.playSystemCue() },
        recordEvent: @escaping (DiagEvent) -> Void = { DiagStore.record($0) },
        now: @escaping () -> Date = Date.init,
        installedVoices: @escaping () -> [ReadAloudVoiceChoice] = ReadAloudVoices.allSystemVoices
    ) {
        self.makeSpeaker = makeSpeaker
        self.store = store
        self.makeMicrophone = makeMicrophone
        self.playCue = playCue
        self.recordEvent = recordEvent
        self.now = now
        self.installedVoices = installedVoices
    }

    /// Built at the first word spoken, never at launch: the live speaker owns
    /// an `AVSpeechSynthesizer`, and while the switch is off nothing of this
    /// feature exists.
    private var speaker: any AgentReplySpeaker {
        if let builtSpeaker { return builtSpeaker }
        let made = makeSpeaker()
        made.onFinish = { [weak self] in self?.replyFinished() }
        made.onProgress = { [weak self] share in self?.progress = share }
        builtSpeaker = made
        return made
    }

    // MARK: - The switch

    /// Follows `agentRepliesEnabled` for the life of the app: on and off take
    /// effect at once, without a relaunch.
    func start(settings: AppSettings) {
        self.settings = settings
        guard settingsTask == nil else { return }
        settingsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.setEnabled(settings.agentRepliesEnabled)
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = settings.agentRepliesEnabled
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// On: load the stored queue and start observing the microphone. Off: stop
    /// speaking, stop observing, and forget the in-memory queue (the file stays).
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            queue = store.load()
            isEnabled = true
            let source = makeMicrophone()
            microphone = source
            microphoneTask = Task { [weak self] in
                for await running in source.signals {
                    self?.anotherAppHoldsMicrophone = running
                    self?.holdChanged()
                }
            }
            recordingTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await withCheckedContinuation { continuation in
                        let recording = withObservationTracking(self.isLoreRecording) {
                            continuation.resume()
                        }
                        if recording != self.loreRecording {
                            self.loreRecording = recording
                            self.refreshOtherApps()
                        }
                        self.holdChanged()
                    }
                }
            }
        } else {
            isEnabled = false
            builtSpeaker?.stop()
            microphoneTask?.cancel()
            microphoneTask = nil
            recordingTask?.cancel()
            recordingTask = nil
            microphone?.shutdown()
            microphone = nil
            queue = AgentReplyQueue()
            playback = .idle
            pauseReason = nil
            isHeldByMicrophone = false
            anotherAppHoldsMicrophone = false
            loreRecording = false
            isMuted = false
            progress = 0
            quietSince = nil
            isPlayerHidden = false
            isHiddenUntilNextReply = false
            escapeStopAt = nil
        }
    }

    // MARK: - Arrival

    /// A reply arrived (#257). Nothing speaking, not muted, no microphone: it is
    /// read at once. Another reply speaking: it waits its turn. The current
    /// reply paused: reading moves on from the first reply it has not begun —
    /// which is this one unless earlier replies are still waiting, because
    /// replies are read in arrival order and none is skipped. Held or muted:
    /// it waits silently and is counted.
    func enqueue(_ reply: AgentReply) {
        guard isEnabled else { return }
        // Something to read again: the player is not running out of replies.
        quietSince = nil
        if queue.append(reply), playback != .idle {
            // The 51st arrival dropped the reply that was playing.
            stopReading()
        }
        recordEvent(.agentReplyArrived(
            hasHostApp: Self.isPresent(reply.said.hostBundleID),
            hasPane: Self.isPresent(reply.said.herdrPaneID),
            hasSession: Self.isPresent(reply.said.sessionID)
        ))
        if playback != .speaking {
            if isHeldByMicrophone || isMuted {
                // A paused reply stays current so play resumes it; otherwise
                // play starts the first reply that waited.
                if playback == .idle { queue.moveToFirstWaiting() }
            } else {
                queue.moveToFirstWaiting()
                start(trigger: .arrival)
            }
        }
        store.save(queue)
    }

    // MARK: - Controls (keys #259, player #260, visibility #263)

    /// A tap of the talk key (#278): the player goes away, or comes back.
    /// Never the speech — a reply being read carries on either way (#263) —
    /// and with nothing a surface would say, nothing happens. What it toggles is
    /// what is on screen: a player up only because a reply is read (#285) goes
    /// away until the next reply, and his own hide is left standing.
    func togglePlayer() {
        if isAnythingShowing { hidePlayer(by: .key) } else { showPlayer(by: .key) }
    }

    /// Fn+R (#278): the play key again, as #259 had it. A reply speaking pauses;
    /// a paused one carries on from where it stopped; with nothing speaking, the
    /// reply at the position starts.
    func playOrPause() {
        guard isEnabled, let current = queue.current else { return }
        playOrPause(replyID: current.id, pause: .key, play: .key)
    }

    /// Brings the player back as it was, on the same reply. With nothing in the
    /// list at all nothing comes up — there is nothing to show, which is the
    /// same reading the key asks for before it acts.
    ///
    /// The ten seconds after the last reply run from the press: a player put up
    /// over a queue that has run out stands for the linger window and then puts
    /// itself away again, exactly as it does when the last reply ends. Only over
    /// one that has run out — a reply speaking, paused or waiting keeps the
    /// player up by itself, and starting a linger there would break the one
    /// thing `quietSince` means (it is nil whenever anything is left to read)
    /// and hand `keepPlayerUp` a window to extend that nothing opened.
    ///
    /// Only when the list has a reply and a shown player would draw something
    /// (the ten seconds running from now): a key that would put nothing on
    /// screen stays a dead key, leaving no trace of a player nobody saw.
    func showPlayer(by source: DiagEvent.ReplyVisibility) {
        let surfaceIfShown = AgentReplySurface.decide(
            isEnabled: isEnabled, playback: playback, isHeldByMicrophone: isHeldByMicrophone,
            isMuted: isMuted, waiting: waitingCount, isLingering: true
        )
        guard !queue.replies.isEmpty, surfaceIfShown != .hidden else { return }
        isPlayerHidden = false
        if playback == .idle, waitingCount == 0 { quietSince = now() }
        recordEvent(.agentReplyPlayerShown(by: source))
    }

    /// Puts the player away: the key, the header's × and the Esc that follows a
    /// pause all land here. Nothing is drawn while it is away — no plate, no
    /// capsule — because the owner put it away himself, and the capsule exists
    /// to explain a silence he did not ask for.
    func hidePlayer(by source: DiagEvent.ReplyVisibility) {
        // Already put away, but shown by the reply being read (#285): the
        // hide is for this reply.
        guard isEnabled, !isPlayerHidden || isAnythingShowing else { return }
        isPlayerHidden = true
        isHiddenUntilNextReply = true
        // An Esc that went to the player is not the second Esc that meant the
        // app in front, which is the only thing that measurement is about (#259).
        if source == .escape { escapeStopAt = nil }
        recordEvent(.agentReplyPlayerHidden(by: source))
    }

    /// Plays the current reply, even while a microphone is in use or muted: an
    /// explicit play is the user's decision. Resumes a paused reply where it
    /// stopped.
    ///
    /// The trigger is always named: it says what the log will show.
    func play(trigger: DiagEvent.ReplyStartTrigger) {
        guard isEnabled else { return }
        switch playback {
        case .speaking:
            return
        case .paused:
            let wasShowing = isPlayerShowing
            speaker.resume()
            playback = .speaking
            pauseReason = nil
            pausedByLoreRecording = false
            recordEvent(.agentReplyReadingStarted(trigger: trigger))
            traceShownByReading(wasShowing: wasShowing)
        case .idle:
            guard queue.current != nil else { return }
            start(trigger: trigger)
            store.save(queue)
        }
    }

    /// Esc while a reply speaks: pause it; it stays current, and the player
    /// stays as it was — up, where the next Esc is the one that puts it away
    /// (#263), or put away, where the next Esc is the front app's (#277). A
    /// pause the speaker could not take is no pause at all, and the second Esc
    /// it would have armed is not armed either.
    func pauseByEscape() {
        guard isEnabled, playback == .speaking, pause(by: .escape) else { return }
        escapeStopAt = now()
    }

    /// An Esc lore did not take (#259). Recorded when it follows an Esc that
    /// stopped a reply within two seconds — that stop was probably meant for
    /// the app in front.
    func escapePassedThrough() {
        guard escapeRepeatIsWorthRecording else { return }
        escapeStopAt = nil
        recordEvent(.agentReplyEscapeRepeated)
    }

    /// A key or the pointer on the player while it lingers: another ten
    /// seconds, because he is doing something with what is on screen. Only
    /// while it lingers — nothing here starts a linger (#260 review), and a
    /// linger already run out is not restarted either: under mute that would
    /// bring back a player put away by time (#278).
    func keepPlayerUp() {
        guard isEnabled, isLingering else { return }
        quietSince = now()
    }

    /// Moves back one reply and plays it; on the first reply, plays it again.
    func previous() {
        guard isEnabled, !queue.replies.isEmpty else { return }
        keepPlayerUp()
        if queue.position > 0 {
            queue.moveBack()
            recordEvent(.agentReplyMoved(direction: .previous))
        }
        start(trigger: .previous)
        store.save(queue)
    }

    /// Skips the current reply and plays the one after it; past the last reply
    /// reading stops.
    func next() {
        guard isEnabled, queue.current != nil else { return }
        keepPlayerUp()
        stopReading()
        queue.moveForward()
        recordEvent(.agentReplyMoved(direction: .next))
        if queue.current != nil {
            start(trigger: .next)
        } else {
            goneQuiet()
        }
        store.save(queue)
    }

    /// A reply clicked in the player (#260, play and pause since #263): the
    /// pointer is the transport now, and what a click does is read from where
    /// the click landed.
    ///
    /// A reply that is not the current one becomes the current one and is read
    /// from the beginning, wherever it sits in the list — a read reply plays
    /// again in place, and the rest of the list does not move. The current one
    /// pauses, and a click again carries on from where it stopped. Leaving a
    /// reply and coming back starts it over: only the reply at the position
    /// keeps a place, and moving off it is what drops that place.
    func playOrPause(replyID: UUID) {
        playOrPause(replyID: replyID, pause: .click, play: .click)
    }

    /// The one play-or-pause, for the pointer and for Fn+R alike; each names
    /// itself in the log.
    private func playOrPause(
        replyID: UUID, pause reason: DiagEvent.ReplyPauseReason,
        play trigger: DiagEvent.ReplyStartTrigger
    ) {
        guard isEnabled, let index = queue.replies.firstIndex(where: { $0.id == replyID }) else {
            return
        }
        keepPlayerUp()
        if index == queue.position {
            switch playback {
            case .speaking: pause(by: reason)
            // Paused resumes where it stopped; idle has no place to carry on
            // from, so `play` starts this reply at its beginning.
            case .paused, .idle: play(trigger: trigger)
            }
            return
        }
        stopReading()
        guard queue.move(to: index) else { return }
        start(trigger: trigger)
        store.save(queue)
    }

    /// Mute holds reading the way the microphone does. Unmuting is the same
    /// moment as a microphone freeing: one sound when something waits, and
    /// nothing plays until play.
    func toggleMute() {
        guard isEnabled else { return }
        keepPlayerUp()
        isMuted.toggle()
        recordEvent(.agentReplyMute(on: isMuted))
        if isMuted {
            if playback == .speaking { pause(by: .mute) }
        } else if !isHeldByMicrophone, hasReplyToPlay {
            playCue()
        }
    }

    // MARK: - Microphone

    /// One of the two holds moved. A reply speaking is paused the moment
    /// reading becomes held.
    private func holdChanged() {
        let held = anotherAppHoldsMicrophone || loreRecording
        guard isEnabled, held != isHeldByMicrophone else { return }
        let wasShowing = isPlayerShowing
        defer { traceShownByReading(wasShowing: wasShowing) }
        isHeldByMicrophone = held
        if held {
            recordEvent(.agentReplyHeldByMicrophone)
            if playback == .speaking, pause(by: .microphone) {
                pausedByLoreRecording = !anotherAppHoldsMicrophone
            }
        } else {
            recordEvent(.agentReplyMicrophoneFreed(waiting: waitingCount))
            // No sound while muted (the user asked for quiet), none over a reply
            // already speaking, and none when there is nothing to play.
            if !isMuted, playback != .speaking, hasReplyToPlay {
                playCue()
            }
        }
    }

    /// Lore's own capture ended — a dictation, or a tap's pre-buffer (#279).
    /// While lore held the device, another app starting or stopping on it made
    /// no edge, so the other apps are read again now.
    func loreCaptureEnded() {
        guard isEnabled else { return }
        refreshOtherApps()
    }

    /// A chord took the talk key's press from a confirmed dictation (#279):
    /// the pause that recording alone caused is lifted, so the chord acts on
    /// the reply as the press found it — Fn+R pauses a speaking reply instead
    /// of resuming the one the dictation paused.
    func dictationDiscardedByChord() {
        guard isEnabled else { return }
        loreRecording = isLoreRecording()
        if !loreRecording, pausedByLoreRecording, playback == .paused, !anotherAppHoldsMicrophone {
            play(trigger: .key)
        }
        holdChanged()
    }

    private func refreshOtherApps() {
        (microphone as? CoreAudioSignalSource)?.refresh()
    }

    /// Whether the cue has anything to announce — the same count the capsule
    /// says out loud, so the sound and the screen cannot disagree.
    private var hasReplyToPlay: Bool { waitingCount > 0 }

    // MARK: - Reading

    /// A reply being read brought a player the owner had put away back on
    /// screen (#285): one trace per showing, whichever edge brought it — a
    /// reply beginning, a paused one carrying on, a microphone freeing.
    private func traceShownByReading(wasShowing: Bool) {
        guard isPlayerHidden, !wasShowing, isPlayerShowing else { return }
        recordEvent(.agentReplyPlayerShown(by: .reading))
    }

    /// `shownBefore` is the surface as the reading before left it, for a
    /// start that follows a reply's end: by now that playback is already idle.
    private func start(trigger: DiagEvent.ReplyStartTrigger, shownBefore: Bool? = nil) {
        guard let reply = queue.current else { return }
        let wasShowing = shownBefore ?? isPlayerShowing
        queue.markStarted()
        playback = .speaking
        pauseReason = nil
        pausedByLoreRecording = false
        progress = 0
        quietSince = nil
        // A new reply: a hide during the one before does not carry over (#285).
        isHiddenUntilNextReply = false
        speaker.speak(utterance(for: reply, announcing: Self.announces(trigger)))
        recordEvent(.agentReplyReadingStarted(trigger: trigger))
        traceShownByReading(wasShowing: wasShowing)
    }

    /// Whether the chat is said before the reply. A reply started by clicking it
    /// in the list is not announced (#267): he is looking at the row he clicked,
    /// and being told what he just pointed at is a second of nothing. Every
    /// other way a reply starts — it arrived, it followed the one before, a key,
    /// previous, next — begins away from the screen, and there the name is the
    /// whole of what says which chat is speaking.
    private nonisolated static func announces(_ trigger: DiagEvent.ReplyStartTrigger) -> Bool {
        trigger != .click
    }

    /// Stops the reply where it is — and says whether it really stopped. The
    /// speaker takes it from the chat's name to the reply's last word, the
    /// half-second between them included (#277). It refuses only when the
    /// reply's words have already run out and the finish is on its way;
    /// calling that paused would leave a reply `resume` cannot restart (#267),
    /// so the finish is left to move the queue on.
    @discardableResult
    private func pause(by reason: DiagEvent.ReplyPauseReason) -> Bool {
        guard speaker.pause() else { return false }
        pausedByLoreRecording = false
        playback = .paused
        pauseReason = reason
        recordEvent(.agentReplyReadingPaused(by: reason))
        return true
    }

    /// Stops whatever is being read and leaves the queue idle: the preamble a
    /// clicked row, Next and the 51st arrival share.
    private func stopReading() {
        speaker.stop()
        playback = .idle
        pauseReason = nil
        pausedByLoreRecording = false
    }

    /// Reading ran out. The player has ten seconds left (`isLingering`) so the
    /// reply just read can still be reached.
    private func goneQuiet() {
        progress = 0
        quietSince = now()
    }

    /// The current reply reached its end: move on, and read the next one unless
    /// reading was asked to stop, or a microphone or mute holds it.
    ///
    /// The speaker decides, not the playback recorded here: a pause landing
    /// between the utterance's end and this hop would otherwise leave a reply
    /// that resume cannot restart and a queue that goes nowhere until the next
    /// key. Such a pause still means quiet, so nothing follows on by itself.
    private func replyFinished() {
        guard isEnabled, playback != .idle else { return }
        let wasShowing = isPlayerShowing
        let askedForQuiet = playback == .paused
        playback = .idle
        pauseReason = nil
        recordEvent(.agentReplyReadingFinished)
        queue.moveForward()
        if queue.current != nil, !askedForQuiet, !isHeldByMicrophone, !isMuted {
            start(trigger: .continued, shownBefore: wasShowing)
        } else {
            goneQuiet()
        }
        store.save(queue)
    }

    private func utterance(for reply: AgentReply, announcing: Bool) -> AgentReplyUtterance {
        Self.utterance(
            for: reply,
            chat: announcing
                ? (chats?.name(for: reply) ?? AgentChatName(reply: reply, herdr: nil))
                : nil,
            mode: settings?.readAloudVoiceMode ?? .perLanguage,
            ru: settings?.readAloudVoiceRu ?? .systemAuto,
            en: settings?.readAloudVoiceEn ?? .systemAuto,
            other: settings?.readAloudVoiceOther ?? .systemAuto,
            single: settings?.readAloudVoiceSingle ?? .systemAuto,
            installed: installedVoices()
        )
    }

    // MARK: - Voice (nonisolated for tests)

    /// The sender's voice when it names an installed system voice (by name, as
    /// `say -v` takes it, or by identifier); otherwise Read Aloud's voice for
    /// the text's language, always a system voice — a Speechify choice there
    /// falls back to the automatic system voice, since replies never use
    /// Speechify.
    ///
    /// The announcement is resolved by its own words and never by the voice the
    /// sender asked for (#267): the chat is named in English and the reply may
    /// be Russian, and one voice reading both ran the name into the text. A nil
    /// `chat` is a reply started by clicking it — nothing is announced.
    nonisolated static func utterance(
        for reply: AgentReply,
        chat: AgentChatName?,
        mode: ReadAloudVoiceMode,
        ru: ReadAloudVoiceChoice,
        en: ReadAloudVoiceChoice,
        other: ReadAloudVoiceChoice,
        single: ReadAloudVoiceChoice,
        installed: [ReadAloudVoiceChoice]
    ) -> AgentReplyUtterance {
        let voice = { (words: String) in
            ReadAloudController.resolveVoice(
                for: words, mode: mode, ru: ru, en: en, other: other, single: single,
                hasSpeechifyKey: false
            )
        }
        let byLanguage = voice(reply.said.text)
        let requested = reply.said.voice.flatMap { wanted in
            installed.first {
                $0.name.caseInsensitiveCompare(wanted) == .orderedSame || $0.id == wanted
            }
        }
        let announced = chat?.spoken ?? ""
        return AgentReplyUtterance(
            announcement: announced.isEmpty ? nil : {
                let forChat = voice(announced)
                return AgentReplyVoicedText(
                    text: announced, voiceID: forChat.voiceID,
                    languageCode: forChat.languageParam
                )
            }(),
            reply: AgentReplyVoicedText(
                text: reply.said.text,
                voiceID: requested?.id ?? byLanguage.voiceID,
                languageCode: byLanguage.languageParam
            )
        )
    }

    /// The microphone-freed and unmute cue: one short system sound.
    static func playSystemCue() {
        guard let sound = NSSound(named: "Tink") else { return }
        sound.volume = 0.5
        sound.play()
    }

    private nonisolated static func isPresent(_ value: String?) -> Bool {
        !(value ?? "").isEmpty
    }
}
