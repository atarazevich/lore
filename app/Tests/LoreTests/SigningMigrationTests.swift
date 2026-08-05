import XCTest
@testable import LoreKit

/// The signing-identity migration (#135, rationale on `SigningIdentityLedger`):
/// the ledger detects the *change* across launches, and the flow closes only on
/// the one fact a cert change cannot fake — a key-down that actually reached
/// Lore's tap. The panel copy it produces is pinned in `HealthCatalogTests`, its
/// notch line in `HealthSummonTests`; this suite is the ledger and the monitor.
@MainActor
final class SigningMigrationTests: XCTestCase {

    private var suiteName = ""

    private func freshDefaults() -> UserDefaults {
        suiteName = "SigningMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    override func tearDown() {
        if !suiteName.isEmpty {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    private func info(_ kind: SigningCertKind, team: String?) -> SigningIdentity.Info {
        SigningIdentity.Info(certKind: kind, teamID: team)
    }

    /// A launch that had nothing to migrate: the launch path acknowledges, which
    /// is what starts the record (`LoreApp.setupHealthMonitor`). Reading alone
    /// never writes, so this is the only way a record comes into existence.
    @discardableResult
    private func launch(_ defaults: UserDefaults, _ identity: SigningIdentity.Info)
    -> SigningIdentityLedger {
        let ledger = SigningIdentityLedger(defaults: defaults, current: identity)
        if !ledger.migrationPending { ledger.acknowledge() }
        return ledger
    }

    // MARK: - Ledger: detect the change across launches

    func testFirstEverLaunchIsNotAMigrationAndStartsTheRecord() {
        let defaults = freshDefaults()
        let first = SigningIdentityLedger(defaults: defaults,
                                          current: info(.appleDevelopment, team: "OLD"))
        XCTAssertFalse(first.migrationPending, "nothing persisted — nothing changed")
        first.acknowledge()

        // The record started: an identical second launch is quiet too.
        let second = SigningIdentityLedger(defaults: defaults,
                                           current: info(.appleDevelopment, team: "OLD"))
        XCTAssertFalse(second.migrationPending)
    }

    func testTeamChangeAloneIsAMigration() {
        let defaults = freshDefaults()
        launch(defaults, info(.appleDevelopment, team: "OLD"))
        let next = SigningIdentityLedger(defaults: defaults, current: info(.appleDevelopment, team: "NEW"))
        XCTAssertTrue(next.migrationPending)
    }

    /// The pending state is derived from the mismatch, so quitting without
    /// re-granting cannot lose it: the next launch re-derives it.
    func testUnacknowledgedMigrationSurvivesARelaunch() {
        let defaults = freshDefaults()
        launch(defaults, info(.appleDevelopment, team: "OLD"))
        let changed = SigningIdentityLedger(defaults: defaults, current: info(.developerID, team: "NEW"))
        XCTAssertTrue(changed.migrationPending)

        let relaunch = SigningIdentityLedger(defaults: defaults, current: info(.developerID, team: "NEW"))
        XCTAssertTrue(relaunch.migrationPending, "not acknowledged — still pending after relaunch")
    }

    func testAcknowledgePersistsTheNewIdentitySoTheFlowDoesNotReTrigger() {
        let defaults = freshDefaults()
        launch(defaults, info(.appleDevelopment, team: "OLD"))
        let changed = SigningIdentityLedger(defaults: defaults, current: info(.developerID, team: "NEW"))
        changed.acknowledge()
        XCTAssertFalse(changed.migrationPending)

        let relaunch = SigningIdentityLedger(defaults: defaults, current: info(.developerID, team: "NEW"))
        XCTAssertFalse(relaunch.migrationPending, "the new identity is the record now")
    }

    /// An unreadable signature proves nothing: no migration, and — since the
    /// launch path acknowledges whenever nothing is pending — it must not write
    /// itself over the good record either. The next readable launch still
    /// compares against the real previous identity.
    func testUnknownSignatureNeitherMigratesNorClobbersTheRecord() {
        let defaults = freshDefaults()
        launch(defaults, info(.appleDevelopment, team: "OLD"))
        let unreadable = launch(defaults, info(.unknown, team: nil))
        XCTAssertFalse(unreadable.migrationPending)

        let next = SigningIdentityLedger(defaults: defaults, current: info(.developerID, team: "NEW"))
        XCTAssertTrue(next.migrationPending, "the record survived the unreadable launch")
    }

    // MARK: - Monitor: only a key-down that reached the tap closes the flow

    private func migrationLedger() -> (UserDefaults, SigningIdentityLedger) {
        let defaults = freshDefaults()
        launch(defaults, info(.appleDevelopment, team: "OLD"))
        let ledger = SigningIdentityLedger(defaults: defaults, current: info(.developerID, team: "NEW"))
        return (defaults, ledger)
    }

    private func monitor(ledger: SigningIdentityLedger, liveness: TapLiveness) -> HealthMonitor {
        let prober = HealthProber(
            readTapLiveness: { liveness },
            // Injected like every other health test (#94): the suite must not
            // read this machine's live secure-input flag.
            readSecureInput: { HealthProberTests.secureInputState(active: false) },
            hasOpenAIKey: { true },
            signingLedger: ledger,
            store: HealthProberTests.emptyStore()
        )
        return HealthMonitor(prober: prober)
    }

    /// The state every launch is in a few seconds after start-up: the tap is
    /// installed, the user has been typing (they just launched the app), and no
    /// key-down has reached *our* tap yet — which is exactly what a stale grant
    /// looks like and what a working one looks like at t+5 s. A silence this
    /// short is the absence of a measurement, so nothing may be concluded from
    /// it: the migration has to survive the cycle.
    func testTheFirstCyclesAfterLaunchDoNotAcknowledgeTheMigration() {
        let (_, ledger) = migrationLedger()
        var justLaunched = TapLiveness()
        _ = justLaunched.observe(isAlive: true, hasReceivedKeyDown: false, tapSilent: 5,
                                 sessionSilent: 5, secureInputActive: false)
        let monitor = monitor(ledger: ledger, liveness: justLaunched)

        monitor.refresh()

        XCTAssertTrue(ledger.migrationPending, "a short silence after launch is not evidence")
        let signing = monitor.snapshot.results.first { $0.id == .signing }!
        XCTAssertEqual(signing.status, .warning)
        XCTAssertEqual(signing.signingIdentityChanged, true)
    }

    func testAKeystrokeReachingTheTapAcknowledgesAndClearsTheRowSameCycle() {
        let (defaults, ledger) = migrationLedger()
        var fed = TapLiveness()
        _ = fed.observe(isAlive: true, hasReceivedKeyDown: true, tapSilent: 0,
                        sessionSilent: 0, secureInputActive: false)
        let monitor = monitor(ledger: ledger, liveness: fed)

        monitor.refresh()

        XCTAssertFalse(ledger.migrationPending, "a key-down reached Lore — the grants work")
        let signing = monitor.snapshot.results.first { $0.id == .signing }!
        XCTAssertNil(signing.signingIdentityChanged, "the published snapshot already shows the clear")

        let relaunch = SigningIdentityLedger(defaults: defaults, current: info(.developerID, team: "NEW"))
        XCTAssertFalse(relaunch.migrationPending, "acknowledged — never re-triggers")
    }
}
