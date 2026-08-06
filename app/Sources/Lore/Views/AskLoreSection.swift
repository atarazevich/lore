import SwiftUI

// MARK: - Chat model

/// Signature of the question→answer transport — `AskLoreClient.ask` in the
/// app; injectable so tests can control when (and whether) an answer lands.
typealias AskLoreAskFunction = @Sendable (
    _ question: String,
    _ transcript: String,
    _ history: [(user: String, assistant: String)],
    _ apiKey: String,
    _ isLive: Bool
) async throws -> String

/// State for the "Ask Lore" chat — the live-meeting rail (MREC-30/31) and the
/// review Chat tab (#62). Chat history is per session: cleared when a new
/// recording starts, swapped when the review selection changes. D-031:
/// additive only — nothing here can affect recording, transcription, or
/// stats; a request failure is just a chat bubble.
@Observable
@MainActor
final class AskLoreChatModel {
    enum Role {
        case user, assistant, failure
    }

    struct Message: Identifiable {
        let id = UUID()
        let role: Role
        let text: String
        /// Failure bubbles carry the question to re-send on Retry.
        var failedQuestion: String? = nil
    }

    private(set) var messages: [Message] = []
    /// True while a request is in flight — one at a time; send is disabled.
    private(set) var isThinking = false

    /// Session guard: bumped whenever the conversation is swapped (new
    /// recording, review selection change), so a response arriving from a
    /// previous session never renders into the wrong chat's view. Whether it
    /// still persists depends on the host — see `send`.
    private var generation = 0
    private let ask: AskLoreAskFunction
    /// Live rail vs review Chat tab — drives the prompt variant/truncation
    /// strategy (AskLoreClient) and the post-switch persistence rule (`send`).
    private let isLive: Bool

    init(
        isLive: Bool = true,
        ask: @escaping AskLoreAskFunction = { question, transcript, history, apiKey, isLive in
            try await AskLoreClient().ask(
                question: question,
                transcript: transcript,
                history: history,
                apiKey: apiKey,
                isLive: isLive
            )
        }
    ) {
        self.isLive = isLive
        self.ask = ask
    }

    /// Fired once per successful question→answer exchange (#60) — the
    /// persistence hook (write-through to the session's chat.json). Failures
    /// never fire it.
    @ObservationIgnored var onExchange: ((_ question: String, _ answer: String) -> Void)?

    /// New recording started — clear the previous session's chat.
    func startNewSession() {
        loadPersistedHistory([])
    }

    /// Review (#62): show a selected session's persisted conversation.
    /// Replaces the messages and bumps the generation guard, so an answer
    /// still in flight for the previously shown session never renders here
    /// (in review it still persists to its origin session's file — `send`).
    func loadPersistedHistory(_ exchanges: [ChatExchange]) {
        generation += 1
        isThinking = false
        messages = exchanges.flatMap {
            [Message(role: .user, text: $0.question),
             Message(role: .assistant, text: $0.answer)]
        }
    }

    func send(question: String, transcript: String, apiKey: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !transcript.isEmpty, !isThinking, !apiKey.isEmpty else { return }

        // History replayed to the API: complete user→assistant exchanges
        // only. A failed (unanswered) question neither enters history nor
        // consumes a cap slot.
        var history: [(user: String, assistant: String)] = []
        var pendingUser: String?
        for message in messages {
            switch message.role {
            case .user:
                pendingUser = message.text
            case .assistant:
                if let user = pendingUser {
                    history.append((user: user, assistant: message.text))
                    pendingUser = nil
                }
            case .failure:
                pendingUser = nil
            }
        }

        messages.append(Message(role: .user, text: question))
        isThinking = true
        let requestGeneration = generation
        let ask = ask
        let isLive = isLive
        // Captured at send time: in review this hook was bound (with its
        // session ID) when the session was selected, so it targets the
        // ORIGIN session's file no matter what is selected when the answer
        // lands.
        let persist = onExchange

        Task {
            let result: Result<String, Error>
            do {
                result = .success(try await ask(question, transcript, history, apiKey, isLive))
            } catch {
                result = .failure(error)
            }
            let isCurrent = generation == requestGeneration
            if case .success(let answer) = result {
                // Review: a completed exchange always persists to its origin
                // session — a switch only suppresses rendering (#62). Live
                // keeps the guard: its hook resolves the target session at
                // fire time, so persisting across a recording boundary could
                // file the exchange under the wrong session.
                if !isLive || isCurrent {
                    persist?(question, answer)
                }
            }
            guard isCurrent else { return }
            switch result {
            case .success(let answer):
                messages.append(Message(role: .assistant, text: answer))
            case .failure(let error):
                messages.append(Message(
                    role: .failure,
                    text: "Couldn\u{2019}t get an answer \u{2014} \(error.localizedDescription)",
                    failedQuestion: question
                ))
            }
            isThinking = false
        }
    }

