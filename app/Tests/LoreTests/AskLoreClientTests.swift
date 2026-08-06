import XCTest
@testable import LoreKit

final class AskLoreClientTests: XCTestCase {

    // MARK: - Message assembly

    func testBuildMessagesOrdersSystemHistoryQuestion() {
        let messages = AskLoreClient.buildMessages(
            transcript: "You: hello\nThem: hi there",
            history: [(user: "What was said?", assistant: "A greeting.")],
            question: "Anything else?",
            isLive: true
        )

        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0].role, "system")
        XCTAssertEqual(messages[1].role, "user")
        XCTAssertEqual(messages[1].content, "What was said?")
        XCTAssertEqual(messages[2].role, "assistant")
        XCTAssertEqual(messages[2].content, "A greeting.")
        XCTAssertEqual(messages[3].role, "user")
        XCTAssertEqual(messages[3].content, "Anything else?")
    }

    func testSystemPromptContainsTranscript() {
        let messages = AskLoreClient.buildMessages(
            transcript: "You: unique-marker-line",
            history: [],
            question: "Q",
            isLive: true
        )
        let system = messages[0].content
        XCTAssertTrue(system.contains("You: unique-marker-line"))
        XCTAssertFalse(system.contains("truncated"))
    }

    /// The prompt variant follows the host (#62): live speaks of a meeting
    /// in progress over the live transcript; review of a meeting that has
    /// ended over the stored one.
    func testSystemPromptTenseFollowsIsLive() {
        let live = AskLoreClient.buildMessages(
            transcript: "You: hi", history: [], question: "Q", isLive: true
        )[0].content
        XCTAssertTrue(live.contains("still in progress"))
        XCTAssertTrue(live.contains("Live transcript:"))

        let review = AskLoreClient.buildMessages(
            transcript: "You: hi", history: [], question: "Q", isLive: false
        )[0].content
        XCTAssertTrue(review.contains("has ended"))
        XCTAssertFalse(review.contains("still in progress"))
        XCTAssertTrue(review.contains("\nTranscript:\n"))
        XCTAssertFalse(review.contains("Live transcript:"))
    }

    // MARK: - Truncation

    private func transcriptSection(of messages: [ChatCompletionsClient.Message], label: String = "Live transcript:\n") -> String {
        messages[0].content.components(separatedBy: label).last ?? ""
    }

    func testLongTranscriptKeepsTailAndDropsPartialFirstLine() {
        // Variable-length lines: the 8k cut almost surely lands mid-line.
        let lines = (0..<2_000).map { "Speaker 1: utterance number \($0)" }
        let transcript = lines.joined(separator: "\n")
        XCTAssertGreaterThan(transcript.count, AskLoreClient.transcriptBudget)

        let messages = AskLoreClient.buildMessages(
            transcript: transcript,
            history: [],
            question: "Q",
            isLive: true
        )
        let system = messages[0].content

        // The tail survives; the head is gone; the cut lands on a line boundary.
        XCTAssertTrue(system.contains("utterance number 1999"))
        XCTAssertFalse(system.contains("utterance number 0\n"))
        XCTAssertTrue(system.contains("truncated"))
        let section = transcriptSection(of: messages)
        XCTAssertTrue(section.hasPrefix("Speaker 1: "))
        XCTAssertLessThanOrEqual(section.count, AskLoreClient.transcriptBudget)
    }

    func testTruncationAtExactLineBoundaryKeepsFirstCompleteLine() {
        // 100 lines of exactly 100 chars (incl. newline) → 10,000 chars; the
        // 8k suffix starts exactly at line 20 (the char before it is "\n"),
        // so line 20 is complete and must NOT be dropped.
        let line = { (i: Int) in
            "line\(String(format: "%04d", i))" + String(repeating: "x", count: 91) + "\n"
        }
        let transcript = (0..<100).map(line).joined()
        XCTAssertEqual(transcript.count, 10_000)

        let messages = AskLoreClient.buildMessages(
            transcript: transcript,
            history: [],
            question: "Q",
            isLive: true
        )
        let section = transcriptSection(of: messages)
        XCTAssertTrue(section.hasPrefix("line0020"))
        XCTAssertEqual(section.count, AskLoreClient.transcriptBudget)
        XCTAssertTrue(messages[0].content.contains("truncated"))
    }

    /// Review truncation (#62): head+tail sampling instead of recency bias —
    /// "summarise this meeting" needs the beginning too. Both samples sit on
    /// line boundaries; the omitted middle is marked in place and in the note.
    func testReviewTruncationSamplesHeadAndTailOnLineBoundaries() {
        let lines = (0..<2_000).map { "Speaker 1: utterance number \($0)" }
        let transcript = lines.joined(separator: "\n")
        XCTAssertGreaterThan(transcript.count, AskLoreClient.transcriptBudget)

        let messages = AskLoreClient.buildMessages(
            transcript: transcript,
            history: [],
            question: "Summarise this meeting",
            isLive: false
        )
        let system = messages[0].content

        // Beginning AND end survive; the middle is omitted and said so.
        XCTAssertTrue(system.contains("utterance number 0\n"))
        XCTAssertTrue(system.contains("utterance number 1999"))
        XCTAssertFalse(system.contains("utterance number 1000\n"))
        XCTAssertTrue(system.contains("the middle was omitted"))

        let section = transcriptSection(of: messages, label: "\nTranscript:\n")
        XCTAssertTrue(section.hasPrefix("Speaker 1: utterance number 0\n"))
        XCTAssertTrue(section.contains("\n[\u{2026}]\n"))
        // Both fragments are whole lines: every line in the section parses
        // as a full "Speaker 1: utterance number N" (or the omission mark).
        for sampleLine in section.components(separatedBy: "\n") where !sampleLine.isEmpty {
            XCTAssertTrue(
                sampleLine == "[\u{2026}]"
                    || sampleLine.wholeMatch(of: /Speaker 1: utterance number \d+/) != nil,
                "unexpected partial line: \(sampleLine)"
            )
        }
        // Head ≤ 4k + tail ≤ 4k + the marker.
        XCTAssertLessThanOrEqual(section.count, AskLoreClient.transcriptBudget + 5)
    }

    // MARK: - History cap

    func testHistoryCappedAtLastFiveExchanges() {
        // History is complete user→assistant exchanges by construction; the
        // 10-turn cap therefore keeps the last 5 exchanges.
        let history = (0..<25).map { (user: "question \($0)", assistant: "answer \($0)") }
        let messages = AskLoreClient.buildMessages(
            transcript: "You: hi",
            history: history,
            question: "Q",
            isLive: true
        )

        // system + 5 exchanges (10 turns) + question
        XCTAssertEqual(messages.count, 12)
        XCTAssertEqual(messages[1].content, "question 20")
        XCTAssertEqual(messages[2].content, "answer 20")
        XCTAssertEqual(messages[9].content, "question 24")
        XCTAssertEqual(messages[10].content, "answer 24")
    }
}
