import Foundation
import os

struct CleanupClient: Sendable {
    private static let log = Logger(subsystem: "com.openoats", category: "CleanupClient")
    private static let model = "openai/gpt-5.3-chat-latest"

    private let client = OpenRouterClient()

    /// Clean up raw transcription text using GPT-5.3.
    func cleanup(rawText: String, prompt: String, apiKey: String) async throws -> String {
        let messages: [OpenRouterClient.Message] = [
            .init(role: "system", content: prompt),
            .init(role: "user", content: rawText),
        ]
        let result = try await client.complete(
            apiKey: apiKey,
            model: Self.model,
            messages: messages,
            maxTokens: 2048
        )
        Self.log.info("Cleanup complete: \(rawText.prefix(40)) → \(result.prefix(40))")
        return result
    }
}
