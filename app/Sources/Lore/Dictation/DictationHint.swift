import Foundation

// MARK: - The five hints (#235)

/// One thing a feature says from its own element, at the moment it would help
/// (#235). Board: `docs/design/prototypes/dictation-hints.html`; the policy, the
/// numbers and the reasoning behind each: `docs/features/contextual-hints.md`.
///
/// Four of the five are *lessons* — they teach a key and retire once the user
/// has used it. One is a *report*: it states a fact about now, is shown whenever
/// that fact is true and withdrawn the instant it is not
/// (`no-false-positives.md`).
///
/// **Declaration order is the priority order** the arbiter reads: report before
/// lesson, then the order the concept fixed. `allCases` is that list, so the
/// ordering lives in one place and cannot be restated somewhere else and drift.
enum DictationHint: String, Codable, Sendable, CaseIterable {
    /// H5 — frames are arriving and none of them carry sound.
    case silentMic
    /// H1 — ten seconds into a held recording, from the open lock.
    case lock
    /// H1b — the first lock ever, from the closed lock.
    case howItEnds
    /// H2 — twenty seconds of quiet inside a locked recording, from the dot.
    case pause
    /// H3 — two minutes in with cleanup unarmed, from the `V` keycap.
    case cleanup

    /// A report states a fact about the world rather than about the app: it is
    /// never counted against the three-showings ceiling, carries no ×, and is
    /// withdrawn the moment its condition ends.
    var isReport: Bool { self == .silentMic }

    /// Which element of the bubble the card's arrow stands on — the element that
    /// owns the feature the sentence is about.
    ///
    /// The pointer's own vocabulary (`BubbleTipOwner`), because it is the same
    /// set of elements: a second enum naming three of them would be one more
    /// place for the dot to stop meaning the dot.
    var anchor: BubbleTipOwner {
        switch self {
        case .silentMic, .pause: .dot
        case .lock, .howItEnds: .lock
        case .cleanup: .letter(.cleanup)
        }
    }

    /// The dot's own line, in the one place both surfaces read it from: the
    /// pause hint speaks it, and it is the locked dot's hover tooltip. One
    /// action, one name (`ui-language.md` rule 1) — the em dash included.
    static let pauseLine = "Recording \u{2014} click to pause"

    /// The board's copy table (§06), as the card draws it: the words, and the
    /// keys the sentence names standing in it as lit keycaps.
    ///
    /// The line breaks are the board's, not a re-wrap: every hint is at most two
    /// lines, which is exactly the room the canvas already keeps under the shape
    /// (`BubbleTipCard.height`), so a card appearing can never resize the
    /// window whatever the chosen talk key's name turns out to be.
    ///
    /// - Parameter talkKey: the keycap of the key the user actually holds
    ///   (#226) — `Fn` unless they recorded another.
    func sentence(talkKey: String) -> [[DictationHintPiece]] {
        switch self {
        case .lock:
            [[.key("Space"), .words(" locks recording,")], [.words("hands free")]]
        case .howItEnds:
            [
                [.words("Press "), .key(talkKey), .words(" to paste,")],
                [.key("Esc"), .words(" to cancel")],
            ]
        case .pause:
            [[.words(Self.pauseLine)]]
        case .cleanup:
            [[.chord(talkKey, "V"), .words(" cleans up on paste")]]
        case .silentMic:
            [[.words("No sound is reaching")], [.words("the microphone")]]
        }
    }
}

/// So the record's dictionary can be keyed by the hint itself and still encode
/// as a JSON object. SE-0320 supplies the whole implementation for a
/// `String`-backed `RawRepresentable`; the conformance is the only thing to say.
extension DictationHint: CodingKeyRepresentable {}

/// One piece of a hint's sentence.
enum DictationHintPiece: Equatable, Sendable {
    case words(String)
    /// A key the sentence names, drawn as the rail's own keycap, lit — a key set
    /// in prose has to be decoded, a keycap is recognised.
    case key(String)
    /// Two keys pressed together. Its own case rather than three pieces because
    /// the board gives a chord one property no run of pieces has: the caps close
    /// on the `+` with none of the margin a lone keycap carries, so `Fn+V` reads
    /// as one press instead of two keys and a symbol.
    case chord(String, String)

