import Foundation
import LoreCore

/// The two wire-format enums this feature decides in (#354), by their short names.
typealias ReplyKeyGesture = DiagEvent.ReplyKeyGesture
typealias ReplyQuietReason = DiagEvent.ReplyQuietReason

/// What a press of the reply key is (#354, board §05), decided from the
/// press's and the release's own timestamps and from whether another key went
/// down while it was held. Pure: the caller feeds it the times and asks it
/// again at `deadline`, so the whole table is walked without a keyboard.
///
/// | He does     | Read as                                                   | Acts                    |
/// |-------------|-----------------------------------------------------------|-------------------------|
/// | click       | up within 400 ms, no second press within 250 ms of the up | 250 ms after the up     |
/// | click twice | a second press within 250 ms of the first one's up        | at the second press     |
/// | hold        | still down at 400 ms                                      | at 400 ms; the up: none |
/// | with a key  | any other key pressed while it is down (⌥E, ⌥⇧K)          | nothing: it was typing  |
struct AgentReplyKeyPress: Equatable, Sendable {
    /// A press let go before this is a click; still down at it, a hold.
    static let holdMark: TimeInterval = 0.4
    /// After a click's release, how long a second press makes it a double.
    static let secondPressWindow: TimeInterval = 0.25

    enum State: Equatable, Sendable {
        case idle
        /// Down since `at`; `typed` once another key went down with it.
        case down(at: TimeInterval, typed: Bool)
        /// A click let go at `at`, waiting out the window for a second press.
        case released(at: TimeInterval)
        /// The press has acted (a hold, or the second press of a double): its
        /// release does nothing.
        case spent
    }

    private(set) var state: State = .idle

    /// When the press now down began; nil while the key is up.
    var pressedAt: TimeInterval? {
        if case .down(let at, _) = state { return at }
        return nil
    }

    /// When `tick` has something to decide; nil while nothing is pending.
    var deadline: TimeInterval? {
        switch state {
        case .down(let at, false): at + Self.holdMark
        case .released(let at): at + Self.secondPressWindow
        case .idle, .down, .spent: nil
        }
    }

    /// The press began at `time`. A second press inside the window is the
    /// double, at once; one that came after a window nobody ticked settles
    /// the click it owed first.
    mutating func press(at time: TimeInterval) -> ReplyKeyGesture? {
        switch state {
        case .idle, .spent:
            state = .down(at: time, typed: false)
            return nil
        case .released(let at):
            if time - at <= Self.secondPressWindow {
                state = .spent
                return .twice
            }
            state = .down(at: time, typed: false)
            return .click
        case .down:
            return nil
        }
    }

    /// The key came up at `time`. A hold the tick did not reach yet is still a
    /// hold by the timestamps.
    mutating func release(at time: TimeInterval) -> ReplyKeyGesture? {
        switch state {
        case .down(let at, let typed):
            if typed {
                state = .idle
                return nil
            }
            if time - at < Self.holdMark {
                state = .released(at: time)
                return nil
            }
            state = .idle
            return .hold
        case .spent:
            state = .idle
            return nil
        case .idle, .released:
            return nil
        }
    }

    /// Another key went down — a letter, or another modifier. While the reply
    /// key is down that makes the press typing. Between a click's release and
    /// its window running out it changes nothing: the click was a click.
    mutating func otherKey() {
        if case .down(let at, _) = state { state = .down(at: at, typed: true) }
    }

    /// The clock reached `time`: a hold at its mark, a click once its window
    /// has passed.
    mutating func tick(at time: TimeInterval) -> ReplyKeyGesture? {
        switch state {
        case .down(let at, false) where time - at >= Self.holdMark:
            state = .spent
            return .hold
        case .released(let at) where time - at >= Self.secondPressWindow:
            state = .idle
            return .click
        default:
            return nil
        }
    }

    /// Forget any press under way: the feature went off, or the key changed.
    mutating func reset() { state = .idle }
}

// MARK: - Quiet and Loud

/// What lore reads outside itself when a reply arrives (#354): the app in
/// front and the other apps' sound. Lore's own microphone and recording are
/// the controller's own state and are not here.
struct AgentReplySurroundings: Equatable, Sendable {
    var gameInFront = false
    var otherAppSound = false
}

/// Whether an arriving reply is read aloud or filed silently (#354, board §06).
enum AgentReplyMode: Equatable, Sendable {
    case loud
    case quiet(ReplyQuietReason)

    var quietReason: ReplyQuietReason? {
        if case .quiet(let reason) = self { return reason }
        return nil
    }

    /// Quiet while any one is true, named by the first in the board's order —
    /// microphone, game, sound, then lore's own recording (a dictation, or a
    /// meeting); Loud otherwise.
    static func resolve(
        otherAppMicrophone: Bool, surroundings: AgentReplySurroundings, loreRecording: ReplyQuietReason?
    ) -> AgentReplyMode {
        if otherAppMicrophone { return .quiet(.microphone) }
        if surroundings.gameInFront { return .quiet(.game) }
        if surroundings.otherAppSound { return .quiet(.sound) }
        if let loreRecording { return .quiet(loreRecording) }
        return .loud
    }
}

/// Whether the app in front is a game (#354): its Info.plist files it under
/// the App Store's games category or one of its sub-categories
/// (`public.app-category.action-games` …), or it has captured the display
/// the way exclusive full-screen games do — a window at the shielding level
/// covering a whole screen. A full-screen browser or video sits at the normal
/// level in its own Space and is not a game.
enum AgentReplyGame {
    static func isGame(category: String?, capturesDisplay: Bool) -> Bool {
        if capturesDisplay { return true }
        guard let category else { return false }
        return category == "public.app-category.games"
            || (category.hasPrefix("public.app-category.") && category.hasSuffix("-games"))
    }
}
