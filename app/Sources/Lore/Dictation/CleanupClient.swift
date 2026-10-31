import Foundation
import LoreCore
import os

/// Seam for tests: DictationCoordinator takes any cleanup provider so a
/// throwing stub can drive the failure-surfacing paths without the network.
protocol CleanupProviding: Sendable {
    func cleanup(rawText: String, prompt: String, apiKey: String) async throws -> String
}

struct CleanupClient: CleanupProviding, Sendable {
    private static let log = Logger(subsystem: "com.lore.app", category: "CleanupClient")
    private static let model = ChatCompletionsClient.defaultOpenAIModel
    private static let endpoint = ChatCompletionsClient.openAIEndpoint

    /// Injectable so tests can answer from memory (`StubURLProtocol`).
    var session: URLSession = .shared

    /// The output budget, sized from the input (#322). A cleanup or a
    /// translation is about as long as what was said, and a byte-level BPE
    /// token is at least one byte, so the raw text's UTF-8 byte count bounds
    /// the tokens a text of its size can take, in any script — the 10,926
    /// bytes of a 17-minute take cleaned to 2,045 tokens and stopped at the
    /// old fixed 2048. The model spends no reasoning tokens inside this budget
    /// (`reasoning_tokens` is 0 on this request). The floor is the old cap; the
    /// ceiling is the model's own completion limit, 128,000, as the API states
    /// when asked for more. Whatever still runs out is caught as `cutOff`.
    static func outputTokenCap(for rawText: String) -> Int {
        min(max(2048, rawText.utf8.count), 128_000)
    }

    func cleanup(rawText: String, prompt: String, apiKey: String) async throws -> String {
        let body: [String: Any] = [
            "model": Self.model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": rawText],
            ],
            "max_completion_tokens": Self.outputTokenCap(for: rawText),
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            // The error body can echo the prompt, which carries the dictated text.
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("""
                OpenAI API error HTTP \(statusCode, privacy: .public): \
                \(responseBody.prefix(200), privacy: .private)
                """)
            throw CleanupError.apiError(statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = message?["content"] as? String ?? ""
        // Only an answer the model finished is a cleaned text. Stopped at the
        // budget, it is cut off mid-sentence; stopped for any other reason, or
        // with no reason at all, it is not known to be whole; and an empty one
        // would paste nothing. Each fails, and the raw words are pasted.
        switch choices?.first?["finish_reason"] as? String {
        case "stop": break
        case "length":
            Self.log.error("cleanup stopped at the output limit after \(content.count, privacy: .public) characters")
            throw CleanupError.cutOff
        case let reason:
            Self.log.error("cleanup did not finish: \(reason ?? "no finish_reason", privacy: .public)")
            throw CleanupError.unfinished
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Self.log.error("cleanup came back empty")
            throw CleanupError.empty
        }

        // Both sides of this arrow are the user's dictated words (#82).
        Self.log.debug("Cleanup: \(rawText, privacy: .private) → \(content, privacy: .private)")
        return content
    }

    enum CleanupError: Error, LocalizedError {
        case apiError(Int)
        /// A translation that came back, twice, not in the language asked for (#321).
        case wrongLanguage
        /// The answer stopped at the output limit (`finish_reason: length`, #322).
        case cutOff
        /// The answer ended for a reason other than `stop`, or gave none (#322).
        case unfinished
        /// The answer carried no text (#322).
        case empty

        /// How a turned-down answer reads in the diagnostic stream; nil for a
        /// failure that is not about the answer's shape.
        var rejection: DiagEvent.OutputRejection? {
            switch self {
            case .cutOff: .cutOff
            case .unfinished: .unfinished
            case .empty: .empty
            case .apiError, .wrongLanguage: nil
            }
        }

        var errorDescription: String? {
            switch self {
            case .apiError(let code): "OpenAI API error (HTTP \(code))"
            case .wrongLanguage: "Translation came back in the wrong language"
            case .cutOff: "Answer stopped at the output limit"
            case .unfinished: "Answer did not finish"
            case .empty: "Answer was empty"
            }
        }
    }
}
