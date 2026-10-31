import Foundation
import LoreCore
import LoreFormat

/// The file side of bringing a note from the iPhone into Meetings (#309): what
/// is in the outbox, whether a note is all on this Mac yet, and the copy into
/// lore's own sessions. Synchronous and blocking — a read of the outbox can
/// wait on macOS's iCloud Drive question — so callers run it off the main
/// actor. `PhoneNoteImporter` decides when; this only does.
///
/// The one thing ever written into the outbox is a note's `.imported` marker.
/// Nothing there is deleted or changed otherwise.
enum PhoneNoteImport {

    // MARK: - The outbox

    enum Listing: Equatable {
        /// The folder isn't there: the phone hasn't sent anything yet. Not a problem.
        case missing
        /// macOS refused the read (the owner said Don't Allow to iCloud Drive).
        case refused
        /// Some other error: nothing is claimed about it.
        case unreadable
        /// Finished notes waiting, by id. Notes already marked imported, and
        /// `.partial` folders, are left out.
        case notes([String])
    }

    static func list(outbox: URL) -> Listing {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: outbox, includingPropertiesForKeys: [.isDirectoryKey], options: []
            )
        } catch {
            switch FileOpenFailure(error) {
            case .missing: return .missing
            case .notPermitted: return .refused
            case .other: return .unreadable
            }
        }
        let ids = entries.compactMap { entry -> String? in
            let id = entry.lastPathComponent
            guard PhoneNotes.isFinishedNote(id),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !FileManager.default.fileExists(atPath: entry.appendingPathComponent(PhoneNotes.importedMarker).path)
            else { return nil }
            return id
        }
        return .notes(ids.sorted())
    }

    // MARK: - Staging

    /// What a pass killed mid-copy left in the sessions folder; a pass clears
    /// it before it starts. Hidden, so no list ever showed it.
    static func removeStaging(in sessions: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        for name in entries where name.hasPrefix(".") && name.hasSuffix(stagingSuffix) {
            try? FileManager.default.removeItem(at: sessions.appendingPathComponent(name))
        }
    }

    private static let stagingSuffix = ".importing"

    // MARK: - One note

    enum Outcome: Equatable {
        /// In the sessions folder and marked — copied now, or found there from
        /// a pass that stopped before marking it.
        case imported(hasTranscript: Bool)
        /// Not all here yet — the folder can sync before its files do. The
        /// downloads were asked for; nothing was written.
        case waiting
        case failed(DiagEvent.PhoneNoteStage)
    }

    /// Bring the note `id` from `outbox` into `sessions`, all or nothing: the
    /// note is copied under a hidden name and renamed into place in one step,
    /// so a session folder is never half a note. Only then is the outbox copy
    /// marked. A note is ready only when its `session.json` and its recording
    /// are there and every file in it is on this Mac.
    static func importNote(_ id: String, from outbox: URL, into sessions: URL) -> Outcome {
        let note = outbox.appendingPathComponent(id, isDirectory: true)
        let destination = sessions.appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default

        if fm.fileExists(atPath: destination.path) {
            // A pass stopped between the rename and the marker — or a Mac
            // meeting started the same second, which is not this note.
            guard source(of: destination) == PhoneNotes.source else { return .failed(.idInUse) }
            mark(note)
            return .imported(hasTranscript: hasTranscript(destination))
        }

        switch readiness(of: note) {
        case .waiting: return .waiting
        case .failed(let stage): return .failed(stage)
        case .ready: break
        }
        guard readsAsMeeting(note) else { return .failed(.noteFile) }

        let staging = sessions.appendingPathComponent(".\(id)\(stagingSuffix)", isDirectory: true)
        try? fm.removeItem(at: staging)
        do {
            try fm.copyItem(at: note, to: staging)
        } catch {
            try? fm.removeItem(at: staging)
            return .failed(stage(of: error, in: note))
        }
        try? fm.removeItem(at: staging.appendingPathComponent(PhoneNotes.importedMarker))
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            return .failed(.copy)
        }
        mark(note)
        return .imported(hasTranscript: hasTranscript(destination))
    }

    /// The marker the phone waits for. A failed write is tried again on the
    /// next pass, which finds the note already here.
    private static func mark(_ note: URL) {
        FileManager.default.createFile(atPath: note.appendingPathComponent(PhoneNotes.importedMarker).path, contents: nil)
    }

    private static func hasTranscript(_ folder: URL) -> Bool {
        let transcript = folder.appendingPathComponent("transcript.final.jsonl")
        return ((try? transcript.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    // MARK: - Is all of it here?

    enum Readiness: Equatable {
        case ready
        case waiting
        case failed(DiagEvent.PhoneNoteStage)
    }

    /// A file iCloud hasn't downloaded yet — dataless, the not-downloaded
    /// status — has its download started and makes the note wait, and so
    /// does a missing `session.json` or recording: iCloud may sync the
    /// renamed folder before the files in it. A download iCloud reports as
    /// failed is a failure of that file.
    static func readiness(of note: URL) -> Readiness {
        let fm = FileManager.default
        for required in ["session.json", PhoneNotes.recordingPath]
        where !fm.fileExists(atPath: note.appendingPathComponent(required).path) {
            return .waiting
        }
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey]
        guard let walk = fm.enumerator(at: note, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        else { return .failed(.noteFile) }
        var waiting = false
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.ubiquitousItemDownloadingError != nil {
                return .failed(stage(of: relativePath(of: url, in: note)))
            }
            if values?.ubiquitousItemDownloadingStatus == .notDownloaded {
                try? fm.startDownloadingUbiquitousItem(at: url)
                waiting = true
            }
        }
        return waiting ? .waiting : .ready
    }

    private static func source(of folder: URL) -> String? {
        struct Meta: Decodable { let startedAt: Date; let source: String? }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")) else { return nil }
        return (try? MeetingFiles.decoder.decode(Meta.self, from: data))?.source
    }

    /// `session.json` decodes as a meeting's: a folder lore could not list
    /// is not imported and marked as if it had been.
    private static func readsAsMeeting(_ note: URL) -> Bool {
        struct Start: Decodable { let startedAt: Date }
        guard let data = try? Data(contentsOf: note.appendingPathComponent("session.json")) else { return false }
        return (try? MeetingFiles.decoder.decode(Start.self, from: data)) != nil
    }

    // MARK: - Which file failed

    static func stage(of path: String) -> DiagEvent.PhoneNoteStage {
        if path.hasPrefix("audio/") || path == "audio" { return .audio }
        if path == "transcript.final.jsonl" { return .transcript }
        return .noteFile
    }

    /// The file a failed copy names: one in the note is the note's problem,
    /// anything else (the destination) was ours.
    static func stage(of error: Error, in note: URL) -> DiagEvent.PhoneNoteStage {
        guard let path = (error as NSError).userInfo[NSFilePathErrorKey] as? String,
              isInside(path, note) else { return .copy }
        return stage(of: relativePath(of: URL(fileURLWithPath: path), in: note))
    }

    private static func isInside(_ path: String, _ folder: URL) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            .hasPrefix(folder.standardizedFileURL.resolvingSymlinksInPath().path + "/")
    }

    private static func relativePath(of url: URL, in folder: URL) -> String {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard full.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(full.dropFirst(base.count + 1))
    }
}
