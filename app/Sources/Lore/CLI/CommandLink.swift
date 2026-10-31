import Foundation
import os

private let linkLog = Logger(subsystem: "com.lore.app", category: "CLI")

/// Puts the `lore` command on the PATH (#254, #301): a `lore` symlink to the
/// running bundle's `Contents/Helpers/lore`, so installing the app is the whole
/// install. A path someone else put there is never touched.
enum CommandLink {
    /// Where the link may go, first choice first: the first two are on a stock
    /// PATH (Apple silicon Homebrew, then Intel Homebrew and the system's own),
    /// writable for this user only when Homebrew made them so; the last is the
    /// user's own and is created when missing.
    static var ladder: [String] {
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
        ]
    }

    /// Links the command in this bundle, when this bundle has one, in the first
    /// directory of `directories` that can take it — unless a link of ours is
    /// already in one of them up to there. Every link of ours on the ladder is
    /// pointed at this bundle; a `lore` that is not a link into some `Lore.app`
    /// is left as it is, and that directory is passed over.
    static func install(bundle: Bundle = .main, directories: [String] = ladder) {
        let fileManager = FileManager.default
        let target = bundle.bundleURL.appendingPathComponent("Contents/Helpers/lore").path
        guard fileManager.isExecutableFile(atPath: target) else { return }
        var linked = false
        for (rung, directory) in directories.enumerated() {
            let linkPath = (directory as NSString).appendingPathComponent("lore")
            do {
                if let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkPath) {
                    let intoLoreApp = destination.split(separator: "/")
                        .contains { $0.caseInsensitiveCompare("Lore.app") == .orderedSame }
                    guard intoLoreApp else { continue }
                    linked = true
                    // An older or moved copy, dangling or not.
                    guard destination != target else { continue }
                    try fileManager.removeItem(atPath: linkPath)
                } else if fileManager.fileExists(atPath: linkPath) || linked {
                    continue
                } else if rung == directories.count - 1 {
                    try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
                } else if !fileManager.isWritableFile(atPath: directory) {
                    continue
                }
                try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
                linked = true
                linkLog.info("lore command linked in rung \(rung, privacy: .public)")
            } catch {
                linkLog.error("lore command not linked: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
