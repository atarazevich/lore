import Foundation
import Observation
import os

private let historyLog = Logger(subsystem: "com.lore.app", category: "DictationHistory")

enum DictationEntryStatus: String, Codable {
    case audioSaved
    case transcribed
    case cleaned
    case failed
}

enum DictationVersion: String, Codable {
    case raw
    case cleaned
}

struct DictationHistoryEntry: Identifiable, Codable, Equatable {
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
    /// non-flagged entries stay byte-identical on disk. Call sites write
    /// `true` (or nil to unflag) and read `== true`; `false` is never
    /// stored.
    var operatorAddressed: Bool?
    /// What rode along with this dictation (#192): what was copied or
    /// screenshotted while it was being spoken, each at the second it happened.
    /// Optional so the synthesized encoder omits nil — a dictation with nothing
    /// attached stays byte-identical on disk, and Safe Flow's readers, which go
    /// by key, ignore the field entirely. `rawText`/`cleanedText` already carry
    /// the items in place, so nothing downstream has to assemble anything.
    var items: [DictationItem]?

    /// The text for the currently active version.
    var displayText: String? {
        switch activeVersion {
        case .cleaned: cleanedText ?? rawText
        case .raw: rawText ?? cleanedText
        }
    }

    /// Whether both raw and cleaned versions are available.
    var hasBothVersions: Bool { rawText != nil && cleanedText != nil }

    var hasAudio: Bool { audioFilename != nil }

    init(timestamp: Date = Date(), durationSeconds: Double, audioFilename: String? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.status = .audioSaved
        self.durationSeconds = durationSeconds
        self.audioFilename = audioFilename
        self.activeVersion = .raw
    }

