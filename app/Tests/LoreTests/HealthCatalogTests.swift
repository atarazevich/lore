import XCTest
@testable import LoreKit

/// The status→remedy mapping is the panel's contract (#83, design §6): every
/// failing link carries a specific instruction, and the critical ones carry
/// buttons that perform the fix. A healthy link carries none.
final class HealthCatalogTests: XCTestCase {

    private func item(_ id: HealthProbeID, _ status: HealthStatus,
                      holderName: String? = nil,
                      holderPID: Int32? = nil,
                      cert: SigningCertKind? = nil,
                      lastAttempt: HealthLastAttempt? = nil) -> HealthItem {
        HealthCatalog.describe(
            HealthResult(id: id, status: status, secureInputHolderPID: holderPID,
                         signingCert: cert, lastAttempt: lastAttempt),
            holderName: holderName
        )
    }

    // MARK: - Healthy links carry no remedy

    func testEveryCheapProbeOKHasNoRemedy() {
        for id in HealthProbeID.allCases where id.cost == .cheap {
            // signing .ok needs a real cert kind to read as healthy.
            let cert: SigningCertKind? = id == .signing ? .appleDevelopment : nil
            XCTAssertNil(item(id, .ok, cert: cert).remedy, "\(id.rawValue) ok should carry no remedy")
        }
    }

    // MARK: - Failing links carry a specific remedy

    func testEveryFailingCheapProbeCarriesARemedy() {
        // secureInput/signing failures are handled below with their extras.
        let plain: [HealthProbeID] = [.urlScheme, .accessibility, .inputMonitoring,
                                      .tap, .microphone, .asrModel, .vadModel, .openAIKey]
        for id in plain {
            XCTAssertNotNil(item(id, .failed).remedy, "\(id.rawValue) failed must carry a remedy")
        }
    }

    // MARK: - The failure-specific remedies from the design doc

    func testAccessibilityFailureDeepLinksAndOffersRestart() {
        let remedy = try! XCTUnwrap(item(.accessibility, .failed).remedy)
        XCTAssertTrue(remedy.actions.contains(.openSettings(.accessibility)))
        XCTAssertTrue(remedy.actions.contains(.restartApp))
        XCTAssertTrue(remedy.instruction.contains("no longer recognizes"),
                      "the enabled-but-unrecognized wording is the whole point")
    }

    func testInputMonitoringFailureDeepLinksToItsOwnPane() {
        let remedy = try! XCTUnwrap(item(.inputMonitoring, .failed).remedy)
        XCTAssertTrue(remedy.actions.contains(.openSettings(.inputMonitoring)))
        XCTAssertFalse(remedy.actions.contains(.openSettings(.accessibility)))
    }

    func testTapFailureOffersRestartFirst() {
        let remedy = try! XCTUnwrap(item(.tap, .failed).remedy)
        XCTAssertEqual(remedy.actions.first, .restartApp)
    }

    /// When secure input is active it starves the tap and is the cause — the tap
    /// remedy points at it and drops the useless restart button. `.warning` is the
    /// tap's reachable state under it: `tapStatus()` cannot return `.failed` there
    /// (#94).
    func testTapWarningWhileSecureInputActiveSurfacesTheCauseNotARestart() {
        let it = HealthCatalog.describe(
            HealthResult(id: .tap, status: .warning),
            secureInputActive: true
        )
        let remedy = try! XCTUnwrap(it.remedy)
        XCTAssertTrue(remedy.instruction.localizedCaseInsensitiveContains("secure input"))
        XCTAssertFalse(remedy.actions.contains(.restartApp),
                       "restart cannot fix a starved tap while secure input is on")
    }

    func testMicrophoneFailureDeepLinksToMicrophonePane() {
        let remedy = try! XCTUnwrap(item(.microphone, .failed).remedy)
        XCTAssertTrue(remedy.actions.contains(.openSettings(.microphone)))
    }

    func testSecureInputFailureNamesTheHolderInTheDetailButNotTheSnapshot() {
        let it = item(.secureInput, .failed, holderName: "1Password")
        XCTAssertTrue(it.detail.contains("1Password"), "the panel names the holder")
        XCTAssertNotNil(it.remedy)
        // The holder name is machine-local: it lives on the item, never the result.
        let encoded = try! JSONEncoder().encode(it.result)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("1Password"),
                       "holder name must not reach the Codable result")
    }

    /// `NSRunningApplication(processIdentifier:)` returns nil for a CLI or daemon
    /// holder, so the name is nil while the pid stands — the case hit live twice,
    /// and the one where the user most needs the hint. The row must point at the pid
    /// rather than fall silent about a holder the report already carries (#92).
    func testSecureInputWithAnUnnamedHolderPointsAtThePID() {
        let it = item(.secureInput, .failed, holderPID: 4242)
        XCTAssertTrue(it.detail.contains("4242"),
                      "with no app to name, the pid is the only hint the panel has")
        XCTAssertTrue(it.detail.contains("may not be the one responsible"),
                      "the pid stays a hedged hint, not an accusation (rdar://48953777)")
    }

    func testAdHocSigningWarnsAboutResetPermissions() {
        let it = item(.signing, .warning, cert: .adHoc)
        let remedy = try! XCTUnwrap(it.remedy)
        XCTAssertTrue(remedy.instruction.localizedCaseInsensitiveContains("permission"))
    }

    func testDeveloperSigningIsHealthy() {
        XCTAssertNil(item(.signing, .ok, cert: .developerID).remedy)
        XCTAssertNil(item(.signing, .ok, cert: .appleDevelopment).remedy)
    }

    // MARK: - Expensive probes: last outcome + Test now

    func testExpensiveProbeWithoutHistoryOffersTestNow() {
        let remedy = try! XCTUnwrap(item(.micCapture, .warning, lastAttempt: nil).remedy)
        XCTAssertEqual(remedy.actions, [.testNow(.micCapture)])
    }

    func testExpensiveProbeFailureShowsLastOutcomeAndTestNow() {
        let attempt = HealthLastAttempt(outcome: .failed, ageSeconds: 240)
        let it = item(.openAILiveness, .failed, lastAttempt: attempt)
        XCTAssertTrue(it.detail.contains("4 min ago"))
        XCTAssertEqual(try! XCTUnwrap(it.remedy).actions, [.testNow(.openAILiveness)])
    }

    func testRelativeAgeIsCoarseAndTextFree() {
        XCTAssertEqual(HealthCatalog.relativeAge(10), "just now")
        XCTAssertEqual(HealthCatalog.relativeAge(240), "4 min ago")
        XCTAssertEqual(HealthCatalog.relativeAge(7200), "2 h ago")
        XCTAssertEqual(HealthCatalog.relativeAge(172_800), "2 d ago")
    }

    /// Issue 1 (#88): "just now" spans the whole first minute so a re-test within
    /// a minute reads as distinct from the prior "1 min ago".
    func testRelativeAgeIsJustNowUnderOneMinute() {
        XCTAssertEqual(HealthCatalog.relativeAge(59), "just now")
        XCTAssertEqual(HealthCatalog.relativeAge(60), "1 min ago")
    }

    // MARK: - Settings panes deep-link to the documented scheme

    func testSettingsPanesResolveToSystemSettingsURLs() {
        for pane in [SettingsPane.accessibility, .inputMonitoring, .microphone] {
            let url = try! XCTUnwrap(pane.settingsURL)
            XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        }
    }
}
