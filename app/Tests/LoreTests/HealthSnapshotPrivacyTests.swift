import XCTest
@testable import LoreKit

/// A `HealthSnapshot` is exactly what #84's report uploads, so it carries the
/// same guarantee as the `DiagEvent` stream: no personal data by construction
/// (design §4, §6). This is the runtime witness — same discipline as
/// `DiagEventPrivacyTests`: build the worst-case snapshot and assert no fixture
/// string survives the encode, and that every string on the wire is either a
/// closed-vocabulary enum value or the (non-personal) version identifiers.
final class HealthSnapshotPrivacyTests: XCTestCase {

    // Strings a snapshot must never contain (`PrivacyFixtures`) — a leaked
    // process name, device name, path or key. A secure-input *holder name* is
    // the realistic leak vector here, since the panel shows it.
    private static let fixtures = PrivacyFixtures.all
    private static let fixtureTokens = PrivacyFixtures.tokens
    private static let stringValues = PrivacyFixtures.stringValues(in:)

    /// The tap's measurement (#97) at its most-revealing legal value. It is Bools
    /// and counts, so it contributes no strings to the wire at all — which is the
    /// property `testEveryStringInEncodedSnapshotIsFromTheClosedVocabulary` checks.
    private static var worstCaseLiveness: TapLiveness {
        var liveness = TapLiveness()
        _ = liveness.observe(isAlive: false, hasReceivedKeyDown: true,
                             tapSilent: .greatestFiniteMagnitude, sessionSilent: 0,
                             secureInputActive: false)
        return liveness
    }

    /// The worst case: every probe present, every optional field populated with
    /// its most-revealing legal value. Because no field is free-form text, the
    /// worst case is still only enums and numbers.
    private static var worstCase: HealthSnapshot {
        HealthSnapshot(
            marketingVersion: "2.0.1",
            build: "2.0.231",
            results: HealthProbeID.allCases.map { id in
                HealthResult(
                    id: id,
                    status: .failed,
                    secureInputHolderPID: .max,
                    signingCert: .adHoc,
                    signingIdentityChanged: true,
                    freeDiskGB: 0,
                    lastAttempt: HealthLastAttempt(outcome: .failed, ageSeconds: .max),
                    tapLiveness: Self.worstCaseLiveness
                )
            }
        )
    }

    /// Every string an enum in the snapshot can legally contribute.
    private static let closedVocabulary: Set<String> = {
        var allowed = Set<String>()
        allowed.formUnion(HealthProbeID.allCases.map(\.rawValue))
        allowed.formUnion(HealthStatus.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.Outcome.allCases.map(\.rawValue))
        allowed.insert(SigningCertKind.adHoc.rawValue)
        allowed.insert(SigningCertKind.appleDevelopment.rawValue)
        allowed.insert(SigningCertKind.developerID.rawValue)
        allowed.insert(SigningCertKind.unknown.rawValue)
        // The version identifiers are non-personal build facts (design §9).
        allowed.insert("2.0.1")
        allowed.insert("2.0.231")
        return allowed
    }()

    func testSnapshotRoundTrips() throws {
        let data = try JSONEncoder().encode(Self.worstCase)
        let decoded = try JSONDecoder().decode(HealthSnapshot.self, from: data)
        XCTAssertEqual(decoded, Self.worstCase)
    }

    func testEncodedSnapshotContainsNoFixture() throws {
        let json = String(decoding: try JSONEncoder().encode(Self.worstCase), as: UTF8.self)
        for fixture in Self.fixtures {
            XCTAssertFalse(json.contains(fixture), "snapshot leaked fixture: \(fixture)")
        }
        for token in Self.fixtureTokens {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(token), "snapshot leaked token: \(token)")
        }
    }

    func testEveryStringInEncodedSnapshotIsFromTheClosedVocabulary() throws {
        let data = try JSONEncoder().encode(Self.worstCase)
        let object = try JSONSerialization.jsonObject(with: data)
        for string in Self.stringValues(object) {
            XCTAssertTrue(
                Self.closedVocabulary.contains(string),
                "snapshot carried the free-form string '\(string)'"
            )
        }
    }
}
