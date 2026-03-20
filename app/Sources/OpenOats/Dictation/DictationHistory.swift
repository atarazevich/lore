import Foundation
import Observation

enum DictationEntryStatus: String, Codable {
    case audioSaved
    case transcribed
    case cleaned
    case failed
}

struct DictationHistoryEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    var status: DictationEntryStatus
    var rawText: String?
    var cleanedText: String?
    var errorMessage: String?
    /// Filename of saved audio (16kHz mono Float32, raw bytes)
    var audioFilename: String?
    var durationSeconds: Double

    var finalText: String? { cleanedText ?? rawText }

    var hasAudio: Bool { audioFilename != nil }

    init(timestamp: Date = Date(), durationSeconds: Double, audioFilename: String? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.status = .audioSaved
        self.durationSeconds = durationSeconds
        self.audioFilename = audioFilename
    }
}

@Observable
@MainActor
final class DictationHistory {
    private(set) var entries: [DictationHistoryEntry] = []

    private static let storageKey = "dictationHistory"
    private static let maxEntries = 500

    static var audioDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OpenOats/DictationAudio", isDirectory: true)
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.audioDirectory, withIntermediateDirectories: true)
        load()
    }

    func add(_ entry: DictationHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            // Remove old audio files when pruning
            let removed = entries.suffix(from: Self.maxEntries)
            for entry in removed {
                deleteAudioFile(for: entry)
            }
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()
    }

    func update(_ entry: DictationHistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func clear() {
        for entry in entries { deleteAudioFile(for: entry) }
        entries.removeAll()
        save()
    }

    /// Save raw audio samples to disk. Returns the filename.
    static func saveAudio(_ samples: [Float]) -> String? {
        let filename = "dictation-\(UUID().uuidString).raw"
        let url = audioDirectory.appendingPathComponent(filename)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try data.write(to: url)
            return filename
        } catch {
            diagLog("[HISTORY] failed to save audio: \(error)")
            return nil
        }
    }

    /// Load raw audio samples from disk.
    static func loadAudio(filename: String) -> [Float]? {
        let url = audioDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            let count = data.count / MemoryLayout<Float>.size
            let floatBuffer = baseAddress.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: floatBuffer, count: count))
        }
    }

    private func deleteAudioFile(for entry: DictationHistoryEntry) {
        guard let filename = entry.audioFilename else { return }
        let url = Self.audioDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data) else { return }
        entries = decoded
    }
}
