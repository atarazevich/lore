import Foundation
import os

private let repoLog = Logger(subsystem: "com.lore.app", category: "SessionRepository")

// MARK: - Supporting Types

/// Lightweight metadata returned by `listSessions()`.
/// Mirrors `SessionIndex` but is produced from the canonical `session.json`.
typealias SessionIndexEntry = SessionIndex

/// Metadata needed to start a new session.
struct SessionStartConfig: Sendable {
    let templateID: UUID?
    let templateSnapshot: TemplateSnapshot?
    /// Initial title written at creation (#58: "Weekday HH:MM" default).
    let title: String?
    /// The recording's start, the instant its default title was made from
    /// (#269); now when nil.
    let startedAt: Date?

    init(
        templateID: UUID? = nil,
        templateSnapshot: TemplateSnapshot? = nil,
        title: String? = nil,
        startedAt: Date? = nil
    ) {
        self.templateID = templateID
        self.templateSnapshot = templateSnapshot
        self.title = title
        self.startedAt = startedAt
    }
}

/// Handle returned by `startSession` — callers use `sessionID` to address
/// subsequent writes.
struct SessionHandle: Sendable {
    let sessionID: String
}

/// Metadata attached to each live utterance write.
struct LiveUtteranceMetadata: Sendable {
    let utteranceID: UUID?
    let transcriptStore: TranscriptStore?
    let isDelayed: Bool

    init(
        utteranceID: UUID? = nil,
        transcriptStore: TranscriptStore? = nil,
        isDelayed: Bool = false
    ) {
        self.utteranceID = utteranceID
        self.transcriptStore = transcriptStore
        self.isDelayed = isDelayed
    }
}

/// Metadata collected at finalization time. The title is not part of it:
/// finalization preserves the title stored at creation (or set by a rename
/// during the recording).
struct SessionFinalizeMetadata: Sendable {
    let endedAt: Date
    let utteranceCount: Int
    let language: String?
    let meetingApp: String?
    let engine: String?
    let templateSnapshot: TemplateSnapshot?
    let utterances: [Utterance]
}

/// Full session detail for loading.
struct SessionDetail: Sendable {
    let index: SessionIndex
    let transcript: [SessionRecord]
    let liveTranscript: [SessionRecord]
    let notes: EnhancedNotes?
    let notesMeta: NotesMeta?
}

/// Metadata persisted alongside notes.
struct NotesMeta: Codable, Sendable {
    let templateSnapshot: TemplateSnapshot
    let generatedAt: Date
}

// MARK: - Canonical session.json

/// The metadata file stored at `sessions/<id>/session.json`.
struct SessionMetadata: Codable, Sendable {
    let id: String
    var startedAt: Date
    var endedAt: Date?
    var templateSnapshot: TemplateSnapshot?
    var title: String?
    var utteranceCount: Int
    var hasNotes: Bool
    var language: String?
    var meetingApp: String?
    var engine: String?
    var tags: [String]?
    /// How the session was created (nil for live sessions, "imported" for imported audio).
    var source: String?
    /// Fresh-meeting marker (MREV-39): true while batch/import output is
    /// pending or unseen; cleared on view. Optional — absent in older files.
    var unviewed: Bool? = nil
    /// On-device enrichment summary (#107). nil = not yet enriched — the
    /// single idempotency rule for the enrichment sweep. Optional — absent
    /// in older files, which therefore backfill themselves.
    var summary: String? = nil
    /// Persisted no-speech verdict (#166): a completed pass over this
    /// session's audio produced no transcript. Cleared when a final
    /// transcript lands. Optional — absent in older files.
    var noSpeech: Bool? = nil
    /// File name of this meeting's Markdown mirror in the notes folder (#280),
    /// so a rename moves its one mirror instead of leaving the old one behind.
    /// Optional — absent in older files and before the first mirror.
    var mirrorFileName: String? = nil
}

extension SessionIndex {
    /// Index entry derived from a canonical `session.json`.
    init(from meta: SessionMetadata) {
        self.init(
            id: meta.id,
            startedAt: meta.startedAt,
            endedAt: meta.endedAt,
            templateSnapshot: meta.templateSnapshot,
            title: meta.title,
            utteranceCount: meta.utteranceCount,
            hasNotes: meta.hasNotes,
            language: meta.language,
            meetingApp: meta.meetingApp,
            engine: meta.engine,
            tags: meta.tags,
            source: meta.source,
            unviewed: meta.unviewed,
            summary: meta.summary,
            noSpeech: meta.noSpeech
        )
    }
}

// MARK: - SessionRepository

