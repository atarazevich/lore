import Foundation

/// Where meeting notes live; the one-time move that put them there is the
/// Mac's `NotesFolderMigration`. Nothing on the launch path may touch a
/// TCC-protected folder; access happens at first use. Rationale:
/// `docs/decisions.md` 2026-08-07 (#148).
public enum NotesFolder {

    /// Spotlight opt-out sentinel: transcript text must not enter the index.
    public static let spotlightSentinel = ".metadata_never_index"

    /// The notes directory inside a given Application Support root.
    static func notes(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Notes", isDirectory: true)
    }

    /// The default notes directory. A path is not an access — building this URL
    /// touches no disk.
    public static var applicationSupportDefault: URL {
        notes(in: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Lore", isDirectory: true))
    }

    /// Create a directory the app owns and keep Spotlight out of it. Call at
    /// the moment of first *use* — a note write, an audio export — never at
    /// launch. Named for its main client; the session store uses the same
    /// idiom on its own directory, and one copy of it is the point.
    public static func prepare(_ directory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent(spotlightSentinel)
        if !fm.fileExists(atPath: sentinel.path) {
            fm.createFile(atPath: sentinel.path, contents: nil)
        }
    }

    /// Where the older sync path leaves the placeholder of an evicted `url`:
    /// `.<name>.icloud` beside it.
    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// iCloud's two tells that a listed entry has no bytes on this Mac: the
    /// downloading status the file provider publishes, and the `.icloud`
    /// placeholder name the older sync path leaves in the directory. Shallow by
    /// design — a *directory* of placeholders can still block, which now costs
    /// a background task rather than the launch.
    public static func isICloudPlaceholder(_ url: URL) -> Bool {
        if url.pathExtension == "icloud" { return true }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        return status == .notDownloaded
    }
}