    /// Retry a failed question: drop the failure bubble and the user bubble
    /// immediately preceding it (its question), then re-send. Index-based so
    /// it stays correct with multiple accumulated failures at any position.
    func retry(_ message: Message, transcript: String, apiKey: String) {
        guard let question = message.failedQuestion, !isThinking,
              let index = messages.firstIndex(where: { $0.id == message.id })
        else { return }
        messages.remove(at: index)
        if index > 0, messages[index - 1].role == .user, messages[index - 1].text == question {
            messages.remove(at: index - 1)
        }
        send(question: question, transcript: transcript, apiKey: apiKey)
    }
}

// MARK: - Section view

/// "Ask Lore" contextual chat: the recording rail (MREC-30, rendered only
/// while recording) and the review Chat tab (#62, over the stored
/// transcript). Answers come from `AskLoreClient` over the speaker-labeled
/// utterances — not the prototype's canned strings (MREC-31).
struct AskLoreSection: View {
    let model: AskLoreChatModel
    let utterances: [Utterance]
    let apiKey: String
    /// Same chat, two hosts: live = rail during a recording, review = Chat
    /// tab over a finished meeting. Differs only in copy and bubble width —
    /// behavior (send, retry, guard, persistence hook) is identical.
    var isLive = true

    @State private var input = ""

    /// Min spacer opposite each bubble: ~88% cap in the 344px rail; the wide
    /// review pane keeps the former read-only section's 120.
    private var bubbleInset: CGFloat { isLive ? 36 : 120 }

    private var chips: [String] {
        [isLive ? "Summarise so far" : "Summarise this meeting",
         "Any action items?", "What did I agree to?"]
    }

    private var hasKey: Bool { !apiKey.isEmpty }
    /// Asking needs material: at least one finalized utterance.
    private var hasTranscript: Bool { !utterances.isEmpty }