    /// What this piece contributes to the sentence read aloud.
    var plain: String {
        switch self {
        case .words(let text): text
        case .key(let name): name
        case .chord(let first, let second): "\(first)+\(second)"
        }
    }
}

extension [[DictationHintPiece]] {
    /// The sentence as one string — the copy table's row, and the card's
    /// VoiceOver name. The board's line breaks are a drawing decision, so they
    /// become the single space a reader hears.
    var plain: String {
        map { $0.map(\.plain).joined() }.joined(separator: " ")
    }
}

// MARK: - What is remembered

/// What the app remembers about one hint (#235): the smallest record that
/// answers every question the policy asks.
struct DictationHintState: Codable, Equatable, Sendable {
    /// The calendar days this hint has been shown on, each as its own start of
    /// day — the bucket the rest of the app already groups dictations into.
    var shownDays: [Date] = []
    /// The × was clicked — never again.
    var closed = false
    /// The action the hint teaches has been performed. Someone who already does
    /// it never sees the hint, whether or not it was ever shown.
    var done = false
}

/// Every hint's record, as one value (#235). One `SettingsStore` property and
/// one defaults key rather than fifteen: the five states change together, are
/// read together on every poll, and mean nothing apart.
struct DictationHintRecord: Codable, Equatable, Sendable {
    /// At most three showings, each on a different calendar day. Why three:
    /// `docs/features/contextual-hints.md`.
    static let maxShowings = 3

    private var states: [DictationHint: DictationHintState] = [:]

    subscript(hint: DictationHint) -> DictationHintState {
        get { states[hint] ?? DictationHintState() }
        set { states[hint] = newValue }
    }

    /// May this hint be shown at all today? A report is always eligible: it is
    /// not a lesson, so nothing about it is counted.
    func isEligible(_ hint: DictationHint, now: Date, calendar: Calendar = .current) -> Bool {
        guard !hint.isReport else { return true }
        let state = self[hint]
        return !state.closed && !state.done
            && state.shownDays.count < Self.maxShowings
            && !state.shownDays.contains { calendar.isDate($0, inSameDayAs: now) }
    }

    func isDone(_ hint: DictationHint) -> Bool { self[hint].done }

    mutating func markShown(_ hint: DictationHint, on now: Date, calendar: Calendar = .current) {
        guard !hint.isReport,
              !self[hint].shownDays.contains(where: { calendar.isDate($0, inSameDayAs: now) })
        else { return }
        self[hint].shownDays.append(calendar.startOfDay(for: now))
    }

    mutating func markClosed(_ hint: DictationHint) {
        guard !hint.isReport else { return }
        self[hint].closed = true
    }

    /// - Returns: `true` the first time the action is seen, so the caller can
    ///   write the record once rather than on every poll.
    @discardableResult
    mutating func markDone(_ hint: DictationHint) -> Bool {
        guard !hint.isReport, !self[hint].done else { return false }
        self[hint].done = true
        return true
    }
}

// MARK: - What the arbiter reads

/// Everything the arbiter is told, taken at one tick of the indicator's 50 ms
/// poll (#235). Every field is a fact that poll already carries — no row needs a
/// new sensor. What the arbiter can read for itself (the settings it holds) is
/// not here.
struct DictationHintSignals: Equatable, Sendable {
    /// The dictation is still capturing. What ends a recording for the arbiter,
    /// and the only thing that clears what one accumulated.
    var capturing = false

    /// The shape can carry a card at all: a live, uncancelled recording with no
    /// failure face standing on it. Computed by `DictationIndicatorView.canExpand`
    /// — the same predicate the shape draws the card by — so the two cannot
    /// disagree for a tick about whether a card is even possible.
    ///
    /// Distinct from `capturing` on purpose: a failure face can come and go
    /// inside one recording, and that is not a new dictation to start counting
    /// from again.
    var canSpeak = false

