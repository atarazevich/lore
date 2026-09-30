import AVFoundation
import Foundation

/// One run of words and the system voice to say them in (#256).
struct AgentReplyVoicedText: Equatable, Sendable {
    let text: String
    /// An `AVSpeechSynthesisVoice` identifier, or `ReadAloudVoiceChoice.systemAutoID`.
    let voiceID: String
    /// The text's detected language, for the automatic voice.
    let languageCode: String?
}

/// What the speaker is asked to say for one reply (#267): the chat announced
/// on its own, a pause, then the reply.
///
/// Two runs of words and one reply. Everything the player counts — pause and
/// resume, progress, the clock and "finished" — is about the pair, and the end
/// is reached once, when the reply's own words run out.
struct AgentReplyUtterance: Equatable, Sendable {
    /// The chat, in a voice for the announcement's own language — an English
    /// name is not read by a Russian voice. Nil when the reply carries no name
    /// to announce.
    let announcement: AgentReplyVoicedText?
    /// The reply itself, in the voice the sender asked for or the one its
    /// language chose.
    let reply: AgentReplyVoicedText
}

/// The one audio path agent replies use. A seam so the queue's behaviour is
/// tested without speech; production speaks live through the system voice.
@MainActor
protocol AgentReplySpeaker: AnyObject {
    /// The reply from the latest `speak` reached its end (never after `stop`).
    var onFinish: (@MainActor () -> Void)? { get set }
    /// Share of the latest reply's own words spoken so far, 0...1. The
    /// announcement in front of them is not counted: what the card's clock
    /// measures is the reply.
    var onProgress: (@MainActor (Double) -> Void)? { get set }
    func speak(_ utterance: AgentReplyUtterance)
    /// Whether the pause took. It takes from the chat's first word to the
    /// reply's last, the half-second between them included (#277): there the
    /// reply not yet begun is held back, and `resume` starts it. It refuses only
    /// once the reply's own words have run out and the finish is still on its
    /// way — a player that called that stopped would have a reply `resume`
    /// cannot restart and a queue that goes nowhere (#267).
    func pause() -> Bool
    /// Whether `pause` would take right now — the chat, the gap after it or
    /// the reply's words sounding. Esc is taken only when it is true (#277):
    /// an Esc that stops nothing is the app in front's.
    var canPause: Bool { get }
    /// Carries on where the pause stopped: mid-word, or — for a pause taken
    /// before the reply began — at the reply's first word, the chat not said
    /// again.
    func resume()
    func stop()
}

/// The `AVSpeechSynthesizer` calls the live speaker makes, as a seam. It exists
/// for one rule that cannot be seen from outside the synthesizer: its pause is
/// sticky — `stopSpeaking(at:)` does not clear a pause taken with
/// `pauseSpeaking(at:)`, and an utterance handed to a paused synthesizer is
/// swallowed silently. The tests model that rule; production is the real class.
@MainActor
protocol AVSpeechSynthesizing: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    var isPaused: Bool { get }
    var isSpeaking: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    @discardableResult func continueSpeaking() -> Bool
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: AVSpeechSynthesizing {}

/// Live `AVSpeechSynthesizer` speech — free, offline, never Speechify (#256).
/// Unlike selected text (#105, rendered to files for Speechify's pipeline and
/// its speed control), a reply is short, has no speed control, and may be
/// replayed by synthesizing again, so it needs no files: pause and resume are
/// the synthesizer's own.
///
/// Built only once the feature's switch is on (#256): the synthesizer is a live
/// audio object and nothing of the feature may exist while it is off.
@MainActor
final class SystemAgentReplySpeaker: NSObject, AgentReplySpeaker {
    var onFinish: (@MainActor () -> Void)?
    var onProgress: (@MainActor (Double) -> Void)?

    /// The pause between the chat and what it said (#267). Long enough to be a
    /// gap rather than a comma, short enough that a reply still starts at once.
    static let announcementPause: TimeInterval = 0.5