    /// Speaker-labeled transcript lines — built at send time.
    private var transcriptText: String {
        utterances
            .map { "\($0.speaker.displayLabel): \($0.displayText)" }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            LoreDivider()
            messagesArea
            if hasKey {
                LoreDivider()
                inputBar
            }
        }
    }

    // MARK: Header (✦ + title + subtitle)

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Text("\u{2726}")
                    .font(.system(size: 13))
                    .foregroundStyle(LoreTheme.Accent.amber)
                    .accessibilityHidden(true)
                Text("Ask \(LoreTheme.wordmark)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LoreTheme.TextColor.primary)
            }
            Text("in context of this conversation")
                .font(.system(size: 11.5))
                .foregroundStyle(LoreTheme.TextColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.init(top: 13, leading: 18, bottom: 11, trailing: 18))
    }

    // MARK: Messages

    private var messagesArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if model.messages.isEmpty {
                    emptyState
                }
                ForEach(model.messages) { message in
                    bubble(message)
                }
                if model.isThinking {
                    thinkingBubble
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.init(top: 14, leading: 16, bottom: 14, trailing: 16))
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isLive
                 ? "Ask anything about what\u{2019}s being said \u{2014} \(LoreTheme.wordmark) answers from the live transcript."
                 : "Ask anything about this meeting \u{2014} \(LoreTheme.wordmark) answers from its transcript.")
                .font(.system(size: 12.5))
                .foregroundStyle(LoreTheme.TextColor.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if !hasKey {
                Text("Add an OpenAI API key in Settings to ask questions")
                    .font(.system(size: 12))
                    .foregroundStyle(LoreTheme.TextColor.faint)
                    .padding(.top, 2)
            } else {
                if !hasTranscript {
                    Text(isLive
                         ? "Waiting for the conversation to start\u{2026}"
                         : "This meeting has no transcript to ask about")
                        .font(.system(size: 12))
                        .foregroundStyle(LoreTheme.TextColor.faint)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(chips, id: \.self) { label in
                        chip(label)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func chip(_ label: String) -> some View {
        Button {
            model.send(question: label, transcript: transcriptText, apiKey: apiKey)
        } label: {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LoreTheme.TextColor.primary)
                .padding(.init(top: 9, leading: 12, bottom: 9, trailing: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: LoreTheme.Radius.chip)
                )
        }
        .buttonStyle(LorePressButtonStyle())
        .disabled(model.isThinking || !hasTranscript)
        .opacity(hasTranscript ? 1 : 0.5)
        .accessibilityLabel("Ask: \(label)")
    }

    /// Bubbles cap at ~88% of the rail (design: `max-width:88%`) via the
    /// shared bubble's opposite-side min spacer.
    @ViewBuilder
    private func bubble(_ message: AskLoreChatModel.Message) -> some View {
        if message.role == .failure {
            HStack(spacing: 0) {
                failureBubble(message)
                Spacer(minLength: bubbleInset)
            }
        } else {
            LoreChatBubble(
                text: message.text,
                isUser: message.role == .user,
                inset: bubbleInset
            )
        }
    }

    private func failureBubble(_ message: AskLoreChatModel.Message) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(message.text)
                .font(.system(size: 12.5))
                .foregroundStyle(LoreTheme.TextColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") {
                model.retry(message, transcript: transcriptText, apiKey: apiKey)
            }
            .buttonStyle(LorePressButtonStyle())
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LoreTheme.TextColor.primary)
            .disabled(model.isThinking)
            .accessibilityLabel("Retry question")
        }
        .padding(.init(top: 9, leading: 12, bottom: 9, trailing: 12))
        .background(
            Color.white.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    /// Static "Thinking…" bubble — no typing animation (Reduce Motion safe).
    private var thinkingBubble: some View {
        Text("Thinking\u{2026}")
            .font(.system(size: 13))
            .foregroundStyle(LoreTheme.TextColor.muted)
            .padding(.init(top: 9, leading: 12, bottom: 9, trailing: 12))
            .background(
                Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .accessibilityLabel("\(LoreTheme.wordmark) is thinking")
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 9) {
            TextField(
                "",
                text: $input,
                prompt: Text("Ask about this meeting\u{2026}")
                    .foregroundStyle(LoreTheme.TextColor.faint)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(LoreTheme.TextColor.primary)
            .padding(.init(top: 9, leading: 12, bottom: 9, trailing: 12))
            .background(
                Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: LoreTheme.Radius.chip)
            )
            .onSubmit(sendCurrentInput)
            .accessibilityLabel("Ask about this meeting")

            Button(action: sendCurrentInput) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        LoreTheme.Accent.blue,
                        in: RoundedRectangle(cornerRadius: LoreTheme.Radius.chip)
                    )
            }
            .buttonStyle(LorePressButtonStyle())
            .disabled(sendDisabled)
            .opacity(sendDisabled ? 0.5 : 1)
            .accessibilityLabel("Send question")
        }
        .padding(.init(top: 11, leading: 14, bottom: 11, trailing: 14))
    }

    private var sendDisabled: Bool {
        model.isThinking
            || !hasTranscript
            || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendCurrentInput() {
        guard !sendDisabled else { return }
        model.send(question: input, transcript: transcriptText, apiKey: apiKey)
        input = ""
    }
}
