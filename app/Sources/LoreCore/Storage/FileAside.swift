import Foundation

/// Corrupt-file policy, in one place.
///
/// A file that exists but does not decode is never rebuilt over — that would
/// destroy whatever it still held. It is moved aside to `<name>.corrupt`, then
/// `.corrupt.1`, `.corrupt.2`, … so earlier asides survive repeat corruption.
///
/// Used by `SessionRepository` (chat.json) and `DiagStore` (events.json).
enum FileAside {
    /// Move `url` to the next free `.corrupt` name. Returns the destination, or
    /// nil if the move failed (in which case the caller still starts fresh in
    /// memory — a diagnostic store that throws while recording a failure is
    /// worse than one that stays quiet).
    @discardableResult
    static func move(_ url: URL) -> URL? {
        var destination = url.appendingPathExtension("corrupt")
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = URL(fileURLWithPath: url.path + ".corrupt.\(suffix)")
            suffix += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
