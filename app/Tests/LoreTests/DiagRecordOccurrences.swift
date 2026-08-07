@testable import LoreKit

/// Reading a folded ring (#149). Identical consecutive events share one record
/// carrying a count, so any test that asks "how many times did this happen"
/// counts occurrences, not slots.
extension Collection where Element == DiagRecord {
    var occurrences: Int {
        reduce(0) { $0 + $1.occurrences }
    }

    /// One event per occurrence, in order.
    var occurrenceEvents: [DiagEvent] {
        flatMap { Array(repeating: $0.event, count: $0.occurrences) }
    }
}
