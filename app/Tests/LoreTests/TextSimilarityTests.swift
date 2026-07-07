import XCTest
@testable import LoreKit

final class TextSimilarityTests: XCTestCase {

    // MARK: - TextSimilarity.normalizedWords

    func testNormalizedWordsLowercases() {
        let words = TextSimilarity.normalizedWords(in: "Hello WORLD")
        XCTAssertEqual(words, ["hello", "world"])
    }

    func testNormalizedWordsRemovesPunctuation() {
        let words = TextSimilarity.normalizedWords(in: "Hello, world! How's it going?")
        XCTAssertEqual(words, ["hello", "world", "how", "s", "it", "going"])
    }

    func testNormalizedWordsHandlesEmpty() {
        let words = TextSimilarity.normalizedWords(in: "")
        XCTAssertTrue(words.isEmpty)
    }

    func testNormalizedWordsHandlesWhitespaceOnly() {
        let words = TextSimilarity.normalizedWords(in: "   \n\t  ")
        XCTAssertTrue(words.isEmpty)
    }

    func testNormalizedWordsHandlesNumbers() {
        let words = TextSimilarity.normalizedWords(in: "Test 123 value")
        XCTAssertEqual(words, ["test", "123", "value"])
    }

    // MARK: - TextSimilarity.normalizedText

    func testNormalizedTextJoinsWithSpaces() {
        let text = TextSimilarity.normalizedText("Hello, WORLD!")
        XCTAssertEqual(text, "hello world")
    }

    func testNormalizedTextEmpty() {
        let text = TextSimilarity.normalizedText("")
        XCTAssertEqual(text, "")
    }

    // MARK: - TextSimilarity.jaccard

    func testJaccardIdenticalStrings() {
        let score = TextSimilarity.jaccard("hello world", "hello world")
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func testJaccardCompletelyDifferent() {
        let score = TextSimilarity.jaccard("hello world", "foo bar")
        XCTAssertEqual(score, 0.0, accuracy: 0.001)
    }

    func testJaccardPartialOverlap() {
        let score = TextSimilarity.jaccard("hello world foo", "hello world bar")
        // Sets: {hello, world, foo} and {hello, world, bar}
        // Intersection = 2, Union = 4
        XCTAssertEqual(score, 0.5, accuracy: 0.001)
    }

    func testJaccardBothEmpty() {
        let score = TextSimilarity.jaccard("", "")
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func testJaccardCaseInsensitive() {
        let score = TextSimilarity.jaccard("HELLO WORLD", "hello world")
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func testJaccardIgnoresPunctuation() {
        let score = TextSimilarity.jaccard("Hello, world!", "hello world")
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func testJaccardSubsetScore() {
        // "hello" is a subset of "hello world"
        let score = TextSimilarity.jaccard("hello", "hello world")
        // Intersection = 1, Union = 2
        XCTAssertEqual(score, 0.5, accuracy: 0.001)
    }

}
