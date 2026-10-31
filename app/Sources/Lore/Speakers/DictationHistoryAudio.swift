import Foundation
import LoreCore

/// The owner's dictation audio for `OwnerVoice`, read from `DictationHistory`.
struct DictationHistoryAudio: DictationAudioSource {
    let history: DictationHistory
    private let directory: URL

    @MainActor
    init(history: DictationHistory) {
        self.history = history
        directory = history.audioDirectory
    }

    /// Only the list is read on the main actor. A recording still being made
    /// has no duration yet, and is left out.
    func recentRecordings(limit: Int) async -> [String] {
        await MainActor.run {
            Array(history.entries.lazy.filter { $0.durationSeconds > 0 }.compactMap(\.audioFilename).prefix(limit))
        }
    }

    func samples(of recording: String, upTo count: Int) async -> [Float]? {
        DictationHistory.readAudio(at: directory.appendingPathComponent(recording), maxSamples: count)
    }
}
