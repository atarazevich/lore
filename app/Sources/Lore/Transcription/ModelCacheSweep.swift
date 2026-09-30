import Darwin
import Foundation

/// Half-finished compiles of the speech model, cleared out of lore's own
/// Neural Engine cache at launch (#294).
///
/// CoreML compiles a model for the Neural Engine into
/// `<hash>.tmp.<pid>_<n>.bundle` beside the place the finished bundle will
/// take, and renames it into place when the compile ends. A process that dies
/// mid-compile — a relaunch 51 s into the encoder's ~80 s — leaves the temp
/// folder behind: 425 MB that nothing reads and nothing removes. Only such a
/// folder whose process is gone is touched. A compile running right now, this
/// process's or any other's, is left alone, and so is every finished bundle.
enum ModelCacheSweep {
    /// lore's own cache, never the system's or another app's.
    static let defaultRoot = URL.cachesDirectory.appending(path: "com.lore.app/com.apple.e5rt.e5bundlecache")

    /// The process a leftover compile names, or nil for anything that is not
    /// one — a finished bundle has no `.tmp.` in its name.
    static func compilingPID(of name: String) -> pid_t? {
        guard let match = name.wholeMatch(of: /.+\.tmp\.(\d+)_.+\.bundle/),
              let pid = pid_t(match.1), pid > 0
        else { return nil }
        return pid
    }

    /// `EPERM` counts as alive: the process exists, it is just not ours to signal.
    static func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Remove every leftover compile under `root` whose process is gone, and
    /// trace how many went. Blocking file work: run it off the main actor.
    /// Symbolic links are never followed — the walk does not descend into
    /// them, and removing one removes the link.
    @discardableResult
    static func removeOrphans(in root: URL = defaultRoot) -> Int {
        let files = FileManager.default
        guard let walker = files.enumerator(at: root, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for case let url as URL in walker where url.pathExtension == "bundle" {
            // What is inside a bundle belongs to that bundle's compile.
            walker.skipDescendants()
            guard let pid = compilingPID(of: url.lastPathComponent), !processIsAlive(pid) else { continue }
            if (try? files.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 { DiagStore.record(.modelCacheOrphansRemoved(folders: removed)) }
        return removed
    }
}
