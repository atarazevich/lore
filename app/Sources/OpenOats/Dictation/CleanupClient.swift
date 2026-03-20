import Foundation
import os

struct CleanupClient: Sendable {
    private static let log = Logger(subsystem: "com.openoats", category: "CleanupClient")
    private static let model = "gpt-5.3-chat-latest"
    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func cleanup(rawText: String, prompt: String, apiKey: String) async throws -> String {
        let body: [String: Any] = [
            "model": Self.model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": rawText],
            ],
            "max_tokens": 2048,
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("OpenAI API error HTTP \(statusCode): \(responseBody.prefix(200))")
            throw CleanupError.apiError(statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = message?["content"] as? String ?? ""

        Self.log.info("Cleanup: \(rawText.prefix(30)) → \(content.prefix(30))")
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
