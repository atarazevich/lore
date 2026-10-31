import AppKit
import Foundation
import LoreCore
import LoreFormat
import Observation
import os

private let historyLog = Logger(subsystem: "com.lore.app", category: "DictationHistory")

struct DictationHistoryEntry: Identifiable, Codable, Equatable, HistoryOrdered {
    let id: UUID
    let timestamp: Date
    var status: DictationEntryStatus
    var rawText: String?
    var cleanedText: String?
    var errorMessage: String?
    /// Filename of saved audio (16kHz mono Float32, raw bytes)
    var audioFilename: String?
    var durationSeconds: Double
    /// Which version is displayed in the UI.
    var activeVersion: DictationVersion
    /// Name of the cleanup mode that was applied (for display)
    var cleanupModeName: String?
    /// `CleanupMethod.key` that produced `cleanedText` ("standard",
    /// "bullet-points", ...) \u{2014} drives the "\u{2726} cleaned \u{00B7} <method>" meta line
    /// and the popover checkmark (DIC-35/37). Nil for paste-time default
    /// cleanup. Tolerant string: unknown values render verbatim, no checkmark.
    var cleanupMethodName: String?
    /// `TranslationLanguage.key` when `cleanedText` is a translation
    /// ("english", ...) \u{2014} drives the "\u{2726} translated \u{2192} <lang>" meta line and
    /// the language popover checkmark (DIC-36/37). Tolerant string like
    /// `cleanupMethodName`.
    var translatedToLanguage: String?
    /// Fn+K "send to operator" (#122): the dispatcher's dictation door
    /// processes ONLY entries carrying this flag; everything else is
    /// archive. Optional so the synthesized encoder omits nil — old and
    /// non-flagged entries stay byte-identical on disk. Nothing sets it since
    /// #324 gave K to the mark: entries flagged before keep it, and it is
    /// decoded and written back as it was.
    var operatorAddressed: Bool?
    /// Marked for later (#324): when the mark was set. Nil while not marked —
    /// omitted on disk, like `operatorAddressed`. A new mark replaces it,
    /// Unmark removes it, and only `DictationHistory.setMarked` and the first
    /// write at `add` change it. Agents sign for it in the `.takes` sidecar
    /// beside this file, which the app reads and never writes.
    var markedAt: Date?
    /// What rode along with this dictation (#192): what was copied or
    /// screenshotted while it was being spoken, each at the second it happened.
    /// Optional so the synthesized encoder omits nil — a dictation with nothing
    /// attached stays byte-identical on disk, and Safe Flow's readers, which go
    /// by key, ignore the field entirely. `rawText`/`cleanedText` already carry
    /// the items in place, so nothing downstream has to assemble anything.
    var items: [DictationItem]?
    /// How many times lore has transcribed this take by itself because a
    /// restart caught it before its words were ready (#294). Counted before
    /// each attempt starts, so an attempt that takes the process down still
    /// counts. Optional for the same reason as `items`: nil until the first
    /// attempt, so every other entry stays byte-identical on disk.
    var automaticAttempts: Int?

    /// The text for the currently active version.
    var displayText: String? {
        activeVersion.text(raw: rawText, cleaned: cleanedText)
    }

    /// Whether both raw and cleaned versions are available.
    var hasBothVersions: Bool { rawText != nil && cleanedText != nil }

    init(timestamp: Date = Date(), durationSeconds: Double, audioFilename: String? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.status = .audioSaved
        self.durationSeconds = durationSeconds
        self.audioFilename = audioFilename
        self.activeVersion = .raw
    }

    // Custom decoder for backward compatibility (existing entries lack
    // activeVersion/cleanupModeName). The fields the `lore` command reads too
    // are decoded once, by `StoredDictation` (#301).
    init(from decoder: Decoder) throws {
        let shared = try StoredDictation(from: decoder)
        id = shared.id
        timestamp = shared.timestamp
        status = shared.status
        rawText = shared.rawText
        cleanedText = shared.cleanedText
        durationSeconds = shared.durationSeconds
        activeVersion = shared.activeVersion
        audioFilename = shared.audioFilename
        markedAt = shared.markedAt
        let c = try decoder.container(keyedBy: CodingKeys.self)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        cleanupModeName = try c.decodeIfPresent(String.self, forKey: .cleanupModeName)
        cleanupMethodName = try c.decodeIfPresent(String.self, forKey: .cleanupMethodName)
        translatedToLanguage = try c.decodeIfPresent(String.self, forKey: .translatedToLanguage)
        operatorAddressed = try c.decodeIfPresent(Bool.self, forKey: .operatorAddressed)
        items = try c.decodeIfPresent([DictationItem].self, forKey: .items)
        automaticAttempts = try c.decodeIfPresent(Int.self, forKey: .automaticAttempts)
    }
}

