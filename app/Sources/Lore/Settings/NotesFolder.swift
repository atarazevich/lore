import Foundation

/// Where meeting notes live, and the one-time move that put them there.
/// Nothing on the launch path may touch a TCC-protected folder; access happens
/// at first use. Rationale: `docs/decisions.md` 2026-08-07 (#148).
enum NotesFolder {

    /// Spotlight opt-out sentinel: transcript text must not enter the index.
    static let spotlightSentinel = ".metadata_never_index"

    /// The notes directory inside a given Application Support root.
    static func notes(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Notes", isDirectory: true)
    }

    /// The default notes directory. A path is not an access — building this URL
    /// touches no disk.
    static var applicationSupportDefault: URL {
        notes(in: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Lore", isDirectory: true))
    }

    /// Directories earlier builds picked *for* the user, in the order the
    /// migration considers them. Neither was ever chosen through the folder
    /// picker: `~/Documents/Lore` was the hard-coded default, and
    /// `~/Documents/OpenGranola` was written into `notesFolderPath` by the
    /// OpenGranola file migration. A path the user actually picked is
    /// recognizable by *not* being in this list — and is never moved.
    static var legacyDefaults: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Documents/Lore", isDirectory: true),
            home.appendingPathComponent("Documents/OpenGranola", isDirectory: true),
        ]
    }

    /// Create a directory the app owns and keep Spotlight out of it. Call at
    /// the moment of first *use* — a note write, an audio export — never at
    /// launch. Named for its main client; the session store uses the same
    /// idiom on its own directory, and one copy of it is the point.
    static func prepare(_ directory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent(spotlightSentinel)
        if !fm.fileExists(atPath: sentinel.path) {
            fm.createFile(atPath: sentinel.path, contents: nil)
        }
    }
}

/// The one-time move of the notes folder into the app's domain (#148).
///
/// Runs once per install from `SettingsStore.init`, and only when the stored
/// notes path is one the *app* chose. Pure in its inputs, so the whole decision
/// table is testable against temp directories.
enum NotesFolderMigration {

    /// One-shot marker, set on every outcome including the ones that touch
    /// nothing: the decision is made once, and a relaunch must not re-probe.
    static let markerKey = "didMigrateNotesToAppSupport"

    /// Set only when the move could not empty the source.
    static let leftoverKey = "notesMigrationLeftoverPath"

    static let notesPathKey = "notesFolderPath"

    /// Keys an earlier launch of this app leaves behind, none of them written
    /// by a framework. Their absence is how a *fresh* install is recognized
    /// without asking the filesystem — looking is the dialog.
    ///
    /// Load-bearing ordering: this runs *before* the OnTheSpot/OpenGranola
    /// migrations in `SettingsStore.init`, which set the first two themselves.
    private static let priorLaunchKeys = [
        "didMigrateFromOnTheSpot",
        "didMigrateFromOpenGranola",
        "hasCompletedOnboarding",
        "hasAcknowledgedRecordingConsent",
    ]

    struct Result {
        var disposition: DiagEvent.NotesMigration
        /// Moved and verified on the far side.
        var moved = 0
        /// Still in the source — a name collision or a failed move. Never
        /// deleted, never overwritten.
        var leftBehind = 0
        /// Moved, but the far side could not be read back. Not `leftBehind`:
        /// the source no longer holds it, and the counts must not say it does.
        var unverified = 0
    }

    // MARK: - Decision

    @discardableResult
    static func run(defaults: UserDefaults, target: URL, legacyDefaults: [URL]) -> Result {
        guard !defaults.bool(forKey: markerKey) else {
            return Result(disposition: .alreadyDone)
        }
        defer { defaults.set(true, forKey: markerKey) }

        let source: URL
        switch defaults.string(forKey: notesPathKey) {
        case .some(let stored) where legacyDefaults.contains(where: { isSamePath($0, stored) }):
            source = URL(fileURLWithPath: stored)

        case .some:
            // The user's own folder. Respected — and deliberately not read:
            // reading it here would be the launch-time touch this change
            // removes, only in someone else's Documents.
            return record(Result(disposition: .customPathRespected))

        case .none:
            guard hasPriorInstall(defaults: defaults), let oldDefault = legacyDefaults.first else {
                return record(Result(disposition: .freshInstall))
            }
            source = oldDefault
        }

        guard FileManager.default.fileExists(atPath: source.path) else {
            defaults.set(target.path, forKey: notesPathKey)
            return record(Result(disposition: .nothingToMove))
        }

        let result = move(from: source, to: target)
        defaults.set(target.path, forKey: notesPathKey)
        if result.leftBehind > 0 {
            defaults.set(source.path, forKey: leftoverKey)
        }
        return record(result)
    }

