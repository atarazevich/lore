import Foundation
import os

private let linkLog = Logger(subsystem: "com.lore.app", category: "CLI")

/// Puts the `lore` command on the PATH (#254): `~/.local/bin/lore` becomes a
/// symlink to the running bundle's `Contents/Helpers/lore`, so installing the app
/// is the whole install. A path someone else put there is never touched.
enum CommandLink {
    static var linkPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/lore").path
    }

    /// Links the command in this bundle, when this bundle has one. Replaces only
    /// a link into some `Lore.app` — an older or moved copy, dangling or not.
    static func install(bundle: Bundle = .main, linkPath: String = linkPath) {
        let fileManager = FileManager.default
        let target = bundle.bundleURL.appendingPathComponent("Contents/Helpers/lore").path
        guard fileManager.isExecutableFile(atPath: target) else { return }
        do {
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkPath) {
                let intoLoreApp = destination.split(separator: "/")
                    .contains { $0.caseInsensitiveCompare("Lore.app") == .orderedSame }
                guard destination != target, intoLoreApp else { return }
                try fileManager.removeItem(atPath: linkPath)
            } else if fileManager.fileExists(atPath: linkPath) {
                return
            }
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: linkPath).deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
            linkLog.info("lore command linked")
        } catch {
            linkLog.error("lore command not linked: \(error.localizedDescription, privacy: .private)")
        }
    }
}