/// How lore writes a history file: an entry's JSON, or a recording's empty
/// audio file. Injectable so tests can refuse writes the way a full disk does
/// (#265); called on the recording's own queue as well as the main actor.
typealias DictationFileWriter = @Sendable (Data, URL) throws -> Void

/// How a deleted dictation's file leaves (#243): to the macOS Trash, never
/// removed outright, answering where it went so it can be put back. Injectable
/// so tests never touch the real Trash. Called off the main actor, one file at
/// a time.
typealias DictationTrash = @Sendable (URL) throws -> URL

/// What a confirmed delete did (#243): the dictations that went; those still
/// in history, whole, because a file of theirs could not be moved to the
/// Trash; and those still in history without a file that went to the Trash
/// and could not be put back.
struct DictationDeletion: Equatable, Sendable {
    var deleted = 0
    var kept = 0
    var incomplete = 0
}

/// A dictation's audio while it is still being spoken (#182). The file is the
/// entry's own from the first buffer, appended to on a private serial queue so
/// the main actor — where capture lands — never waits on the disk, and the
/// entry's JSON is written beside it in that same first operation: audio no
/// entry names can never be matched to anything afterwards. The entry joins
/// `entries` only when the recording ends, so nothing offers a retry over a
/// file that is still growing. Why: `docs/decisions.md` 2026-08-15.
///
/// `@unchecked Sendable`: every mutable field is touched only on `queue`,
/// except `audioIsOnDisk`, which `finish` publishes through it.
final class LiveDictationRecording: @unchecked Sendable {
    /// The entry written at the first buffer. Its duration stays 0 until the
    /// recording ends — the one field a start cannot know.
    let entry: DictationHistoryEntry

    /// Whether the audio reached disk. Meaningful once `finish` has run.
    private(set) var audioIsOnDisk = false

    private let audioURL: URL
    private let entryURL: URL
    private let entryData: Data
    private let queue = DispatchQueue(label: "com.lore.dictation.recording", qos: .userInitiated)

    private var handle: FileHandle?
    /// Set by the first buffer whether or not the file could be created: one
    /// open attempt per recording, and no later buffer can re-create a file
    /// this recording is done with.
    private var attemptedOpen = false
    private var wroteAudio = false

    private let writeData: DictationFileWriter

    init(
        entry: DictationHistoryEntry, audioURL: URL, entryURL: URL, entryData: Data,
        writeData: @escaping DictationFileWriter
    ) {
        self.entry = entry
        self.writeData = writeData
        self.audioURL = audioURL
        self.entryURL = entryURL
        self.entryData = entryData
    }

    /// Hand one capture buffer to the disk. Returns immediately — the copy is
    /// the caller's cost, the write is the queue's.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        queue.async { [self] in
            if !attemptedOpen {
                attemptedOpen = true
                handle = openFiles()
                wroteAudio = handle != nil
            }
            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                // A failed write leaves the file short; appending past it would
                // splice a gap into the middle of the audio. Keep what landed.
                close()
                DiagStore.record(.historyWriteFailed(reason: .init(error: error)))
                historyLog.error("dictation audio write failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// End the recording. Synchronous by design: it runs behind every buffer
    /// already queued, so when it returns, what the user said is on disk.
    func finish() {
        audioIsOnDisk = queue.sync {
            close()
            return wroteAudio
        }
    }

    /// Leave nothing behind — audio and entry file go together, behind every
    /// buffer already queued. Every gesture that does not become a dictation
    /// ends here: a tap, and a slip under half a second that collected nothing
    /// — one carrying items is a dictation after all (#229). (Esc ended here
    /// too, until #206 made it a pause.)
    func abandon() {
        queue.sync {
            close()
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: entryURL)
        }
        audioIsOnDisk = false
    }

    /// The entry this recording wrote at its first buffer, completed with the
    /// duration only the end knows. Nil when no audio reached disk — the
    /// caller still holds the samples and saves them itself. Read after
    /// `finish`.
    func completed(durationSeconds: Double) -> DictationHistoryEntry? {
        guard audioIsOnDisk else { return nil }
        var completed = entry
        completed.durationSeconds = durationSeconds
        return completed
    }

    private func close() {
        try? handle?.close()
        handle = nil
        attemptedOpen = true
    }

