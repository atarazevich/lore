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

    /// #140: macOS keys TCC grants to the team (`build.sh` pins the designated
    /// requirement there), so a dev ↔ release cert flip within the same team
    /// keeps its grants — summoning the re-grant walkthrough for it would be a
    /// state-bit interruption over a non-event. The stored record is the old
    /// full `kind|team` format, so this also pins old-format compatibility.
    func testACertKindFlipWithinTheSameTeamIsNotAMigration() {
        let defaults = freshDefaults()
        launch(defaults, info(.appleDevelopment, team: "SAME"))
        let release = SigningIdentityLedger(defaults: defaults, current: info(.developerID, team: "SAME"))
        XCTAssertFalse(release.migrationPending, "same team shares TCC — a non-event")

        // And back: the record now says developerID|SAME after the launch path
        // acknowledged; a dev build on the same team stays quiet too.
        if !release.migrationPending { release.acknowledge() }
        let dev = SigningIdentityLedger(defaults: defaults, current: info(.appleDevelopment, team: "SAME"))
        XCTAssertFalse(dev.migrationPending)
    }

    /// Ad-hoc has no team to key grants on, so any transition involving it is
    /// genuinely TCC-affecting and keeps summoning.
    func testTransitionsInvolvingAdHocRemainMigrations() {
        let defaults = freshDefaults()
        launch(defaults, info(.appleDevelopment, team: "SAME"))
        let intoAdHoc = SigningIdentityLedger(defaults: defaults, current: info(.adHoc, team: nil))
        XCTAssertTrue(intoAdHoc.migrationPending, "into ad-hoc: grants drop")
        intoAdHoc.acknowledge()

        let outOfAdHoc = SigningIdentityLedger(defaults: defaults, current: info(.appleDevelopment, team: "SAME"))
        XCTAssertTrue(outOfAdHoc.migrationPending, "out of ad-hoc: a fresh identity to grant")
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
        justLaunched.observe(isAlive: true, hasReceivedKeyDown: false, tapSilent: 5,
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
        fed.observe(isAlive: true, hasReceivedKeyDown: true, tapSilent: 0,
                    sessionSilent: 0, secureInputActive: false)
        let monitor = monitor(ledger: ledger, liveness: fed)

        monitor.refresh()

        XCTAssertFalse(ledger.migrationPending, "a key-down reached Lore — the grants work")
        let signing = monitor.snapshot.results.first { $0.id == .signing }!
        XCTAssertNil(signing.signingIdentityChanged, "the published snapshot already shows the clear")

        let relaunch = SigningIdentityLedger(defaults: defaults, current: info(.developerID, team: "NEW"))
        XCTAssertFalse(relaunch.migrationPending, "acknowledged — never re-triggers")
    }

    /// The production wiring, end to end: the ack rides the first real key-down
    /// (`HotkeyManager.noteRealKeyDown` → `onFirstRealKeyDown` → one
    /// `refresh()`), and the prober reads the *manager's own* liveness — the
    /// exact shape `LoreApp.setupHealthMonitor` wires. The 5 s repair loop has
    /// usually not ticked between the key-down and the refresh, so the key-down
    /// path must feed the measurement itself; a refresh reading the last tick's
    /// stale value consumed the one-shot with `hasReceivedKeyDown` still nil
    /// and left the migration pending forever. The direct-injection tests above
    /// cannot catch that — this one pins the wiring.
    func testTheFirstRealKeyDownAcknowledgesThroughTheLiveWiring() async {
        let (_, ledger) = migrationLedger()
        let hotkeys = HotkeyManager() // no install(): no tap, no monitors
        let prober = HealthProber(
            readTapLiveness: { hotkeys.tapLiveness },
            readSecureInput: { HealthProberTests.secureInputState(active: false) },
            hasOpenAIKey: { true },
            signingLedger: ledger,
            store: HealthProberTests.emptyStore()
        )
        let monitor = HealthMonitor(prober: prober)
        hotkeys.onFirstRealKeyDown = { monitor.refresh() }

        XCTAssertTrue(ledger.migrationPending)
        hotkeys.noteRealKeyDown() // what the tap callback runs on a real key-down
        // The observe + refresh ride a Task hop off the callback's critical path.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(ledger.migrationPending,
                       "the first real key-down must acknowledge without waiting for a 5 s tick")
    }
}
