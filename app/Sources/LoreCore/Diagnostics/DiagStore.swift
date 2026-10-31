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
/// **Repeats do not evict history** (#149, diagnostics.md §4): an event identical
/// to the newest record folds into it as a count plus a last-seen timestamp
/// instead of taking a slot. Still typed, still no free-form string (#82).
///
/// **Initialization.** The lazy `static let shared` decodes the persisted ring —
/// real disk I/O. `DiagStore.prepare()` forces that to happen on the main thread
/// at launch, *before* any capture path exists, so no `record()` from `halQueue`
/// or a CoreAudio listener queue can ever be the thread that pays for it.
///
/// **Records this build cannot read are kept** (#314). events.json is decoded one
/// record at a time; a record an older build does not understand (a case name or
/// enum value from a newer build) stays in its slot as its own JSON and is
/// written back with it, so the build that wrote it can still
/// read it. It holds its place in file order, which is last-seen order, and ages
/// out of the ring like any record. Readers never see it: `recent` and `last`
/// return decoded records only, and no repeat ever folds into it.
///
/// The store deliberately holds no reference to the app: it is a leaf.
public final class DiagStore: @unchecked Sendable {

    /// Ring capacity. 2000 events ≈ several sessions of real use.
    static let capacity = 2000

    /// Coalescing window for disk writes.
    private static let flushInterval: TimeInterval = 1.0

    public static let shared = DiagStore(directory: defaultDirectory)

    private let fileURL: URL
    private let directory: URL
    private let flushQueue = DispatchQueue(label: "com.lore.diag-store.flush", qos: .utility)
    private let log = Logger(subsystem: "com.lore.app", category: "DiagStore")

    /// Everything mutable lives inside the lock's state — no `@unchecked` hand-waving
    /// beyond the immutable `let`s above.
    private let state: OSAllocatedUnfairLock<State>

    public func setObserver(_ onRecord: (@Sendable (DiagEvent) -> Void)?) {
        state.withLock { $0.observer = onRecord }
    }

    /// One slot of the ring: a record this build reads, or one it kept unread
    /// as the JSON of a single array element (#314).
    private enum Slot {
        case decoded(DiagRecord)
        case unread(Data)

        var decoded: DiagRecord? {
            if case .decoded(let record) = self { return record }
            return nil
        }
    }

    private struct State {
        /// Preallocated slots: `append` writes one slot and moves an index. No
        /// resize, no rehash, bounded work under the lock.
        var slots: [Slot?]
        var next = 0
        var count = 0
        /// True while a coalesced flush is already scheduled.
        var flushScheduled = false
        /// The one observer (#140): `HealthMonitor` listens for failed user actions
        /// so a summon fires *because something just failed*, not because a 5 s loop
        /// re-read a state bit. Called synchronously from `record()` on whatever
        /// thread recorded — the observer must filter cheaply and hop itself.
        /// A struct field (#291): a bare closure as `withLock`'s generic state is
        /// re-thunked on every read, deepening the call per event.
        var observer: (@Sendable (DiagEvent) -> Void)?

        /// Fold a consecutive repeat into the newest record, or take a fresh slot.
        ///
        /// Only the newest record, so a fold always touches the tail and slot
        /// order stays last-seen order — reaching further back would let a repeat
        /// land behind an unrelated newer event, and "what happened after this
        /// point" is what the ring is for. A repeating *cycle* of distinct events
        /// is bounded at its source (`RetryBudget`) instead.
        ///
        /// An unread newest slot never folds: what it holds is unknown, so the
        /// repeat takes a fresh slot after it.
        mutating func append(_ record: DiagRecord) {
            let newest = (next - 1 + slots.count) % slots.count
            if count > 0, case .decoded(var last) = slots[newest], last.event == record.event {
                last.merge(record)
                slots[newest] = .decoded(last)
                return
            }
            take(.decoded(record))
        }

        /// Write `slot` at the head, evicting the oldest once full.
        mutating func take(_ slot: Slot) {
            slots[next] = slot
            next = (next + 1) % slots.count
            count = Swift.min(count + 1, slots.count)
        }

        /// Every slot, oldest → newest — what is written back to disk.
        var allChronological: [Slot] {
            guard count > 0 else { return [] }
            let capacity = slots.count
            let start = count < capacity ? 0 : next
            return (0..<count).compactMap { slots[(start + $0) % capacity] }
        }