    /// Every branch that decides something is traced: a one-shot irreversible
    /// migration has to stay answerable from events.json, including the
    /// branches that moved nothing. `.alreadyDone` is the one outcome not
    /// recorded — it is every launch after the first, and one event per launch
    /// forever would evict the very trace this exists to keep.
    @discardableResult
    private static func record(_ result: Result) -> Result {
        DiagStore.record(.notesFolderMigrated(
            disposition: result.disposition,
            moved: result.moved,
            leftBehind: result.leftBehind,
            unverified: result.unverified
        ))
        return result
    }

    private static func hasPriorInstall(defaults: UserDefaults) -> Bool {
        priorLaunchKeys.contains { defaults.object(forKey: $0) != nil }
    }

    /// Lexical comparison — `standardizedFileURL` normalizes a trailing slash
    /// without asking the filesystem. Resolving symlinks would be a
    /// `~/Documents` access inside the check whose purpose is to avoid one.
    private static func isSamePath(_ url: URL, _ path: String) -> Bool {
        url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - The move

    /// Move, not copy — and never over anything. Each entry moves individually
    /// and is verified on the far side; a name that already exists in the
    /// target is left where it is rather than resolved by guessing which copy
    /// is the real one. The source *directory* goes only once it holds no data.
    private static func move(from source: URL, to target: URL) -> Result {
        NotesFolder.prepare(target)

        let fm = FileManager.default
        var result = Result(disposition: .moved)
        let entries = (try? fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: []
        )) ?? []

        for entry in entries where !isDisposable(entry.lastPathComponent) {
            let destination = target.appendingPathComponent(entry.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else {
                result.leftBehind += 1
                continue
            }
            let before = size(of: entry)
            do {
                try fm.moveItem(at: entry, to: destination)
            } catch {
                result.leftBehind += 1
                continue
            }
            switch (before, size(of: destination)) {
            case (.directory, .directory):
                result.moved += 1
            case (.bytes(let sent), .bytes(let landed)) where sent == landed:
                result.moved += 1
            default:
                // The move itself succeeded, so the entry is out of the source
                // whatever the far side reads back.
                result.unverified += 1
            }
        }

        let remaining = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
        if result.leftBehind == 0, remaining.allSatisfy(isDisposable) {
            try? fm.removeItem(at: source)
        }
        return result
    }

    /// Files this app or Finder put there, carrying no user data — they must
    /// not keep an otherwise-empty source folder alive.
    private static func isDisposable(_ name: String) -> Bool {
        name == NotesFolder.spotlightSentinel || name == ".DS_Store"
    }

    private enum EntrySize: Equatable {
        case bytes(Int)
        /// Existence is the whole check — a directory's "size" compares nothing.
        case directory
        case unreadable
    }

    private static func size(of url: URL) -> EntrySize {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        else { return .unreadable }
        if values.isDirectory == true { return .directory }
        guard let bytes = values.fileSize else { return .unreadable }
        return .bytes(bytes)
    }

    // MARK: - Leftovers

    /// The marker alone, no filesystem. This is what the *launch* probe reads:
    /// the leftover folder is in `~/Documents`, so verifying it at launch would
    /// be the TCC touch this whole change removes (#148).
    static func pendingLeftoverPath(defaults: UserDefaults) -> String? {
        defaults.string(forKey: leftoverKey)
    }

    /// The verified read, for the moment the panel is on screen — the one place
    /// the row may look inside the folder it names. A folder that has since
    /// been emptied clears the marker and reports nothing
    /// (`.claude/rules/no-false-positives.md` §1–2).
    @discardableResult
    static func verifyLeftover(defaults: UserDefaults) -> String? {
        guard let path = defaults.string(forKey: leftoverKey) else { return nil }
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        guard remaining.contains(where: { !isDisposable($0) }) else {
            defaults.removeObject(forKey: leftoverKey)
            DiagStore.record(.notesFolderLeftoverCleared)
            return nil
        }
        return path
    }
}
