import Foundation

/// Prompt assembly + transport for the "Ask Lore" chat — live rail (MREC-30/31)
/// and review Chat tab (#62). Transport goes through the shared
/// `ChatCompletionsClient.complete` — it sends `max_completion_tokens`,
/// which gpt-5.4-mini requires.
/// D-031: purely additive — a failure here surfaces only as a chat bubble and
/// never touches recording, transcription, or stats.
struct AskLoreClient: Sendable {
    private static let model = ChatCompletionsClient.defaultOpenAIModel
    /// A hung request must not lock the chat input for the default 60s.
    private static let timeout: TimeInterval = 30

    /// Transcript character budget. Live keeps the LAST ~8k (the recent
    /// conversation matters most mid-meeting); review samples the first and
    /// last ~4k (questions there span the whole meeting).
    static let transcriptBudget = 8_000
    /// Replay at most the last 10 chat turns (5 user→assistant exchanges).
    static let historyTurnCap = 10

    private let client = ChatCompletionsClient()

    /// Assembles the messages payload: system prompt (with the transcript and
    /// a truncation note when the budget cut it), capped history, question.
    /// `isLive` drives tense ("still in progress" vs "has ended") and the
    /// truncation strategy. History is complete user→assistant exchanges by
    /// construction — an unanswered question can't be represented, so it
    /// can't leak into the payload or consume a cap slot. Pure — exposed for
    /// tests.
    static func buildMessages(
        transcript: String,
        history: [(user: String, assistant: String)],
        question: String,
        isLive: Bool
    ) -> [ChatCompletionsClient.Message] {
        var truncated = false
        let transcriptPart: String
        if transcript.count <= transcriptBudget {
            transcriptPart = transcript
        } else if isLive {
            truncated = true
            transcriptPart = String(tail(of: transcript, budget: transcriptBudget))
        } else {
            // Review (#62): "summarise this meeting" spans the whole
            // conversation, so sample the beginning AND the end instead of
            // recency-biasing; the omission is marked in place and in the
            // truncation note.
            truncated = true
            let half = transcriptBudget / 2
            transcriptPart = head(of: transcript, budget: half)
                + "\n[\u{2026}]\n"
                + tail(of: transcript, budget: half)
        }

        var system = """
        You are \(LoreTheme.wordmark), assisting \
        \(isLive ? "during a meeting that is still in progress" : "after a meeting that has ended"). \
        Answer the user's questions using ONLY the \
        \(isLive ? "live transcript" : "meeting transcript") below. \
        Be concise: 2-4 sentences. If the transcript does not contain the \
        answer, say so plainly instead of guessing.
        """
        if truncated {
            system += isLive
                ? "\nThe transcript was truncated: only the most recent part of the conversation is shown."
                : "\nThe transcript was truncated: only the beginning and the end of the conversation are shown; the middle was omitted."
        }
        system += "\n\n\(isLive ? "Live transcript" : "Transcript"):\n\(transcriptPart)"

        var messages = [ChatCompletionsClient.Message(role: "system", content: system)]
        for exchange in history.suffix(historyTurnCap / 2) {
            messages.append(.init(role: "user", content: exchange.user))
            messages.append(.init(role: "assistant", content: exchange.assistant))
        }
        messages.append(.init(role: "user", content: question))
        return messages
    }

    /// Last `budget` chars, trimmed to a line boundary: the leading line is
    /// dropped only when the cut split it (the char just before the suffix
    /// not being a newline means the first line is partial).
    private static func tail(of transcript: String, budget: Int) -> Substring {
        guard transcript.count > budget else { return Substring(transcript) }
        var part = transcript.suffix(budget)
        let cut = transcript.index(transcript.endIndex, offsetBy: -budget - 1)
        if transcript[cut] != "\n" {
            part = part.drop(while: { $0 != "\n" }).dropFirst()
        }
        return part
    }

    /// First `budget` chars, trimmed to a line boundary: the trailing line is
    /// dropped when the cut split it (the char right after the prefix not
    /// being a newline means the last line is partial).
    private static func head(of transcript: String, budget: Int) -> String {
        guard transcript.count > budget else { return transcript }
        var part = transcript.prefix(budget)
        if transcript[part.endIndex] != "\n" {
            part = part[..<(part.lastIndex(of: "\n") ?? part.startIndex)]
        }
        return String(part)
    }

    func ask(
        question: String,
        transcript: String,
        history: [(user: String, assistant: String)],
        apiKey: String,
        isLive: Bool
    ) async throws -> String {
        try await client.complete(
            apiKey: apiKey,
            model: Self.model,
            messages: Self.buildMessages(
                transcript: transcript,
                history: history,
                question: question,
                isLive: isLive
            ),
            maxTokens: 1024,
            timeout: Self.timeout,
            endpoint: .askLore
        )
    }
}
