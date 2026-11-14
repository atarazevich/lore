import AppKit
import Foundation
import LoreCore
import Observation

/// Agent replies (#236, core #256): one queue with a position, read aloud one
/// at a time — the chat announced on its own first, then the reply (#267).
///
/// Since #354 lore picks a mode for every arriving reply: Loud reads it, Quiet
/// files it silently with a count (`AgentReplyMode`). One key does the rest —
/// click, twice, hold (`replyKey(_:)`, decided by `AgentReplyKeyPress`).
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
    /// He held the reply key to show the list (#354), over replies still to be
    /// heard. It stays until a hold, the × or Esc hides it, or reading runs out
    /// and the ten seconds after it take over. Not persisted.
    private(set) var isListOpen = false
    /// Put away during the reply being read, or since the last one (#285):
    /// every hide sets it and a reply beginning clears it. While it is false a
    /// reply being read — and the linger after — shows the player.
    private(set) var isHiddenUntilNextReply = false
    /// Share of the current reply spoken, 0...1.
    private(set) var progress: Double = 0
    /// When reading last ran out — the last reply ended and nothing followed.
    /// The player stays up for `lingerWindow` after it, so the Go to of the
    /// reply just read is still there to click (#260 review). Nil whenever
    /// something is being read.
    private(set) var quietSince: Date?
    /// The replies filed silently (#354) and why — what the capsule counts and
    /// what its tooltip names. In memory only: after a relaunch the rows' dots
    /// still say what was not heard.
    private(set) var silentReasons: [UUID: ReplyQuietReason] = [:]
    /// The outside, read for the capsule's tooltip while the pointer is on it
    /// (#354); nil otherwise. The tooltip's present tense is read from this
    /// alone, so it never claims a game or a sound from an older reading.
    private(set) var presentedSurroundings: AgentReplySurroundings?

    var currentReply: AgentReply? { queue.current }
    /// What is still to be read: the queue's waiting replies, and the current
    /// one while it is paused.
    var waitingCount: Int { queue.waitingCount + (playback == .paused ? 1 : 0) }
    var isSpeaking: Bool { playback == .speaking }
    /// A reply is speaking and Esc would really stop it (#277): its chat, the
    /// gap after it, or its words are sounding. In the moment after the last
    /// word, before the finish arrives, the speaker has nothing to pause — and
    /// an Esc taken there would stop nothing and reach no app.
    var canStopSpeech: Bool { isSpeaking && builtSpeaker?.canPause == true }

    /// Click twice plays the reply after the card's (#354): there is one only
    /// when the card is not the last reply. The strip dims its Next otherwise.
    var canPlayNext: Bool { isEnabled && queue.position + 1 < queue.replies.count }
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

    /// The replies filed silently that are not heard yet — the capsule's count.
    var silentWaitingCount: Int {
        queue.replies.reduce(0) { count, reply in
            count + (silentReasons[reply.id] != nil && !queue.startedIDs.contains(reply.id) ? 1 : 0)
        }
    }

    /// Why the newest reply still waiting silently was silent, and whether
    /// that reason still holds — read now (`no-false-positives.md`): the
    /// microphone and lore's recording from their live state, a game or a
    /// sound only from the reading taken for this presentation.
    var silentReason: (reason: ReplyQuietReason, holds: Bool)? {
        guard let reason = queue.replies.reversed().lazy.compactMap({ reply -> ReplyQuietReason? in
            self.queue.startedIDs.contains(reply.id) ? nil : self.silentReasons[reply.id]
        }).first else { return nil }
        let holds = switch reason {
        case .microphone: anotherAppHoldsMicrophone
        case .dictation, .meeting: loreRecordingReason == reason
        case .game: presentedSurroundings?.gameInFront == true
        case .sound: presentedSurroundings?.otherAppSound == true
        case .unknown: false
        }
        return (reason, holds)
    }

    /// Whether the player's plate is drawn right now — the same reading the
    /// window and the view take, never a flag of its own, so what Esc does and
    /// what is on screen cannot disagree (`no-false-positives.md`).
    var isPlayerShowing: Bool { AgentReplySurface.of(self) == .player }

    /// The ?'s card in the player's title bar (#289): open on hover, pinned by
    /// a click. Kept here because Esc is read here.
    let help = AgentReplyHelp()
    /// The card is pinned on a player that is on screen — Esc's first claim
    /// while it is (#289). Read with the plate, never the pin alone, so a card
    /// that went with its player cannot keep the key.
    var isHelpPinned: Bool { help.isPinned && isPlayerShowing }

    /// Voice settings (per-language system voices) and the reply key's name.
    /// Set by `start(settings:)`.
    @ObservationIgnored var settings: AppSettings?
    /// The reply key's cap, as the strip, the capsule and the tooltips print it.
    var keyCap: String { (settings?.agentReplyKey ?? AgentReplyKey.defaultKey(talkKey: .fn)).shortName }

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
    /// …and whether that recording is a meeting (#354): what a reply kept
    /// silent under it is said to be silent for.
    @ObservationIgnored var isMeetingRecording: @MainActor () -> Bool = { false }

    /// Lore's own recording as a reason to keep replies silent, read now.
    private var loreRecordingReason: ReplyQuietReason? {
        guard loreRecording else { return nil }
        return isMeetingRecording() ? .meeting : .dictation
    }

    /// …and as the reason a key starts no sound into it.
    private var loreRecordingRefusal: DiagEvent.ReplyRefusal? {
        loreRecordingReason.map { $0 == .meeting ? .meeting : .dictation }
    }
    /// A second Esc this soon after an Esc that stopped a reply is recorded.
    nonisolated static let escapeRepeatWindow: TimeInterval = 2.0
    /// How long the player stays up after the last reply ended.
    nonisolated static let lingerWindow: TimeInterval = 10.0
    /// While another app holds the microphone, how often that is read again
    /// (#327): the per-process input property sends no notification, so a
    /// stale reading at the end of lore's own capture would otherwise stand.
    nonisolated static let holdRecheckInterval: TimeInterval = 2.0

    @ObservationIgnored private let makeSpeaker: () -> any AgentReplySpeaker
    @ObservationIgnored private let store: AgentReplyStore
    @ObservationIgnored private let makeMicrophone: () -> any AudioSignalSource
    /// Reads the app in front and the other apps' sound (#354); its answer
    /// comes back on the main actor, at once in a test.
    @ObservationIgnored let surroundings: any AgentReplySurroundingsReading
    @ObservationIgnored private let recordEvent: (DiagEvent) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async -> Void
    @ObservationIgnored private let installedVoices: () -> [ReadAloudVoiceChoice]

    @ObservationIgnored private var builtSpeaker: (any AgentReplySpeaker)?
    @ObservationIgnored private var microphone: (any AudioSignalSource)?
    @ObservationIgnored private var microphoneTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    @ObservationIgnored private var holdRecheckTask: Task<Void, Never>?
    @ObservationIgnored private var escapeStopAt: Date?
    /// The two things that hold reading, kept apart so each edge can be told
    /// from the other; `isHeldByMicrophone` is their sum.
    private var anotherAppHoldsMicrophone = false
    private var loreRecording = false
    /// The mode last derived, so each change is traced once (#354).
    @ObservationIgnored private var lastMode: AgentReplyMode?

    init(
        makeSpeaker: @escaping () -> any AgentReplySpeaker = { SystemAgentReplySpeaker() },
        store: AgentReplyStore = AgentReplyStore(),
        makeMicrophone: @escaping () -> any AudioSignalSource = {
            CoreAudioSignalSource(purpose: .microphoneHold)
        },
        surroundings: any AgentReplySurroundingsReading = LiveAgentReplySurroundings(),
        recordEvent: @escaping (DiagEvent) -> Void = { DiagStore.record($0) },
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        installedVoices: @escaping () -> [ReadAloudVoiceChoice] = ReadAloudVoices.allSystemVoices
    ) {
        self.makeSpeaker = makeSpeaker
        self.store = store
        self.makeMicrophone = makeMicrophone
        self.surroundings = surroundings
        self.recordEvent = recordEvent
        self.now = now
        self.sleep = sleep
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
                    self?.recheckWhileAnotherAppHolds()
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
                            self.microphone?.refresh()
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
            holdRecheckTask?.cancel()
            holdRecheckTask = nil
            microphone?.shutdown()
            microphone = nil
            queue = AgentReplyQueue()
            playback = .idle
            pauseReason = nil
            isHeldByMicrophone = false
            anotherAppHoldsMicrophone = false
            loreRecording = false
            progress = 0
            quietSince = nil
            isListOpen = false
            isHiddenUntilNextReply = false
            silentReasons = [:]
            presentedSurroundings = nil
            lastMode = nil
            escapeStopAt = nil
        }
    }

    // MARK: - Arrival

    /// A reply arrived (#257). Its place in the queue is taken now, so replies
    /// keep their arrival order however long a reading takes; its mode is
    /// derived when the outside has been read (#354, `file`).
    func enqueue(_ reply: AgentReply) {
        guard isEnabled else { return }
        if queue.append(reply), playback != .idle {
            // The 51st arrival dropped the reply that was playing.
            stopReading()
        }
        let kept = Set(queue.replies.map(\.id))
        silentReasons = silentReasons.filter { kept.contains($0.key) }
        recordEvent(.agentReplyArrived(
            hasHostApp: Self.isPresent(reply.said.hostBundleID),
            hasPane: Self.isPresent(reply.said.herdrPaneID),
            hasSession: Self.isPresent(reply.said.sessionID)
        ))
        store.save(queue)
        surroundings.read { [weak self] outside in self?.file(reply.id, outside) }
    }

    /// The arrived reply's mode, now that the outside is read: Quiet files it
    /// silently and counts it; Loud reads — at once when nothing speaks, from
    /// the first reply not begun, because replies are read in arrival order
    /// and none is skipped. A reply speaking keeps it waiting its turn, and
    /// the end of that reply decides again (`replyFinished`).
    private func file(_ id: UUID, _ outside: AgentReplySurroundings) {
        guard isEnabled, queue.replies.contains(where: { $0.id == id }) else { return }
        let mode = noteMode(outside)
        guard playback != .speaking else { return }
        if let reason = mode.quietReason {
            // No sound and no player (board §06). A paused reply stays
            // current so a click carries it on; otherwise a click starts the
            // first reply that waited.
            if !queue.startedIDs.contains(id) { silentReasons[id] = reason }
            if playback == .idle { queue.moveToFirstWaiting() }
        } else {
            let wasShowing = isPlayerShowing
            queue.moveToFirstWaiting()
            start(trigger: .arrival, shownBefore: wasShowing)
        }
        store.save(queue)
    }

    /// The mode for this reading and lore's own state, traced when it differs
    /// from the last one derived for a reply.
    @discardableResult
    private func noteMode(_ outside: AgentReplySurroundings) -> AgentReplyMode {
        let mode = mode(outside)
        if mode != lastMode {
            lastMode = mode
            recordEvent(.agentReplyModeChanged(quietBecause: mode.quietReason))
        }
        return mode
    }

    private func mode(_ outside: AgentReplySurroundings) -> AgentReplyMode {
        AgentReplyMode.resolve(
            otherAppMicrophone: anotherAppHoldsMicrophone, surroundings: outside,
            loreRecording: loreRecordingReason
        )
    }

    /// The pointer came onto the capsule: the outside is read for its tooltip,
    /// whose tense says whether the reason still holds. A presentation, not a
    /// reply's mode: nothing is traced for it.
    func readSurroundingsForTooltip() {
        guard isEnabled else { return }
        surroundings.read { [weak self] outside in
            guard let self, self.isEnabled else { return }
            self.presentedSurroundings = outside
        }
    }

    /// …and left it: the reading is not kept past its presentation.
    func endTooltipReading() { presentedSurroundings = nil }

    // MARK: - The reply key (#354)

    /// One gesture of the reply key, decided by `AgentReplyKeyPress`. Every
    /// decision is traced; each acts in every mode — a click in Quiet plays,
    /// because he pressed it — except into lore's own recording.
    func replyKey(_ gesture: ReplyKeyGesture) {
        guard isEnabled else { return }
        recordEvent(.agentReplyKeyPressed(gesture: gesture))
        keepPlayerUp()
        switch gesture {
        case .click: click()
        case .twice: if canPlayNext { next() }
        case .hold: if isPlayerShowing { hidePlayer(by: .key) } else { showPlayer(by: .key) }
        case .unknown: break
        }
    }

    /// Speaking: pause. Paused: carry on from where it stopped. Nothing
    /// speaking: the first reply not heard; every one heard, the last again.
    /// While lore records, a click starts no sound: it would go into the
    /// dictation or the meeting's open microphone.
    private func click() {
        if playback != .speaking, let recording = loreRecordingRefusal {
            recordEvent(.agentReplyPlayRefused(because: recording))
            return
        }
        switch playback {
        case .speaking:
            pause(by: .key)
        case .paused:
            play(trigger: .key)
        case .idle:
            guard !queue.replies.isEmpty else { return }
            queue.moveToFirstWaiting()
            if queue.current == nil { _ = queue.move(to: queue.replies.count - 1) }
            start(trigger: .key)
            store.save(queue)
        }
    }

    // MARK: - Controls (player #260, visibility #263)

    /// Shows the list on the current reply (board frame b): with nothing
    /// speaking, the card is the first reply not heard. Over replies still to
    /// be heard it stays until it is hidden; over a list all heard it stands
    /// for the ten seconds after the last reply, as it does when one ends.
    /// With nothing in the list, nothing comes up.
    func showPlayer(by source: DiagEvent.ReplyVisibility) {
        guard isEnabled, !queue.replies.isEmpty else { return }
        if playback == .idle {
            queue.moveToFirstWaiting()
            store.save(queue)
        }
        isHiddenUntilNextReply = false
        if playback == .idle, waitingCount == 0 {
            quietSince = now()
        } else {
            isListOpen = true
        }
        recordEvent(.agentReplyPlayerShown(by: source))
    }

    /// Puts the list away: a hold of the reply key, the header's × and the Esc
    /// that follows a pause all land here. Never the voice. Replies that wait
    /// silently still show their capsule.
    func hidePlayer(by source: DiagEvent.ReplyVisibility) {
        guard isEnabled, isPlayerShowing else { return }
        isListOpen = false
        isHiddenUntilNextReply = true
        // An Esc that went to the player is not the second Esc that meant the
        // app in front, which is the only thing that measurement is about (#259).
        if source == .escape { escapeStopAt = nil }
        recordEvent(.agentReplyPlayerHidden(by: source))
    }

    /// Plays the current reply, in any mode: an explicit play is the user's
    /// decision. Resumes a paused reply where it stopped.
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
    /// while it lingers — nothing here starts a linger (#260 review).
    func keepPlayerUp() {
        guard isEnabled, isLingering else { return }
        quietSince = now()
    }

    /// Skips the card's reply and plays the one after it from its start —
    /// click twice (#354). On the last reply there is none, and nothing moves.
    /// While lore records it moves there and starts no sound into the open
    /// microphone, which the trace says.
    func next() {
        guard canPlayNext else { return }
        keepPlayerUp()
        let wasShowing = isPlayerShowing
        stopReading()
        queue.moveForward()
        recordEvent(.agentReplyMoved(direction: .next))
        if let recording = loreRecordingRefusal {
            recordEvent(.agentReplyPlayRefused(because: recording))
        } else {
            start(trigger: .next, shownBefore: wasShowing)
        }
        store.save(queue)
    }

    /// A reply clicked in the player (#260, play and pause since #263): the
    /// pointer is the transport, and what a click does is read from where the
    /// click landed.
    ///
    /// A reply that is not the current one becomes the current one and is read
    /// from the beginning, wherever it sits in the list — a read reply plays
    /// again in place, and the rest of the list does not move. The current one
    /// pauses, and a click again carries on from where it stopped. Leaving a
    /// reply and coming back starts it over: only the reply at the position
    /// keeps a place, and moving off it is what drops that place.
    func playOrPause(replyID: UUID) {
        guard isEnabled, let index = queue.replies.firstIndex(where: { $0.id == replyID }) else {
            return
        }
        keepPlayerUp()
        if index == queue.position {
            switch playback {
            case .speaking: pause(by: .click)
            // Paused resumes where it stopped; idle has no place to carry on
            // from, so `play` starts this reply at its beginning.
            case .paused, .idle: play(trigger: .click)
            }
            return
        }
        let wasShowing = isPlayerShowing
        stopReading()
        guard queue.move(to: index) else { return }
        start(trigger: .click, shownBefore: wasShowing)
        store.save(queue)
    }

    // MARK: - Microphone

    /// One of the two holds moved. A reply speaking is paused the moment
    /// reading becomes held; nothing starts when it lets go (#354: Quiet
    /// ending starts nothing — the count stays until he clicks).
    private func holdChanged() {
        let held = anotherAppHoldsMicrophone || loreRecording
        guard isEnabled, held != isHeldByMicrophone else { return }
        let wasShowing = isPlayerShowing
        defer { traceShownByReading(wasShowing: wasShowing) }
        isHeldByMicrophone = held
        if held {
            recordEvent(.agentReplyHeldByMicrophone)
            if playback == .speaking { pause(by: .microphone) }
        } else {
            recordEvent(.agentReplyMicrophoneFreed(waiting: waitingCount))
        }
    }

    /// Lore's own capture ended — a dictation, or a tap's pre-buffer (#279).
    /// While lore held the device, another app starting or stopping on it made
    /// no edge, so the other apps are read again now.
    func loreCaptureEnded() {
        guard isEnabled else { return }
        microphone?.refresh()
    }

    /// While another app holds the microphone, read it again until it lets go (#327).
    private func recheckWhileAnotherAppHolds() {
        guard anotherAppHoldsMicrophone, holdRecheckTask == nil else { return }
        holdRecheckTask = Task { [weak self, sleep] in
            while true {
                await sleep(Self.holdRecheckInterval)
                guard let self, !Task.isCancelled else { return }
                guard self.anotherAppHoldsMicrophone else {
                    self.holdRecheckTask = nil
                    return
                }
                self.microphone?.refresh()
            }
        }
    }

    // MARK: - Reading

    /// A reply being read brought the player on screen (#285, every showing
    /// since #354 made Loud what brings it up): one trace per showing,
    /// whichever edge brought it — a reply beginning, a paused one carrying
    /// on, a microphone freeing over a paused reply.
    private func traceShownByReading(wasShowing: Bool) {
        guard !wasShowing, isPlayerShowing else { return }
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
    }

    /// Reading ran out. The player has ten seconds left (`isLingering`) so the
    /// reply just read can still be reached, and then hides itself — a list
    /// he opened included (board §09, "The last ten seconds").
    private func goneQuiet() {
        progress = 0
        quietSince = now()
        isListOpen = false
    }

    /// The current reply reached its end: move on, and read the next one only
    /// if the mode read now is Loud (#354). In Quiet the chain stops, and the
    /// replies left are counted in the capsule; asked to stop, it stops too.
    /// While the outside is read the player keeps its ten seconds, so nothing
    /// flickers between two replies.
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
        store.save(queue)
        guard let next = queue.current, !askedForQuiet else {
            goneQuiet()
            return
        }
        quietSince = now()
        surroundings.read { [weak self] outside in
            guard let self, self.isEnabled, self.playback == .idle, self.queue.current?.id == next.id else { return }
            if let reason = self.noteMode(outside).quietReason {
                for reply in self.queue.replies[self.queue.position...]
                where !self.queue.startedIDs.contains(reply.id) {
                    self.silentReasons[reply.id] = self.silentReasons[reply.id] ?? reason
                }
                self.goneQuiet()
            } else {
                self.start(trigger: .continued, shownBefore: wasShowing)
                self.store.save(self.queue)
            }
        }
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
    ///
    /// The language the sender named with `--lang` comes before detection
    /// (#351). The local voice follows the language: the reply's only when no
    /// system voice was asked for by name; the announcement's always, English
    /// for a name in neither language — the service reads each script in its
    /// own voice.
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
        let voice = { (words: String, language: ReadAloudController.TextLanguage) in
            ReadAloudController.resolveVoice(
                for: words, mode: mode, ru: ru, en: en, other: other, single: single,
                hasSpeechifyKey: false, language: language
            )
        }
        let replyLanguage = reply.said.language.flatMap { $0.isEmpty ? nil : ReadAloudController.TextLanguage(code: $0) }
            ?? ReadAloudController.detectLanguage(reply.said.text)
        let byLanguage = voice(reply.said.text, replyLanguage)
        let requested = reply.said.voice.flatMap { wanted in
            installed.first {
                $0.name.caseInsensitiveCompare(wanted) == .orderedSame || $0.id == wanted
            }
        }
        let announced = chat?.spoken ?? ""
        return AgentReplyUtterance(
            announcement: announced.isEmpty ? nil : {
                let chatLanguage = ReadAloudController.detectLanguage(announced)
                let forChat = voice(announced, chatLanguage)
                return AgentReplyVoicedText(
                    text: announced, voiceID: forChat.voiceID,
                    languageCode: forChat.languageParam,
                    localVoice: SileroVoice(chatLanguage) ?? .en116
                )
            }(),
            reply: AgentReplyVoicedText(
                text: reply.said.text,
                voiceID: requested?.id ?? byLanguage.voiceID,
                languageCode: byLanguage.languageParam,
                localVoice: requested == nil ? SileroVoice(replyLanguage) : nil
            )
        )
    }

    private nonisolated static func isPresent(_ value: String?) -> Bool {
        !(value ?? "").isEmpty
    }
}
