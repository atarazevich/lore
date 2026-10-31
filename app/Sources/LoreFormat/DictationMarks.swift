import Darwin
import Foundation

/// One agent signing for a marked dictation (#324): one line of the entry's
/// `<UUID>.takes` sidecar. Dates are seconds since 2001, as in the entry file.
///
/// One writer per file: the app alone writes the entry's `markedAt`, the
/// `lore` command alone appends to the sidecar. Why: `docs/decisions.md`
/// 2026-10-31.
public struct DictationTake: Codable, Sendable, Equatable {
    /// The agent's name as it signed.
    public let by: String
    public let at: Date
    /// The entry's `markedAt` this take signed for. A dictation marked again
    /// after a take carries a new `markedAt`, which no earlier take matches.
    public let markedAt: Date

    public init(by: String, at: Date, markedAt: Date) {
        self.by = by
        self.at = at
        self.markedAt = markedAt
    }

    /// Whether this take signed for the mark set at `markedAt`. Within half a
    /// millisecond rather than bit-equal: both sides read the same number from
    /// JSON, but a writer that rounds its decimals must not unmark a take.
    public func took(_ markedAt: Date) -> Bool {
        abs(self.markedAt.timeIntervalSince(markedAt)) < 0.0005
    }
}

/// What a dictation's row says about its mark (#324).
public enum DictationMark: Equatable, Sendable {
    case none
    /// "Marked for later": no take has signed for the current mark yet.
    case waiting(markedAt: Date)
    /// "Taken by <agent> · <time>": the first take of the current mark.
    case taken(DictationTake)

    /// Takes of earlier marks stay in the sidecar and say nothing here: the
    /// row shows only the current state.
    public init(markedAt: Date?, takes: [DictationTake]) {
        guard let markedAt else {
            self = .none
            return
        }
        if let first = takes.first(where: { $0.took(markedAt) }) {
            self = .taken(first)
        } else {
            self = .waiting(markedAt: markedAt)
        }
    }
}

/// The `<UUID>.takes` sidecars beside the entry files (#324): append-only JSON
/// lines. Not `.json`, so neither the history scan (`DictationFiles.entries`)
/// nor Safe Flow's reader, which both glob `*.json`, take one for an entry.
public enum DictationTakes {
    public static let fileExtension = "takes"

    public static func url(of id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(fileExtension)")
    }

    /// The id a sidecar's file name carries, or nil for any other file.
    public static func id(ofSidecar url: URL) -> UUID? {
        guard url.pathExtension == fileExtension else { return nil }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    /// Every take in one sidecar, in the order they were appended. A line that
    /// does not decode is skipped, so a torn last line costs only itself.
    public static func read(at url: URL) -> [DictationTake] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(DictationTake.self, from: Data($0))
        }
    }

    public static func read(_ id: UUID, in directory: URL) -> [DictationTake] {
        read(at: url(of: id, in: directory))
    }

    /// Every sidecar in `directory`, by entry id. One with no line that
    /// decodes is listed too, with no takes: it still names its entry.
    public static func all(in directory: URL) -> [UUID: [DictationTake]] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var takes: [UUID: [DictationTake]] = [:]
        for file in files {
            guard let id = id(ofSidecar: file) else { continue }
            takes[id] = read(at: file)
        }
        return takes
    }

    /// Append one take as one line, in one `write` to a file opened with
    /// `O_APPEND`: two agents taking at once each land a whole line, and
    /// neither overwrites the other. Synced before it returns.
    public static func append(_ take: DictationTake, for id: UUID, in directory: URL) throws {
        var line = try JSONEncoder().encode(take)
        line.append(UInt8(ascii: "\n"))
        let fd = open(url(of: id, in: directory).path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
