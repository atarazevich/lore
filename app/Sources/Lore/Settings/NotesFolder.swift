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

/// The folder the #148 move could not empty, and why. The cause decides the
/// remedy: a collision leftover is a duplicate the user may delete, while an
/// iCloud placeholder is this Mac's only reference to content still in the
/// cloud — deleting it loses the meeting audio the play button resolves.
struct NotesLeftover: Equatable, Sendable {
    let path: String
    let hasEvicted: Bool
}

/// The one-time move of the notes folder into the app's domain (#148).
///
/// Two halves: `decide` is UserDefaults arithmetic and belongs on the launch
/// path; `PendingMove` is filesystem work and never does. The ordering rules
/// that hold it together — decide before the bundle migrations, marker and
/// repoint after the move, setting before folder removal — are load-bearing and
/// argued in `docs/decisions.md` 2026-08-07 (#148 and its fix pass).
enum NotesFolderMigration {

    /// One-shot marker, written when the decision *ends*: for a move that is
    /// the move's completion, so a kill mid-move retries on the next launch.
    static let markerKey = "didMigrateNotesToAppSupport"

    /// Set only when the move could not empty the source.
    static let leftoverKey = "notesMigrationLeftoverPath"

    /// Whether that leftover includes an iCloud placeholder. Seeded by the move
    /// and re-derived live whenever the panel verifies, so the remedy the user
    /// reads names the cause that is true then.
    static let leftoverEvictedKey = "notesMigrationLeftoverEvicted"

    static let notesPathKey = "notesFolderPath"

    /// Keys an earlier launch of this app leaves behind, none of them written
    /// by a framework. Their absence is how a *fresh* install is recognized
    /// without asking the filesystem — looking is the dialog.
    private static let priorLaunchKeys = [
        "didMigrateFromOnTheSpot",
        "didMigrateFromOpenGranola",
        SetupState.tourCompletedKey,
        SetupState.consentAcknowledgedKey,
    ]

    struct Result: Equatable {
        var disposition: DiagEvent.NotesMigration
        /// Moved and verified on the far side.
        var moved = 0
        /// Still in the source — a name collision or a failed move. Never
        /// deleted, never overwritten.
        var leftBehind = 0
        /// Moved, but the far side could not be read back. Not `leftBehind`:
        /// the source no longer holds it, and the counts must not say it does.
        var unverified = 0
        /// Left in the source because it has no bytes on this Mac. Counted
        /// apart from `leftBehind` because it needs a different remedy.
        var evicted = 0
    }

    // MARK: - Decision (launch path)

    /// UserDefaults only — no `stat`, no listing. Even "is the legacy folder
    /// there?" belongs to the move: asking is already a Documents touch.
    /// Must run *before* the bundle migrations in `SettingsStore.init`, which
    /// write two of the keys `hasPriorInstall` reads.
    ///
    /// Returns the folder to empty, or nil when there is nothing to do.
    static func decide(defaults: UserDefaults, target: URL, legacyDefaults: [URL]) -> PendingMove? {
        // `.alreadyDone`: every launch after the first, so deliberately untraced.
        guard !defaults.bool(forKey: markerKey) else { return nil }

        switch defaults.string(forKey: notesPathKey) {
        case .some(let stored) where isSamePath(target, stored):
            // The app's own folder, with the marker still down: a launch killed
            // between the move's repoint and its marker. Never the user's choice.
            settle(Result(disposition: .alreadyAtTarget), defaults: defaults)
            return nil

        case .some(let stored) where legacyDefaults.contains(where: { isSamePath($0, stored) }):
            return PendingMove(defaults: defaults, source: URL(fileURLWithPath: stored),
                               target: target, expectedStoredPath: stored)

        case .some:
            // The user's own folder. Respected — and deliberately not read:
            // reading it here would be the launch-time touch this change
            // removes, only in someone else's Documents.
            settle(Result(disposition: .customPathRespected), defaults: defaults)
            return nil

        case .none:
            guard hasPriorInstall(defaults: defaults), let oldDefault = legacyDefaults.first else {
                settle(Result(disposition: .freshInstall), defaults: defaults)
                return nil
            }
            return PendingMove(defaults: defaults, source: oldDefault,
                               target: target, expectedStoredPath: nil)
        }
    }

