import AppKit
import Foundation
import LoreCore
import LoreFormat
import Observation
import os

private let phoneLog = Logger(subsystem: "com.lore.app", category: "PhoneNotes")

/// Notes from the iPhone into Meetings (#309): when the outbox is read, what
/// a failed note costs, and the two things the Settings row may say — that
/// macOS refused iCloud Drive, and that one note could not be brought in.
///
/// Nothing reads the outbox while "Show notes from iPhone" (or Meetings) is
/// off, and nothing reads it on the launch path: the first pass of a launch
/// waits `launchDelay`. After that it is read when the switch turns on, when
/// Settings opens, when lore becomes the active app, and every few minutes —
/// sooner while a note is downloading. No folder watching: the folder may not
/// exist, and watching its parent would itself ask macOS for iCloud Drive.
///
/// Every report is derived from the latest read of this launch
/// (`no-false-positives.md`): the refusal line from the last read, a note's
/// report only while that read still lists the note.
@MainActor
@Observable
final class PhoneNoteImporter {

    /// A note's failures, kept across launches so a note that keeps failing
    /// is not tried on every pass, and its report outlives a relaunch only as
    /// "shown" and "dismissed" — never as a claim (see `reports`).
    struct FailureRecord: Codable, Equatable {
        var failures: Int
        var firstFailure: Date
        var lastFailure: Date
        var stage: DiagEvent.PhoneNoteStage
        var shown = false
        var dismissed = false
    }

    /// The last read of the outbox was refused by macOS.
    private(set) var accessRefused = false

    /// Tries per note before the report may show; then one quiet try a launch.
    static let attemptLimit = 5
    static let recordsKey = "phoneNoteImportFailures"
    static let launchDelay: Duration = .seconds(10)
    static let interval: Duration = .seconds(180)
    static let downloadingInterval: Duration = .seconds(15)

    private var records: [String: FailureRecord]
    /// The notes the latest read of this launch listed. A report shows only
    /// for a note still in it.
    private var listed: Set<String> = []
    /// Notes given their one quiet try this launch, after their tries ran out.
    private var quietTries: Set<String> = []
    private var scanning = false
    /// False until the launch delay has passed: nothing reads before it, not
    /// even lore becoming the active app as it launches.
    private var launched = false
    private var lastListingUnreadable = false
    private var rescanRequested = false
    private var downloading = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var activation: NSObjectProtocol?

    private let outbox: URL
    private let sessionsDirectory: URL
    private let defaults: UserDefaults
    private let isEnabled: @MainActor () -> Bool
    private let now: () -> Date
    private let onImported: @MainActor (String, Bool) async -> Void

    init(
        outbox: URL,
        sessionsDirectory: URL,
        defaults: UserDefaults,
        isEnabled: @escaping @MainActor () -> Bool,
        now: @escaping () -> Date = Date.init,
        onImported: @escaping @MainActor (_ sessionID: String, _ hasTranscript: Bool) async -> Void
    ) {
        self.outbox = outbox
        self.sessionsDirectory = sessionsDirectory
        self.defaults = defaults
        self.isEnabled = isEnabled
        self.now = now
        self.onImported = onImported
        records = defaults.data(forKey: Self.recordsKey)
            .flatMap { try? JSONDecoder().decode([String: FailureRecord].self, from: $0) } ?? [:]
    }

    // MARK: - What the row shows

    /// Notes given up on, not dismissed, and still listed by this launch's
    /// latest read, by start: they withdraw by themselves when the note comes
    /// in or leaves the folder.
    var reports: [(id: String, record: FailureRecord)] {
        records
            .filter { id, record in
                record.failures >= Self.attemptLimit && !record.dismissed && listed.contains(id)
            }
            .map { (id: $0.key, record: $0.value) }
            .sorted { $0.id < $1.id }
    }

    /// The report was on screen: traced once per note, ever.
    func reportShown(_ id: String) {
        guard var record = records[id], !record.shown else { return }
        record.shown = true
        records[id] = record
        save()
        DiagStore.record(.phoneNoteReportShown)
    }

    /// × on the report: hidden for good for this note.
    func dismiss(_ id: String) {
        guard var record = records[id], !record.dismissed else { return }
        record.dismissed = true
        records[id] = record
        save()
        DiagStore.record(.phoneNoteReportDismissed)
    }

    // MARK: - When to read

