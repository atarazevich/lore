import Foundation

/// Client for the OpenAI chat-completions endpoint — the one LLM transport
/// behind dictation cleanup, translation, Ask Lore, and transcript refinement.
actor ChatCompletionsClient {
    /// The one OpenAI model and endpoint shared by dictation cleanup,
    /// translation, Ask Lore, and transcript refinement.
    static let defaultOpenAIModel = "gpt-5.4-mini"
    static let openAIEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }

    struct ChatRequest: Codable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let max_completion_tokens: Int?
    }

    /// Non-streaming completion against `openAIEndpoint`.
    func complete(
        apiKey: String,
        model: String,
        messages: [Message],
        maxTokens: Int = 512,
        timeout: TimeInterval? = nil
    ) async throws -> String {
        let request = ChatRequest(
            model: model,
            messages: messages,
            stream: false,
            max_completion_tokens: maxTokens
        )

        var urlRequest = URLRequest(url: Self.openAIEndpoint)
        if let timeout {
            urlRequest.timeoutInterval = timeout
        }
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ChatCompletionsError.httpError(statusCode)
        }

        let completionResponse = try JSONDecoder().decode(CompletionResponse.self, from: data)
        return completionResponse.choices.first?.message.content ?? ""
    }

    enum ChatCompletionsError: Error, LocalizedError {
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .httpError(let code):
                // User-facing copy in the Ask Lore failure bubble.
                return "OpenAI API error (HTTP \(code))"
            }
        }
    }

    private struct CompletionResponse: Codable {
        let choices: [CompletionChoice]

        struct CompletionChoice: Codable {
            let message: CompletionMessage
        }

        struct CompletionMessage: Codable {
            let content: String
        }
    }
}
