import XCTest
@testable import LoreKit

/// JSON coding of DictationHistoryEntry must stay backward-compatible:
/// history persists in UserDefaults, so entries written by older builds
/// (without activeVersion/cleanupModeName, and now without
/// cleanupMethodName/translatedToLanguage) must still decode.
final class DictationHistoryEntryTests: XCTestCase {

    /// Entry shaped like a pre-v1.13 build: no activeVersion, no
    /// cleanupModeName, none of the Stage C meta fields.
    func testDecodesLegacyEntryWithoutOptionalFields() throws {
        let legacyJSON = """
        {
            "id": "6F1A2B3C-4D5E-6F70-8192-A3B4C5D6E7F8",
            "timestamp": 741700000.0,
            "status": "transcribed",
            "rawText": "hello world",
            "durationSeconds": 4.2
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(DictationHistoryEntry.self, from: legacyJSON)

        XCTAssertEqual(entry.id.uuidString, "6F1A2B3C-4D5E-6F70-8192-A3B4C5D6E7F8")
        XCTAssertEqual(entry.status, .transcribed)
        XCTAssertEqual(entry.rawText, "hello world")
        XCTAssertEqual(entry.durationSeconds, 4.2, accuracy: 0.001)
        // Missing activeVersion + no cleanedText → raw
        XCTAssertEqual(entry.activeVersion, .raw)
        XCTAssertNil(entry.cleanupModeName)
        XCTAssertNil(entry.cleanupMethodName)
        XCTAssertNil(entry.translatedToLanguage)
    }

    /// Legacy entry that has a cleaned text but no activeVersion field:
    /// the decoder infers .cleaned.
    func testDecodesLegacyCleanedEntryInferringActiveVersion() throws {
        let legacyJSON = """
        {
            "id": "0B1C2D3E-4F50-6172-8394-A5B6C7D8E9F0",
            "timestamp": 741700000.0,
            "status": "cleaned",
            "rawText": "um hello world",
            "cleanedText": "Hello world.",
            "durationSeconds": 3.0
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(DictationHistoryEntry.self, from: legacyJSON)

        XCTAssertEqual(entry.activeVersion, .cleaned)
        XCTAssertEqual(entry.cleanedText, "Hello world.")
        XCTAssertNil(entry.cleanupMethodName)
        XCTAssertNil(entry.translatedToLanguage)
    }

    /// New fields survive an encode/decode round trip (stored as the stable
    /// enum keys, not display names).
    func testRoundTripsMethodAndLanguageFields() throws {
        var entry = DictationHistoryEntry(durationSeconds: 7.5, audioFilename: "a.raw")
        entry.status = .cleaned
        entry.rawText = "raw"
        entry.cleanedText = "clean"
        entry.activeVersion = .cleaned
        entry.cleanupModeName = "Translate"
        entry.cleanupMethodName = CleanupMethod.bulletPoints.key
        entry.translatedToLanguage = TranslationLanguage.german.key

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DictationHistoryEntry.self, from: data)

        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.cleanupModeName, "Translate")
        XCTAssertEqual(decoded.cleanupMethodName, "bullet-points")
        XCTAssertEqual(decoded.translatedToLanguage, "german")
        XCTAssertEqual(decoded.activeVersion, .cleaned)
    }

    /// The stored fields are tolerant strings: an unknown key must decode
    /// as-is (the UI renders it verbatim with no checkmark).
    func testDecodesUnknownMethodAndLanguageKeysVerbatim() throws {
        let json = """
        {
            "id": "1A2B3C4D-5E6F-7081-92A3-B4C5D6E7F809",
            "timestamp": 741700000.0,
            "status": "cleaned",
            "rawText": "raw",
            "cleanedText": "clean",
            "durationSeconds": 2.0,
            "activeVersion": "cleaned",
            "cleanupMethodName": "future-method",
            "translatedToLanguage": "klingon"
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(DictationHistoryEntry.self, from: json)

        XCTAssertEqual(entry.cleanupMethodName, "future-method")
        XCTAssertEqual(entry.translatedToLanguage, "klingon")
        XCTAssertNil(CleanupMethod(rawValue: entry.cleanupMethodName!))
        XCTAssertNil(TranslationLanguage(rawValue: entry.translatedToLanguage!))
    }

    /// Fn+K contract (#122): `operatorAddressed` is `Bool?` so the
    /// synthesized encoder omits it unless set — old and non-flagged
    /// entries stay byte-identical — and an entry without the key decodes
    /// as nil (readers check `== true`). Clearing the flag writes nil back, so
    /// an entry that carried it and lost it is byte-identical to one that never
    /// carried it. (Until #209 the post-paste bare K was what could clear it;
    /// the arming is Fn+K during the recording now, and the round trip is still
    /// the Codable contract every reader of the file depends on.)
    ///
    /// Encoded with `.sortedKeys` on both sides: `JSONEncoder`'s key order is
    /// not stable across calls, so a bare `encode` == `encode` comparison was a
    /// coin flip that had nothing to do with the field being tested.
    func testOperatorAddressedEncodedOnlyWhenTrue() throws {
        var entry = DictationHistoryEntry(durationSeconds: 2.0, audioFilename: nil)
        entry.status = .transcribed
        entry.rawText = "send this to the operator"

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let unflagged = try encoder.encode(entry)
        XCTAssertFalse(String(data: unflagged, encoding: .utf8)!.contains("operatorAddressed"))
        XCTAssertNil(try JSONDecoder().decode(DictationHistoryEntry.self, from: unflagged).operatorAddressed)

        entry.operatorAddressed = true
        let flagged = try encoder.encode(entry)
        XCTAssertTrue(String(data: flagged, encoding: .utf8)!.contains("\"operatorAddressed\":true"))
        XCTAssertEqual(try JSONDecoder().decode(DictationHistoryEntry.self, from: flagged).operatorAddressed, true)

        entry.operatorAddressed = nil
        XCTAssertEqual(try encoder.encode(entry), unflagged)
    }
}
