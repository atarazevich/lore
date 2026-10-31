@preconcurrency import AVFoundation
import Foundation
import LoreFormat
import os

private let repoLog = Logger(subsystem: "com.lore.app", category: "SessionRepository")

// MARK: - Supporting Types

/// Lightweight metadata returned by `listSessions()`.
/// Mirrors `SessionIndex` but is produced from the canonical `session.json`.
typealias SessionIndexEntry = SessionIndex

/// Metadata needed to start a new session.
public struct SessionStartConfig: Sendable {
    let templateID: UUID?
    let templateSnapshot: TemplateSnapshot?
    /// Initial title written at creation (#58: "Weekday HH:MM" default).
    let title: String?
    /// The recording's start, the instant its default title was made from
    /// (#269); now when nil.
    let startedAt: Date?
    /// `source` written into `session.json` at creation — `PhoneNotes.source`
    /// for a note recorded on the phone (#306); nil for a Mac meeting.
    let source: String?

    public init(
        templateID: UUID? = nil,
        templateSnapshot: TemplateSnapshot? = nil,
        title: String? = nil,
        startedAt: Date? = nil,
        source: String? = nil
    ) {
        self.templateID = templateID
        self.templateSnapshot = templateSnapshot
        self.title = title
        self.startedAt = startedAt
        self.source = source
    }
}

/// Handle returned by `startSession` — callers use `sessionID` to address
/// subsequent writes.
public struct SessionHandle: Sendable {
    public let sessionID: String
}

/// Metadata attached to each live utterance write.
public struct LiveUtteranceMetadata: Sendable {
    let utteranceID: UUID?
    let transcriptStore: TranscriptStore?
    let isDelayed: Bool

