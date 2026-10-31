import Foundation

/// A bounded budget for retrying something that can keep failing (#149).
///
/// Spends one attempt per failure, refuses further attempts once spent, and
/// starts over only on a **fresh signal** — never on a timer, which is the
/// unbounded loop this replaces. Owns all four retry sites: the two taps that
/// need a TCC grant to install (keyboard, system audio) and AudioBus's start
/// retries and no-frames recoveries. Rationale: docs/design/diagnostics.md §6.
/// One timer retry is allowed outside it: `DictationHistory` writes its unsaved
/// entries again every 30 s (#265) — a write costs nothing, and the timer stops
/// once nothing is unsaved.
public struct RetryBudget: Sendable {
    /// How many consecutive failures are tolerated before giving up.
    let limit: Int
    public private(set) var failures: Int

    /// `failures` already spent — a budget carried across launches on disk.
    public init(limit: Int, failures: Int = 0) {
        self.limit = limit
        self.failures = failures
    }

    /// `false` once the budget is spent.
    public var allowsAttempt: Bool { failures < limit }

    /// Record one failed attempt. Returns `true` on the failure that exhausts
    /// the budget — the one moment worth a diagnostic event.
    @discardableResult
    public mutating func noteFailure() -> Bool {
        guard allowsAttempt else { return false }
        failures += 1
        return failures == limit
    }

    /// A success, or a fresh user signal: attempts start over.
    public mutating func reset() { failures = 0 }
}
