import Foundation

/// FIFO serializer for one notch surface's window operations (#141).
///
/// DynamicNotchKit's `hide()` awaits a checked continuation that only its
/// `closePanelTask` resumes — and `expand()`/`compact()` start by cancelling
/// that task, and a cancelled `closePanelTask` never resumes the continuation.
/// So a state change landing during hide's ~0.4 s animation strands the
/// awaiting Task forever. Serializing every present/dismiss through one queue
/// makes that interleaving impossible: an operation starts only after the
/// previous one — including a hide, continuation and all — has fully finished.
@MainActor
final class NotchOpQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await op()
        }
    }
}