    /// The card the arbiter chose is really on screen. A card is counted, traced
    /// and put on its six seconds from the first tick this is true — the cleanup
    /// card's own element arrives only after the rail widens, and a card nobody
    /// saw may not spend one of its three days.
    var cardDrawn = false

    /// This dictation's own audio length, which freezes while paused.
    var elapsedSeconds = 0
    var locked = false
    var paused = false
    /// The pointer has opened a tooltip: intent beats a hint.
    var hoverTipShowing = false
    /// Frames are arriving and none of them carried sound
    /// (`DictationCoordinator.noSignal`).
    var noSignal = false
    /// `AudioBus`'s own level, `min(rms * 25, 1)`.
    var level: Float = 0
    /// Cleanup is armed for this dictation (Fn+V, or the `V` keycap). The
    /// standing setting behind it is the arbiter's own to read.
    var cleanupArmed = false
}

// MARK: - The arbiter

/// The one place that decides whether a hint may speak, which one, and when it
/// goes (#235).
///
/// It rides the indicator's existing 50 ms poll: `tick` is called with the
/// moment's signals and answers with the hint to draw. Every deadline is derived
/// from the `now` it is handed rather than from a timer of its own, which is
/// what keeps a recording to one clock — and what makes the six seconds, the
/// twenty seconds of quiet and the five of silence testable without waiting for
/// any of them.
@MainActor
final class DictationHintArbiter {

    // MARK: The numbers
    //
    // What each is and why it is that: `docs/features/contextual-hints.md`,
    // "The numbers, and where they come from".

    /// Held capture before the lock speaks.
    static let lockSeconds = 10

    /// Capture before cleanup speaks.
    static let cleanupSeconds = 120

    /// Under the speech floor, after speech was heard, before the dot offers the
    /// pause.
    static let quietSeconds: TimeInterval = 20

    /// Digital silence before the microphone is reported.
    static let silenceSeconds: TimeInterval = 5

    /// How long a card stays — and how long a chosen one waits for the shape to
    /// draw it before being dropped unshown.
    static let cardSeconds: TimeInterval = 6

    /// A recording's opening, in which nothing speaks.
    static let settleSeconds = 2

    /// What counts as speech on `AudioBus`'s own `audioLevel` scale
    /// (`min(rms * 25, 1)`), the only level the poll carries.
    static let speechFloor: Float = 0.1

    // MARK: State

    /// The hint the shape is being asked to draw — chosen, but not yet
    /// necessarily on screen.
    private(set) var chosen: DictationHint?
    /// The hint the shape has reported drawing: the one that has cost a day, and
    /// the only one the × or the six seconds can reach.
    private(set) var showing: DictationHint?

    private let settings: AppSettings
    private var record: DictationHintRecord

    /// When this card's clock started — at the choice while it waits to be
    /// drawn, and again at the moment it is. Both waits are `cardSeconds`: a
    /// card the shape cannot draw is dropped as quietly as it was chosen.
    private var cardSince = Date.distantPast
    /// The pointer is on the card.
    private var cardHeld = false

    // Per recording, all cleared when one ends.
    private var inRecording = false
    /// A lesson has already spoken in this recording. One hint per recording —
    /// a report is not counted, because a true report may not be suppressed by a
    /// lesson that happened to speak first (board §05, amended 2026-09-04).
    private var lessonShown = false
    private var wasLocked = false
    private var previousLocked = false
    /// A lock transition is a moment, not a state, so it is latched until the
    /// hint gets its chance (the first two seconds, a failure face or a hover
    /// tooltip can all be standing when it happens).
    private var pendingHowItEnds = false
    private var speechHeard = false
    private var quietSince: Date?
    private var silentSince: Date?
    /// One card per standing silence: the report re-arms when sound comes back,
    /// so a microphone that stays muted is named once rather than every six
    /// seconds. The dimmed dot and the flat bars go on saying it (#216).
    private var reportArmed = true

