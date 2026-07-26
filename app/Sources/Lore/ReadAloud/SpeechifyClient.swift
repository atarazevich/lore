import Foundation
import os

/// The Read Aloud synthesis seam: renders one chunk of text and returns the
/// audio file it wrote — MP3 (Speechify) or CAF (system engine). The caller
/// owns the file. Injectable into ReadAloudController (mirrors
/// `CleanupProviding`).
protocol SpeechSynthesizing: Sendable {
    func synthesize(
        text: String, voice: String, model: String, language: String?, apiKey: String
    ) async throws -> URL
}

struct SpeechifyClient: SpeechSynthesizing, Sendable {
    private static let log = Logger(subsystem: "com.lore.app", category: "SpeechifyClient")
    static let endpoint = URL(string: "https://api.sws.speechify.com/v1/audio/stream")!

    /// Injectable for tests (StubURLProtocol); production uses `.shared`.
    var session: URLSession = .shared

    private struct SynthesisRequest: Encodable {
        let input: String
        let voiceId: String
        let model: String
        let language: String?

        enum CodingKeys: String, CodingKey {
            case input, model, language
            case voiceId = "voice_id"
        }
    }

    /// One request = one MP3, written to a temp file. Measured
    /// (experiments/tts/): TTFB 1.3–3 s, a single request handles ≥15k chars
    /// — chunking exists for latency, not for API limits.
    func synthesize(
        text: String, voice: String, model: String, language: String?, apiKey: String
    ) async throws -> URL {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            SynthesisRequest(input: text, voiceId: voice, model: model, language: language)
        )

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            // The error body can echo the input, which is the user's selected text.
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("""
                Speechify API error HTTP \(statusCode, privacy: .public): \
                \(responseBody.prefix(200), privacy: .private)
                """)
            throw SpeechifyError.apiError(statusCode)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lore-ReadAloud-\(UUID().uuidString).mp3")
        try data.write(to: url)
        return url
    }

    enum SpeechifyError: Error, LocalizedError, Equatable {
        case apiError(Int)
        var errorDescription: String? {
            switch self {
            case .apiError(let code): "Speechify API error (HTTP \(code))"
            }
        }
    }

    /// Transient = worth retrying: network-shaped `URLError`s, HTTP 429 and
    /// 5xx. Anything else (bad key at 401, out of credits at 402) goes
    /// straight to the failure state. Same shape as
    /// `DictationCoordinator.isTransientCleanupError`.
    static func isTransient(_ error: any Error) -> Bool {
        if let urlError = error as? URLError {
            return DictationCoordinator.transientURLErrorCodes.contains(urlError.code)
        }
        if case SpeechifyError.apiError(let code) = error {
            return code == 429 || (500...599).contains(code)
        }
        return false
    }

    /// HTTP status behind a synthesis failure, when the error carries one.
    static func httpStatus(from error: any Error) -> Int? {
        if case SpeechifyError.apiError(let code) = error { return code }
        return nil
    }
}
