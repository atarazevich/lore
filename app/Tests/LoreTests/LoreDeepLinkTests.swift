import XCTest
@testable import LoreKit

/// Parse-layer coverage for the lore:// control channel (#65). The AppKit
/// delivery seam (AppDelegate.application(_:open:)) is deliberately thin —
/// log, parse, activate, enqueue — and is exercised live, not here:
/// constructing AppDelegate in tests would touch LoreRootApp.sharedContext.
final class LoreDeepLinkTests: XCTestCase {

    func testParse() {
        let cases: [(url: String, expected: ExternalCommand?)] = [
            ("lore://start", .startSession),
            ("lore://stop", .stopSession),
            ("LORE://start", .startSession),
            ("lore://START", .startSession),
            ("lore://notes", .openNotes(sessionID: nil)),
            ("lore://notes?sessionID=session_abc", .openNotes(sessionID: "session_abc")),
            ("lore://notes?sessionId=session_abc", .openNotes(sessionID: "session_abc")),
            ("lore://notes?id=session_abc", .openNotes(sessionID: "session_abc")),
            ("lore://notes/session_path", .openNotes(sessionID: "session_path")),
            // Query beats path when both carry a session ID.
            ("lore://notes/session_path?sessionID=session_query", .openNotes(sessionID: "session_query")),
            ("lore://bogus", nil),
            ("https://start", nil),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(LoreDeepLink.parse(URL(string: url)!), expected, url)
        }
    }
}