    // Custom decoder for backward compatibility (existing entries lack activeVersion/cleanupModeName)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        status = try c.decode(DictationEntryStatus.self, forKey: .status)
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText)
        cleanedText = try c.decodeIfPresent(String.self, forKey: .cleanedText)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        audioFilename = try c.decodeIfPresent(String.self, forKey: .audioFilename)
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        activeVersion = try c.decodeIfPresent(DictationVersion.self, forKey: .activeVersion)
            ?? (cleanedText != nil ? .cleaned : .raw)
        cleanupModeName = try c.decodeIfPresent(String.self, forKey: .cleanupModeName)
        cleanupMethodName = try c.decodeIfPresent(String.self, forKey: .cleanupMethodName)
        translatedToLanguage = try c.decodeIfPresent(String.self, forKey: .translatedToLanguage)
        operatorAddressed = try c.decodeIfPresent(Bool.self, forKey: .operatorAddressed)
        items = try c.decodeIfPresent([DictationItem].self, forKey: .items)
    }
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

    init(entry: DictationHistoryEntry, audioURL: URL, entryURL: URL, entryData: Data) {
        self.entry = entry
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
                DiagStore.record(.historyWriteFailed)
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
            try entryData.write(to: entryURL, options: .atomic)
            guard FileManager.default.createFile(atPath: audioURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return try FileHandle(forWritingTo: audioURL)
        } catch {
            try? FileManager.default.removeItem(at: entryURL)
            try? FileManager.default.removeItem(at: audioURL)
            DiagStore.record(.historyWriteFailed)
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
    /// Non-nil after a failed entry-file write, cleared by the next
    /// successful one. The status strip renders it as a thin red line — a
    /// silently unsaved history must be visible (#51 review).
    private(set) var lastSaveError: String?

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

    static var defaultAudioDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Lore/DictationAudio", isDirectory: true)
    }

    static var defaultEntriesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Lore/DictationHistory", isDirectory: true)
    }

    /// `defaults` and the directories are injectable so tests never touch the
    /// user's real history or audio files.
    init(
        defaults: UserDefaults = .standard,
        entriesDirectory: URL? = nil,
        audioDirectory: URL? = nil,
        richInputDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.entriesDirectory = entriesDirectory ?? Self.defaultEntriesDirectory
        self.audioDirectory = audioDirectory ?? Self.defaultAudioDirectory
        self.richInputDirectory = richInputDirectory ?? RichInputStore.defaultDirectory
        try? FileManager.default.createDirectory(at: self.audioDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.entriesDirectory, withIntermediateDirectories: true)
        migrateFromDefaultsIfNeeded()
        load()
    }

    func add(_ entry: DictationHistoryEntry) {
        entries.insert(entry, at: 0)
        writeEntryFile(entry)
        pruneOldestAudioBeyondRetention()
        revision += 1
    }

    func update(_ entry: DictationHistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        writeEntryFile(entry)
        revision += 1
    }

    /// "Clear history" means everything: audio, the images the dictations
    /// collected (#196), every entry file in the directory (including stray
    /// leftovers), and the legacy blob + its migration backup — nothing may
    /// resurrect deleted entries later.
    func clear() {
        for entry in entries { deleteAudioFile(for: entry) }
        // What a dictation collected goes with it (#196): its images are named
        // after the entry, so nothing outlives the row that pointed at it.
        RichInputStore.deleteFiles(
            ofEntries: Set(entries.map(\.id)), directory: richInputDirectory
        )
        entries.removeAll()
        if let files = try? FileManager.default.contentsOfDirectory(
            at: entriesDirectory, includingPropertiesForKeys: nil
        ) {
            for url in files where url.pathExtension == "json" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        defaults.removeObject(forKey: Self.legacyStorageKey)
        defaults.removeObject(forKey: Self.legacyBackupKey)
        revision += 1
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
            DiagStore.record(.historyWriteFailed)
            historyLog.error("failed to encode in-progress entry")
            return nil
        }
        return LiveDictationRecording(
            entry: entry,
            audioURL: audioDirectory.appendingPathComponent(filename),
            entryURL: entryFileURL(entry.id),
            entryData: data
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
            DiagStore.record(.historyWriteFailed)
            historyLog.error("failed to save audio: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Load raw audio samples from disk.
    func loadAudio(filename: String) -> [Float]? {
        let url = audioDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
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
            writeEntryFile(entries[index])
        }
        return true
    }

    // MARK: - Persistence (per-entry files, #51)

    private func entryFileURL(_ id: UUID) -> URL {
        entriesDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Returns false when the entry could not be persisted; the failure is
    /// surfaced through `lastSaveError` (cleared by the next success).
    @discardableResult
    private func writeEntryFile(_ entry: DictationHistoryEntry) -> Bool {
        guard let data = try? JSONEncoder().encode(entry) else {
            DiagStore.record(.historyWriteFailed)
            historyLog.error("failed to encode entry")
            lastSaveError = "Couldn't save history"
            return false
        }
        do {
            try data.write(to: entryFileURL(entry.id), options: .atomic)
            lastSaveError = nil
            return true
        } catch {
            DiagStore.record(.historyWriteFailed)
            historyLog.error("failed to write entry file: \(error.localizedDescription, privacy: .private)")
            lastSaveError = "Couldn't save history"
            return false
        }
    }

    private func load() {
        var loaded: [DictationHistoryEntry] = []
        if let files = try? FileManager.default.contentsOfDirectory(
            at: entriesDirectory, includingPropertiesForKeys: nil
        ) {
            for url in files where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                   var entry = try? JSONDecoder().decode(DictationHistoryEntry.self, from: data) {
                    // A recording interrupted before it ended never learned its
                    // duration (#182) — read it back from the audio that
                    // survived, so a recovered entry doesn't sit beside its own
                    // sound claiming 0:00.
                    if entry.durationSeconds == 0, let filename = entry.audioFilename,
                       let duration = durationOfAudio(filename) {
                        entry.durationSeconds = duration
                    }
                    loaded.append(entry)
                } else {
                    DiagStore.record(.corruptFileAside(artifact: .historyEntry))
                    historyLog.error("skipping unreadable entry file: \(url.lastPathComponent, privacy: .private)")
                }
            }
        }
        // An aborted migration leaves the legacy blob authoritative: serve
        // any of its entries that never made it to disk, so nothing
        // disappears from the UI while the migration waits to retry.
        if let data = defaults.data(forKey: Self.legacyStorageKey),
           let legacy = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data) {
            let onDisk = Set(loaded.map(\.id))
            loaded += legacy.filter { !onDisk.contains($0.id) }
        }
        // Stable across launches: id breaks timestamp ties deterministically.
        entries = loaded.sorted {
            $0.timestamp != $1.timestamp
                ? $0.timestamp > $1.timestamp
                : $0.id.uuidString < $1.id.uuidString
        }
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
        let written = decoded.filter { writeEntryFile($0) }.count
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