    private let synthesizer: any AVSpeechSynthesizing
    /// The reply's own words — the one utterance whose end is the reply's end.
    /// The announcement before it finishes unremarked, and `stop` clears this,
    /// so a late callback can finish nothing.
    private var replyWords: AVSpeechUtterance?
    private var replyLength = 0
    /// The synthesizer has begun the reply's own words (its `didStart`). Until
    /// then a refused pause is the gap after the chat, not the end of the reply.
    private var replyBegun = false
    /// A reply a pause held back before its first word (#277): the synthesizer
    /// cannot pause the silence after the chat, so the reply queued behind it
    /// is taken off the synthesizer and waits here for `resume`, which hands a
    /// copy of it back — a fresh object, so the cancelled one's late callbacks
    /// finish nothing.
    private var heldReply: AVSpeechUtterance?

    init(synthesizer: (any AVSpeechSynthesizing)? = nil) {
        self.synthesizer = synthesizer ?? AVSpeechSynthesizer()
        super.init()
        self.synthesizer.delegate = self
    }

    /// The announcement and the reply are queued together: the synthesizer
    /// speaks them in turn, so pause, resume and stop take both. The one thing
    /// it cannot pause is the silence between them, and that one moment is
    /// held here (`pause`, #277).
    func speak(_ utterance: AgentReplyUtterance) {
        stop()
        // A pause survives the stop above: a synthesizer paused when the next
        // reply arrives stays paused and would swallow it without a sound.
        if synthesizer.isPaused { synthesizer.continueSpeaking() }
        if let announcement = utterance.announcement {
            let named = Self.spoken(announcement)
            named.postUtteranceDelay = Self.announcementPause
            synthesizer.speak(named)
        }
        replyLength = (utterance.reply.text as NSString).length
        speakReply(Self.spoken(utterance.reply))
    }

    private func speakReply(_ words: AVSpeechUtterance) {
        replyWords = words
        replyBegun = false
        synthesizer.speak(words)
    }

    private static func spoken(_ part: AgentReplyVoicedText) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: part.text)
        utterance.voice = SystemSpeechSynthesizer.resolveVoice(
            id: part.voiceID, languageCode: part.languageCode
        )
        return utterance
    }

    func pause() -> Bool {
        if synthesizer.pauseSpeaking(at: .immediate) { return true }
        // Refused: nothing is sounding. Before the reply's first word that is
        // the gap after the chat, and the reply queued behind it would start by
        // itself half a second later — so it comes off the synthesizer and
        // waits for `resume` (#277). After it, the words have run out and the
        // finish is on its way: nothing to stop.
        guard !replyBegun, let words = replyWords else { return false }
        replyWords = nil
        synthesizer.stopSpeaking(at: .immediate)
        heldReply = words
        return true
    }

    var canPause: Bool {
        replyWords != nil && (!replyBegun || synthesizer.isSpeaking)
    }

    func resume() {
        guard let held = heldReply else {
            synthesizer.continueSpeaking()
            return
        }
        heldReply = nil
        speakReply((held.copy() as? AVSpeechUtterance) ?? held)
    }

    func stop() {
        replyWords = nil
        heldReply = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Callbacks name their utterance, so a late one from a replaced or stopped
    /// utterance — or from the announcement in front of this one — cannot
    /// finish the reply that followed it.
    private func isReply(_ id: ObjectIdentifier) -> Bool {
        replyWords.map(ObjectIdentifier.init) == id
    }

    fileprivate func didFinish(_ id: ObjectIdentifier) {
        guard isReply(id) else { return }
        replyWords = nil
        onProgress?(1)
        onFinish?()
    }

    fileprivate func willSpeak(upTo end: Int, of id: ObjectIdentifier) {
        guard isReply(id), replyLength > 0 else { return }
        onProgress?(min(Double(end) / Double(replyLength), 1))
    }

    fileprivate func didStart(_ id: ObjectIdentifier) {
        guard isReply(id) else { return }
        replyBegun = true
    }
}

extension SystemAgentReplySpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.didStart(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.didFinish(id) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        let end = characterRange.location + characterRange.length
        Task { @MainActor in self.willSpeak(upTo: end, of: id) }
    }
}
