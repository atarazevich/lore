import XCTest
@testable import LoreKit

/// The status→remedy mapping is the panel's contract (#83, design §6): every
/// failing link carries a specific instruction, and the critical ones carry
/// buttons that perform the fix. A healthy link carries none.
final class HealthCatalogTests: XCTestCase {

    private func item(_ id: HealthProbeID, _ status: HealthStatus,
                      holderName: String? = nil,
                      cert: SigningCertKind? = nil,
                      lastAttempt: HealthLastAttempt? = nil) -> HealthItem {
        HealthCatalog.describe(
            HealthResult(id: id, status: status, signingCert: cert, lastAttempt: lastAttempt),
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

    /// When the tap is dead AND secure input is active, secure input is the
    /// cause — the tap remedy points at it and drops the useless restart button.
    func testTapFailureWhileSecureInputActiveSurfacesTheCauseNotARestart() {
        let it = HealthCatalog.describe(
            HealthResult(id: .tap, status: .failed),
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

    // MARK: - Settings panes deep-link to the documented scheme

    func testSettingsPanesResolveToSystemSettingsURLs() {
        for pane in [SettingsPane.accessibility, .inputMonitoring, .microphone] {
            let url = try! XCTUnwrap(pane.settingsURL)
            XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        }
    }
}
