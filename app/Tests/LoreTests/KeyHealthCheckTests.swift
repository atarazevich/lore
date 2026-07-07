import XCTest
@testable import LoreKit

/// Pure status → verdict mapping for the OpenAI key liveness probe (#50).
/// Only a definitive 401 may call a key invalid; anything inconclusive
/// (missing status, 403, 5xx, rate limit) must stay `.unknown` so a flaky
/// connection never shows a false "key rejected" warning.
final class KeyHealthCheckTests: XCTestCase {

    func testSuccessStatusMeansKeyOK() {
        XCTAssertEqual(KeyHealthCheck.classify(statusCode: 200), .ok)
        XCTAssertEqual(KeyHealthCheck.classify(statusCode: 204), .ok)
    }

    func test401MeansKeyInvalid() {
        XCTAssertEqual(KeyHealthCheck.classify(statusCode: 401), .invalid)
    }

    func testOtherStatusesAreInconclusive() {
        // 403 is the documented blind spot: deliberately .unknown.
        XCTAssertEqual(KeyHealthCheck.classify(statusCode: 403), .unknown)
        XCTAssertEqual(KeyHealthCheck.classify(statusCode: 429), .unknown)
        XCTAssertEqual(KeyHealthCheck.classify(statusCode: 500), .unknown)
        XCTAssertEqual(KeyHealthCheck.classify(statusCode: nil), .unknown)
    }
}
