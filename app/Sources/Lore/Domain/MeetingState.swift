import Foundation

// MARK: - Meeting State

/// The lifecycle state of a meeting recording session.
/// Designed as a pure value type for testability.
enum MeetingState: Sendable, Equatable {
    /// No active session. The system is waiting.
    case idle

    /// A session is actively recording.
    case recording(MeetingMetadata)

    /// The user suspended capture (#153). The session, its transcript and its
    /// audio files are all still open — nothing is finalized, and a resume
    /// continues the same session. Distinct from `.recording` because no audio
    /// is being captured, and distinct from `.idle` because a session exists.
    case paused(MeetingMetadata)

    /// Recording has stopped; the session is being finalized (draining audio, writing files).
    case ending(MeetingMetadata)
}

extension MeetingState {
    /// The metadata of whatever session exists, in any non-idle phase.
    var metadata: MeetingMetadata? {
        switch self {
        case .idle: nil
        case .recording(let m), .paused(let m), .ending(let m): m
        }
    }

    /// A session the user is still inside: capturing or suspended. `.ending`
    /// is not live — finalization is underway and no user action applies to it.
    /// This is the predicate for "stop is possible", "a second start must be
    /// rejected", "quitting needs a warning" (#153).
    var isLive: Bool {
        switch self {
        case .recording, .paused: true
        case .idle, .ending: false
        }
    }
}

/// How a session arrived at `.paused` (#153). The user asking is the ordinary
/// case; a resume that could not bring capture back is the other, and the two
/// must not leave the same trace — a `sessionPaused` following a
/// `sessionResumed` would read as a resume that hung.
enum PauseCause: Sendable, Equatable {
    case userRequest
    case resumeFailed
}

// MARK: - Meeting Event

/// Events that drive state transitions in the meeting lifecycle.
enum MeetingEvent: Sendable {
    /// The user pressed Start.
    case userStarted(MeetingMetadata)

    /// Capture is suspended in place (#153). The cause does not change the
    /// transition — only what it leaves in the diagnostic record.
    case userPaused(PauseCause)

    /// The user pressed Resume (#153). Continues the same session.
    case userResumed

    /// The user pressed Stop.
    case userStopped

    /// The user discarded the current session (delete files, return to idle).
    case userDiscarded

    /// Finalization (drain + write sidecar) completed.
    case finalizationComplete

    /// Finalization timed out. Force transition to idle.
    case finalizationTimeout
}

// MARK: - Pure Transition Function

/// Pure function: given a state and event, returns the next state.
/// No side effects. All side effects are dispatched by the coordinator after transition.
func transition(from state: MeetingState, on event: MeetingEvent) -> MeetingState {
    switch (state, event) {

    // idle + userStarted -> recording
    case (.idle, .userStarted(let metadata)):
        return .recording(metadata)

    // recording + userPaused -> paused (same metadata: one session spans the gap)
    case (.recording(let metadata), .userPaused):
        return .paused(metadata)

    // paused + userResumed -> recording (the session never ended)
    case (.paused(let metadata), .userResumed):
        return .recording(metadata)

    // recording + userStopped -> ending
    case (.recording(let metadata), .userStopped):
        return .ending(metadata)

    // paused + userStopped -> ending. Stop from a pause finalizes what was
    // captured; it never has to be resumed first.
    case (.paused(let metadata), .userStopped):
        return .ending(metadata)

    // recording + userDiscarded -> idle (discard without finalizing)
    case (.recording, .userDiscarded):
        return .idle

    // paused + userDiscarded -> idle (same: drop the session, files and all)
    case (.paused, .userDiscarded):
        return .idle

    // ending + finalizationComplete -> idle
    case (.ending, .finalizationComplete):
        return .idle

    // ending + finalizationTimeout -> idle (forced)
    case (.ending, .finalizationTimeout):
        return .idle

    // All other combinations are no-ops: double-start, stop while idle, a
    // pause while already paused, a resume while recording, and any pause or
    // resume aimed at `.idle`/`.ending` — nothing to suspend, nothing to
    // continue.
    default:
        return state
    }
}