    /// Close the decision: the marker goes down and the branch is traced. Every
    /// branch that decides something is traced, because a one-shot irreversible
    /// migration has to stay answerable from events.json — including the
    /// branches that moved nothing.
    fileprivate static func settle(_ result: Result, defaults: UserDefaults) {
        defaults.set(true, forKey: markerKey)
        DiagStore.record(.notesFolderMigrated(
            disposition: result.disposition,
            moved: result.moved,
            leftBehind: result.leftBehind,
            unverified: result.unverified,
            evicted: result.evicted
        ))
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

    // MARK: - The move (never the launch path)

    /// A legacy folder still to be emptied. Carries no marker and no repointed
    /// setting — both follow completion, so a killed move resumes rather than
    /// being forgotten.
    ///
    /// `@unchecked`: only for `UserDefaults`, which Apple documents as
    /// thread-safe but has never annotated `Sendable`.
    struct PendingMove: @unchecked Sendable {
        let defaults: UserDefaults
        let source: URL
        let target: URL
        /// What `notesPathKey` held when the decision was made. The repoint is
        /// conditional on it still holding that: the app is usable throughout,
        /// so a folder picked in Settings meanwhile wins.
        let expectedStoredPath: String?

        /// Off the launch path. `.utility`, not `.background`: background QoS
        /// starves under Low Power, and a move that never finishes is a move
        /// that re-runs on every launch.
        func start(repoint: @escaping @Sendable @MainActor (String) -> Void) {
            Task.detached(priority: .utility) { await perform(repoint: repoint) }
        }

        @discardableResult
        func perform(repoint: @escaping @Sendable @MainActor (String) -> Void) async -> Result {
            // The migration's first filesystem touch, and the one that raises
            // the Documents dialog. A denial reads as "not there" — the same
            // honest answer as a folder that really is gone.
            guard FileManager.default.fileExists(atPath: source.path) else {
                return await land(Result(disposition: .nothingToMove), sentinels: [], repoint: repoint)
            }
            let (result, sentinels) = move()
            return await land(result, sentinels: sentinels, repoint: repoint)
        }

        /// Move, not copy — and never over anything. Each entry moves
        /// individually and is verified on the far side; a name that already
        /// exists in the target is left where it is rather than resolved by
        /// guessing which copy is the real one. Returns the sentinel files it
        /// listed, which `land` sweeps only once the source is safe to drop.
        private func move() -> (Result, sentinels: [URL]) {
            NotesFolder.prepare(target)

            let fm = FileManager.default
            var result = Result(disposition: .moved)
            var sentinels: [URL] = []
            let entries = (try? fm.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: []
            )) ?? []

            // The start half of the pair: a move that blocks leaves this and no
            // completion, which is how a stuck one is told from a quiet launch.
            DiagStore.record(.notesFolderMoveStarted(entries: entries.count))

            for entry in entries {
                guard !NotesFolderMigration.isDisposable(entry.lastPathComponent) else {
                    sentinels.append(entry)
                    continue
                }
                // No bytes on this Mac: moving it out of the synced folder makes
                // macOS download it first. Left alone and counted, never waited on.
                guard !NotesFolderMigration.isICloudPlaceholder(entry) else {
                    result.evicted += 1
                    continue
                }
                let destination = target.appendingPathComponent(entry.lastPathComponent)
                guard !fm.fileExists(atPath: destination.path) else {
                    result.leftBehind += 1
                    continue
                }
                let before = NotesFolderMigration.size(of: entry)
                do {
                    try fm.moveItem(at: entry, to: destination)
                } catch {
                    result.leftBehind += 1
                    continue
                }
                switch (before, NotesFolderMigration.size(of: destination)) {
                case (.directory, .directory):
                    result.moved += 1
                case (.bytes(let sent), .bytes(let landed)) where sent == landed:
                    result.moved += 1
                default:
                    // The move itself succeeded, so the entry is out of the
                    // source whatever the far side reads back.
                    result.unverified += 1
                }
            }
            return (result, sentinels)
        }

        /// Everything that must follow the move, in the order a live app
        /// requires. The setting moves first, so no write can be aimed at a path
        /// about to disappear; the folder goes second and only if `rmdir`
        /// accepts it, so anything written into the gap survives instead of
        /// being deleted, and its refusal is how that is noticed at all.
        private func land(
            _ result: Result,
            sentinels: [URL],
            repoint: @escaping @Sendable @MainActor (String) -> Void
        ) async -> Result {
            if await repointed(repoint) {
                for sentinel in sentinels { try? FileManager.default.removeItem(at: sentinel) }
                // rmdir, not `removeItem`, which is recursive.
                rmdir(source.path)
            }
            let stranded = NotesFolderMigration.userData(in: source)
            if !stranded.isEmpty {
                defaults.set(source.path, forKey: NotesFolderMigration.leftoverKey)
                defaults.set(stranded.contains(where: NotesFolderMigration.isICloudPlaceholder),
                             forKey: NotesFolderMigration.leftoverEvictedKey)
            }
            NotesFolderMigration.settle(result, defaults: defaults)
            return result
        }

        /// Decided and applied on the main actor, so it serializes with a folder
        /// the user may be picking in Settings at that same moment.
        private func repointed(_ repoint: @escaping @Sendable @MainActor (String) -> Void) async -> Bool {
            await MainActor.run {
                guard defaults.string(forKey: NotesFolderMigration.notesPathKey) == expectedStoredPath
                else { return false }
                defaults.set(target.path, forKey: NotesFolderMigration.notesPathKey)
                repoint(target.path)
                return true
            }
        }
    }

