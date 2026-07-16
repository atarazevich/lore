import Foundation

/// What Lore knows about its own keyboard tap: the raw measurement **and** the
/// verdict derived from it, in one value so the two cannot disagree — the defect
/// #93 removed from secure input, kept out of here by construction.
///
/// `HotkeyManager` owns the live instance and cannot be tested (every relevant
/// piece of state is `private`, and `install()` creates a real tap), so the logic
/// that was wrong lives here as a pure value type — the move `SummonDebouncer`
/// makes for the notch's debounce.
///
/// Codable and PII-free by construction: Bools and counts, nothing else — the
/// same guarantee `DiagEvent` makes (design §4).
struct TapLiveness: Codable, Sendable, Equatable {
    /// Our tap must be silent for longer than this before the question is even
    /// asked. The health loop ticks every 5 s; this is the window it compares.
    static let threshold: TimeInterval = 30

    /// The tap object exists and `CGEvent.tapIsEnabled` is true. Starts false —
    /// there is no tap until `installEventTap` says so, and a default of `true`
    /// reported green for the 5 s before the first health tick, tap or no tap.
    var isAlive = false

    /// Seconds since **our tap's own callback** last received a key-down.
    var tapSilentSeconds = 0

    /// Seconds since the **session** last received a key-down, from any process.
    var sessionSilentSeconds = 0

    /// The session is receiving key-downs and our tap is not. Latched — see
    /// `observe`. Stored rather than computed so `observe` is its one definition.
    private(set) var isStarved = false

    /// A transition worth recording. Maps 1:1 onto `DiagEvent.tapEventsStalled` /
    /// `.tapEventsResumed`, whose names now describe what they measure.
    enum Edge: Equatable, Sendable { case stalled, resumed }

    /// Feed one health cycle's measurement; returns the edge to record, or `nil`.
    /// Edges, not a heartbeat: the loop ticks every 5 s and the ring buffer is
    /// worthless if one starved minute evicts the launch history (design §4).
    ///
    /// **Only positive evidence moves the verdict.** Our tap receiving a key-down
    /// proves it is fed; the session being fed while we are not proves it is
    /// starved. A quiet machine proves nothing, so it holds the last verdict
    /// rather than clearing it — the old code read that silence as recovery, which
    /// is why a 1436-second stall in report 8763HGZT "resolved" in 5 seconds.
    ///
    /// **Except under secure input, where the starved half is unmeasurable.** The
    /// session gets key-downs and every tap on the machine gets none *by design*,
    /// which is the exact shape this reads as starvation — so the conclusion is
    /// not drawn rather than drawn and compensated for downstream. Latching it
    /// would outlive the condition: `HealthProber.tapStatus`'s #94 gate stops
    /// applying the moment secure input clears, and a latch needs our tap to
    /// receive a key-down to lift, so anyone who typed a password and then reached
    /// for the mouse would be told their keyboard was broken, permanently. The
    /// clearing half is unaffected: a key-down reaching our tap is proof it is fed
    /// no matter what else is true of the machine.
    mutating func observe(
        isAlive: Bool, tapSilent: TimeInterval, sessionSilent: TimeInterval, secureInputActive: Bool
    ) -> Edge? {
        self.isAlive = isAlive
        tapSilentSeconds = Self.count(tapSilent)
        sessionSilentSeconds = Self.count(sessionSilent)

        let was = isStarved
        if tapSilent <= Self.threshold {
            isStarved = false
        } else if sessionSilent <= Self.threshold && !secureInputActive {
            isStarved = true
        }
        guard isStarved != was else { return nil }
        return isStarved ? .stalled : .resumed
    }

    /// An interval as a whole-second count, floored at 0 and capped: the value
    /// crosses a C API boundary and `Int(_:)` traps rather than saturates.
    private static func count(_ interval: TimeInterval) -> Int {
        guard interval > 0 else { return 0 }
        return Int(min(interval, TimeInterval(Int32.max)))
    }
}
