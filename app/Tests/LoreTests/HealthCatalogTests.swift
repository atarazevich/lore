import XCTest
@testable import LoreKit

/// The status→remedy mapping is the panel's contract (#83, design §6): every
/// failing link carries a specific instruction, and the critical ones carry
/// buttons that perform the fix. A healthy link carries none.
final class HealthCatalogTests: XCTestCase {

    private func item(_ id: HealthProbeID, _ status: HealthStatus,
                      holder: SecureInput.Attribution? = nil,
                      holderPID: Int32? = nil,
                      cert: SigningCertKind? = nil,
                      identityChanged: Bool? = nil,
                      lastAttempt: HealthLastAttempt? = nil) -> HealthItem {
        HealthCatalog.describe(
            HealthResult(id: id, status: status, secureInputHolderPID: holderPID,
                         signingCert: cert, signingIdentityChanged: identityChanged,
                         lastAttempt: lastAttempt),
            secureInputHolder: holder
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
        let plain: [HealthProbeID] = [.accessibility, .inputMonitoring,
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
        // #99: `observe` is designed never to conclude here, so the row says the
        // measurement is unavailable rather than asserting a verdict it never drew.
        XCTAssertTrue(it.detail.localizedCaseInsensitiveContains("can't be measured"),
                      "no verdict exists under secure input, and the row must say so")
    }

    func testMicrophoneFailureDeepLinksToMicrophonePane() {
        let remedy = try! XCTUnwrap(item(.microphone, .failed).remedy)
        XCTAssertTrue(remedy.actions.contains(.openSettings(.microphone)))
    }

    func testSecureInputFailureNamesTheHolderInTheDetailButNotTheSnapshot() {
        let it = item(.secureInput, .failed, holder: .app("1Password"))
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
        let it = item(.secureInput, .failed, holder: .process(4242), holderPID: 4242)
        XCTAssertTrue(it.detail.contains("4242"),
                      "with no app to name, the pid is the only hint the panel has")
        XCTAssertTrue(it.detail.contains("may not be the one responsible"),
                      "the pid stays a hedged hint, not an accusation (rdar://48953777)")
    }

    /// #98: a misattributed holder gets a bisection procedure, not a target
    /// (canonical account in design §6). Only the mutation-relevant pins — the
    /// exact wording is the copy's business, not this test's.
    func testAMisattributedHolderGetsTheBisectionProcedureNotATarget() {
        let it = item(.secureInput, .failed, holder: .misattributed, holderPID: 422)
        XCTAssertTrue(it.detail.contains("won't name"))
        XCTAssertFalse(it.detail.contains("422"), "no pid to chase")
        let remedy = try! XCTUnwrap(it.remedy)
        XCTAssertTrue(remedy.instruction.contains("one at a time"), "bisection, not a target")
        XCTAssertFalse(remedy.instruction.localizedCaseInsensitiveContains("kill"))
        XCTAssertEqual(remedy.actions, [], "no button — there is no single target to act on")
    }

    func testAdHocSigningWarnsAboutResetPermissions() {
        let it = item(.signing, .warning, cert: .adHoc)
        let remedy = try! XCTUnwrap(it.remedy)
        XCTAssertTrue(remedy.instruction.localizedCaseInsensitiveContains("permission"))
    }

    /// The identity migration (#135): a signed build whose signature changed
    /// carries the same remove-and-re-add walkthrough as a measured stale grant,
    /// because macOS keys the grant to the signature and toggling does not
    /// re-bind it.
    func testASignatureChangeCarriesTheReGrantWalkthroughWithBothPanes() {
        let it = item(.signing, .warning, cert: .developerID, identityChanged: true)
        XCTAssertTrue(it.detail.contains("changed since the last launch"))
        let remedy = try! XCTUnwrap(it.remedy)
        XCTAssertTrue(remedy.actions.contains(.openSettings(.accessibility)))
        XCTAssertTrue(remedy.actions.contains(.openSettings(.inputMonitoring)))
        XCTAssertTrue(remedy.actions.contains(.restartApp))
        XCTAssertTrue(remedy.instruction.localizedCaseInsensitiveContains("remove"),
                      "removing the entry is the step that re-binds a grant; toggling is not")
    }

    /// A build that changed *into* ad-hoc changed identity too, but re-granting
    /// is not its answer: macOS drops the grants again on the next launch, so the
    /// row must keep its own advice — reinstall a signed build.
    func testAChangeIntoAdHocKeepsTheReinstallAdviceNotTheReGrantWalkthrough() {
        let it = item(.signing, .warning, cert: .adHoc, identityChanged: true)
        let remedy = try! XCTUnwrap(it.remedy)
        XCTAssertTrue(remedy.instruction.localizedCaseInsensitiveContains("reinstall"))
        XCTAssertEqual(remedy.actions, [], "no pane to re-grant in")
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

    /// #149: the row reported "Last capture failed" and named no way out. A
    /// failed system-audio capture now points at the grant that gates the tap —
    /// and still offers no Test-now, which it genuinely cannot run.
    func testSystemAudioFailureExplainsTheGrantInsteadOfOfferingATestItCannotRun() {
        let attempt = HealthLastAttempt(outcome: .failed, ageSeconds: 60)
        let remedy = try! XCTUnwrap(item(.systemAudio, .failed, lastAttempt: attempt).remedy)
        XCTAssertEqual(remedy.actions, [.openSettings(.screenRecording)])
        XCTAssertTrue(remedy.instruction.contains("Screen & System Audio Recording"))
        XCTAssertFalse(remedy.actions.contains(.testNow(.systemAudio)))
    }

    /// A system-audio capture that has never run is still not an accusation: no
    /// remedy, no button, just "no meeting recorded yet".
    func testSystemAudioWithoutHistoryStillOffersNothing() {
        XCTAssertNil(item(.systemAudio, .warning, lastAttempt: nil).remedy)
    }

    // MARK: - Settings panes deep-link to the documented scheme

    func testSettingsPanesResolveToSystemSettingsURLs() {
        for pane in SettingsPane.allCases {
            let url = try! XCTUnwrap(pane.settingsURL)
            XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        }
    }
}
