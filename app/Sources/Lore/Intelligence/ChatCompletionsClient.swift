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
    ///
    /// `endpoint` names the *caller's* purpose for the diagnostic event (#82) —
    /// the prompt and the completion never leave this function.
    func complete(
        apiKey: String,
        model: String,
        messages: [Message],
        maxTokens: Int = 512,
        timeout: TimeInterval? = nil,
        endpoint: DiagEvent.Endpoint
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

        let startedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            // Transport failure — no HTTP status exists.
            DiagStore.record(.apiCall(
                endpoint: endpoint,
                outcome: .failed,
                httpStatus: nil,
                ms: Int(Date().timeIntervalSince(startedAt) * 1000)
            ))
            throw error
        }

        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            DiagStore.record(.apiCall(endpoint: endpoint, outcome: .failed, httpStatus: statusCode, ms: ms))
            throw ChatCompletionsError.httpError(statusCode)
        }
        DiagStore.record(.apiCall(
            endpoint: endpoint,
            outcome: .ok,
            httpStatus: httpResponse.statusCode,
            ms: ms
        ))

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