    /// The passes of this run: the first after `launchDelay`, then on every
    /// interval and whenever lore becomes the active app.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            self?.launched = true
            while !Task.isCancelled {
                await self?.scan()
                let pause = self?.downloading == true ? Self.downloadingInterval : Self.interval
                try? await Task.sleep(for: pause)
            }
        }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Read now: the switch turned on, Settings opened, lore became active.
    /// Not before the launch delay: the first pass of the run is the loop's.
    func refresh() {
        guard launched else { return }
        Task { await scan() }
    }

    /// The switch or Meetings turned off: the last reading is not kept, so
    /// turning it on again shows nothing until a fresh read says so.
    func switchedOff() {
        accessRefused = false
    }

    /// One pass, never two at once: a request during a pass runs one more
    /// after it.
    func scan() async {
        guard isEnabled() else { return }
        guard !scanning else {
            rescanRequested = true
            return
        }
        scanning = true
        repeat {
            rescanRequested = false
            await scanOnce()
        } while rescanRequested && isEnabled()
        scanning = false
    }

    private func scanOnce() async {
        let outbox = outbox
        let sessions = sessionsDirectory
        let listing = await Task.detached(priority: .utility) {
            PhoneNoteImport.removeStaging(in: sessions)
            return PhoneNoteImport.list(outbox: outbox)
        }.value
        // Turned off while macOS was asking: nothing more is read or said.
        guard isEnabled() else { return }
        let unreadable = listing == .unreadable
        if unreadable, !lastListingUnreadable {
            phoneLog.error("iPhone notes folder could not be read")
            DiagStore.record(.phoneNotesFolderUnreadable)
        }
        lastListingUnreadable = unreadable
        let ids: [String]
        switch listing {
        case .refused:
            setRefused(true)
            return
        case .unreadable:
            return
        case .missing:
            ids = []
        case .notes(let found):
            ids = found
        }
        setRefused(false)
        relist(Set(ids))

        downloading = false
        for id in ids where shouldTry(id) {
            guard isEnabled() else { return }
            let outcome = await Task.detached(priority: .utility) {
                PhoneNoteImport.importNote(id, from: outbox, into: sessions)
            }.value
            switch outcome {
            case .imported(let hasTranscript):
                succeeded(id)
                DiagStore.record(.phoneNoteImported(hasTranscript: hasTranscript))
                await onImported(id, hasTranscript)
            case .waiting:
                downloading = true
            case .failed(let stage):
                failed(id, at: stage)
            }
        }
    }

    // MARK: - Retries

    /// A note with failures waits longer after each (1 h, 2 h, 4 h, 8 h), so its
    /// tries span the day the phone may need to get it right; with them spent,
    /// it gets one quiet try a launch, which is how a report clears itself
    /// when the note comes in after all.
    private func shouldTry(_ id: String) -> Bool {
        guard let record = records[id] else { return true }
        if record.failures >= Self.attemptLimit { return quietTries.insert(id).inserted }
        let wait = 3600.0 * pow(2, Double(record.failures - 1))
        return now() >= record.lastFailure.addingTimeInterval(wait)
    }

    private func failed(_ id: String, at stage: DiagEvent.PhoneNoteStage) {
        let at = now()
        var record = records[id] ?? FailureRecord(failures: 0, firstFailure: at, lastFailure: at, stage: stage)
        record.failures += 1
        record.lastFailure = at
        record.stage = stage
        records[id] = record
        save()
        DiagStore.record(.phoneNoteImportFailed(stage: stage, attempt: record.failures))
        if record.failures == Self.attemptLimit {
            quietTries.insert(id)
            DiagStore.record(.phoneNoteImportGaveUp(attempts: record.failures))
        }
    }

    private func succeeded(_ id: String) {
        guard let record = records.removeValue(forKey: id) else { return }
        save()
        if record.shown, !record.dismissed { DiagStore.record(.phoneNoteReportCleared) }
    }

    /// A note no longer listed has left the folder (or was marked imported):
    /// its record goes, and its report with it.
    private func relist(_ ids: Set<String>) {
        listed = ids
        for (id, record) in records where !ids.contains(id) {
            records[id] = nil
            if record.shown, !record.dismissed, record.failures >= Self.attemptLimit {
                DiagStore.record(.phoneNoteReportCleared)
            }
        }
        save()
    }

    private func setRefused(_ refused: Bool) {
        guard refused != accessRefused else { return }
        accessRefused = refused
        DiagStore.record(refused ? .phoneNotesAccessRefused : .phoneNotesAccessRestored)
    }

    private func save() {
        if records.isEmpty {
            defaults.removeObject(forKey: Self.recordsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.recordsKey)
        }
    }
}
