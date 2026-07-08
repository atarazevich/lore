import Foundation
import os

/// Thread-safe ring buffer of `DiagRecord`, persisted to
/// `~/Library/Application Support/Lore/events.json` (design: docs/design/diagnostics.md §4).
/// Never `/tmp` — the old `/tmp/lore.log` was mode 0644, readable by any process.
///
/// **Concurrency.** `record(_:)` is callable from any thread or queue, including
/// CoreAudio's `listenerQueue` and the HAL queue, and never blocks on I/O: it takes
/// an `OSAllocatedUnfairLock` (priority-donating, no inversion on Darwin) for the
/// duration of one slot write, then leaves. Persistence is coalesced onto a
/// background serial queue, at most one write per `flushInterval`, so a burst of
/// events costs one `asyncAfter` rather than one per event.
///
/// **Initialization.** The lazy `static let shared` decodes the persisted ring —
/// real disk I/O. `DiagStore.prepare()` forces that to happen on the main thread
/// at launch, *before* any capture path exists, so no `record()` from `halQueue`
/// or a CoreAudio listener queue can ever be the thread that pays for it.
///
/// The store deliberately holds no reference to the app: it is a leaf.
final class DiagStore: @unchecked Sendable {

    /// Ring capacity. 2000 events ≈ several sessions of real use.
    static let capacity = 2000

    /// Coalescing window for disk writes.
    private static let flushInterval: TimeInterval = 1.0

    static let shared = DiagStore(directory: defaultDirectory)

    private let fileURL: URL
    private let directory: URL
    private let flushQueue = DispatchQueue(label: "com.lore.diag-store.flush", qos: .utility)
    private let log = Logger(subsystem: "com.lore.app", category: "DiagStore")

    /// Everything mutable lives inside the lock's state — no `@unchecked` hand-waving
    /// beyond the immutable `let`s above.
    private let state: OSAllocatedUnfairLock<State>

    private struct State {
        /// Preallocated slots: `append` writes one slot and moves an index. No
        /// resize, no rehash, bounded work under the lock.
        var slots: [DiagRecord?]
        var next = 0
        var count = 0
        /// True while a coalesced flush is already scheduled.
        var flushScheduled = false

        mutating func append(_ record: DiagRecord) {
            slots[next] = record
            next = (next + 1) % slots.count
            count = Swift.min(count + 1, slots.count)
        }

        /// Oldest → newest.
        var chronological: [DiagRecord] {
            guard count > 0 else { return [] }
            let capacity = slots.count
            let start = count < capacity ? 0 : next
            return (0..<count).compactMap { slots[(start + $0) % capacity] }
        }
    }

    // MARK: - Init

    init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("events.json")

        let loaded = Self.loadPersisted(from: fileURL)
        var initial = State(slots: Array(repeating: nil, count: Self.capacity))
        for record in loaded.records {
            initial.append(record)
        }
        self.state = OSAllocatedUnfairLock(uncheckedState: initial)

        // The store's own corruption is a diagnostic fact like any other. Recorded
        // after `state` exists, so it lands in the fresh ring rather than vanishing.
        if loaded.wasCorrupt {
            record(.corruptFileAside(artifact: .eventsJSON))
        }
    }

    /// Under XCTest the store writes to a per-process temp directory, so a test run
    /// never touches the user's real `events.json`.
    private static var defaultDirectory: URL {
        if RuntimeEnvironment.isRunningUnitTests {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent(
                    "LoreDiagStore-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Lore", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Force `shared` into existence (decoding the persisted ring, and possibly
    /// moving a corrupt file aside) on the caller's thread. Call once at launch,
    /// on main, before audio or the hotkey tap can run: otherwise the first
    /// `record()` — which may come from `halQueue` or a CoreAudio listener queue —
    /// would perform that disk I/O there, contradicting this class's whole promise.
    static func prepare() {
        _ = shared
    }

    // MARK: - Recording

    /// Append one event. Safe from any thread; never performs I/O on the caller.
    static func record(_ event: DiagEvent) {
        shared.record(event)
    }

    func record(_ event: DiagEvent) {
        let record = DiagRecord(event: event)
        let needsSchedule = state.withLock { state -> Bool in
            state.append(record)
            guard !state.flushScheduled else { return false }
            state.flushScheduled = true
            return true
        }
        guard needsSchedule else { return }
        flushQueue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.flush()
        }
    }

    // MARK: - Reading

    /// The most recent `n` events, oldest → newest.
    func recent(_ n: Int) -> [DiagRecord] {
        Array(state.withLock { $0.chronological }.suffix(n))
    }

    /// The latest event matching `predicate` — how the health panel asks
    /// "what happened the last time we tried to capture?".
    func last(where predicate: (DiagRecord) -> Bool) -> DiagRecord? {
        state.withLock { $0.chronological }.last(where: predicate)
    }

    // MARK: - Persistence

    /// Write the ring to disk. Called on `flushQueue`; safe to call directly in tests.
    func flush() {
        let snapshot = state.withLock { state -> [DiagRecord] in
            state.flushScheduled = false
            return state.chronological
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A diagnostic store that throws while recording a failure is worse
            // than one that stays quiet. The in-memory ring is still intact.
            // The error embeds the file path — private, like every other write error.
            log.error("events.json write failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Decode the persisted ring. A file that exists but does not decode is moved
    /// aside rather than rebuilt over — see `FileAside`, shared with the
    /// `chat.json` policy in `SessionRepository`.
    private static func loadPersisted(from url: URL) -> (records: [DiagRecord], wasCorrupt: Bool) {
        guard let data = try? Data(contentsOf: url) else { return ([], false) }
        if let decoded = try? decoder.decode([DiagRecord].self, from: data) {
            return (Array(decoded.suffix(capacity)), false)
        }
        FileAside.move(url)
        return ([], true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