    /// - Parameter history: read at every launch, for the one thing history can
    ///   answer — an entry that was already cleaned means this user knows about
    ///   cleanup, and the hint is done before it is ever shown. Re-read rather
    ///   than latched behind a first-run flag, so an entry cleaned after the
    ///   update counts too; `markDone` writes once and answers false after.
    ///   Lock use cannot be seeded: nothing ever recorded it (which is what
    ///   `dictationLocked` fixes).
    init(settings: AppSettings, history: DictationHistory?) {
        self.settings = settings
        self.record = settings.dictationHints
        if history?.entries.contains(where: { $0.cleanedText != nil }) == true {
            markDone(.cleanup)
        }
    }

    // MARK: One tick of the poll

    /// - Returns: the hint the bubble should be drawing at this moment, or nil.
    @discardableResult
    func tick(_ signals: DictationHintSignals, now: Date = Date()) -> DictationHint? {
        guard signals.capturing else {
            endRecording()
            return nil
        }
        if !inRecording {
            reset()
            inRecording = true
        }
        observe(signals, now: now)

        // At most one card decision per tick: a card that goes leaves the slot
        // empty until the next one, 50 ms later. Choosing a replacement in the
        // same breath would let a card the shape cannot draw be re-chosen
        // forever inside one tick's worth of state.
        if let hint = chosen {
            // The shape reports when the card is really on screen; only then
            // does it cost a day, leave a trace and start its six seconds.
            if showing == nil, signals.cardDrawn { beginShowing(hint, now: now) }

            if !stillStands(hint, signals) {
                // A lesson's action was performed — the best dismissal there is,
                // since the user just learned it by doing it — or the report's
                // condition ended, which is a different fact and says so.
                withdraw(hint, hint.isReport ? .conditionCleared : .actionPerformed)
            } else if signals.hoverTipShowing || !signals.canSpeak || signals.paused {
                // The slot was taken by something with more right to it: the
                // pointer's own tooltip, a failure face, or the paused face —
                // a card teaching a live recording has nothing to say over a
                // capture that is standing still.
                withdraw(hint, .displaced)
            } else if cardHeld {
                cardSince = now
                return hint
            } else if now.timeIntervalSince(cardSince) >= Self.cardSeconds {
                // Shown, and its six seconds are up — or chosen and never drawn,
                // which is not a showing: it spends nothing and leaves no trace,
                // so the next tick is free to choose it again.
                if showing == nil { drop() } else { withdraw(hint, .timedOut) }
            } else {
                return hint
            }
            return nil
        }

        guard gatesOpen(signals) else { return nil }
        guard let next = candidate(signals, now: now) else { return nil }
        choose(next, now: now)
        return next
    }

    /// The pointer is on the card, which holds the six seconds; they start again
    /// when it leaves.
    func hold(_ holding: Bool) { cardHeld = holding }

    /// The ×: this hint is done for good. Only a card the user can see has one.
    func close() {
        guard let hint = showing, !hint.isReport else { return }
        withdraw(hint, .closed)
    }

    // MARK: Reading the moment

    /// Every action the hints teach, watched live — so a user who already does
    /// one never sees its hint, shown or not.
    private func observe(_ signals: DictationHintSignals, now: Date) {
        if signals.locked {
            wasLocked = true
            if !previousLocked {
                markDone(.lock)
                pendingHowItEnds = true
            }
        }
        previousLocked = signals.locked

        if signals.paused { markDone(.pause) }
        if cleanupOn(signals) { markDone(.cleanup) }

        if signals.level >= Self.speechFloor {
            speechHeard = true
            quietSince = nil
        } else if speechHeard, quietSince == nil {
            quietSince = now
        }

        if signals.noSignal {
            if silentSince == nil { silentSince = now }
        } else {
            silentSince = nil
            reportArmed = true
        }
    }

    /// Cleanup will happen to this dictation — armed for it, or on for every
    /// one. Either answers both questions the cleanup hint asks: whether the
    /// user already knows the feature, and whether the offer is worth making.
    private func cleanupOn(_ signals: DictationHintSignals) -> Bool {
        signals.cleanupArmed || settings.cleanupByDefault
    }

