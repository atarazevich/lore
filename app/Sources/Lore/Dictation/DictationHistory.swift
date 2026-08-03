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
        audioDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.entriesDirectory = entriesDirectory ?? Self.defaultEntriesDirectory
        self.audioDirectory = audioDirectory ?? Self.defaultAudioDirectory
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

    /// "Clear history" means everything: audio, every entry file in the
    /// directory (including stray leftovers), and the legacy blob + its
    /// migration backup — nothing may resurrect deleted entries later.
    func clear() {
        for entry in entries { deleteAudioFile(for: entry) }
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

    /// Save raw audio samples to disk. Returns the filename.
    func saveAudio(_ samples: [Float]) -> String? {
        let filename = "dictation-\(UUID().uuidString).raw"
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
                   let entry = try? JSONDecoder().decode(DictationHistoryEntry.self, from: data) {
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
