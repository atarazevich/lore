import FluidAudio
import Foundation
import os

/// The speech model lore transcribes with (#299). The raw value is what a
/// meeting records as its `engine` and what an event records as identity.
public enum SpeechModel: String, Codable, Sendable, CaseIterable {
    /// Parakeet TDT v3, lore's model until #299. Used only on a Mac that
    /// already has it, until Parakeet Ultra is ready to take its place.
    case parakeetV3
    /// Parakeet Ultra (moondream, CC BY 4.0): the same 25 languages and API as
    /// v3, and keeps Russian speech where v3 drifts into invented English.
    case parakeetUltra

    var version: AsrModelVersion {
        switch self {
        case .parakeetV3: .v3
        case .parakeetUltra: .ultra
        }
    }

    /// `FluidInference/parakeet-ultra-coreml` as the owner measured it
    /// (2026-09-24), pinned with the other models before any load (`ModelBundle.pinAll`).
    static let ultraRevision = "95eaa59a39d4394f047a4dc5cce480388a60d1b6"
}

/// The speech model's folders under one models root, and which model this
/// process transcribes with (#299).
///
/// Decided once per launch: Ultra when the swap marker is there and Ultra is
/// whole on disk, otherwise v3 when v3 is whole, otherwise Ultra. A launch on
/// Ultra first removes v3's folders (`removeSuperseded`), before anything has
/// loaded, so nothing can be reading them. The marker is written only after
/// every cache serves Ultra; a quit before that simply runs the upgrade again.
public final class SpeechModelFiles: Sendable {
    public static let shared = SpeechModelFiles(
        root: AsrModels.defaultCacheDirectory(for: .ultra).deletingLastPathComponent())

    let root: URL
    private let chosen = OSAllocatedUnfairLock<SpeechModel?>(initialState: nil)

    init(root: URL) {
        self.root = root
    }

    func folder(_ model: SpeechModel) -> URL {
        root.appendingPathComponent(
            AsrModels.defaultCacheDirectory(for: model.version).lastPathComponent, isDirectory: true)
    }

    /// Every file the model needs is in its folder.
    func isOnDisk(_ model: SpeechModel) -> Bool {
        AsrModels.modelsExist(at: folder(model), version: model.version)
    }

    /// Written once both caches serve Ultra: the next launch is on Ultra even
    /// though v3's folder is still there, and removes it.
    var swapMarker: URL { root.appendingPathComponent(".lore-swapped-to-parakeet-ultra") }

    /// The model this process transcribes with, read from disk once.
    public var working: SpeechModel {
        chosen.withLock { chosen in
            if let chosen { return chosen }
            let swapped = FileManager.default.fileExists(atPath: swapMarker.path) && isOnDisk(.parakeetUltra)
            let model: SpeechModel = !swapped && isOnDisk(.parakeetV3) ? .parakeetV3 : .parakeetUltra
            chosen = model
            return model
        }
    }

    /// From here on every load uses Ultra; and the next launch too, when the
    /// marker could be written — the returned answer. Without it the next
    /// launch starts on v3 again and repeats the upgrade.
    func adoptUltra() -> Bool {
        chosen.withLock { $0 = .parakeetUltra }
        return FileManager.default.createFile(atPath: swapMarker.path, contents: nil)
    }

    /// The model's files, removed so its next load downloads it again.
    /// Whether anything went: v3 is never removed here — it is the fallback,
    /// and only `removeSuperseded` takes it, once Ultra has replaced it.
    public func clear(_ model: SpeechModel) -> Bool {
        guard model == .parakeetUltra else { return false }
        return (try? FileManager.default.removeItem(at: folder(model))) != nil
    }

    /// At launch, before any model loads: on Ultra, with Ultra whole on disk,
    /// v3's folder and the older `parakeet-tdt-0.6b-v3-coreml` one go, then
    /// the marker. Traced when there was anything to remove.
    public func removeSuperseded() {
        guard working == .parakeetUltra, isOnDisk(.parakeetUltra) else { return }
        let files = FileManager.default
        let superseded = [folder(.parakeetV3), root.appendingPathComponent(Repo.parakeetV3.name, isDirectory: true)]
            .filter { files.fileExists(atPath: $0.path) }
        guard !superseded.isEmpty else { return }
        // Every folder is attempted, whatever happened to the one before it.
        let failures = superseded.filter { (try? files.removeItem(at: $0)) == nil }
        let removed = failures.isEmpty
        if removed { try? files.removeItem(at: swapMarker) }
        DiagStore.record(.speechModelRemoved(outcome: removed ? .ok : .failed))
    }
}
