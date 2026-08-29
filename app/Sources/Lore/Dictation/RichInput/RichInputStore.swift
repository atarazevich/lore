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

    /// PNG bytes pass through untouched; a TIFF (what most apps put on the
    /// pasteboard when they copy pixels) is re-encoded once.
    private static func asPNG(_ data: Data) -> Data? {
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if data.count > 4, Array(data.prefix(4)) == pngMagic { return data }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