/// Unified storage actor replacing SessionStore + TranscriptLogger.
///
/// Canonical layout per session:
/// ```
/// sessions/<id>/session.json
/// sessions/<id>/transcript.live.jsonl
/// sessions/<id>/transcript.final.jsonl
/// sessions/<id>/notes.md
/// sessions/<id>/notes.meta.json
/// sessions/<id>/audio/
/// ```
actor SessionRepository {
    private let sessionsDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Live Session State

    private var currentSessionID: String?
    private var liveFileHandle: FileHandle?
    private var liveUtteranceCount: Int = 0

    /// Tracks in-flight delayed writes.
    private var pendingWrites = 0
    private var pendingWriteWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called (once) when a write error occurs during the session.
    private var onWriteError: (@Sendable (String) -> Void)?
    private var hasReportedWriteError = false

    /// The notes folder artifacts are mirrored into — `Application
    /// Support/Lore/Notes` by default since #148, or the folder the user picked.
    private var notesFolderPath: URL?

    init(rootDirectory: URL? = nil) {
        let baseDirectory: URL
        if let rootDirectory {
            baseDirectory = rootDirectory
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            baseDirectory = appSupport.appendingPathComponent("Lore", isDirectory: true)
        }
        sessionsDirectory = baseDirectory.appendingPathComponent("sessions", isDirectory: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Create + keep Spotlight out, one implementation (#148). This is the
        // app's own Application Support tree, so it is safe at launch.
        NotesFolder.prepare(sessionsDirectory)

        // No orphan cleanup here (#166): the batch stash is the durable
        // marker of an interrupted whole-audio pass, and the launch sweep
        // (`TranscriptHealer.sweep`) resumes it or — when a final transcript
        // proves the pass finished — cleans it on that evidence. The old
        // 24h directory-mtime cleanup deleted recoverable stashes before
        // anything could look.
    }

    // MARK: - Configuration

    /// Update the notes folder path used for mirroring artifacts.
    func setNotesFolderPath(_ url: URL?) {
        notesFolderPath = url
    }

    /// Register a callback invoked once per session when a write error occurs.
    func setWriteErrorHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onWriteError = handler
    }

    // MARK: - Session Lifecycle

    @discardableResult
    func startSession(config: SessionStartConfig = SessionStartConfig()) -> SessionHandle {
        let startedAt = config.startedAt ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let sessionID = "session_\(formatter.string(from: startedAt))"
        currentSessionID = sessionID
        hasReportedWriteError = false
        liveUtteranceCount = 0

        let sessionDir = sessionDirectory(for: sessionID)
        let fm = FileManager.default
        try? fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // Create transcript.live.jsonl and keep handle open
        let liveFile = sessionDir.appendingPathComponent("transcript.live.jsonl")
        fm.createFile(atPath: liveFile.path, contents: nil,
                      attributes: [.posixPermissions: 0o600])
        do {
            liveFileHandle = try FileHandle(forWritingTo: liveFile)
        } catch {
            reportWriteError("Failed to open live transcript file: \(error.localizedDescription)")
        }

        // Write initial session.json
        let metadata = SessionMetadata(
            id: sessionID,
            startedAt: startedAt,
            templateSnapshot: config.templateSnapshot,
            title: config.title,
            utteranceCount: 0,
            hasNotes: false
        )
        writeSessionMetadata(metadata, sessionID: sessionID)

        return SessionHandle(sessionID: sessionID)
    }

    // MARK: - Live Utterance Writing

    /// Append a live utterance to transcript.live.jsonl.
    /// For remote speakers with `isDelayed`, uses delayed-write aggregation.
    func appendLiveUtterance(
        sessionID: String,
        utterance: Utterance,
        metadata: LiveUtteranceMetadata = LiveUtteranceMetadata()
    ) {
        let baseRecord = SessionRecord(
            speaker: utterance.speaker,
            text: utterance.text,
            timestamp: utterance.timestamp,
            refinedText: utterance.refinedText
        )

        if metadata.isDelayed {
            appendRecordDelayed(
                baseRecord: baseRecord,
                utteranceID: metadata.utteranceID,
                transcriptStore: metadata.transcriptStore
            )
        } else {
            appendRecord(baseRecord)
        }
    }

    /// Direct record append (for local speaker / non-delayed writes).
    func appendRecord(_ record: SessionRecord) {
        guard let fileHandle = liveFileHandle else {
            reportWriteError("No file handle available for session write")
            return
        }

        do {
            let data = try encoder.encode(record)
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.write("\n".data(using: .utf8)!)
            liveUtteranceCount += 1
        } catch {
            reportWriteError("Failed to write record: \(error.localizedDescription)")
        }
    }

    /// Delayed write: sleeps 5s to capture pipeline enrichment (refined
    /// text landing asynchronously), then writes.
    private func appendRecordDelayed(
        baseRecord: SessionRecord,
        utteranceID: UUID?,
        transcriptStore: TranscriptStore?
    ) {
        pendingWrites += 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))

            guard let self else { return }

            let refinedText: String?
            if let utteranceID, let store = transcriptStore {
                refinedText = await store.utterances.first(where: { $0.id == utteranceID })?.refinedText
            } else {
                refinedText = baseRecord.refinedText
            }

            let enrichedRecord = SessionRecord(
                speaker: baseRecord.speaker,
                text: baseRecord.text,
                timestamp: baseRecord.timestamp,
                refinedText: refinedText
            )

            await self.appendRecord(enrichedRecord)
            await self.decrementPendingWrites()
        }
    }

    private func decrementPendingWrites() {
        pendingWrites -= 1
        if pendingWrites == 0 {
            let waiters = pendingWriteWaiters
            pendingWriteWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /// Suspends until all in-flight delayed writes have completed.
    func awaitPendingWrites() async {
        guard pendingWrites > 0 else { return }
        await withCheckedContinuation { continuation in
            pendingWriteWaiters.append(continuation)
        }
    }

    // MARK: - Finalization

    @discardableResult
    func finalizeSession(sessionID: String, metadata: SessionFinalizeMetadata) -> SessionIndex {
        // Close the live file handle
        try? liveFileHandle?.close()
        liveFileHandle = nil
        currentSessionID = nil

        // Backfill refined text into live transcript
        backfillRefinedText(sessionID: sessionID, from: metadata.utterances)

        // Write session.json with final metadata. Finalize derives only what
        // the recording itself decides; everything set while it ran — a
        // rename, tags, the mirror's file name (#280) — is kept from the
        // stored file.
        var sessionMeta = loadSessionMetadataFile(sessionID: sessionID)
            ?? SessionMetadata(id: sessionID, startedAt: Date(), utteranceCount: 0, hasNotes: false)
        // A title still the default for when the session was created becomes
        // the default for when the recording started, the time the meta line
        // shows (#269) — and so still reads as the default to enrichment.
        let titleIsDefault = sessionMeta.title.map {
            SessionIndex.isDefaultTitle($0, startedAt: sessionMeta.startedAt)
        } ?? false
        sessionMeta.startedAt = metadata.utterances.first?.timestamp ?? Date()
        if titleIsDefault {
            sessionMeta.title = SessionIndex.defaultTitle(startedAt: sessionMeta.startedAt)
        }
        sessionMeta.endedAt = metadata.endedAt
        sessionMeta.templateSnapshot = metadata.templateSnapshot
        sessionMeta.utteranceCount = metadata.utteranceCount
        sessionMeta.hasNotes = false
        sessionMeta.language = metadata.language
        sessionMeta.meetingApp = metadata.meetingApp
        sessionMeta.engine = metadata.engine
        writeSessionMetadata(sessionMeta, sessionID: sessionID)
        return SessionIndex(from: sessionMeta)
    }

    /// End a session without full finalization (discard path).
    func endSession() {
        try? liveFileHandle?.close()
        liveFileHandle = nil
        currentSessionID = nil
        liveUtteranceCount = 0
    }

    // MARK: - Imported Session

    /// Configuration for creating an imported session (no live file handle needed).
    struct ImportedSessionConfig: Sendable {
        let title: String
        let startedAt: Date
        let endedAt: Date
        let language: String?
        let engine: String?
    }

    /// Create a session directory and initial metadata for an imported audio file.
    /// Unlike `startSession`, this does not open a live file handle.
    @discardableResult
    func createImportedSession(config: ImportedSessionConfig) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let sessionID = "session_\(formatter.string(from: config.startedAt))"

        prepareAudioDirectory(sessionID: sessionID)

        let metadata = SessionMetadata(
            id: sessionID,
            startedAt: config.startedAt,
            endedAt: config.endedAt,
            title: config.title,
            utteranceCount: 0,
            hasNotes: false,
            language: config.language,
            engine: config.engine,
            source: SessionIndex.importedSource
        )
        writeSessionMetadata(metadata, sessionID: sessionID)

        return sessionID
    }

    /// Update utterance count and endedAt for a finalized imported session.
    func finalizeImportedSession(sessionID: String, utteranceCount: Int, endedAt: Date) {
        guard var meta = loadSessionMetadataFile(sessionID: sessionID) else { return }
        meta.utteranceCount = utteranceCount
        // A live session (source nil) rebuilt from its m4a export (#109)
        // keeps its recorded end — the last speech timestamp would shrink
        // the duration when the meeting had trailing silence. Imports have
        // no prior end worth preserving.
        if meta.source != nil || meta.endedAt == nil {
            meta.endedAt = endedAt
        }
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    // MARK: - Ask Lore chat (#60)

    /// Append one completed exchange to the session's `chat.json`.
    /// Write-through per successful answer so the chat survives crashes;
    /// the file is small (a handful of turns), so read-modify-write is fine.
    ///
    /// Corrupt-file policy: a chat.json that exists but fails to decode is
    /// never rebuilt over (that would destroy prior turns) — it is moved
    /// aside to a unique name (`chat.json.corrupt`, then `.corrupt.1`,
    /// `.corrupt.2`, …) so earlier asides survive repeat corruption, and a
    /// fresh file starts with this exchange.
    func appendChatExchange(sessionID: String, exchange: ChatExchange) {
        let url = sessionDirectory(for: sessionID).appendingPathComponent("chat.json")

        var exchanges: [ChatExchange] = []
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? decoder.decode([ChatExchange].self, from: data) {
                exchanges = decoded
            } else {
                DiagStore.record(.corruptFileAside(artifact: .chatJSON))
                repoLog.error("corrupt chat.json for \(sessionID, privacy: .private) — moving aside")
                FileAside.move(url)
            }
        }

        exchanges.append(exchange)
        guard let data = try? encoder.encode(exchanges) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Chat history for a session. Missing file (legacy sessions, sessions
    /// without questions) or decode failure → empty, never an error.
    func loadChat(sessionID: String) -> [ChatExchange] {
        let url = sessionDirectory(for: sessionID).appendingPathComponent("chat.json")
        guard let data = try? Data(contentsOf: url),
              let exchanges = try? decoder.decode([ChatExchange].self, from: data)
        else { return [] }
        return exchanges
    }

    /// Copy an audio file into the session's audio directory.
    func copyAudioFileToSession(sessionID: String, sourceURL: URL) {
        let audioDir = prepareAudioDirectory(sessionID: sessionID)
        let dest = audioDir.appendingPathComponent("imported.\(sourceURL.pathExtension)")
        // Retry of an import (#43) re-runs over the session's own copy —
        // an explicit no-op, not a swallowed error.
        guard sourceURL.standardizedFileURL.path != dest.standardizedFileURL.path else { return }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            // Non-fatal: the import proceeds from the source URL; only
            // retry/playback lose the session copy.
            DiagStore.record(.sessionImportFailed)
            repoLog.error("audio copy into session failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Final Transcript

    /// Atomic by construction (#166): the payload lands in a temp file, then
    /// replaces the final in one rename. A process killed at any instant
    /// leaves either the previous good file or the new one — never a partial
    /// write, and never the remove-then-move window that used to lose an
    /// existing final transcript.
    /// True when the transcript is on disk.
    @discardableResult
    func saveFinalTranscript(sessionID: String, records: [SessionRecord]) -> Bool {
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var payload = Data()
        for record in records {
            if let data = try? encoder.encode(record) {
                payload.append(data)
                payload.append(Data("\n".utf8))
            }
        }

        let finalURL = dir.appendingPathComponent("transcript.final.jsonl")
        let tempURL = dir.appendingPathComponent("transcript.final.jsonl.tmp")

        do {
            try payload.write(to: tempURL, options: .atomic)
            let fm = FileManager.default
            if fm.fileExists(atPath: finalURL.path) {
                _ = try fm.replaceItemAt(finalURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: finalURL)
            }
        } catch {
            repoLog.error("Failed to write final transcript: \(error.localizedDescription, privacy: .private)")
            return false
        }

        // A speaker map names the lines of the transcript it was made with
        // (#269); a new transcript leaves none until its own pass writes one,
        // and the names given to the old map's voices leave with it.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(SpeakerMap.fileName))
        forgetNaming(sessionID: sessionID)

        // The index count follows the file it counts (#166, ui-language
        // rule 8): a rebuild that replaced the transcript must not leave a
        // stale promise beside the new text. A landed transcript also
        // retires any persisted no-speech verdict.
        if var meta = loadSessionMetadataFile(sessionID: sessionID),
           meta.utteranceCount != records.count || meta.noSpeech != nil {
            meta.utteranceCount = records.count
            meta.noSpeech = nil
            writeSessionMetadata(meta, sessionID: sessionID)
        }

        // Mirror to notesFolderPath
        mirrorNotesArtifacts(sessionID: sessionID)
        return true
    }

    // MARK: - Speakers

    /// The meeting's speaker map (#269), written whole or not at all, 0600.
    func saveSpeakerMap(_ map: SpeakerMap, sessionID: String) throws {
        try Self.writePrivately(
            SpeakerMap.encoder.encode(map),
            to: sessionDirectory(for: sessionID).appendingPathComponent(SpeakerMap.fileName)
        )
    }

    /// A file only this user may read, from its first byte: written to a
    /// temporary created 0600 beside it, then renamed over it — whole or not
    /// at all.
    nonisolated static func writePrivately(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    func hasSpeakerMap(sessionID: String) -> Bool {
        FileManager.default.fileExists(
            atPath: sessionDirectory(for: sessionID).appendingPathComponent(SpeakerMap.fileName).path)
    }

    // MARK: - Speaker names (#269)

    private var voicesDirectory: URL {
        KnownVoices.directory(in: sessionsDirectory.deletingLastPathComponent())
    }

    /// The meeting's speaker map, only when it joins these lines
    /// (`SpeakerMap.joins`); otherwise nil, and the lines read You/Them.
    func loadSpeakerMap(sessionID: String, records: [SessionRecord]) -> SpeakerMap? {
        let url = sessionDirectory(for: sessionID).appendingPathComponent(SpeakerMap.fileName)
        guard let data = try? Data(contentsOf: url),
              let map = try? SpeakerMap.decoder.decode(SpeakerMap.self, from: data),
              map.joins(records) else { return nil }
        return map
    }

    /// A naming file as it was found. One that is there but cannot be read —
    /// torn, or written by a later version — is kept: readers go without it
    /// and nothing writes over it.
    enum NamingFile<Value> {
        case absent
        case read(Value)
        case unreadable
    }

    private struct NamingVersion: Decodable { let version: Int }

    /// Unreadable naming files already traced this launch.
    private var tracedUnreadable: Set<String> = []

    private func readNaming<Value: Decodable>(
        _ type: Value.Type, at url: URL, file: DiagEvent.SpeakerNamesFile, currentVersion: Int
    ) -> NamingFile<Value> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let data = try? Data(contentsOf: url)
        let problem: DiagEvent.SpeakerNamesProblem
        if let version = data.flatMap({ try? SpeakerMap.decoder.decode(NamingVersion.self, from: $0) })?.version,
           version > currentVersion {
            problem = .newerVersion
        } else if let data, let value = try? SpeakerMap.decoder.decode(type, from: data) {
            return .read(value)
        } else {
            problem = .damaged
        }
        if tracedUnreadable.insert(url.path).inserted {
            DiagStore.record(.speakerNamesUnreadable(file: file, problem: problem))
        }
        return .unreadable
    }

    /// Everyone the owner has named; empty before the first name, and when
    /// the file cannot be read.
    func loadKnownVoices() -> KnownVoices {
        if case .read(let voices) = readKnownVoices() { return voices }
        return KnownVoices()
    }

    private func readKnownVoices() -> NamingFile<KnownVoices> {
        readNaming(
            KnownVoices.self, at: voicesDirectory.appendingPathComponent(KnownVoices.fileName),
            file: .people, currentVersion: KnownVoices.currentVersion)
    }

    /// The map that joins these lines, with this meeting's names and the known
    /// people, and whether a naming change may be written over them; nil
    /// without such a map.
    private func naming(sessionID: String, records: [SessionRecord]) -> (speakers: MeetingSpeakers, writable: Bool)? {
        guard let map = loadSpeakerMap(sessionID: sessionID, records: records) else { return nil }
        let names = readNaming(
            SpeakerNames.self, at: sessionDirectory(for: sessionID).appendingPathComponent(SpeakerNames.fileName),
            file: .meeting, currentVersion: SpeakerNames.currentVersion)
        let voices = readKnownVoices()
        var writable = true
        func value<V>(_ file: NamingFile<V>) -> V? {
            switch file {
            case .absent: return nil
            case .read(let value): return value
            case .unreadable:
                writable = false
                return nil
            }
        }
        let speakers = MeetingSpeakers(map: map, names: value(names), voices: value(voices) ?? KnownVoices())
        return (speakers, writable)
    }

    func meetingSpeakers(sessionID: String, records: [SessionRecord]) -> MeetingSpeakers? {
        naming(sessionID: sessionID, records: records)?.speakers
    }

    /// The meeting's transcript as every reader reads it: its lines, their
    /// speakers, its turns.
    func meetingTranscript(sessionID: String) -> MeetingTranscript {
        let records = loadTranscript(sessionID: sessionID)
        return MeetingTranscript(records: records, speakers: meetingSpeakers(sessionID: sessionID, records: records))
    }

    /// What the naming popover changes.
    enum SpeakerChange: Sendable {
        /// To another speaker of the meeting, someone known, or You.
        case assign(SpeakerKey, to: SpeakerKey)
        /// As someone new.
        case name(SpeakerKey, String)
        case renamePerson(String, to: String)
    }

    /// What a naming change came to.
    enum SpeakerChangeResult: Sendable {
        /// Saved; the transcript as it now reads.
        case changed(MeetingTranscript)
        /// Nothing to change; nothing written.
        case unchanged
        /// Not applied, nothing written, traced: the meeting is not the one
        /// the change was made on, or a naming file cannot be read.
        case refused
        /// The transcript as it now reads, when the change was saved.
        var transcript: MeetingTranscript? {
            if case .changed(let transcript) = self { transcript } else { nil }
        }
    }

    /// Applies one naming change to the meeting as `basis` read it, saves the
    /// names (0600) and rewrites the meeting's Markdown mirror. A change made
    /// on other lines or another speaker map than those on disk (a
    /// re-transcription, a new speaker pass: "system-1" is another voice) is
    /// refused, as is one over a naming file that cannot be read.
    ///
    /// Written so that no failure loses a name or shows a false one: first
    /// `names.json` with every person kept (a new person is there before
    /// anything names them), then the meeting's file, then `names.json` again
    /// pruned of people named nowhere. A failed second write leaves an
    /// unreferenced person or a stale contribution, both harmless and made
    /// right at the next write; a failed third leaves people to prune later.
    /// A failed write is traced and thrown.
    func changeSpeakers(_ change: SpeakerChange, sessionID: String, basis: MeetingTranscript) throws -> SpeakerChangeResult {
        let records = loadTranscript(sessionID: sessionID)
        guard records == basis.records, let loaded = naming(sessionID: sessionID, records: records),
              loaded.speakers.map.createdAt == basis.speakers?.map.createdAt
        else {
            DiagStore.record(.speakerNamingNotSaved(reason: .staleBasis))
            return .refused
        }
        guard loaded.writable else {
            DiagStore.record(.speakerNamingNotSaved(reason: .unreadableFile))
            return .refused
        }
        var speakers = loaded.speakers
        let changed = switch change {
        case .assign(let key, let target): speakers.assign(key, to: target)
        case .name(let key, let name): speakers.name(key, as: name)
        case .renamePerson(let id, let name): speakers.renamePerson(id, to: name)
        }
        guard changed else { return .unchanged }
        speakers.syncContributions(meeting: sessionID)
        let peopleURL = voicesDirectory.appendingPathComponent(KnownVoices.fileName)
        do {
            try Self.writePrivately(SpeakerMap.encoder.encode(speakers.voices), to: peopleURL)
            try Self.writePrivately(
                SpeakerMap.encoder.encode(speakers.names),
                to: sessionDirectory(for: sessionID).appendingPathComponent(SpeakerNames.fileName))
            let unpruned = speakers.voices
            speakers.voices.prune()
            if speakers.voices != unpruned {
                try Self.writePrivately(SpeakerMap.encoder.encode(speakers.voices), to: peopleURL)
            }
        } catch {
            DiagStore.record(.speakerNamingNotSaved(reason: .writeFailed))
            throw error
        }
        mirrorNotesArtifacts(sessionID: sessionID)
        return .changed(MeetingTranscript(records: records, speakers: speakers))
    }

    /// A meeting's namings leave the known voices — it was deleted, or its
    /// speaker map is gone — with anyone they named nowhere else, and its
    /// naming file goes. Not while `names.json` cannot be read: it is never
    /// written over.
    private func forgetNaming(sessionID: String) {
        try? FileManager.default.removeItem(
            at: sessionDirectory(for: sessionID).appendingPathComponent(SpeakerNames.fileName))
        guard case .read(var voices) = readKnownVoices() else { return }
        let before = voices
        voices.forget(meeting: sessionID)
        voices.prune()
        guard voices != before else { return }
        do {
            try Self.writePrivately(
                SpeakerMap.encoder.encode(voices), to: voicesDirectory.appendingPathComponent(KnownVoices.fileName))
        } catch {
            DiagStore.record(.speakerNamingNotSaved(reason: .writeFailed))
        }
    }

    /// `transcript.final.jsonl` alone — what a speaker map is made for.
    func finalTranscript(sessionID: String) -> [SessionRecord] {
        let url = sessionDirectory(for: sessionID).appendingPathComponent("transcript.final.jsonl")
        return (try? String(contentsOf: url, encoding: .utf8)).map(parseJSONL) ?? []
    }

    /// The final transcript's lines with where their words are in the tracks,
    /// kept beside the tracks for the speaker pass and deleted with them. No
    /// text. New lines are a new transcript: the pass's attempts start over.
    @discardableResult
    func saveSpeakerLines(_ lines: [SpeakerFinder.Line], sessionID: String) -> Bool {
        guard let directory = stash(sessionID: sessionID)?.directory,
              let data = try? JSONEncoder().encode(lines),
              (try? data.write(to: BatchAudioStash.linesURL(in: directory), options: .atomic)) != nil
        else { return false }
        setStashCount(0, at: BatchAudioStash.attemptsURL, sessionID: sessionID)
        return true
    }

    func speakerLines(sessionID: String) -> [SpeakerFinder.Line]? {
        guard let directory = stash(sessionID: sessionID)?.directory,
              let data = try? Data(contentsOf: BatchAudioStash.linesURL(in: directory)) else { return nil }
        return try? JSONDecoder().decode([SpeakerFinder.Line].self, from: data)
    }

    /// Speaker passes started on this meeting's tracks, crashes included.
    func speakerAttempts(sessionID: String) -> Int {
        stashCount(at: BatchAudioStash.attemptsURL, sessionID: sessionID)
    }

    func setSpeakerAttempts(_ attempts: Int, sessionID: String) {
        setStashCount(attempts, at: BatchAudioStash.attemptsURL, sessionID: sessionID)
    }

    /// Exports of this meeting's merged recording started, crashes included
    /// (#290). Nonisolated, so a quit can put the running one's count back
    /// before the process ends (`TranscriptHealer.willTerminate`).
    nonisolated func exportAttempts(sessionID: String) -> Int {
        stashCount(at: BatchAudioStash.exportAttemptsURL, sessionID: sessionID)
    }

    nonisolated func setExportAttempts(_ attempts: Int, sessionID: String) {
        setStashCount(attempts, at: BatchAudioStash.exportAttemptsURL, sessionID: sessionID)
    }

    /// A count kept beside the tracks, gone with them — and never below what
    /// this launch last set it to, so a count the disk refused (a full disk)
    /// still bounds the attempts, which would otherwise start over at every
    /// retry (#290).
    nonisolated private func stashCount(at url: (URL) -> URL, sessionID: String) -> Int {
        let key = url(audioDirectory(for: sessionID)).path
        let floor = launchCounts.withLock { $0[key] } ?? 0
        guard let directory = stash(sessionID: sessionID)?.directory,
              let text = try? String(contentsOf: url(directory), encoding: .utf8) else { return floor }
        return max(floor, Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    nonisolated private func setStashCount(_ count: Int, at url: (URL) -> URL, sessionID: String) {
        let key = url(audioDirectory(for: sessionID)).path
        launchCounts.withLock { $0[key] = count }
        guard let directory = stash(sessionID: sessionID)?.directory else { return }
        do {
            try "\(count)".write(to: url(directory), atomically: true, encoding: .utf8)
        } catch {
            repoLog.error("attempt count not written: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// The counts this launch set, by the count's file in the meeting's
    /// `audio/` directory (`stashCount`).
    private let launchCounts = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    // MARK: - Notes

    func saveNotes(sessionID: String, notes: EnhancedNotes) {
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Write notes.md
        let mdURL = dir.appendingPathComponent("notes.md")
        try? notes.markdown.write(to: mdURL, atomically: true, encoding: .utf8)

        // Write notes.meta.json
        let meta = NotesMeta(
            templateSnapshot: notes.template,
            generatedAt: notes.generatedAt
        )
        if let data = try? encoder.encode(meta) {
            let metaURL = dir.appendingPathComponent("notes.meta.json")
            try? data.write(to: metaURL, options: .atomic)
        }

        // Update session.json hasNotes flag
        if var sessionMeta = loadSessionMetadataFile(sessionID: sessionID) {
            sessionMeta.hasNotes = true
            writeSessionMetadata(sessionMeta, sessionID: sessionID)
        }

        // Mirror to notesFolderPath
        mirrorNotesArtifacts(sessionID: sessionID)
    }

    func loadNotes(sessionID: String) -> EnhancedNotes? {
        let dir = sessionDirectory(for: sessionID)
        let mdURL = dir.appendingPathComponent("notes.md")
        let metaURL = dir.appendingPathComponent("notes.meta.json")

        guard let markdown = try? String(contentsOf: mdURL, encoding: .utf8),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? decoder.decode(NotesMeta.self, from: metaData) else {
            // Fall back to legacy
            return LegacySessionReader.loadNotes(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
        }

        return EnhancedNotes(
            template: meta.templateSnapshot,
            generatedAt: meta.generatedAt,
            markdown: markdown
        )
    }

    // MARK: - Listing & Loading

    func listSessions() -> [SessionIndex] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var results: [SessionIndex] = []

        // Canonical sessions: directories with session.json
        for item in contents {
            let name = item.lastPathComponent
            // Skip hidden directories and non-session items
            guard !name.hasPrefix(".") else { continue }

            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let metaURL = item.appendingPathComponent("session.json")
                if let data = try? Data(contentsOf: metaURL),
                   let meta = try? decoder.decode(SessionMetadata.self, from: data) {
                    // Transcript-state flag (#109): derived from file
                    // existence at load, never persisted. Recoverability is
                    // not derived here (#166) — `TranscriptHealer` asks
                    // `rebuildAudioSource` at the moment it matters, so a
                    // damaged final file can't block the answer.
                    var index = SessionIndex(from: meta)
                    index.hasFinalTranscript = fm.fileExists(
                        atPath: item.appendingPathComponent("transcript.final.jsonl").path
                    )
                    results.append(index)
                    continue
                }
            }
        }

        // Legacy sessions: .jsonl files without canonical directories
        let canonicalIDs = Set(results.map(\.id))
        let legacyResults = LegacySessionReader.listSessions(
            sessionsDirectory: sessionsDirectory,
            excludingIDs: canonicalIDs
        )
        results.append(contentsOf: legacyResults)

        return results.sorted { $0.startedAt > $1.startedAt }
    }

    /// A session's index alone, canonical or legacy — no transcript read.
    func sessionIndex(sessionID: String) -> SessionIndex {
        loadSessionMetadataFile(sessionID: sessionID).map(SessionIndex.init(from:))
            ?? LegacySessionReader.loadIndex(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
    }

    func loadSession(id: String) -> SessionDetail {
        let dir = sessionDirectory(for: id)
        let metaURL = dir.appendingPathComponent("session.json")

        // Try canonical first
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? decoder.decode(SessionMetadata.self, from: data) {
            let index = SessionIndex(from: meta)

            let transcript = loadTranscript(sessionID: id)
            let liveTranscript = loadLiveTranscript(sessionID: id)
            let notes = loadNotes(sessionID: id)

            return SessionDetail(
                index: index,
                transcript: transcript,
                liveTranscript: liveTranscript,
                notes: notes,
                notesMeta: nil
            )
        }

        // Fall back to legacy
        return LegacySessionReader.loadSession(id: id, sessionsDirectory: sessionsDirectory)
    }

    /// Transcript file candidates in load-preference order — the ONE list
    /// `loadTranscript` and the sweep's `hasTranscriptText` both read (#166),
    /// so the two can never disagree about where text lives. Canonical
    /// final/live first, then the legacy layouts (`batch.jsonl`, flat
    /// `<id>.jsonl`) that `LegacySessionReader` documents.
    private func transcriptCandidates(sessionID: String) -> [URL] {
        let dir = sessionDirectory(for: sessionID)
        return [
            dir.appendingPathComponent("transcript.final.jsonl"),
            dir.appendingPathComponent("transcript.live.jsonl"),
            dir.appendingPathComponent("batch.jsonl"),
            sessionsDirectory.appendingPathComponent("\(sessionID).jsonl"),
        ]
    }

    func loadTranscript(sessionID: String) -> [SessionRecord] {
        for url in transcriptCandidates(sessionID: sessionID) {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let records = parseJSONL(content)
            if !records.isEmpty { return records }
        }
        return []
    }

    func loadLiveTranscript(sessionID: String) -> [SessionRecord] {
        let dir = sessionDirectory(for: sessionID)
        let liveURL = dir.appendingPathComponent("transcript.live.jsonl")
        if let content = try? String(contentsOf: liveURL, encoding: .utf8) {
            let records = parseJSONL(content)
            if !records.isEmpty { return records }
        }

        // Fall back to legacy live transcript
        return LegacySessionReader.loadLiveTranscript(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
    }

    // MARK: - Session Management

    func renameSession(sessionID: String, title: String) {
        // Whitespace-only counts as empty: title clears to nil and the
        // derived default name (#58) takes over. Fixed here so every rename
        // surface (list context menu, review header) inherits it.
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Legacy sessions keep the sidecar rename — no migration on rename.
        guard loadSessionMetadataFile(sessionID: sessionID) != nil else {
            LegacySessionReader.renameSession(
                sessionID: sessionID,
                newTitle: trimmed,
                sessionsDirectory: sessionsDirectory
            )
            return
        }

        mutateSessionMetadata(sessionID: sessionID) { $0.title = trimmed.isEmpty ? nil : trimmed }
        mirrorNotesArtifacts(sessionID: sessionID)
    }

    func updateSessionTags(sessionID: String, tags: [String]) {
        let normalized = Self.normalizeTags(tags)
        mutateSessionMetadata(sessionID: sessionID) { $0.tags = normalized.isEmpty ? nil : normalized }
    }

    /// Persist the on-device enrichment summary (#107). Written last by the
    /// enrichment engine — a non-nil summary is what marks a session as
    /// enriched. Legacy sessions migrate to canonical on first write, same
    /// as `updateSessionTags`, so the sweep converges instead of retrying
    /// them forever.
    ///
    /// nil drops the marker (#109): called after a successful rebuild
    /// replaces the transcript, so `enrichIfNeeded` regenerates on the whole
    /// text. Title and tags are left alone — enrichment's own rules protect
    /// manual renames and append tags. Clearing never migrates legacy
    /// sessions and no-ops when there is nothing to clear (the auto path:
    /// enrichment waits for the batch, so the summary is still nil).
    func updateSessionSummary(sessionID: String, summary: String?) {
        guard summary != nil
            || loadSessionMetadataFile(sessionID: sessionID)?.summary != nil else { return }
        mutateSessionMetadata(sessionID: sessionID) { $0.summary = summary }
    }

    /// Shared load-or-migrate + write behind the metadata writers above:
    /// canonical sessions are mutated in place; legacy sessions migrate to
    /// canonical format on first write.
    private func mutateSessionMetadata(sessionID: String, _ mutate: (inout SessionMetadata) -> Void) {
        var meta: SessionMetadata
        if let existing = loadSessionMetadataFile(sessionID: sessionID) {
            meta = existing
        } else {
            let index = LegacySessionReader.loadIndex(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
            meta = SessionMetadata(
                id: index.id,
                startedAt: index.startedAt,
                endedAt: index.endedAt,
                templateSnapshot: index.templateSnapshot,
                title: index.title,
                utteranceCount: index.utteranceCount,
                hasNotes: index.hasNotes,
                language: index.language,
                meetingApp: index.meetingApp,
                engine: index.engine,
                tags: index.tags
            )
            let dir = sessionDirectory(for: sessionID)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        mutate(&meta)
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    /// Mark a session as fresh/unviewed (MREV-39): called when batch
    /// processing or an import is kicked off, so the green dot survives
    /// relaunch mid-batch. Canonical sessions only — legacy sessions never
    /// enter the batch pipeline.
    func markSessionUnviewed(sessionID: String) {
        guard var meta = loadSessionMetadataFile(sessionID: sessionID) else { return }
        meta.unviewed = true
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    /// Clear the fresh/unviewed marker once the user views the processed
    /// meeting.
    func markSessionViewed(sessionID: String) {
        guard var meta = loadSessionMetadataFile(sessionID: sessionID),
              meta.unviewed == true else { return }
        meta.unviewed = nil
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    /// Update source and tags for an imported session.
    func updateSessionSource(sessionID: String, source: String, tags: [String]) {
        guard var meta = loadSessionMetadataFile(sessionID: sessionID) else { return }
        meta.source = source
        let existing = meta.tags ?? []
        meta.tags = Self.normalizeTags(existing + tags)
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    /// Collect all unique tags across all sessions for autocomplete.
    func allTags() -> [String] {
        let sessions = listSessions()
        var seen = Set<String>()
        var result: [String] = []
        for session in sessions {
            for tag in session.tags ?? [] {
                let lower = tag.lowercased()
                if !seen.contains(lower) {
                    seen.insert(lower)
                    result.append(tag)
                }
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func normalizeTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                result.append(trimmed)
            }
            if result.count >= 5 { break }
        }
        return result
    }

    func deleteSession(sessionID: String) {
        forgetNaming(sessionID: sessionID)
        removePartialExport(sessionID: sessionID)
        let fm = FileManager.default
        let dir = sessionDirectory(for: sessionID)

        // Remove canonical directory
        if fm.fileExists(atPath: dir.path) {
            try? fm.removeItem(at: dir)
        }

        // Also remove legacy files if present
        LegacySessionReader.deleteSession(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
    }

    // MARK: - Recently Deleted

    private var recentlyDeletedDirectory: URL {
        sessionsDirectory.appendingPathComponent(".recently-deleted", isDirectory: true)
    }

    /// Nothing restores from here, so the meeting's names leave now (#269).
    func moveToRecentlyDeleted(sessionID: String) {
        forgetNaming(sessionID: sessionID)
        let fm = FileManager.default
        try? fm.createDirectory(at: recentlyDeletedDirectory, withIntermediateDirectories: true)

        let dir = sessionDirectory(for: sessionID)
        if fm.fileExists(atPath: dir.path) {
            let dest = recentlyDeletedDirectory.appendingPathComponent(dir.lastPathComponent)
            try? fm.moveItem(at: dir, to: dest)
        }

        // Also move legacy files
        LegacySessionReader.moveToRecentlyDeleted(
            sessionID: sessionID,
            sessionsDirectory: sessionsDirectory,
            recentlyDeletedDirectory: recentlyDeletedDirectory
        )
    }

    func purgeRecentlyDeleted() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: recentlyDeletedDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Plain Text Export

    func exportPlainText(sessionID: String) -> String {
        let transcript = meetingTranscript(sessionID: sessionID)
        let records = transcript.records
        guard !records.isEmpty else { return "" }

        let meta = loadSessionMetadataFile(sessionID: sessionID)
        let startDate = meta?.startedAt ?? records.first?.timestamp ?? Date()

        let headerFmt = DateFormatter()
        headerFmt.dateStyle = .medium
        headerFmt.timeStyle = .short
        var result = "\(LoreTheme.wordmark) - \(headerFmt.string(from: startDate))\n\n"

        result += transcript.clockLines().map { $0 + "\n" }.joined()

        return result
    }

    // MARK: - Batch Audio Persistence

    /// The session's own `audio/` directory. Not created — see
    /// `prepareAudioDirectory`.
    nonisolated private func audioDirectory(for sessionID: String) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent("audio", isDirectory: true)
    }

    /// Where a session's per-track stash can be, in preference order: the
    /// canonical `audio/` subdirectory, then the legacy layout that put the
    /// same three files straight in the session directory.
    nonisolated private func stashDirectories(sessionID: String) -> [URL] {
        [audioDirectory(for: sessionID), sessionDirectory(for: sessionID)]
    }

    /// The session's `audio/` directory, created — where `MeetingRecording`
    /// records the two tracks from the first buffer (#177).
    @discardableResult
    func prepareAudioDirectory(sessionID: String) -> URL {
        let audioDir = audioDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        return audioDir
    }

    func batchAudioURLs(sessionID: String) -> (mic: URL?, sys: URL?) {
        stash(sessionID: sessionID).map { ($0.mic, $0.sys) } ?? (nil, nil)
    }

    /// The stash directory holding the session's tracks, and the tracks in it.
    nonisolated private func stash(sessionID: String) -> (directory: URL, mic: URL?, sys: URL?)? {
        let fm = FileManager.default
        for directory in stashDirectories(sessionID: sessionID) {
            let mic = BatchAudioStash.micURL(in: directory)
            let sys = BatchAudioStash.sysURL(in: directory)
            let found = (
                directory: directory,
                mic: fm.fileExists(atPath: mic.path) ? mic : nil,
                sys: fm.fileExists(atPath: sys.path) ? sys : nil
            )
            if found.mic != nil || found.sys != nil { return found }
        }
        return nil
    }

    /// Removes the session's tracks and the files that go with them — or,
    /// while its merged recording is still to be written (#290), leaves the
    /// removal to the export, which does it when it is done. Nothing removes
    /// a track the export has yet to read, and the request outlives a quit.
    func cleanupBatchAudio(sessionID: String) {
        if var pending = pendingExport(sessionID: sessionID) {
            pending.removeTracks = true
            writePendingExport(pending, sessionID: sessionID)
            return
        }
        for directory in stashDirectories(sessionID: sessionID) {
            BatchAudioStash.remove(in: directory)
        }
    }

    // MARK: - Merged recording export (#290)

    /// A meeting's merged recording still to be written into the notes
    /// folder: the marker finalize leaves beside the tracks when "Save audio
    /// recording" is on, and the export removes once it is settled.
    struct PendingExport: Codable, Sendable {
        /// The m4a's file name in the notes folder.
        let name: String
        /// The tracks' timing as the recording closed with it. The export
        /// merges by this and reads no other file; a marker without it gets
        /// no export, since tracks merged without their timing are misaligned.
        let meta: BatchMeta?
        /// The tracks' removal was asked for meanwhile: nothing but the
        /// export reads them any more.
        var removeTracks = false
    }

    /// What an export can do now.
    enum ExportPlan: Sendable {
        /// Merge the tracks in `tracks` by `meta` into `file`, the partial
        /// recording beside the m4a.
        case ready(tracks: URL, meta: BatchMeta, file: URL)
        /// No export is pending: the meeting was deleted, or its export is done.
        case gone
        /// The marker carries no timing for the tracks.
        case noTiming
        /// No notes folder is known yet to write into.
        case notesFolderUnset
    }

    /// False when the marker is not on disk: then nothing keeps the tracks
    /// for an export, and none may be queued.
    func markExportPending(sessionID: String, name: String, meta: BatchMeta) -> Bool {
        writePendingExport(PendingExport(name: name, meta: meta), sessionID: sessionID)
    }

    func pendingExport(sessionID: String) -> PendingExport? {
        guard let data = try? Data(contentsOf: BatchAudioStash.pendingExportURL(in: audioDirectory(for: sessionID)))
        else { return nil }
        return try? JSONDecoder().decode(PendingExport.self, from: data)
    }

    @discardableResult
    private func writePendingExport(_ pending: PendingExport, sessionID: String) -> Bool {
        do {
            try Self.writePrivately(
                JSONEncoder().encode(pending),
                to: BatchAudioStash.pendingExportURL(in: audioDirectory(for: sessionID))
            )
            return true
        } catch {
            repoLog.error("export marker not written: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    func planExport(sessionID: String) -> ExportPlan {
        guard let pending = pendingExport(sessionID: sessionID) else { return .gone }
        guard let meta = pending.meta else { return .noTiming }
        guard let notesFolderPath else { return .notesFolderUnset }
        return .ready(
            tracks: audioDirectory(for: sessionID), meta: meta,
            file: Self.partialExport(of: notesFolderPath.appendingPathComponent(pending.name))
        )
    }

    /// Where the export fills the m4a before it is renamed into place: one
    /// fixed hidden name beside it, `.<stamp>.part.m4a`. Exports run one at a
    /// time, and `AVAudioFile(forWriting:)` overwrites what a killed one left.
    nonisolated static func partialExport(of recording: URL) -> URL {
        recording.deletingLastPathComponent().appendingPathComponent(
            ".\(recording.deletingPathExtension().lastPathComponent)\(partialExportSuffix)")
    }

    private static let partialExportSuffix = ".part.m4a"

    /// Every partial recording a killed export left in the notes folder,
    /// whichever meeting's — a deleted one's too. The launch sweep runs it
    /// before any export of the launch.
    func removePartialExports() {
        guard let notesFolderPath,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: notesFolderPath, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.lastPathComponent.hasPrefix(".")
            && file.lastPathComponent.hasSuffix(Self.partialExportSuffix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// A deleted meeting's partial recording goes with it.
    private func removePartialExport(sessionID: String) {
        guard let notesFolderPath, let pending = pendingExport(sessionID: sessionID) else { return }
        try? FileManager.default.removeItem(
            at: Self.partialExport(of: notesFolderPath.appendingPathComponent(pending.name)))
    }

    /// The export is over: the file it wrote, if any, renamed over the m4a,
    /// then the marker removed — and the tracks with it, when their removal
    /// was asked for meanwhile. False, with the file removed, when no export
    /// is pending any more: the meeting was deleted while it ran. Throws,
    /// keeping the marker for another attempt, when the rename fails.
    func finishExport(sessionID: String, writtenTo file: URL?) throws -> Bool {
        guard let pending = pendingExport(sessionID: sessionID) else {
            if let file { try? FileManager.default.removeItem(at: file) }
            return false
        }
        if let file, rename(file.path, file.deletingLastPathComponent().appendingPathComponent(pending.name).path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try? FileManager.default.removeItem(at: BatchAudioStash.pendingExportURL(in: audioDirectory(for: sessionID)))
        if pending.removeTracks {
            cleanupBatchAudio(sessionID: sessionID)
        }
        return true
    }

    /// Audio a session's transcript can be rebuilt from (#109), in
    /// preference order: the per-track batch stash (keeps You/Them via
    /// timing anchors), then any merged audio `audioFileURL(for:)` resolves —
    /// the session's own copy (imports, earlier rebuild attempts) or the m4a
    /// export in the notes folder.
    ///
    /// A stash is no longer evidence that the meeting ended: since #177 a live
    /// meeting has one from its first buffer. Callers must exclude the live
    /// session themselves — `TranscriptHealer` does it in `sweep` and
    /// `ensure`, both against `liveSessionID()`.
    ///
    /// This ordering IS the speaker-collapse policy (#129, decided by policy
    /// under #166 — never a dialog): the merged-file pass labels every
    /// utterance `.them`, so it runs only when the per-track stash is gone,
    /// and by then either the transcript is damaged/absent (no separation
    /// left to preserve) or a single-speaker whole transcript is still the
    /// best obtainable text.
    func rebuildAudioSource(sessionID: String) -> RebuildAudioSource? {
        let tracks = batchAudioURLs(sessionID: sessionID)
        if tracks.mic != nil || tracks.sys != nil { return .tracks }
        if let merged = audioFileURL(for: sessionID) { return .file(merged) }
        return nil
    }

    /// The session's recorded start, for anchoring a merged-file rebuild.
    func sessionStartDate(sessionID: String) -> Date? {
        loadSessionMetadataFile(sessionID: sessionID)?.startedAt
    }

    /// Cheap launch-sweep predicate (#166): does this session have
    /// transcript bytes to show? Same candidate list as `loadTranscript`,
    /// file presence + non-zero size only — the full parse happens at open,
    /// where the load is already paid for, and atomic final writes mean a
    /// non-empty final file is a whole one.
    func hasTranscriptText(sessionID: String) -> Bool {
        transcriptCandidates(sessionID: sessionID).contains { url in
            ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
    }

    /// Persist the no-speech verdict (#166): a completed pass produced no
    /// transcript, so nothing changes by running again. Canonical sessions
    /// only — legacy sessions never enter the repair pipeline.
    func markSessionNoSpeech(sessionID: String) {
        guard var meta = loadSessionMetadataFile(sessionID: sessionID),
              meta.noSpeech != true else { return }
        meta.noSpeech = true
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    /// The persisted no-speech verdict, read at assessment time.
    func sessionNoSpeech(sessionID: String) -> Bool {
        loadSessionMetadataFile(sessionID: sessionID)?.noSpeech == true
    }

    /// The merged m4a export in the notes folder for a session. The export
    /// filename (`MeetingRecording.exportTimestampFormat`, minute resolution)
    /// and the session ID come from two independent `Date()` reads separated
    /// by actor hops — and, on the model-download-gate path, arbitrary user
    /// wait — so prefix equality can miss across a minute boundary. Tolerant
    /// match instead: parse every m4a timestamp and take the one nearest the
    /// session's start within [startedAt − 1 min, endedAt (startedAt +
    /// 10 min when the session never ended)]; nearest-to-start wins so a
    /// later meeting's export can't be grabbed.
    private func notesFolderExport(sessionID: String) -> URL? {
        guard let notesFolder = notesFolderPath,
              let meta = loadSessionMetadataFile(sessionID: sessionID),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: notesFolder, includingPropertiesForKeys: nil
              )
        else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = MeetingRecording.exportTimestampFormat
        let windowStart = meta.startedAt.addingTimeInterval(-60)
        let windowEnd = meta.endedAt ?? meta.startedAt.addingTimeInterval(600)

        return files
            .filter { $0.pathExtension == "m4a" }
            .compactMap { url -> (url: URL, distance: TimeInterval)? in
                guard let stamp = formatter.date(from: url.deletingPathExtension().lastPathComponent),
                      stamp >= windowStart, stamp <= windowEnd else { return nil }
                return (url, abs(stamp.timeIntervalSince(meta.startedAt)))
            }
            .min { $0.distance < $1.distance }?
            .url
    }

    func loadBatchMeta(sessionID: String) -> BatchMeta? {
        stashDirectories(sessionID: sessionID)
            .lazy
            .compactMap { BatchAudioStash.readMeta(in: $0) }
            .first
    }



    // MARK: - Refined Text Backfill

    func backfillRefinedText(from utterances: [Utterance]) {
        guard let sessionID = currentSessionID else { return }

        try? liveFileHandle?.close()
        liveFileHandle = nil

        let liveURL = sessionDirectory(for: sessionID).appendingPathComponent("transcript.live.jsonl")
        rewriteJSONLWithRefinedText(file: liveURL, utterances: utterances)

        liveFileHandle = try? FileHandle(forWritingTo: liveURL)
    }

    func backfillRefinedText(sessionID: String, from utterances: [Utterance]) {
        let liveURL = sessionDirectory(for: sessionID).appendingPathComponent("transcript.live.jsonl")
        if FileManager.default.fileExists(atPath: liveURL.path) {
            rewriteJSONLWithRefinedText(file: liveURL, utterances: utterances)
            return
        }

        // Legacy fallback
        let legacyURL = sessionsDirectory.appendingPathComponent("\(sessionID).jsonl")
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            rewriteJSONLWithRefinedText(file: legacyURL, utterances: utterances)
        }
    }

    // MARK: - Seeding (for tests / UI tests)

    func seedSession(
        id: String,
        records: [SessionRecord],
        startedAt: Date,
        endedAt: Date? = nil,
        templateSnapshot: TemplateSnapshot? = nil,
        title: String? = nil,
        notes: EnhancedNotes? = nil
    ) {
        let dir = sessionDirectory(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Write session.json
        let meta = SessionMetadata(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            templateSnapshot: templateSnapshot,
            title: title,
            utteranceCount: records.count,
            hasNotes: notes != nil,
            meetingApp: nil,
            engine: nil
        )
        writeSessionMetadata(meta, sessionID: id)

        // Write transcript.live.jsonl
        let liveURL = dir.appendingPathComponent("transcript.live.jsonl")
        var payload = Data()
        for record in records {
            if let data = try? encoder.encode(record) {
                payload.append(data)
                payload.append(Data("\n".utf8))
            }
        }
        try? payload.write(to: liveURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: liveURL.path)

        // Write notes if provided
        if let notes {
            saveNotes(sessionID: id, notes: notes)
        }
    }

    // MARK: - Accessors

    nonisolated var sessionsDirectoryURL: URL { sessionsDirectory }

    func getCurrentSessionID() -> String? { currentSessionID }

    /// Returns the URL of the playable audio file for a session, if one exists.
    /// Checks for merged M4A exports and imported audio files. Normal meetings
    /// keep their merged m4a in the notes folder, not in the session (#130) —
    /// when the session's audio/ has no playable file, resolve it there. The
    /// session-local copy wins when both exist.
    func audioFileURL(for sessionID: String) -> URL? {
        let audioDir = audioDirectory(for: sessionID)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: nil
        )) ?? []
        // Skip raw CAF and batch metadata; among playable files prefer M4A
        // exports, tie-broken by filename so the pick is deterministic.
        let skipExtensions: Set<String> = ["caf", "json"]
        return contents
            .filter { !skipExtensions.contains($0.pathExtension.lowercased()) }
            .min { a, b in
                let aM4A = a.pathExtension.lowercased() == "m4a"
                let bM4A = b.pathExtension.lowercased() == "m4a"
                if aM4A != bM4A { return aM4A }
                return a.lastPathComponent < b.lastPathComponent
            } ?? notesFolderExport(sessionID: sessionID)
    }

    // MARK: - Private Helpers

    nonisolated private func sessionDirectory(for sessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent(sessionID, isDirectory: true)
    }

    private func writeSessionMetadata(_ metadata: SessionMetadata, sessionID: String) {
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("session.json")
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try Self.writePrivately(enc.encode(metadata), to: url)
        } catch {
            repoLog.error("Failed to write session.json: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func loadSessionMetadataFile(sessionID: String) -> SessionMetadata? {
        let url = sessionDirectory(for: sessionID).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SessionMetadata.self, from: data)
    }

    private func parseJSONL(_ content: String) -> [SessionRecord] {
        content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(SessionRecord.self, from: data)
            }
    }

    /// `message` is caller-constructed and every caller interpolates an
    /// `error.localizedDescription` into it — which embeds the file path, which
    /// embeds the session id. `.private`, like every other write error (#82).
    private func reportWriteError(_ message: String) {
        repoLog.error("\(message, privacy: .private)")
        guard !hasReportedWriteError else { return }
        hasReportedWriteError = true
        onWriteError?(message)
    }

    @discardableResult
    private func rewriteJSONLWithRefinedText(file: URL, utterances: [Utterance]) -> Bool {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return false }

        let backupURL = file.appendingPathExtension("pre-cleanup.bak")
        try? FileManager.default.copyItem(at: file, to: backupURL)

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var refinedLookup: [String: String] = [:]
        for utterance in utterances {
            guard let refined = utterance.refinedText else { continue }
            let key = "\(iso8601Formatter.string(from: utterance.timestamp))|\(utterance.speaker.storageKey)"
            refinedLookup[key] = refined
        }

        guard !refinedLookup.isEmpty else { return false }

        var updatedLines: [String] = []
        var anyUpdated = false

        for line in lines {
            guard let data = line.data(using: .utf8),
                  var record = try? decoder.decode(SessionRecord.self, from: data) else {
                updatedLines.append(line)
                continue
            }

            if record.refinedText == nil {
                let key = "\(iso8601Formatter.string(from: record.timestamp))|\(record.speaker.storageKey)"
                if let refined = refinedLookup[key] {
                    record = record.withRefinedText(refined)
                    anyUpdated = true
                }
            }

            if let encoded = try? encoder.encode(record),
               let jsonString = String(data: encoded, encoding: .utf8) {
                updatedLines.append(jsonString)
            } else {
                updatedLines.append(line)
            }
        }

        if anyUpdated {
            let newContent = updatedLines.joined(separator: "\n") + "\n"
            try? newContent.write(to: file, atomically: true, encoding: .utf8)
        }

        return anyUpdated
    }

    // MARK: - Notes Folder Mirroring

    /// Mirror notes.md and plain-text transcript to the user-visible
    /// notesFolderPath. Also called when a meeting's speaker pass settles (#269).
    func mirrorNotesArtifacts(sessionID: String) {
        guard let outputDir = notesFolderPath else { return }

        let meta = loadSessionMetadataFile(sessionID: sessionID)
        let transcript = meetingTranscript(sessionID: sessionID)
        let records = transcript.records
        guard !records.isEmpty else { return }

        let index = SessionIndex(
            id: meta?.id ?? sessionID,
            startedAt: meta?.startedAt ?? records.first?.timestamp ?? Date(),
            endedAt: meta?.endedAt,
            templateSnapshot: meta?.templateSnapshot,
            title: meta?.title,
            utteranceCount: meta?.utteranceCount ?? records.count,
            hasNotes: meta?.hasNotes ?? false,
            language: meta?.language,
            meetingApp: meta?.meetingApp,
            engine: meta?.engine,
            tags: meta?.tags,
            source: meta?.source
        )

        // Load generated notes (if any) to include in the export
        let notes = loadNotes(sessionID: sessionID)

        // Write/update Markdown meeting notes — the meeting's one mirror (#280).
        let written = MarkdownMeetingWriter.write(
            metadata: .init(from: index),
            transcript: transcript,
            notesMarkdown: notes?.markdown,
            outputDirectory: outputDir,
            previousFileName: meta?.mirrorFileName
        )
        // Canonical sessions only: a mirror write must not migrate a legacy one.
        if let meta, let name = written?.lastPathComponent, meta.mirrorFileName != name {
            mutateSessionMetadata(sessionID: sessionID) { $0.mirrorFileName = name }
        }
    }


}

// MARK: - Batch Transcription Support Types

/// What a chunked session's rebuild (#109) can run from.
enum RebuildAudioSource: Sendable {
    /// Per-track mic/sys stash — `BatchTranscriptionEngine.process()`,
    /// keeps You/Them via timing anchors.
    case tracks
    /// A single merged audio file — the import-style pass
    /// (`BatchTranscriptionEngine.importFile`), single-speaker transcript.
    case file(URL)
}

/// The layout of a meeting's per-track stash. `MeetingRecording` writes it live
/// (#177) and `SessionRepository` reads it, so the names and the meta format
/// have exactly one owner. The same three names describe the legacy layout,
/// which put them straight in the session directory instead of `audio/`.
enum BatchAudioStash {
    static func micURL(in directory: URL) -> URL {
        directory.appendingPathComponent("mic.caf")
    }

    static func sysURL(in directory: URL) -> URL {
        directory.appendingPathComponent("sys.caf")
    }

    static func metaURL(in directory: URL) -> URL {
        directory.appendingPathComponent("batch-meta.json")
    }

    /// The speaker pass's inputs (#269): where each transcript line's words are,
    /// and how many passes have started.
    static func linesURL(in directory: URL) -> URL {
        directory.appendingPathComponent("speaker-lines.json")
    }

    static func attemptsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("speaker-attempts.json")
    }

    /// Exports of the merged recording started (#290), beside the speaker
    /// pass's count and gone with the tracks like it.
    static func exportAttemptsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("export-attempts.json")
    }

    /// The merged recording still to be written (#290): while it is here the
    /// tracks stay (`SessionRepository.PendingExport`).
    static func pendingExportURL(in directory: URL) -> URL {
        directory.appendingPathComponent("export-pending.json")
    }

    /// Logged, not swallowed: a meeting's timing anchors are written from an
    /// off-thread queue with nobody waiting on the result, so a failure that
    /// left no trace would surface much later as a rebuilt transcript stamped
    /// at the moment of the rebuild. `MeetingRecording.close()` writes
    /// the last snapshot again, which is the retry.
    static func writeMeta(_ meta: BatchMeta, in directory: URL) {
        do {
            let data = try metaEncoder.encode(meta)
            try data.write(to: metaURL(in: directory), options: .atomic)
        } catch {
            repoLog.error("batch meta write failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    static func readMeta(in directory: URL) -> BatchMeta? {
        guard let data = try? Data(contentsOf: metaURL(in: directory)) else { return nil }
        return try? metaDecoder.decode(BatchMeta.self, from: data)
    }

    /// Dates keep their fraction of a second: the merge places the two tracks
    /// by their start dates to the sample, and the batch pass must place them
    /// the same way (#268).
    private static let metaEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        return encoder
    }()

    /// Reads both forms, so meta written before #268 (whole seconds) still loads.
    private static let metaDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
                return date
            }
            return try Date.ISO8601FormatStyle().parse(text)
        }
        return decoder
    }()

    /// Remove the whole stash — both tracks, their timing meta, and what the
    /// speaker pass kept beside them.
    static func remove(in directory: URL) {
        let fm = FileManager.default
        for url in [micURL(in: directory), sysURL(in: directory), metaURL(in: directory),
                    linesURL(in: directory), attemptsURL(in: directory), exportAttemptsURL(in: directory)] {
            try? fm.removeItem(at: url)
        }
    }
}

/// Codable batch metadata persisted as batch-meta.json.
struct BatchMeta: Codable, Sendable {
    let micStartDate: Date?
    let sysStartDate: Date?
    let micAnchors: [TimingAnchor]
    let sysAnchors: [TimingAnchor]

    /// There is timing worth persisting: a track's first successful write
    /// dates it, so neither date means no audio ever landed. (Anchors are
    /// written only when a track has more than one stretch, #268.)
    var hasTiming: Bool { micStartDate != nil || sysStartDate != nil }

    struct TimingAnchor: Codable, Sendable {
        let frame: Int64
        let date: Date
    }
}