    /// The entry lands with the first sample, never after it. Neither file may
    /// survive alone: an entry with no audio offers a retry over nothing, and
    /// audio with no entry is what left six unreferenced blobs on disk (#182).
    private func openFiles() -> FileHandle? {
        do {
            try writeData(entryData, entryURL)
            // Created by a write that throws, so a full disk is named as one.
            try writeData(Data(), audioURL)
            return try FileHandle(forWritingTo: audioURL)
        } catch {
            try? FileManager.default.removeItem(at: entryURL)
            try? FileManager.default.removeItem(at: audioURL)
            DiagStore.record(.historyWriteFailed(reason: .init(error: error)))
            historyLog.error("failed to open recording: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }
}

@Observable
@MainActor
final class DictationHistory {
    private(set) var entries: [DictationHistoryEntry] = []
    /// Monotonic change counter — cheap memoization key for views that derive
    /// expensive projections (filter/group) from `entries` (#51).
    private(set) var revision = 0
    /// The entries whose newest state is in memory and not on disk (#265),
    /// each with why its latest write was refused. The row reads it: an entry
    /// listed here shows its words and says it is not in history yet. Never
    /// latched — every attempt rewrites the reason, and a write that lands
    /// removes the entry, so the line goes with the condition
    /// (`no-false-positives.md` 1–2). Memory only: a quit loses what is here.
    private(set) var unsaved: [UUID: DiagEvent.HistoryWriteReason] = [:]
    /// Entries a transcription, a retry or a row transform is working on right
    /// now (#243), each with how many such jobs hold it. A delete never touches
    /// one: the take lands as it would have, and only then can it go.
    private(set) var inFlight: [UUID: Int] = [:]
    /// What agents signed for (#324): each entry's `.takes` sidecar as last
    /// read. The app never writes one; `lore marks take` appends to it, and
    /// `takesEvents` reads it again when it changes.
    private(set) var takes: [UUID: [DictationTake]] = [:]

    /// How often an unsaved entry is written again while any is waiting.
    static let saveRetryInterval: Duration = .seconds(30)

    private static let legacyStorageKey = "dictationHistory"
    /// The pre-migration UserDefaults blob is preserved under this key
    /// forever — never deleted (#51 migration safety).
    static let legacyBackupKey = "dictationHistory.backup"
    /// Audio retention (#51/#52): text entries are uncapped; past this many
    /// recordings the oldest AUDIO files are pruned at `add`. The entry row
    /// survives with `audioFilename` nilled. 0 = unlimited (never prune).
    /// DictationCoordinator syncs this from Settings before each add, keeping
    /// DictationHistory decoupled from SettingsStore; the default matches the
    /// pre-setting hardcoded policy.
    var audioRetentionLimit = 500

    private let defaults: UserDefaults
    /// Per-entry JSON files live here (one `<uuid>.json` per entry) — replaces
    /// the single UserDefaults blob that was fully re-encoded on every save.
    private let entriesDirectory: URL
    /// Non-private so Settings can measure on-disk audio usage (#52).
    let audioDirectory: URL
    /// Where the images collected during a dictation are written (#192), so
    /// that deleting entries takes their files with them (#196).
    private let richInputDirectory: URL
    /// How an entry file reaches disk. Injectable so tests can refuse writes
    /// the way a full disk does (#265).
    @ObservationIgnored private let writeData: DictationFileWriter
    @ObservationIgnored private let trash: DictationTrash
    /// Deletes whose files are still moving (#243). A job about to work on an
    /// entry waits for them (`deletionsSettled`), so it finds the dictation
    /// either gone or back, never missing for a moment.
    @ObservationIgnored private var deletions: [UUID: Task<DictationDeletion, Never>] = [:]
    @ObservationIgnored private var saveRetryTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// Changes to the history folder (#324), for the sidecars agents append to.
    @ObservationIgnored private var takesEvents: FolderEvents?
    /// Dictations a delete is moving to the Trash now (#324): their sidecars
    /// are the delete's, not orphans.
    @ObservationIgnored private var deleting: Set<UUID> = []
    /// Called whenever `unsaved` may have changed, so the bubble's "not in
    /// history" face follows the row instead of outliving it (#265).
    @ObservationIgnored var onUnsavedChange: (@MainActor () -> Void)?

    /// Where entry files are written, as a person reads a path (#265: the
    /// no-permission line's tooltip).
    var folderForDisplay: String {
        (entriesDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    static var defaultAudioDirectory: URL {
        LoreFiles.dictationAudio(in: LoreFiles.root)
    }

    static var defaultEntriesDirectory: URL {
        LoreFiles.dictationHistory(in: LoreFiles.root)
    }

    /// `defaults` and the directories are injectable so tests never touch the
    /// user's real history or audio files.
    init(
        defaults: UserDefaults = .standard,
        entriesDirectory: URL? = nil,
        audioDirectory: URL? = nil,
        richInputDirectory: URL? = nil,
        writeData: @escaping DictationFileWriter = { try $0.write(to: $1, options: .atomic) },
        trash: @escaping DictationTrash = { url in
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            // No answer means no way back: count it as not moved.
            guard let trashed else { throw CocoaError(.fileWriteUnknown) }
            return trashed as URL
        }
    ) {
        self.defaults = defaults
        self.writeData = writeData
        self.trash = trash
        self.entriesDirectory = entriesDirectory ?? Self.defaultEntriesDirectory
        self.audioDirectory = audioDirectory ?? Self.defaultAudioDirectory
        self.richInputDirectory = richInputDirectory ?? RichInputStore.defaultDirectory
        try? FileManager.default.createDirectory(at: self.audioDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.entriesDirectory, withIntermediateDirectories: true)
        migrateFromDefaultsIfNeeded()
        load()
        var found = DictationTakes.all(in: self.entriesDirectory)
        dropOrphanTakes(&found)
        takes = found.filter { !$0.value.isEmpty }
        takesEvents = FolderEvents(folder: self.entriesDirectory) { [weak self] changed in
            self?.readTakes(changed)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.saveUnsaved()
                // Coming back to lore reads every sidecar again, so a folder
                // event that never arrived cannot leave a row behind.
                self?.readTakes(nil)
            }
        }
    }

    isolated deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func add(_ entry: DictationHistoryEntry) {
        entries.insert(entry, at: 0)
        persist(entry)
        pruneOldestAudioBeyondRetention()
        revision += 1
    }

    /// Whether the entry reached disk — false too when it is no longer in
    /// history.
    ///
    /// - Parameter onlyIfSaved: keep memory as it was when the disk refused the
    ///   change (#294: an attempt count nothing may act on unsaved, which a later
    ///   write would otherwise carry to disk). By default memory takes the
    ///   change regardless: a row the user is looking at keeps its words, says
    ///   it is not in history yet, and is written again by itself (#265).
    @discardableResult
    func update(_ entry: DictationHistoryEntry, onlyIfSaved: Bool = false) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        // The mark is not a copy's to change (#324): a transcription or a row
        // transform holds the entry as it was when the job began, and a mark
        // set or cleared on the row meanwhile must survive its write.
        var entry = entry
        entry.markedAt = entries[index].markedAt
        let refused = writeEntryFile(entry)
        // `onlyIfSaved`: memory moves only behind the disk, so a refusal leaves
        // both as they were — and leaves `unsaved` as it was too.
        if refused != nil, onlyIfSaved { return false }
        entries[index] = entry
        revision += 1
        return settle(entry.id, refused: refused)
    }

    /// Write every unsaved entry again (#265), in its newest in-memory state.
    /// Runs every `saveRetryInterval` while any is waiting, after any other
    /// write that landed, and when lore becomes the active app.
    func saveUnsaved() {
        saveUnsaved(recovered: 0)
    }

    /// `recovered`: entries that already landed on the way here, traced with
    /// the ones this pass saves.
    private func saveUnsaved(recovered: Int) {
        guard !unsaved.isEmpty || recovered > 0 else { return }
        var recovered = recovered
        for id in Array(unsaved.keys) {
            guard let entry = entries.first(where: { $0.id == id }) else {
                unsaved[id] = nil
                continue
            }
            unsaved[id] = writeEntryFile(entry)
            if unsaved[id] == nil { recovered += 1 }
        }
        if recovered > 0 { DiagStore.record(.historySaveRecovered(entries: recovered)) }
        if unsaved.isEmpty {
            saveRetryTask?.cancel()
            saveRetryTask = nil
        }
        onUnsavedChange?()
    }

    /// Write one entry and keep `unsaved` true to the result.
    @discardableResult
    private func persist(_ entry: DictationHistoryEntry) -> Bool {
        settle(entry.id, refused: writeEntryFile(entry))
    }

    /// One write's outcome. A refusal leaves the entry unsaved and the timer
    /// running; a write that lands is the moment to try the others, since
    /// whatever refused them may have cleared.
    private func settle(_ id: UUID, refused: DiagEvent.HistoryWriteReason?) -> Bool {
        guard let refused else {
            let wasUnsaved = unsaved.removeValue(forKey: id) != nil
            saveUnsaved(recovered: wasUnsaved ? 1 : 0)
            return true
        }
        unsaved[id] = refused
        if saveRetryTask == nil {
            saveRetryTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.saveRetryInterval)
                    guard !Task.isCancelled, let self else { return }
                    self.saveUnsaved()
                }
            }
        }
        onUnsavedChange?()
        return false
    }

