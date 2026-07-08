import Foundation

/// Refines utterances by cleaning up filler words and fixing punctuation via LLM.
/// Runs as a background actor with bounded concurrency.
actor TranscriptRefinementEngine {
    private let client = ChatCompletionsClient()
    private let settings: AppSettings
    private let transcriptStore: TranscriptStore

    private let maxConcurrent = 3
    private var inFlightCount = 0
    private var pendingQueue: [Utterance] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    private let minimumWordCount = 5

    private let systemPrompt = """
        Clean up this speech transcript: remove filler words (uh, um, like, you know), \
        fix punctuation, add sentence breaks. Output only the cleaned text.
        """

    init(settings: AppSettings, transcriptStore: TranscriptStore) {
        self.settings = settings
        self.transcriptStore = transcriptStore
    }

    /// Queue an utterance for refinement.
    func refine(_ utterance: Utterance) {
        // Skip short utterances unless they look like a question
        let words = utterance.text.split(separator: " ")
        if words.count < minimumWordCount && !utterance.text.contains("?") {
            Task { @MainActor in
                transcriptStore.updateRefinedText(id: utterance.id, refinedText: nil, status: .skipped)
            }
            return
        }

        pendingQueue.append(utterance)
        drainQueue()
    }

    /// Await all pending and in-flight refinements, with a timeout.
    func drain(timeout: Duration = .seconds(5)) async {
        guard inFlightCount > 0 || !pendingQueue.isEmpty else { return }

        let tasks = activeTasks.values.map { $0 }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for task in tasks {
                    await task.value
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            // Return as soon as either completes
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Private

    private func drainQueue() {
        while inFlightCount < maxConcurrent, let utterance = pendingQueue.first {
            pendingQueue.removeFirst()
            inFlightCount += 1

            // Mark as pending on main actor
            let store = transcriptStore
            Task { @MainActor in
                store.updateRefinedText(id: utterance.id, refinedText: nil, status: .pending)
            }

            let task = Task { [weak self] in
                guard let self else { return }
                await self.performRefinement(utterance)
                await self.taskCompleted(id: utterance.id)
            }
            activeTasks[utterance.id] = task
        }
    }

    private func taskCompleted(id: UUID) {
        activeTasks.removeValue(forKey: id)
        inFlightCount -= 1
        drainQueue()
    }

    private func performRefinement(_ utterance: Utterance) async {
        // Same OpenAI key as cleanup and Ask Lore; read on MainActor.
        let apiKey = await MainActor.run { settings.openaiApiKey }

        let messages: [ChatCompletionsClient.Message] = [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", content: utterance.text)
        ]

        do {
            let refined = try await client.complete(
                apiKey: apiKey,
                model: ChatCompletionsClient.defaultOpenAIModel,
                messages: messages,
                maxTokens: 512,
                endpoint: .refinement
            )

            let trimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                await markFailed(utterance.id)
                return
            }

            let store = transcriptStore
            Task { @MainActor in
                store.updateRefinedText(id: utterance.id, refinedText: trimmed, status: .completed)
            }
        } catch {
            await markFailed(utterance.id)
        }
    }

    private func markFailed(_ id: UUID) async {
        let store = transcriptStore
        Task { @MainActor in
            store.updateRefinedText(id: id, refinedText: nil, status: .failed)
        }
    }
}