    public init(
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
public struct SessionFinalizeMetadata: Sendable {
    let endedAt: Date
    let utteranceCount: Int
    let language: String?
    let meetingApp: String?
    let engine: String?
    let templateSnapshot: TemplateSnapshot?
    let utterances: [Utterance]

    public init(
        endedAt: Date,
        utteranceCount: Int,
        language: String?,
        meetingApp: String?,
        engine: String?,
        templateSnapshot: TemplateSnapshot?,
        utterances: [Utterance]
    ) {
        self.endedAt = endedAt
        self.utteranceCount = utteranceCount
        self.language = language
        self.meetingApp = meetingApp
        self.engine = engine
        self.templateSnapshot = templateSnapshot
        self.utterances = utterances
    }
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
    /// File name of this meeting's merged recording in the notes folder (#330):
    /// `<stamp>.m4a`, or `<stamp>-2.m4a` when a meeting started in the same
    /// minute took the name first. Optional — absent before #330.
    var recordingFileName: String? = nil
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
public actor SessionRepository {
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

    public init(rootDirectory: URL? = nil) {
        sessionsDirectory = LoreFiles.sessions(in: rootDirectory ?? LoreFiles.root)

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
    public func setNotesFolderPath(_ url: URL?) {
        notesFolderPath = url
    }

    /// Register a callback invoked once per session when a write error occurs.
    public func setWriteErrorHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onWriteError = handler
    }

    // MARK: - Session Lifecycle

    @discardableResult
    public func startSession(config: SessionStartConfig = SessionStartConfig()) -> SessionHandle {
        let startedAt = config.startedAt ?? Date()
        let sessionID = MeetingFiles.sessionID(startedAt: startedAt)
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
            hasNotes: false,
            source: config.source
        )
        writeSessionMetadata(metadata, sessionID: sessionID)

        return SessionHandle(sessionID: sessionID)
    }

    // MARK: - Live Utterance Writing

    /// Append a live utterance to transcript.live.jsonl.
    /// For remote speakers with `isDelayed`, uses delayed-write aggregation.
    public func appendLiveUtterance(
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
    public func awaitPendingWrites() async {
        guard pendingWrites > 0 else { return }
        await withCheckedContinuation { continuation in
            pendingWriteWaiters.append(continuation)
        }
    }

    // MARK: - Finalization

    @discardableResult
    public func finalizeSession(sessionID: String, metadata: SessionFinalizeMetadata) -> SessionIndex {
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
        // A recording without live text (the phone's, #306) keeps its stored
        // start, which its folder name and transcript anchor are made from.
        sessionMeta.startedAt = metadata.utterances.first?.timestamp ?? sessionMeta.startedAt
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
    public func endSession() {
        try? liveFileHandle?.close()
        liveFileHandle = nil
        currentSessionID = nil
        liveUtteranceCount = 0
    }

    // MARK: - Imported Session

    /// Configuration for creating an imported session (no live file handle needed).
    public struct ImportedSessionConfig: Sendable {
        let title: String
        let startedAt: Date
        let endedAt: Date
        let language: String?
        let engine: String?

        public init(title: String, startedAt: Date, endedAt: Date, language: String?, engine: String?) {
            self.title = title
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.language = language
            self.engine = engine
        }
    }

    /// Create a session directory and initial metadata for an imported audio file.
    /// Unlike `startSession`, this does not open a live file handle.
    @discardableResult
    public func createImportedSession(config: ImportedSessionConfig) -> String {
        let sessionID = MeetingFiles.sessionID(startedAt: config.startedAt)

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
        // A stored end is kept exactly; only a session without one takes the last line's (#306).
        if meta.endedAt == nil { meta.endedAt = endedAt }
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
    public func appendChatExchange(sessionID: String, exchange: ChatExchange) {
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
    public func loadChat(sessionID: String) -> [ChatExchange] {
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
        // Retry of an import (#43) re-runs over the session's own copy, and a
        // phone note (#309) is transcribed from the recording it brought in
        // its own audio/ — nothing to copy, an explicit no-op either way.
        guard sourceURL.standardizedFileURL.deletingLastPathComponent().path
            != audioDir.standardizedFileURL.path else { return }
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
    /// - Parameter engine: the speech model that made `records`, when known —
    ///   a rebuild after the model changed (#299) must not leave the old name.
    func saveFinalTranscript(sessionID: String, records: [SessionRecord], engine: String? = nil) -> Bool {
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
           meta.utteranceCount != records.count || meta.noSpeech != nil || (engine != nil && meta.engine != engine) {
            meta.utteranceCount = records.count
            meta.noSpeech = nil
            if let engine { meta.engine = engine }
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
        MeetingFiles.speakerMap(sessionDirectory: sessionDirectory(for: sessionID), records: records)
    }

    /// Unreadable naming files already traced this launch.
    private var tracedUnreadable: Set<String> = []

    private func traceUnreadable(_ file: DiagEvent.SpeakerNamesFile, _ problem: DiagEvent.SpeakerNamesProblem, _ url: URL) {
        if tracedUnreadable.insert(url.path).inserted {
            DiagStore.record(.speakerNamesUnreadable(file: file, problem: problem))
        }
    }

    /// Everyone the owner has named; empty before the first name, and when
    /// the file cannot be read.
    func loadKnownVoices() -> KnownVoices {
        if case .read(let voices) = readKnownVoices() { return voices }
        return KnownVoices()
    }

    private func readKnownVoices() -> MeetingFiles.NamingFile<KnownVoices> {
        let url = MeetingFiles.knownVoicesURL(voicesDirectory: voicesDirectory)
        let file = MeetingFiles.readNaming(KnownVoices.self, at: url, currentVersion: KnownVoices.currentVersion)
        if case .unreadable(let problem) = file { traceUnreadable(.people, problem, url) }
        return file
    }

    /// The map that joins these lines, with this meeting's names and the known
    /// people, and whether a naming change may be written over them; nil
    /// without such a map.
    private func naming(sessionID: String, records: [SessionRecord]) -> (speakers: MeetingSpeakers, writable: Bool)? {
        MeetingFiles.naming(
            sessionDirectory: sessionDirectory(for: sessionID), voicesDirectory: voicesDirectory,
            records: records, unreadable: traceUnreadable)
    }

    func meetingSpeakers(sessionID: String, records: [SessionRecord]) -> MeetingSpeakers? {
        naming(sessionID: sessionID, records: records)?.speakers
    }

    /// The meeting's transcript as every reader reads it: its lines, their
    /// speakers, its turns.
    public func meetingTranscript(sessionID: String) -> MeetingTranscript {
        let records = loadTranscript(sessionID: sessionID)
        return MeetingTranscript(records: records, speakers: meetingSpeakers(sessionID: sessionID, records: records))
    }

    /// What the naming popover changes.
    public enum SpeakerChange: Sendable {
        /// To another speaker of the meeting, someone known, or You.
        case assign(SpeakerKey, to: SpeakerKey)
        /// As someone new.
        case name(SpeakerKey, String)
        case renamePerson(String, to: String)
    }

    /// What a naming change came to.
    public enum SpeakerChangeResult: Sendable {
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
    public func changeSpeakers(_ change: SpeakerChange, sessionID: String, basis: MeetingTranscript) throws -> SpeakerChangeResult {
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

    /// `transcript.final.jsonl` alone — what a speaker map is made for. Read
    /// outside the actor: the file is only ever replaced whole.
    nonisolated func finalTranscript(sessionID: String) -> [SessionRecord] {
        let url = sessionDirectory(for: sessionID).appendingPathComponent("transcript.final.jsonl")
        return (try? String(contentsOf: url, encoding: .utf8)).map(MeetingFiles.parseJSONL) ?? []
    }

    /// The final transcript's lines with where their words are in the tracks,
    /// kept beside the tracks for the speaker pass and deleted with them. No
    /// text. New lines are a new transcript: the pass's attempts start over.
    @discardableResult
    func saveSpeakerLines(_ lines: [SpeakerFinder.Line], sessionID: String) -> Bool {
        guard let directory = stash(sessionID: sessionID)?.directory, Self.writeSpeakerLines(lines, in: directory)
        else { return false }
        setStashCount(0, at: BatchAudioStash.attemptsURL, sessionID: sessionID)
        return true
    }

    func speakerLines(sessionID: String) -> [SpeakerFinder.Line]? {
        stash(sessionID: sessionID).flatMap { Self.readSpeakerLines(in: $0.directory) }
    }

    /// `speaker-lines.json` in `directory`: a meeting's stash, or a phone
    /// note's `audio/` (#308).
    private static func writeSpeakerLines(_ lines: [SpeakerFinder.Line], in directory: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(lines) else { return false }
        return (try? data.write(to: BatchAudioStash.linesURL(in: directory), options: .atomic)) != nil
    }

    private static func readSpeakerLines(in directory: URL) -> [SpeakerFinder.Line]? {
        guard let data = try? Data(contentsOf: BatchAudioStash.linesURL(in: directory)) else { return nil }
        return try? JSONDecoder().decode([SpeakerFinder.Line].self, from: data)
    }

    // MARK: - A phone note's speakers (#308)

    /// A phone note's lines, beside its one recording in `audio/`, in the
    /// meeting's format. No stash and no attempt count: the Mac's speaker
    /// pass never reads them (it needs a meeting's tracks).
    func saveNoteSpeakerLines(_ lines: [SpeakerFinder.Line], sessionID: String) -> Bool {
        let directory = audioDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Self.writeSpeakerLines(lines, in: directory)
    }

    nonisolated func noteSpeakerLines(sessionID: String) -> [SpeakerFinder.Line]? {
        Self.readSpeakerLines(in: audioDirectory(for: sessionID))
    }

    /// What a phone note's speaker pass works from: its final transcript and
    /// the lines beside its recording, one per transcript line.
    enum NoteSpeakerMaterial: Sendable {
        /// No transcript text: nothing to place a voice on.
        case noText
        /// The lines are gone or belong to another transcript; only
        /// transcribing the note again writes them.
        case noLines
        case ready(records: [SessionRecord], lines: [SpeakerFinder.Line])
    }

    /// The one check of whether a phone note can be given speakers:
    /// `PhoneSpeakerPass.run` stops on anything but `.ready`, and
    /// `canFindSpeakers` reads the same answer.
    nonisolated func noteSpeakerMaterial(sessionID: String) -> NoteSpeakerMaterial {
        let records = finalTranscript(sessionID: sessionID)
        guard !records.isEmpty else { return .noText }
        guard let lines = noteSpeakerLines(sessionID: sessionID), lines.count == records.count else { return .noLines }
        return .ready(records: records, lines: lines)
    }

    /// A speaker pass over this phone note can place voices: it has
    /// transcript text and the lines that match it. False with no text, and
    /// false when the lines are missing or do not match — no pass can help
    /// until the note is transcribed again, so neither the key nor a retry
    /// is worth offering. It does not say whether the note already has
    /// speakers (`hasSpeakers`): a note with speakers still reads true, and
    /// a pass over it returns at once.
    nonisolated public func canFindSpeakers(sessionID: String) -> Bool {
        if case .ready = noteSpeakerMaterial(sessionID: sessionID) { true } else { false }
    }

    func removeNoteSpeakerLines(sessionID: String) {
        try? FileManager.default.removeItem(at: BatchAudioStash.linesURL(in: audioDirectory(for: sessionID)))
    }

    /// The session's speakers are on disk and join the transcript its readers
    /// read: what `noteTranscript` shows them from.
    public func hasSpeakers(sessionID: String) -> Bool {
        loadSpeakerMap(sessionID: sessionID, records: loadTranscript(sessionID: sessionID)) != nil
    }

    /// A phone note's transcript as the phone reads it
    /// (`MeetingTranscript(phoneNote:map:)`): Speaker 1, Speaker 2… by first
    /// appearance, no You; without speakers, no names at all.
    public func noteTranscript(sessionID: String) -> MeetingTranscript {
        let records = loadTranscript(sessionID: sessionID)
        return MeetingTranscript(phoneNote: records, map: loadSpeakerMap(sessionID: sessionID, records: records))
    }

    /// Speaker passes started on this meeting's tracks, crashes included.
    func speakerAttempts(sessionID: String) -> Int {
        stashCount(at: BatchAudioStash.attemptsURL, sessionID: sessionID)
    }

    func setSpeakerAttempts(_ attempts: Int, sessionID: String) {
        setStashCount(attempts, at: BatchAudioStash.attemptsURL, sessionID: sessionID)
    }

    // MARK: - A speaker pass asked for (#308)

    /// What the review's meta line reads about a meeting's speaker pass, from
    /// disk, each time it draws: no stored "can run" flag. Nonisolated file
    /// checks only, so the main actor reads it without waiting on this actor.
    public struct SpeakerPassState: Equatable, Sendable {
        /// No speaker map yet, and the tracks and the lines the pass joins to
        /// are on disk, with nothing about to remove them.
        public var canRun: Bool
        /// Passes started on these tracks since they were last asked for.
        public var attempts: Int
        /// The passes counted were asked for with Who spoke?, and the owner
        /// has not closed their failure.
        public var requested: Bool

        /// The last passes were asked for and used up their attempts. A pass
        /// lore ran by itself never reads as this (no-false-positives rule 3).
        public func requestedPassFailed(limit: Int) -> Bool { requested && attempts >= limit }
    }

    nonisolated public func speakerPassState(sessionID: String) -> SpeakerPassState {
        let hasMap = FileManager.default.fileExists(
            atPath: sessionDirectory(for: sessionID).appendingPathComponent(SpeakerMap.fileName).path)
        return SpeakerPassState(
            canRun: !hasMap && speakerStash(sessionID: sessionID) != nil
                && pendingExport(sessionID: sessionID).map { $0.settled == nil && $0.removeTracks } != true,
            attempts: stashCount(at: BatchAudioStash.attemptsURL, sessionID: sessionID),
            requested: stashCount(at: BatchAudioStash.requestedURL, sessionID: sessionID) > 0
        )
    }

    /// Who spoke?: the attempts start over, counted as asked for.
    nonisolated func requestSpeakerPass(sessionID: String) {
        setStashCount(0, at: BatchAudioStash.attemptsURL, sessionID: sessionID)
        setStashCount(1, at: BatchAudioStash.requestedURL, sessionID: sessionID)
    }

    /// The × after "couldn't finish finding who spoke": the attempts are no
    /// longer the owner's to hear about, so the line goes back to Who spoke?.
    /// False when that could not be written.
    nonisolated public func dismissSpeakerFailure(sessionID: String) -> Bool {
        setStashCount(0, at: BatchAudioStash.requestedURL, sessionID: sessionID)
    }

    /// The meeting's tracks, when the lines the speaker pass joins to are
    /// beside them: what the pass, and keeping the tracks for it, needs.
    nonisolated private func speakerStash(sessionID: String) -> (directory: URL, mic: URL?, sys: URL?)? {
        guard let stash = stash(sessionID: sessionID),
              FileManager.default.fileExists(atPath: BatchAudioStash.linesURL(in: stash.directory).path)
        else { return nil }
        return stash
    }

    /// The directory whose recorded tracks are to be kept compressed, when
    /// there are any, beside their lines, and no export of the merged
    /// recording still has to read them: an unsaved one is retried from the
    /// lossless tracks, and they are compressed only after its tries (#330).
    func tracksToKeep(sessionID: String) -> URL? {
        guard pendingExport(sessionID: sessionID)?.exportsLeft != true,
              let stash = speakerStash(sessionID: sessionID) else { return nil }
        let fm = FileManager.default
        let recorded = [BatchAudioStash.micURL(in: stash.directory), BatchAudioStash.sysURL(in: stash.directory)]
        return recorded.contains { fm.fileExists(atPath: $0.path) } ? stash.directory : nil
    }

    /// Some track is already kept compressed (#308): the meeting waits for
    /// Who spoke?, even with its other side still as recorded.
    func hasKeptTrack(sessionID: String) -> Bool {
        guard let stash = stash(sessionID: sessionID) else { return false }
        return [stash.mic, stash.sys].contains { $0?.pathExtension == "m4a" }
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

    @discardableResult
    nonisolated private func setStashCount(_ count: Int, at url: (URL) -> URL, sessionID: String) -> Bool {
        let key = url(audioDirectory(for: sessionID)).path
        launchCounts.withLock { $0[key] = count }
        guard let directory = stash(sessionID: sessionID)?.directory else { return false }
        do {
            try "\(count)".write(to: url(directory), atomically: true, encoding: .utf8)
            return true
        } catch {
            // The floor set above still bounds this launch's attempts (#290);
            // what the disk refused is traced.
            repoLog.error("attempt count not written: \(error.localizedDescription, privacy: .private)")
            DiagStore.record(.stashCountNotSaved)
            return false
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

    public func loadNotes(sessionID: String) -> EnhancedNotes? {
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

    public func listSessions() -> [SessionIndex] {
        // Canonical sessions: folders with a session.json, the same list
        // `lore search` reads (#301).
        var results = MeetingFiles.sessionFolders(in: sessionsDirectory, as: SessionMetadata.self).map { folder in
            // Transcript-state flag (#109): derived from file existence at
            // load, never persisted. Recoverability is not derived here
            // (#166) — `TranscriptHealer` asks `rebuildAudioSource` at the
            // moment it matters, so a damaged final file can't block the answer.
            var index = SessionIndex(from: folder.meta)
            index.hasFinalTranscript = FileManager.default.fileExists(
                atPath: folder.directory.appendingPathComponent("transcript.final.jsonl").path
            )
            return index
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
    public func sessionIndex(sessionID: String) -> SessionIndex {
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
        MeetingFiles.transcriptCandidates(
            sessionDirectory: sessionDirectory(for: sessionID), sessionsDirectory: sessionsDirectory, id: sessionID)
    }

    func loadTranscript(sessionID: String) -> [SessionRecord] {
        MeetingFiles.loadTranscript(candidates: transcriptCandidates(sessionID: sessionID))
    }

    func loadLiveTranscript(sessionID: String) -> [SessionRecord] {
        let dir = sessionDirectory(for: sessionID)
        let liveURL = dir.appendingPathComponent("transcript.live.jsonl")
        if let content = try? String(contentsOf: liveURL, encoding: .utf8) {
            let records = MeetingFiles.parseJSONL(content)
            if !records.isEmpty { return records }
        }

        // Fall back to legacy live transcript
        return LegacySessionReader.loadLiveTranscript(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
    }

    // MARK: - Session Management

    public func renameSession(sessionID: String, title: String) {
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

    public func updateSessionTags(sessionID: String, tags: [String]) {
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
    public func updateSessionSummary(sessionID: String, summary: String?) {
        guard summary != nil
            || loadSessionMetadataFile(sessionID: sessionID)?.summary != nil else { return }
        mutateSessionMetadata(sessionID: sessionID) { $0.summary = summary }
    }

    /// Shared load-or-migrate + write behind the metadata writers above:
    /// canonical sessions are mutated in place; legacy sessions migrate to
    /// canonical format on first write.
    @discardableResult
    private func mutateSessionMetadata(sessionID: String, _ mutate: (inout SessionMetadata) -> Void) -> Bool {
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
        return writeSessionMetadata(meta, sessionID: sessionID)
    }

    /// Mark a session as fresh/unviewed (MREV-39): called when batch
    /// processing or an import is kicked off, so the green dot survives
    /// relaunch mid-batch. Canonical sessions only — legacy sessions never
    /// enter the batch pipeline.
    public func markSessionUnviewed(sessionID: String) {
        guard var meta = loadSessionMetadataFile(sessionID: sessionID) else { return }
        meta.unviewed = true
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    /// Clear the fresh/unviewed marker once the user views the processed
    /// meeting.
    public func markSessionViewed(sessionID: String) {
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
    public func allTags() -> [String] {
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

    public func deleteSession(sessionID: String) {
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

    public func purgeRecentlyDeleted() {
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
        var result = "\(LoreBrand.wordmark) - \(headerFmt.string(from: startDate))\n\n"

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
    public func prepareAudioDirectory(sessionID: String) -> URL {
        let audioDir = audioDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        return audioDir
    }

    func batchAudioURLs(sessionID: String) -> (mic: URL?, sys: URL?) {
        stash(sessionID: sessionID).map { ($0.mic, $0.sys) } ?? (nil, nil)
    }

    /// The stash directory holding the session's tracks, and the tracks in it.
    nonisolated private func stash(sessionID: String) -> (directory: URL, mic: URL?, sys: URL?)? {
        for directory in stashDirectories(sessionID: sessionID) {
            let tracks = BatchAudioStash.tracks(in: directory)
            if tracks.mic != nil || tracks.sys != nil { return (directory, tracks.mic, tracks.sys) }
        }
        return nil
    }

    /// Removes the session's tracks and the files that go with them — or,
    /// while its merged recording is still to be written (#290), leaves the
    /// removal to the export, which does it when it is done. Nothing removes
    /// a track the export has yet to read, and the request outlives a quit.
    ///
    /// The one gate every removal of a meeting's tracks passes (#330): they go
    /// only when the owner had "Save audio recording" off for the meeting, or
    /// the merged recording this meeting's export wrote is in the notes folder
    /// and holds them (`MeetingRecording.covers`). Otherwise they stay, marked
    /// unsaved, and the export is tried again at the next launch.
    ///
    /// `savedTo` is the recording finalize wrote itself when no marker could
    /// be (#290): the exact file, judged like the one a marker names.
    public func cleanupBatchAudio(sessionID: String, savedTo recording: URL? = nil) {
        let pending = pendingExport(sessionID: sessionID)
        if var pending, pending.settled == nil {
            pending.removeTracks = true
            writePendingExport(pending, sessionID: sessionID)
            return
        }
        removeTracksIfSaved(sessionID: sessionID, marker: pending, recording: recording)
    }

    private func removeTracksIfSaved(sessionID: String, marker: PendingExport?, recording: URL? = nil) {
        guard let stash = stash(sessionID: sessionID) else { return }
        guard marker?.settled == .declined
            || (recording ?? savedRecording(sessionID: sessionID, marker: marker))
                .map({ MeetingRecording.covers($0, [stash.mic, stash.sys].compactMap { $0 }) }) == true
        else {
            var kept = marker ?? PendingExport(
                name: exportName(sessionID: sessionID), meta: loadBatchMeta(sessionID: sessionID))
            kept.removeTracks = true
            markUnsaved(kept, permanent: kept.settled == .unsavable, sessionID: sessionID)
            return
        }
        // The marker carries the saved name until the session does: it goes
        // with the tracks, and the player finds the recording by that name.
        if let marker, marker.settled == .saved,
           loadSessionMetadataFile(sessionID: sessionID)?.recordingFileName != marker.name,
           !recordSavedRecording(sessionID: sessionID, name: marker.name) {
            repoLog.error("recording name not saved to the session; its tracks stay for now")
            return
        }
        discardBatchAudio(sessionID: sessionID)
    }

    /// The merged recording this meeting's export wrote, by the exact name
    /// it was saved under, in its marker or its session — and, with a name,
    /// only that file. Without either (one that could not be written,
    /// #290, or a meeting from before #330) the notes folder is searched by
    /// timestamp, and only a single candidate counts: two could be a
    /// neighbouring meeting's, whose length proves nothing about this one.
    private func savedRecording(sessionID: String, marker: PendingExport?) -> URL? {
        guard let notesFolderPath else { return nil }
        // A name the export only planned may be another meeting's file.
        if let marker { return marker.settled == .saved ? notesFolderPath.appendingPathComponent(marker.name) : nil }
        guard let meta = loadSessionMetadataFile(sessionID: sessionID) else { return nil }
        if let name = meta.recordingFileName { return notesFolderPath.appendingPathComponent(name) }
        guard let endedAt = meta.endedAt else { return nil }
        // From this meeting's own start minute to just before the minute it
        // ended: the previous meeting's recording can carry the minute before,
        // and the next one's the end minute.
        func minute(_ date: Date) -> Date {
            Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        }
        let candidates = notesFolderExports(sessionID: sessionID)
            .filter { $0.stamp >= minute(meta.startedAt) && $0.stamp < minute(endedAt) }
        return candidates.count == 1 ? candidates[0].url : nil
    }

    /// The export settled without a saved recording: the tracks stay, and
    /// unless the cause is `permanent` the next launches try it again, up to
    /// `PendingExport.retryLimit`. Traced once, as it first becomes so.
    @discardableResult
    private func markUnsaved(_ marker: PendingExport, permanent: Bool = false, sessionID: String) -> PendingExport {
        var unsaved = marker
        unsaved.settled = permanent ? .unsavable : .unsaved
        writePendingExport(unsaved, sessionID: sessionID)
        if marker.settled != .unsaved && marker.settled != .unsavable { DiagStore.record(.recordingTracksKept) }
        return unsaved
    }

    /// One more try at an unsaved recording, this launch (#330): false when
    /// none is left, the cause was permanent, or there is no timing to merge
    /// by. Counted on the marker before it runs; one that cannot be counted
    /// is not run.
    func startExportRetry(sessionID: String) -> Bool {
        guard var pending = pendingExport(sessionID: sessionID), pending.settled == .unsaved,
              pending.meta != nil, (pending.retries ?? 0) < PendingExport.retryLimit
        else { return false }
        pending.retries = (pending.retries ?? 0) + 1
        return writePendingExport(pending, sessionID: sessionID)
    }

    /// The owner had "Save audio recording" off when the meeting ended: its
    /// tracks go when nothing else reads them, with no merged recording.
    /// Written by finalize; when it cannot be, the tracks stay (#330).
    public func markSavingDeclined(sessionID: String) {
        var declined = PendingExport(name: "", meta: nil)
        declined.settled = .declined
        writePendingExport(declined, sessionID: sessionID)
    }

    /// The owner discarded the meeting: its tracks go with it, saved or not.
    public func discardBatchAudio(sessionID: String) {
        for directory in stashDirectories(sessionID: sessionID) {
            BatchAudioStash.remove(in: directory)
        }
    }

    // MARK: - Merged recording export (#290)

    /// A meeting's merged recording: the marker finalize leaves beside the
    /// tracks, while it is to be written into the notes folder and after, so
    /// the tracks are let go against the exact file (#330). It goes with them.
    struct PendingExport: Codable, Sendable {
        /// The m4a's file name in the notes folder: the planned one until it
        /// is saved, then the one it was saved under (`placeRecording`).
        /// Empty when declined.
        var name: String
        /// The tracks' timing as the recording closed with it. The export
        /// merges by this and reads no other file; a marker without it gets
        /// no export, since tracks merged without their timing are misaligned.
        let meta: BatchMeta?
        /// The tracks' removal was asked for meanwhile: nothing but the
        /// export reads them any more.
        var removeTracks = false
        /// Nil while the export is still to run (#330).
        var settled: Settled?
        /// Exports tried again at later launches after it gave up (#330),
        /// counted before each runs, so one a crash cut short counts.
        var retries: Int?

        enum Settled: String, Codable, Sendable {
            /// The m4a is in the notes folder.
            case saved
            /// The export gave up: the tracks stay, and it is tried again at
            /// the next launches, up to `retryLimit`.
            case unsaved
            /// The export gave up for a cause no later try changes — a track
            /// that does not read whole, nothing to merge, no timing: the
            /// tracks stay, and it is not tried again.
            case unsavable
            /// "Save audio recording" was off: no export, and the tracks may go.
            case declined
        }

        /// Launches that try an unsaved recording again.
        static let retryLimit = 3

        /// An export may run: still pending, or tried again after it gave up.
        var wantsExport: Bool { settled == nil || settled == .unsaved }

        /// The export may still read the recorded tracks: it is pending, or
        /// tries are left. Compressing them first (#308) would merge the
        /// meeting from the lossy copies.
        var exportsLeft: Bool {
            settled == nil || (settled == .unsaved && (retries ?? 0) < Self.retryLimit)
        }
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
    public func markExportPending(sessionID: String, name: String, meta: BatchMeta) -> Bool {
        writePendingExport(PendingExport(name: name, meta: meta), sessionID: sessionID)
    }

    nonisolated func pendingExport(sessionID: String) -> PendingExport? {
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
        guard let pending = pendingExport(sessionID: sessionID), pending.wantsExport else { return .gone }
        guard let meta = pending.meta else { return .noTiming }
        guard let notesFolderPath else { return .notesFolderUnset }
        return .ready(
            tracks: stash(sessionID: sessionID)?.directory ?? audioDirectory(for: sessionID), meta: meta,
            file: Self.partialExport(of: notesFolderPath.appendingPathComponent(pending.name), sessionID: sessionID)
        )
    }

    /// Where the export fills the m4a before it is moved into place: a
    /// hidden name beside it, `.<stamp>.<session id>.part.m4a`, the meeting's
    /// own — two meetings of the same minute never share one (#330), and
    /// `AVAudioFile(forWriting:)` overwrites what a killed export of the same
    /// meeting left.
    nonisolated static func partialExport(of recording: URL, sessionID: String) -> URL {
        recording.deletingLastPathComponent().appendingPathComponent(
            ".\(recording.deletingPathExtension().lastPathComponent).\(sessionID)\(partialExportSuffix)")
    }

    private static let partialExportSuffix = ".part.m4a"

    /// Moves a written recording into the notes folder as `name`, or as
    /// `<stamp>-2.m4a`, `-3`, … when a recording already has the name — two
    /// meetings started in the same minute — and never over one (#330).
    /// Nil, with the partial left for its caller, when it could not move.
    nonisolated static func placeRecording(
        _ partial: URL, named name: String,
        renameExclusive: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) }
    ) -> URL? {
        let folder = partial.deletingLastPathComponent()
        let stem = (name as NSString).deletingPathExtension
        for n in 1...99 {
            let candidate = folder.appendingPathComponent(n == 1 ? name : "\(stem)-\(n).m4a")
            if moveExclusively(partial.path, candidate.path, renameExclusive) == 0 { return candidate }
            guard errno == EEXIST else { return nil }
        }
        return nil
    }

    /// `from` moved to `to` only when nothing is at `to`: 0, or -1 with errno
    /// (EEXIST when the name is taken). SMB and exFAT refuse an exclusive
    /// rename (ENOTSUP), so a hard link stands in, failing on EEXIST like it;
    /// with no hard links either, a check before a plain rename is enough,
    /// since exports run one at a time.
    private nonisolated static func moveExclusively(
        _ from: String, _ to: String, _ renameExclusive: (String, String) -> Int32
    ) -> Int32 {
        if renameExclusive(from, to) == 0 { return 0 }
        guard errno == ENOTSUP || errno == EINVAL else { return -1 }
        if link(from, to) == 0 {
            unlink(from)
            return 0
        }
        guard errno != EEXIST else { return -1 }
        guard !FileManager.default.fileExists(atPath: to) else {
            errno = EEXIST
            return -1
        }
        return rename(from, to)
    }

    /// The name a meeting's recording was saved under, for the gate and the
    /// player to find it by (#330).
    /// False, logged, when `session.json` could not be written.
    @discardableResult
    public func recordSavedRecording(sessionID: String, name: String) -> Bool {
        mutateSessionMetadata(sessionID: sessionID) { $0.recordingFileName = name }
    }

    /// The meeting's recording in the notes folder. With a recorded name only
    /// that file, or nil when it is gone: a `-2` meeting never resolves to its
    /// neighbour's (#330). Without one, the timestamp search, as before.
    private func notesRecording(sessionID: String) -> URL? {
        guard let name = loadSessionMetadataFile(sessionID: sessionID)?.recordingFileName else {
            return notesFolderExport(sessionID: sessionID)
        }
        guard let url = notesFolderPath?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

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
        guard let notesFolderPath, let pending = pendingExport(sessionID: sessionID), pending.wantsExport
        else { return }
        try? FileManager.default.removeItem(
            at: Self.partialExport(of: notesFolderPath.appendingPathComponent(pending.name), sessionID: sessionID))
    }

    /// The export is over: the file it wrote, if any, renamed over the m4a
    /// and the marker settled as saved — or, with no file, as unsaved
    /// (unsavable when the cause is `permanent`) — then
    /// the tracks removed through the gate when their removal was asked for
    /// meanwhile (#330). False, with the file removed, when no export is
    /// pending any more: the meeting was deleted while it ran. Throws,
    /// keeping the marker for another attempt, when the rename fails.
    func finishExport(sessionID: String, writtenTo file: URL?, permanent: Bool = false) throws -> Bool {
        guard var pending = pendingExport(sessionID: sessionID), pending.wantsExport else {
            if let file { try? FileManager.default.removeItem(at: file) }
            return false
        }
        if let file {
            guard let placed = Self.placeRecording(file, named: pending.name)
            else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            pending.name = placed.lastPathComponent
            pending.settled = .saved
            writePendingExport(pending, sessionID: sessionID)
            recordSavedRecording(sessionID: sessionID, name: pending.name)
        } else {
            pending = markUnsaved(pending, permanent: permanent, sessionID: sessionID)
        }
        if pending.removeTracks {
            removeTracksIfSaved(sessionID: sessionID, marker: pending)
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
        notesFolderExports(sessionID: sessionID).min { $0.distance < $1.distance }?.url
    }

    /// Every m4a in the notes folder whose timestamp falls in the meeting's
    /// window, with the stamp and its distance from the meeting's start.
    private func notesFolderExports(sessionID: String) -> [(url: URL, stamp: Date, distance: TimeInterval)] {
        guard let notesFolder = notesFolderPath,
              let meta = loadSessionMetadataFile(sessionID: sessionID),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: notesFolder, includingPropertiesForKeys: nil
              )
        else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = MeetingRecording.exportTimestampFormat
        let windowStart = meta.startedAt.addingTimeInterval(-60)
        let windowEnd = meta.endedAt ?? meta.startedAt.addingTimeInterval(600)

        return files
            .filter { $0.pathExtension == "m4a" }
            .compactMap { url -> (url: URL, stamp: Date, distance: TimeInterval)? in
                guard let stamp = formatter.date(from: url.deletingPathExtension().lastPathComponent),
                      stamp >= windowStart, stamp <= windowEnd else { return nil }
                return (url, stamp, abs(stamp.timeIntervalSince(meta.startedAt)))
            }
    }

    /// A name for a meeting's merged recording when no marker carried the
    /// recording's own (#330): the session's start, in the export's format.
    private func exportName(sessionID: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = MeetingRecording.exportTimestampFormat
        let start = loadSessionMetadataFile(sessionID: sessionID)?.startedAt ?? Date()
        return "\(formatter.string(from: start)).m4a"
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

    public func seedSession(
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

    public nonisolated var sessionsDirectoryURL: URL { sessionsDirectory }

    public func getCurrentSessionID() -> String? { currentSessionID }

    /// Returns the URL of the playable audio file for a session, if one exists.
    /// Checks for merged M4A exports and imported audio files. Normal meetings
    /// keep their merged m4a in the notes folder, not in the session (#130) —
    /// when the session's audio/ has no playable file, resolve it there. The
    /// session-local copy wins when both exist.
    public func audioFileURL(for sessionID: String) -> URL? {
        let audioDir = audioDirectory(for: sessionID)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: nil
        )) ?? []
        // Skip raw CAF and batch metadata, and the per-side tracks kept
        // compressed for a later speaker pass (#308) with their partials: one
        // side is not the meeting. Among playable files prefer M4A exports,
        // tie-broken by filename so the pick is deterministic.
        let skipExtensions: Set<String> = ["caf", "json"]
        let keptTracks: Set<String> = [
            BatchAudioStash.keptMicURL(in: audioDir).lastPathComponent,
            BatchAudioStash.keptSysURL(in: audioDir).lastPathComponent,
        ]
        return contents
            .filter { !skipExtensions.contains($0.pathExtension.lowercased()) }
            .filter { !keptTracks.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".") }
            .min { a, b in
                let aM4A = a.pathExtension.lowercased() == "m4a"
                let bM4A = b.pathExtension.lowercased() == "m4a"
                if aM4A != bM4A { return aM4A }
                return a.lastPathComponent < b.lastPathComponent
            } ?? notesRecording(sessionID: sessionID)
    }

    // MARK: - Private Helpers

    nonisolated private func sessionDirectory(for sessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent(sessionID, isDirectory: true)
    }

    @discardableResult
    private func writeSessionMetadata(_ metadata: SessionMetadata, sessionID: String) -> Bool {
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("session.json")
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try Self.writePrivately(enc.encode(metadata), to: url)
            return true
        } catch {
            repoLog.error("Failed to write session.json: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func loadSessionMetadataFile(sessionID: String) -> SessionMetadata? {
        let url = sessionDirectory(for: sessionID).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SessionMetadata.self, from: data)
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
    /// notesFolderPath. Also called when a meeting's speaker pass settles (#269),
    /// and when a note from the iPhone comes in with its transcript (#309).
    public func mirrorNotesArtifacts(sessionID: String) {
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
    /// A meeting's tracks in `directory`: each side as recorded, or the copy
    /// kept compressed in its place (#308) — the recorded one first, since a
    /// compression a kill cut short leaves both. The one definition the export
    /// and the gate that lets the tracks go both judge (#330).
    static func tracks(in directory: URL) -> (mic: URL?, sys: URL?) {
        func existing(_ urls: URL...) -> URL? { urls.first { FileManager.default.fileExists(atPath: $0.path) } }
        return (existing(micURL(in: directory), keptMicURL(in: directory)),
                existing(sysURL(in: directory), keptSysURL(in: directory)))
    }

    static func micURL(in directory: URL) -> URL {
        directory.appendingPathComponent("mic.caf")
    }

    static func sysURL(in directory: URL) -> URL {
        directory.appendingPathComponent("sys.caf")
    }

    /// The two tracks compressed to AAC, kept in place of the recorded ones
    /// when "Separate speakers" is off, so the pass can run later (#308).
    static func keptMicURL(in directory: URL) -> URL {
        directory.appendingPathComponent("mic.m4a")
    }

    static func keptSysURL(in directory: URL) -> URL {
        directory.appendingPathComponent("sys.m4a")
    }

    /// Where a kept track is written before it is renamed into place: hidden,
    /// so nothing takes a half-written one for a track or a recording.
    static func partialKept(_ kept: URL) -> URL {
        kept.deletingLastPathComponent().appendingPathComponent(".\(kept.lastPathComponent)")
    }

    /// 1 while the attempts counted were asked for with Who spoke? (#308).
    static func requestedURL(in directory: URL) -> URL {
        directory.appendingPathComponent("speaker-requested.json")
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

    /// The meeting's merged recording (#290, #330): while it is to be
    /// written the tracks stay (`SessionRepository.PendingExport`).
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

    /// Remove the whole stash — both tracks, their timing meta, what the
    /// speaker pass kept beside them, and the recording's marker.
    static func remove(in directory: URL) {
        let fm = FileManager.default
        let kept = [keptMicURL(in: directory), keptSysURL(in: directory)]
        for url in [micURL(in: directory), sysURL(in: directory), metaURL(in: directory),
                    linesURL(in: directory), attemptsURL(in: directory), exportAttemptsURL(in: directory),
                    requestedURL(in: directory), pendingExportURL(in: directory)] + kept + kept.map(partialKept) {
            try? fm.removeItem(at: url)
        }
    }
}

/// Codable batch metadata persisted as batch-meta.json.
public struct BatchMeta: Codable, Sendable {
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