    /// iCloud's two tells that a listed entry has no bytes on this Mac: the
    /// downloading status the file provider publishes, and the `.icloud`
    /// placeholder name the older sync path leaves in the directory. Shallow by
    /// design — a *directory* of placeholders can still block, which now costs
    /// a background task rather than the launch.
    static func isICloudPlaceholder(_ url: URL) -> Bool {
        if url.pathExtension == "icloud" { return true }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        return status == .notDownloaded
    }

    /// The single spelling of "what user data is still in there", called by the
    /// site that raises the leftover marker and by the site that clears it. Two
    /// spellings would eventually disagree, and the row would latch.
    static func userData(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [])) ?? [])
            .filter { !isDisposable($0.lastPathComponent) }
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

    /// The launch read: markers only. The folder they name is in `~/Documents`,
    /// and `HealthMonitor.init` probes on the launch path.
    static func pendingLeftover(defaults: UserDefaults) -> NotesLeftover? {
        guard let path = defaults.string(forKey: leftoverKey) else { return nil }
        return NotesLeftover(path: path, hasEvicted: defaults.bool(forKey: leftoverEvictedKey))
    }

    /// The verified read, for the moment the panel is on screen — the one place
    /// the row may look inside the folder it names, and where its cause is
    /// re-derived rather than recalled. A folder that has since been emptied
    /// clears the markers and reports nothing
    /// (`.claude/rules/no-false-positives.md` §1–2).
    @discardableResult
    static func verifyLeftover(defaults: UserDefaults) -> NotesLeftover? {
        guard let path = defaults.string(forKey: leftoverKey) else { return nil }
        let remaining = userData(in: URL(fileURLWithPath: path))
        guard !remaining.isEmpty else {
            defaults.removeObject(forKey: leftoverKey)
            defaults.removeObject(forKey: leftoverEvictedKey)
            DiagStore.record(.notesFolderLeftoverCleared)
            return nil
        }
        let hasEvicted = remaining.contains(where: isICloudPlaceholder)
        defaults.set(hasEvicted, forKey: leftoverEvictedKey)
        return NotesLeftover(path: path, hasEvicted: hasEvicted)
    }
}
