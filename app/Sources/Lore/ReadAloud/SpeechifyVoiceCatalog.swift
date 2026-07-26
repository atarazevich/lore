import Foundation
import os

/// One voice from `GET /v1/voices`, reduced to what the pickers need.
struct SpeechifyVoice: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    /// BCP-47, e.g. "ru-RU".
    let locale: String
    let previewURL: URL?
    /// Model names this voice supports ("simba-multilingual", …).
    let models: [String]
    /// Raw tags like "age:young-adult", "timbre:deep", "use-case:audiobook".
    let tags: [String]

    /// Compact secondary label for menu rows: age · timbre (· audiobook).
    var tagLabel: String? {
        var parts: [String] = []
        if let age = tags.first(where: { $0.hasPrefix("age:") }) {
            parts.append(String(age.dropFirst(4)))
        }
        if let timbre = tags.first(where: { $0.hasPrefix("timbre:") }) {
            parts.append(String(timbre.dropFirst(7)))
        }
        if tags.contains("use-case:audiobook") {
            parts.append("audiobook")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}

/// Cache over `GET /v1/voices` (#105): the full catalog (~950 voices),
/// fetched once per app run on first use. Powers the Settings pickers
/// (filtered by locale) and the ▶ preview buttons.
actor SpeechifyVoiceCatalog {
    static let shared = SpeechifyVoiceCatalog()

    private static let log = Logger(subsystem: "com.lore.app", category: "SpeechifyVoices")
    private static let endpoint = URL(string: "https://api.sws.speechify.com/v1/voices")!

    private var voices: [SpeechifyVoice]?
    private var fetchTask: Task<[SpeechifyVoice], Never>?

    func allVoices(apiKey: String) async -> [SpeechifyVoice] {
        if let voices {
            return voices
        }
        if let fetchTask {
            return await fetchTask.value
        }
        let task = Task { await Self.fetch(apiKey: apiKey) }
        fetchTask = task
        let result = await task.value
        fetchTask = nil
        // Cache only a successful (non-empty) fetch, so a transient failure
        // doesn't pin an empty catalog for the rest of the run.
        if !result.isEmpty {
            voices = result
        }
        return result
    }

    /// Voices whose locale matches any of `localePrefixes` ("ru", "en"),
    /// optionally narrowed to those supporting `model`, name-sorted.
    func voices(
        localePrefixes: [String], model: String? = nil, apiKey: String
    ) async -> [SpeechifyVoice] {
        await allVoices(apiKey: apiKey)
            .filter { voice in
                localePrefixes.contains(where: voice.locale.hasPrefix)
                    && (model.map(voice.models.contains) ?? true)
            }
            .sorted { $0.name < $1.name }
    }

    /// One voice as `GET /v1/voices` serves it. Fields beyond `id` are
    /// optional so one malformed entry never sinks the whole catalog.
    private struct VoicePayload: Decodable {
        struct ModelPayload: Decodable {
            let name: String?
        }

        let id: String
        let displayName: String?
        let locale: String?
        let previewAudio: String?
        let models: [ModelPayload]?
        let tags: [String]?

        enum CodingKeys: String, CodingKey {
            case id, locale, models, tags
            case displayName = "display_name"
            case previewAudio = "preview_audio"
        }
    }

    private static func fetch(apiKey: String) async -> [SpeechifyVoice] {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                log.error("voice list failed: HTTP \(status, privacy: .public)")
                return []
            }
            let payloads = try JSONDecoder().decode([VoicePayload].self, from: data)
            return payloads.map { payload in
                SpeechifyVoice(
                    id: payload.id,
                    name: payload.displayName ?? payload.id,
                    locale: payload.locale ?? "",
                    previewURL: payload.previewAudio.flatMap(URL.init(string:)),
                    models: (payload.models ?? []).compactMap(\.name),
                    tags: payload.tags ?? []
                )
            }
        } catch {
            log.error("voice list failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