    /// When a hint may appear at all: only on a shape that can carry one, never
    /// in a recording's first two seconds, never while a hover tooltip is up,
    /// never while paused.
    private func gatesOpen(_ signals: DictationHintSignals) -> Bool {
        signals.canSpeak && signals.elapsedSeconds >= Self.settleSeconds
            && !signals.hoverTipShowing && !signals.paused
    }

    /// The highest-priority hint that is both triggered and allowed to speak.
    private func candidate(
        _ signals: DictationHintSignals, now: Date
    ) -> DictationHint? {
        DictationHint.allCases.first { hint in
            (hint.isReport || !lessonShown)
                && record.isEligible(hint, now: now)
                && triggered(hint, signals, now: now)
        }
    }

    private func triggered(
        _ hint: DictationHint, _ signals: DictationHintSignals, now: Date
    ) -> Bool {
        switch hint {
        case .silentMic:
            reportArmed && hasStood(silentSince, Self.silenceSeconds, now)
        case .lock:
            // DSET-05: with Space-lock off there is no lock glyph to speak from.
            settings.modifierLockEnabled && !signals.locked
                && signals.elapsedSeconds >= Self.lockSeconds
        case .howItEnds:
            pendingHowItEnds
        case .pause:
            signals.locked && hasStood(quietSince, Self.quietSeconds, now)
        case .cleanup:
            signals.elapsedSeconds >= Self.cleanupSeconds && !cleanupOn(signals)
        }
    }

    private func hasStood(_ since: Date?, _ seconds: TimeInterval, _ now: Date) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) >= seconds
    }

    /// Does the card still have something to say? A lesson until its action is
    /// performed; the report for exactly as long as its condition is true.
    private func stillStands(_ hint: DictationHint, _ signals: DictationHintSignals) -> Bool {
        hint.isReport ? signals.noSignal : !record.isDone(hint)
    }

    // MARK: Choosing, showing, withdrawing, remembering

    /// The shape is asked to draw this card. Nothing is spent yet.
    private func choose(_ hint: DictationHint, now: Date) {
        chosen = hint
        showing = nil
        cardSince = now
        cardHeld = false
    }

    /// The card is on screen. Now it costs a day, leaves a trace, and starts its
    /// six seconds.
    private func beginShowing(_ hint: DictationHint, now: Date) {
        showing = hint
        cardSince = now
        if hint.isReport {
            reportArmed = false
        } else {
            lessonShown = true
            record.markShown(hint, on: now)
            settings.dictationHints = record
        }
        if hint == .howItEnds { pendingHowItEnds = false }
        DiagStore.record(.hintShown(hint: hint))
    }

    /// A chosen card the shape never drew. It was never seen, so it spends
    /// nothing and says nothing.
    private func drop() {
        chosen = nil
        showing = nil
        cardHeld = false
    }

    private func withdraw(_ hint: DictationHint, _ reason: DiagEvent.HintWithdrawal) {
        let wasShown = showing != nil
        drop()
        guard wasShown else { return }
        if reason == .closed {
            record.markClosed(hint)
            settings.dictationHints = record
        }
        DiagStore.record(.hintWithdrawn(hint: hint, reason: reason))
    }

    private func markDone(_ hint: DictationHint) {
        guard record.markDone(hint) else { return }
        settings.dictationHints = record
    }

    private func endRecording() {
        guard inRecording else { return }
        if let hint = chosen { withdraw(hint, .recordingEnded) }
        // The first finish from a locked recording is what retires "how it
        // ends" — whichever way it finished, and however the lock was cleared on
        // the way out (#225).
        if wasLocked { markDone(.howItEnds) }
        reset()
    }

    private func reset() {
        inRecording = false
        lessonShown = false
        wasLocked = false
        previousLocked = false
        pendingHowItEnds = false
        speechHeard = false
        quietSince = nil
        silentSince = nil
        reportArmed = true
        drop()
    }
}
