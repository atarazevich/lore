import Foundation
import Observation

struct DictationHistoryEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let rawText: String
    let cleanedText: String?
    /// The text that was actually pasted
    var finalText: String { cleanedText ?? rawText }

    init(timestamp: Date = Date(), rawText: String, cleanedText: String? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.rawText = rawText
        self.cleanedText = cleanedText
    }
}

@Observable
@MainActor
final class DictationHistory {
    private(set) var entries: [DictationHistoryEntry] = []

    private static let storageKey = "dictationHistory"
    private static let maxEntries = 500

    init() {
        load()
    }

    func add(_ entry: DictationHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
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