    // MARK: - Marked for later (#324)

    /// What the row says about this entry's mark.
    func mark(of entry: DictationHistoryEntry) -> DictationMark {
        DictationMark(markedAt: entry.markedAt, takes: takes[entry.id] ?? [])
    }

    /// Mark it for later, or clear the mark. Marking replaces any earlier
    /// mark, so a taken dictation marked again waits for an agent again, and
    /// its earlier takes stay in the sidecar. Written like any other change:
    /// a refused write keeps memory, says so on the row and is retried.
    func setMarked(_ marked: Bool, id: UUID, source: DiagEvent.MarkSource, now: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].markedAt = marked ? now : nil
        revision += 1
        persist(entries[index])
        DiagStore.record(.dictationMarked(source: source, marked: marked))
    }

    /// Read sidecars again: the ones named, or every one when `changed` is nil.
    /// A take that is new since the last read is traced once.
    private func readTakes(_ changed: Set<URL>?) {
        var fresh: [UUID: [DictationTake]]
        let ids: Set<UUID>
        if let changed {
            ids = Set(changed.compactMap(DictationTakes.id(ofSidecar:)))
            guard !ids.isEmpty else { return }
            fresh = Dictionary(uniqueKeysWithValues: ids.map { ($0, DictationTakes.read($0, in: entriesDirectory)) })
        } else {
            fresh = DictationTakes.all(in: entriesDirectory)
            ids = Set(fresh.keys).union(takes.keys)
        }
        dropOrphanTakes(&fresh)
        var moved = false
        for id in ids {
            let lines = fresh[id] ?? []
            let known = takes[id] ?? []
            guard lines != known else { continue }
            for _ in 0..<max(0, lines.count - known.count) { DiagStore.record(.markTakeSeen) }
            takes[id] = lines.isEmpty ? nil : lines
            moved = true
        }
        if moved { revision += 1 }
    }

    /// A sidecar whose dictation is gone is not read, and goes to the Trash
    /// off the main actor: a take that raced a delete creates it again after
    /// its entry left. Gone means in neither history nor its unsaved writes,
    /// not being deleted right now (the delete moves that one), and with no
    /// entry file: a dictation kept after a failed delete keeps its takes
    /// even while its file could not come back.
    private func dropOrphanTakes(_ takes: inout [UUID: [DictationTake]]) {
        let orphans = takes.keys.filter { id in
            !deleting.contains(id) && unsaved[id] == nil && !entries.contains { $0.id == id }
                && !FileManager.default.fileExists(atPath: entryFileURL(id).path)
        }
        guard !orphans.isEmpty else { return }
        for id in orphans { takes[id] = nil }
        let sidecars = orphans.map { DictationTakes.url(of: $0, in: entriesDirectory) }
        let trash = self.trash
        Task.detached(priority: .utility) {
            for sidecar in sidecars where FileManager.default.fileExists(atPath: sidecar.path) {
                if (try? trash(sidecar)) != nil { DiagStore.record(.orphanTakesTrashed) }
            }
        }
    }

    // MARK: - Deleting (#243)

    /// Hold an entry while a job works on it, so no delete can take it.
    func beginWork(on id: UUID) {
        inFlight[id, default: 0] += 1
    }

    func endWork(on id: UUID) {
        guard let holds = inFlight[id] else { return }
        inFlight[id] = holds > 1 ? holds - 1 : nil
    }

    /// The ones a delete may take now: in history, and no job working on them.
    func deletable(_ ids: Set<UUID>) -> Set<UUID> {
        Set(entries.lazy.map(\.id).filter { ids.contains($0) && self.inFlight[$0] == nil })
    }

    /// Whether any of these collected a screenshot still on disk (#196): the
    /// alert names screenshots only then, so nothing goes it does not name.
    func collectedScreenshots(_ ids: Set<UUID>) -> Bool {
        !RichInputStore.files(ofEntries: ids, in: richInputDirectory).isEmpty
    }

    /// Whether this entry's audio is on disk now, not only named. A quit in the
    /// middle of a delete, or a file removed in Finder, leaves an entry naming
    /// audio that is gone; Retry must not be offered over it.
    func hasAudio(_ entry: DictationHistoryEntry) -> Bool {
        guard let filename = entry.audioFilename else { return false }
        return FileManager.default.fileExists(atPath: audioDirectory.appendingPathComponent(filename).path)
    }

    /// Return once no delete is moving files. Retry, the stranded-take sweep
    /// and row transforms call it before they look an entry up: a dictation
    /// being deleted is out of `entries` until its files have moved, and comes
    /// back if they could not.
    func deletionsSettled() async {
        while let running = deletions.values.first { _ = await running.value }
    }

    /// Move these dictations to the Trash: each one's audio, the screenshots
    /// it collected (#196) and its entry file. The rows leave the list at
    /// once; the files go off the main actor, a few milliseconds each.
    ///
    /// Each dictation goes whole or not at all: its entry file goes last, and
    /// when any of its files will not move, the ones already moved are put
    /// back from the Trash. A dictation kept that way is exactly as it was —
    /// in history, read whole by `lore` and Safe Flow — and counts as kept. A
    /// file that cannot be put back either is struck from the kept entry, and
    /// that dictation counts as incomplete. One in flight is never touched.
    ///
    /// - Parameter all: this is Settings' Delete All, which the trace tells
    ///   apart from a row or the select bar.
    @discardableResult
    func delete(_ ids: Set<UUID>, all: Bool = false) async -> DictationDeletion {
        let ids = deletable(ids)
        guard !ids.isEmpty else { return DictationDeletion() }
        let scope: DiagEvent.DictationDeleteScope = all ? .all : ids.count == 1 ? .one : .several
        let doomed = entries.filter { ids.contains($0.id) }
        deleting.formUnion(ids)
        // Out of memory first: no update, retry or unsaved-write can put a
        // file back behind the Trash's back while the move runs. A job that
        // comes for one meanwhile waits in `deletionsSettled`.
        entries.removeAll { ids.contains($0.id) }
        let waiting = unsaved.filter { ids.contains($0.key) }
        for id in waiting.keys { unsaved[id] = nil }
        if unsaved.isEmpty {
            saveRetryTask?.cancel()
            saveRetryTask = nil
        }
        onUnsavedChange?()
        revision += 1

        let plans = doomed.map { entry in
            DeletionPlan(
                id: entry.id,
                audio: entry.audioFilename.map { audioDirectory.appendingPathComponent($0) },
                takes: DictationTakes.url(of: entry.id, in: entriesDirectory),
                entryFile: entryFileURL(entry.id)
            )
        }
        let images = richInputDirectory
        let trash = self.trash
        let token = UUID()
        let job = Task { () -> DictationDeletion in
            // Gone from `deletions` only once memory and disk agree again.
            defer { deletions[token] = nil }
            let stayed = await Task.detached(priority: .userInitiated) {
                Self.trashFiles(of: plans, images: images, trash: trash)
            }.value
            return settleDeletion(doomed, stayed: stayed, waiting: waiting, scope: scope)
        }
        deletions[token] = job
        return await job.value
    }

    /// Put back in history what stayed, struck of any file now in the Trash.
    private func settleDeletion(
        _ doomed: [DictationHistoryEntry], stayed: [UUID: Set<String>],
        waiting: [UUID: DiagEvent.HistoryWriteReason], scope: DiagEvent.DictationDeleteScope
    ) -> DictationDeletion {
        var result = DictationDeletion()
        for var entry in doomed {
            guard let lost = stayed[entry.id] else {
                result.deleted += 1
                continue
            }
            if lost.isEmpty {
                result.kept += 1
                entries.append(entry)
                // Still only in memory, as before the delete: written again by itself.
                if let reason = waiting[entry.id] { _ = settle(entry.id, refused: reason) }
                continue
            }
            result.incomplete += 1
            if let audio = entry.audioFilename, lost.contains(audio) { entry.audioFilename = nil }
            entry.items = entry.items?.filter { item in
                item.path.map { !lost.contains(URL(fileURLWithPath: $0).lastPathComponent) } ?? true
            }
            entries.append(entry)
            // Rewritten so nothing it names is in the Trash — the entry file
            // too, should it be the one that could not come back.
            persist(entry)
        }
        if result.kept + result.incomplete > 0 { entries = entries.newestFirst() }
        deleting.subtract(doomed.map(\.id))
        // The sidecars went with their entries, or came back with them.
        readTakes(Set(doomed.map { DictationTakes.url(of: $0.id, in: entriesDirectory) }))
        forgetInLegacyBlobs(Set(doomed.map(\.id)).subtracting(stayed.keys))
        revision += 1
        DiagStore.record(.dictationsDeleted(
            scope: scope, deleted: result.deleted, kept: result.kept, incomplete: result.incomplete
        ))
        return result
    }

    private struct DeletionPlan: Sendable {
        let id: UUID
        let audio: URL?
        /// What agents signed (#324): it goes after its entry, so `lore marks`
        /// never reads a taken dictation as waiting mid-delete.
        let takes: URL
        let entryFile: URL
    }

    /// The dictations that stayed, each with the names of its files that are
    /// in the Trash and could not be put back (empty: kept whole). A file
    /// already gone counts as moved, so deleting again after a quit or a
    /// failure finishes the job.
    nonisolated private static func trashFiles(
        of plans: [DeletionPlan], images: URL, trash: DictationTrash
    ) -> [UUID: Set<String>] {
        let screenshots = RichInputStore.files(ofEntries: Set(plans.map(\.id)), in: images)
        var stayed: [UUID: Set<String>] = [:]
        for plan in plans {
            let files = ([plan.audio].compactMap { $0 } + (screenshots[plan.id] ?? []) + [plan.entryFile, plan.takes])
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            var moved: [(from: URL, to: URL)] = []
            var refused = false
            for file in files {
                do {
                    moved.append((file, try trash(file)))
                } catch {
                    historyLog.error("could not move a dictation file to the Trash: \(error.localizedDescription, privacy: .private)")
                    refused = true
                    break
                }
            }
            guard refused else { continue }
            for move in moved.reversed() {
                do {
                    try FileManager.default.moveItem(at: move.to, to: move.from)
                } catch {
                    historyLog.error("could not put a dictation file back from the Trash: \(error.localizedDescription, privacy: .private)")
                }
            }
            // Whatever is not where it was is lost to this dictation: one put
            // back that failed, or one the Trash took without saying where.
            stayed[plan.id] = Set(
                files.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
            )
        }
        return stayed
    }

    /// A deleted dictation must not come back from the pre-#51 blob, nor stay
    /// on this Mac in its backup.
    private func forgetInLegacyBlobs(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for key in [Self.legacyStorageKey, Self.legacyBackupKey] {
            guard let data = defaults.data(forKey: key),
                  let blob = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data) else { continue }
            let rest = blob.filter { !ids.contains($0.id) }
            guard rest.count != blob.count else { continue }
            if rest.isEmpty {
                defaults.removeObject(forKey: key)
            } else if let encoded = try? JSONEncoder().encode(rest) {
                defaults.set(encoded, forKey: key)
            }
        }
    }

    /// Open the files a recording is written to while it is being spoken
    /// (#182). The entry is deliberately not added to `entries`: an in-progress
    /// recording must not appear in history, because a growing file has nothing
    /// to retry. It joins the list at `add`, or disappears with `abandon`.
    func beginRecording(timestamp: Date = Date()) -> LiveDictationRecording? {
        let filename = Self.newAudioFilename()
        let entry = DictationHistoryEntry(
            timestamp: timestamp, durationSeconds: 0, audioFilename: filename
        )
        guard let data = try? JSONEncoder().encode(entry) else {
            DiagStore.record(.historyWriteFailed(reason: .other))
            historyLog.error("failed to encode in-progress entry")
            return nil
        }
        return LiveDictationRecording(
            entry: entry,
            audioURL: audioDirectory.appendingPathComponent(filename),
            entryURL: entryFileURL(entry.id),
            entryData: data,
            writeData: writeData
        )
    }

    private static func newAudioFilename() -> String {
        "dictation-\(UUID().uuidString).raw"
    }

    /// Save raw audio samples to disk. Returns the filename.
    func saveAudio(_ samples: [Float]) -> String? {
        let filename = Self.newAudioFilename()
        let url = audioDirectory.appendingPathComponent(filename)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try data.write(to: url)
            return filename
        } catch {
            DiagStore.record(.historyWriteFailed(reason: .init(error: error)))
            historyLog.error("failed to save audio: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Load raw audio samples from disk.
    func loadAudio(filename: String) -> [Float]? {
        Self.readAudio(at: audioDirectory.appendingPathComponent(filename))
    }

    /// A recording, or at most its first `maxSamples`, off any actor (#269).
    nonisolated static func readAudio(at url: URL, maxSamples: Int? = nil) -> [Float]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? maxSamples.map { try handle.read(upToCount: $0 * MemoryLayout<Float>.size) } ?? handle.readToEnd())
            ?? Data()
        return data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            let count = data.count / MemoryLayout<Float>.size
            let floatBuffer = baseAddress.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: floatBuffer, count: count))
        }
    }

    /// Bytes per second of the raw audio files this store writes: the 16 kHz
    /// mono float32 the dictation capture converts to.
    private static let audioBytesPerSecond = 16000.0 * Double(MemoryLayout<Float>.size)

    private func durationOfAudio(_ filename: String) -> Double? {
        let url = audioDirectory.appendingPathComponent(filename)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { return nil }
        return Double(size) / Self.audioBytesPerSecond
    }

    private func deleteAudioFile(for entry: DictationHistoryEntry) {
        guard let filename = entry.audioFilename else { return }
        let url = audioDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    /// Immediate prune for when the retention setting decreases (#52) — the
    /// user shouldn't wait for the next dictation to reclaim disk. Also
    /// adopts `limit` for subsequent add-time pruning. Deleted audio is gone:
    /// raising the limit later cannot restore it.
    func pruneAudio(keeping limit: Int) {
        audioRetentionLimit = limit
        if pruneOldestAudioBeyondRetention() { revision += 1 }
    }

    /// Audio retention (#51/#52): keeps the newest `audioRetentionLimit`
    /// recordings' audio; older audio files are deleted and their entries keep
    /// living with `audioFilename = nil` (the play/retry affordances key off
    /// it). Replaces the old 500-entry cap that deleted text and audio
    /// together. Returns true when anything was pruned.
    @discardableResult
    private func pruneOldestAudioBeyondRetention() -> Bool {
        guard audioRetentionLimit > 0 else { return false } // 0 = unlimited
        let withAudio = entries.indices.filter { entries[$0].audioFilename != nil }
        guard withAudio.count > audioRetentionLimit else { return false }
        // `entries` is newest-first, so everything past the first
        // `audioRetentionLimit` audio-bearing indices is the oldest audio.
        for index in withAudio.dropFirst(audioRetentionLimit) {
            deleteAudioFile(for: entries[index])
            entries[index].audioFilename = nil
            persist(entries[index])
        }
        return true
    }

    // MARK: - Persistence (per-entry files, #51)

    private func entryFileURL(_ id: UUID) -> URL {
        DictationFiles.url(of: id, in: entriesDirectory)
    }

    /// Nil when the entry reached disk; otherwise why it did not.
    private func writeEntryFile(_ entry: DictationHistoryEntry) -> DiagEvent.HistoryWriteReason? {
        guard let data = try? JSONEncoder().encode(entry) else {
            DiagStore.record(.historyWriteFailed(reason: .other))
            historyLog.error("failed to encode entry")
            return .other
        }
        do {
            try writeData(data, entryFileURL(entry.id))
            return nil
        } catch {
            let reason = DiagEvent.HistoryWriteReason(error: error)
            DiagStore.record(.historyWriteFailed(reason: reason))
            historyLog.error("failed to write entry file: \(error.localizedDescription, privacy: .private)")
            return reason
        }
    }

    private func load() {
        var loaded = DictationFiles.entries(DictationHistoryEntry.self, in: entriesDirectory) { url in
            DiagStore.record(.corruptFileAside(artifact: .historyEntry))
            historyLog.error("skipping unreadable entry file: \(url.lastPathComponent, privacy: .private)")
        }.map { entry in
            // A recording interrupted before it ended never learned its
            // duration (#182) — read it back from the audio that survived, so
            // a recovered entry doesn't sit beside its own sound claiming 0:00.
            var entry = entry
            if entry.durationSeconds == 0, let filename = entry.audioFilename,
               let duration = durationOfAudio(filename) {
                entry.durationSeconds = duration
            }
            return entry
        }
        // An aborted migration leaves the legacy blob authoritative: serve
        // any of its entries that never made it to disk, so nothing
        // disappears from the UI while the migration waits to retry.
        if let data = defaults.data(forKey: Self.legacyStorageKey),
           let legacy = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data) {
            let onDisk = Set(loaded.map(\.id))
            loaded += legacy.filter { !onDisk.contains($0.id) }
        }
        entries = loaded.newestFirst()
    }

    /// One-time move off the single UserDefaults JSON blob (#51): decode the
    /// old blob, write per-entry files, keep the raw blob under a backup key
    /// (never deleted). Audio files are untouched. Idempotent: rewriting an
    /// already-migrated entry produces the same file; an undecodable blob is
    /// left in place under the original key.
    ///
    /// The legacy key is cleared ONLY when every entry file wrote
    /// successfully — a partial write (disk full, permissions) leaves the
    /// blob in place so migration retries on the next launch, and `load()`
    /// backfills the missing entries from the blob meanwhile.
    private func migrateFromDefaultsIfNeeded() {
        guard let data = defaults.data(forKey: Self.legacyStorageKey) else { return }
        guard let decoded = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data) else {
            DiagStore.record(.corruptFileAside(artifact: .legacyHistoryBlob))
            historyLog.error("migration: legacy blob undecodable — left in place")
            return
        }
        let written = decoded.filter { writeEntryFile($0) == nil }.count
        guard written == decoded.count else {
            DiagStore.record(.historyMigrated(entries: decoded.count, written: written))
            historyLog.error("migration incomplete — legacy blob kept, retrying next launch")
            return
        }
        defaults.set(data, forKey: Self.legacyBackupKey)
        defaults.removeObject(forKey: Self.legacyStorageKey)
        DiagStore.record(.historyMigrated(entries: decoded.count, written: written))
    }
}
