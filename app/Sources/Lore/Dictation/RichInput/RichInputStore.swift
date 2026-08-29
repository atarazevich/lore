import AppKit
import os

/// The one storage exception (#192, D4): an image that exists only on the
/// clipboard is going to a target that can open a file, so its bytes are
/// written once, beside the dictation they belong to, and the prompt carries
/// the path. Nothing else about an item is stored — a copied file keeps its own
/// path, and text is text.
enum RichInputStore {
    private static let log = Logger(subsystem: "com.lore.app", category: "RichInputStore")

    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Lore/RichInput", isDirectory: true)
    }

    /// Write one clipboard image as PNG and return its absolute path. Nil when
    /// nothing landed — the caller drops the item, because a prompt must never
    /// name a picture that is not there.
    ///
    /// `directory` is injectable so tests never write into the user's own
    /// Application Support.
    static func writePNG(
        _ data: Data, entryID: UUID, index: Int, directory: URL = defaultDirectory
    ) -> String? {
        guard let png = asPNG(data) else {
            log.error("clipboard image is not convertible to PNG")
            return nil
        }
        let url = directory.appendingPathComponent("\(entryID.uuidString)-\(index).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return url.path
        } catch {
            DiagStore.record(.historyWriteFailed)
            log.error("failed to write clipboard image: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    // MARK: - Keeping the folder small (#196)

    /// One collected PNG on disk: what pruning needs to know about it, and
    /// nothing about what it shows.
    struct StoredImage: Equatable, Sendable {
        let url: URL
        let bytes: Int64
        /// When it was written. These files are written once and never touched
        /// again, so this is their age.
        let written: Date
    }

    /// Which files go, oldest first, so what is left fits under `limitBytes`.
    /// Pure: the order and the arithmetic are testable with no disk at all.
    /// Empty when the folder already fits.
    static func pruneList(_ files: [StoredImage], limitBytes: Int64) -> [StoredImage] {
        var total = files.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > limitBytes else { return [] }
        var doomed: [StoredImage] = []
        for file in files.sorted(by: { $0.written < $1.written }) {
            guard total > limitBytes else { break }
            doomed.append(file)
            total -= file.bytes
        }
        return doomed
    }

    /// Keep the collected screenshots under the ceiling from Settings →
    /// Copying, oldest deleted first (#196). Called after a paste, off the main
    /// thread, never on the launch path.
    ///
    /// The rule is the one dictation recordings already follow: newest kept,
    /// oldest deleted, 0 = unlimited. A pruned file leaves its history entry
    /// alone — the paste it was named in already happened, and rewriting text
    /// that has left the app is not something this can do.
    static func pruneToCap(
        limitMegabytes: Int, directory: URL = defaultDirectory
    ) {
        guard limitMegabytes > 0 else { return }
        let doomed = pruneList(
            contents(of: directory), limitBytes: Int64(limitMegabytes) * 1_048_576
        )
        guard !doomed.isEmpty else { return }
        var deleted = 0
        var freed: Int64 = 0
        for file in doomed {
            do {
                try FileManager.default.removeItem(at: file.url)
                deleted += 1
                freed += file.bytes
            } catch {
                log.error("failed to prune image: \(error.localizedDescription, privacy: .private)")
            }
        }
        guard deleted > 0 else { return }
        DiagStore.record(.dictationItemsPruned(deleted: deleted, bytesFreed: Int(freed)))
    }

    /// Everything these entries put on disk goes with them (#196). No index is
    /// kept anywhere: the file names carry the entry they belong to.
    static func deleteFiles(ofEntries ids: Set<UUID>, directory: URL = defaultDirectory) {
        guard !ids.isEmpty else { return }
        for file in contents(of: directory) {
            guard let owner = entryID(of: file.url), ids.contains(owner) else { continue }
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// The entry a collected file belongs to. The name is `<entry id>-<n>.png`
    /// and a UUID carries its own dashes, so the index is what follows the last
    /// one. Nil for anything else that ended up in the folder.
    static func entryID(of url: URL) -> UUID? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let dash = name.lastIndex(of: "-") else { return nil }
        return UUID(uuidString: String(name[name.startIndex..<dash]))
    }

    /// The folder as it is right now. Only the PNGs this store writes — a stray
    /// file is never counted and never deleted.
    static func contents(of directory: URL) -> [StoredImage] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return [] }
        return urls.filter { $0.pathExtension == "png" }.compactMap { url in
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ), let size = values.fileSize else { return nil }
            return StoredImage(
                url: url,
                bytes: Int64(size),
                written: values.contentModificationDate ?? .distantPast
            )
        }
    }

    /// PNG bytes pass through untouched; a TIFF (what most apps put on the
    /// pasteboard when they copy pixels) is re-encoded once.
    private static func asPNG(_ data: Data) -> Data? {
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if data.count > 4, Array(data.prefix(4)) == pngMagic { return data }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