        /// Decoded records only, oldest → newest — what every reader sees.
        var chronological: [DiagRecord] {
            allChronological.compactMap(\.decoded)
        }
    }

    // MARK: - Init

    init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("events.json")

        let loaded = Self.loadPersisted(from: fileURL)
        var initial = State(slots: Array(repeating: nil, count: Self.capacity))
        for slot in loaded.slots {
            switch slot {
            case .decoded(let record): initial.append(record)
            case .unread: initial.take(slot)
            }
        }
        self.state = OSAllocatedUnfairLock(uncheckedState: initial)

        // The store's own corruption is a diagnostic fact like any other. Recorded
        // after `state` exists, so it lands in the fresh ring rather than vanishing.
        if loaded.wasCorrupt {
            record(.corruptFileAside(artifact: .eventsJSON))
        }
        let unread = loaded.slots.reduce(0) { $1.decoded == nil ? $0 + 1 : $0 }
        if unread > 0 {
            record(.unreadRecordsKept(count: unread))
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
    public static func prepare() {
        _ = shared
    }

    // MARK: - Recording

    /// Append one event. Safe from any thread; never performs I/O on the caller.
    public static func record(_ event: DiagEvent) {
        shared.record(event)
    }

    public func record(_ event: DiagEvent) {
        let record = DiagRecord(event: event)
        let (needsSchedule, observer) = state.withLock { state in
            state.append(record)
            defer { state.flushScheduled = true }
            return (!state.flushScheduled, state.observer)
        }
        observer?(event)
        guard needsSchedule else { return }
        flushQueue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.write()
        }
    }

    // MARK: - Reading

    /// The most recent `n` events, oldest → newest.
    public func recent(_ n: Int) -> [DiagRecord] {
        Array(state.withLock { $0.chronological }.suffix(n))
    }

    /// The latest event matching `predicate` — how the health panel asks
    /// "what happened the last time we tried to capture?". Slot order is
    /// last-seen order (see `append`), so the last match is the latest one.
    public func last(where predicate: (DiagRecord) -> Bool) -> DiagRecord? {
        state.withLock { $0.chronological }.last(where: predicate)
    }

    // MARK: - Persistence

    /// Write the ring to disk now, from any thread but `flushQueue`. Runs on
    /// `flushQueue` like the coalesced write, so writes never interleave and the
    /// last one on disk always carries the latest snapshot (#314: a pending write
    /// could otherwise land after this one with an older ring).
    public func flush() {
        dispatchPrecondition(condition: .notOnQueue(flushQueue))
        flushQueue.sync { write() }
    }

    /// Snapshot and write. Only ever runs on `flushQueue`.
    private func write() {
        let snapshot = state.withLock { state -> [Slot] in
            state.flushScheduled = false
            return state.allChronological
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            // Element by element, so an unread record goes back as the JSON it
            // was kept as. Joined like this, a file of decoded records is
            // byte-identical to encoding the whole array at once.
            var data = Data("[".utf8)
            for (index, slot) in snapshot.enumerated() {
                if index > 0 { data.append(UInt8(ascii: ",")) }
                switch slot {
                case .decoded(let record): data.append(try Self.encoder.encode(record))
                case .unread(let raw): data.append(raw)
                }
            }
            data.append(UInt8(ascii: "]"))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A diagnostic store that throws while recording a failure is worse
            // than one that stays quiet. The in-memory ring is still intact.
            // The error embeds the file path — private, like every other write error.
            log.error("events.json write failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Decode the persisted ring one record at a time (#314). A record this build
    /// cannot decode is kept as its own JSON — re-serialized, so semantically
    /// identical rather than byte-identical, which is all a later `JSONDecoder`
    /// needs. A file that is not a JSON array at all is moved aside rather than
    /// rebuilt over — see `FileAside`, shared with the `chat.json` policy in
    /// `SessionRepository`.
    private static func loadPersisted(from url: URL) -> (slots: [Slot], wasCorrupt: Bool) {
        guard let data = try? Data(contentsOf: url) else { return ([], false) }
        guard let elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            FileAside.move(url)
            return ([], true)
        }
        // A value `JSONSerialization` just parsed always serializes back.
        let slots = elements.suffix(capacity).compactMap { element -> Slot? in
            guard let json = try? JSONSerialization.data(
                withJSONObject: element, options: .fragmentsAllowed
            ) else { return nil }
            if let record = try? decoder.decode(DiagRecord.self, from: json) {
                return .decoded(record)
            }
            return .unread(json)
        }
        return (slots, false)
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
