import Foundation
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

    func cleanup(rawText: String, prompt: String, apiKey: String) async throws -> String {
        let body: [String: Any] = [
            "model": Self.model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": rawText],
            ],
            "max_completion_tokens": 2048,
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

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

        // Both sides of this arrow are the user's dictated words (#82).
        Self.log.debug("Cleanup: \(rawText, privacy: .private) → \(content, privacy: .private)")
        return content
    }

    enum CleanupError: Error, LocalizedError {
        case apiError(Int)
        var errorDescription: String? {
            switch self {
            case .apiError(let code): "OpenAI API error (HTTP \(code))"
            }
        }
    }
}
