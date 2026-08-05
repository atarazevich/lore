import XCTest
@testable import LoreKit

/// C1 (#83): the tap probe must reflect the *starved* verdict, not just
/// "the tap object exists". An enabled-but-starved tap — the reported "Fn dead,
/// all toggles on" incident, caused by secure input — has to read as failed so
/// the critical link fails and the notch summons itself. `tapIsEnabled` alone
/// reads it as healthy, which is exactly why the bug went unseen.
@MainActor
final class HealthProberTests: XCTestCase {

    /// A fresh empty event store so the expensive probes have no last-attempt.
    /// `static` and shared with the other health suites, like `liveness` and
    /// `secureInputState` below — one definition of a health test's fixtures.
    static func emptyStore() -> DiagStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HealthTests-\(UUID().uuidString)", isDirectory: true)
        return DiagStore(directory: dir)
    }

    /// `secureInput` drives the injected read (#94), so the tap gate is exercised
    /// without touching this machine's actual secure-input flag — holding it for
    /// real would starve the keyboard of whoever runs the suite.
    private func prober(alive: Bool, stalled: Bool, secureInput: Bool = false) -> HealthProber {
        HealthProber(
            readTapLiveness: { Self.liveness(alive: alive, stalled: stalled) },
            readSecureInput: { Self.secureInputState(active: secureInput) },
            hasOpenAIKey: { true },
            store: Self.emptyStore()
        )
    }

    /// A literal secure-input reading, per the `holderPIDs(in:)` doctrine of
    /// testing the decision logic off values rather than the live registry.
    static func secureInputState(
        active: Bool, pid: Int32? = nil, consoleLocked: Bool = false,
        attribution: SecureInput.Attribution = .nobody
    ) -> SecureInput.State {
        SecureInput.State(active: active, pid: pid, consoleLocked: consoleLocked,
                          attribution: attribution, name: nil)
    }

    /// `stalled` is driven through the real measurement rather than asserted into
    /// the value: starved *is* "our tap silent past the threshold while the session
    /// was fed key-downs", which is the pair #97 made the verdict a function of.
    /// The silence is the *first* tick that can latch one — the health loop ticks
    /// every 5 s against a 30 s threshold — because that is the value the row is
    /// read at: the banner goes up on this tick and the user opens the panel next.
    static func liveness(alive: Bool, stalled: Bool) -> TapLiveness {
        var liveness = TapLiveness()
        _ = liveness.observe(isAlive: alive,
                            hasReceivedKeyDown: true,
                            tapSilent: stalled ? TapLiveness.threshold + 1 : 0,
                            sessionSilent: 0,
                            secureInputActive: false)
        return liveness
    }

    private func tapResult(_ prober: HealthProber) -> HealthResult {
        prober.probe().snapshot.results.first { $0.id == .tap }!
    }

    func testEnabledAndFlowingTapIsHealthy() {
        XCTAssertEqual(tapResult(prober(alive: true, stalled: false)).status, .ok)
    }

    func testEnabledButStarvedTapReadsAsFailed() {
        // The whole point: alive == true, yet no events flow → failed.
        let result = tapResult(prober(alive: true, stalled: true))
        XCTAssertEqual(result.status, .failed, "enabled-but-starved must not read healthy")
    }

    func testDeadTapReadsAsFailed() {
        XCTAssertEqual(tapResult(prober(alive: false, stalled: false)).status, .failed)
    }

    func testStalledTapIsACriticalFailure() {
        let snapshot = prober(alive: true, stalled: true).probe().snapshot
        XCTAssertTrue(snapshot.criticalFailures.contains(.tap),
                      "a starved tap is a critical link failure")
    }

    /// The remedy has to match the fault, and a starvation can be measured on a tap
    /// that then dies (`reinstallEventTap` failing leaves exactly this). The tap
    /// object is genuinely gone, a restart genuinely reinstalls it, and the
    /// stale-grant copy — which offers no restart — would send the user to strip
    /// Lore's permissions instead.
    func testADeadTapIsOfferedARestartEvenIfAStarvationWasMeasuredToo() {
        let tap = prober(alive: false, stalled: true).probe().items.first { $0.id == .tap }!
        let remedy = try! XCTUnwrap(tap.remedy)
        XCTAssertTrue(remedy.actions.contains(.restartApp), "a tap that is gone is reinstalled by a restart")
    }

    /// The health loop sleeps before its first tick, so a panel opened in the first
    /// 5 s renders whatever a never-measured liveness says. Green there is a claim
    /// about a tap that may have failed to install — there is no health without
    /// evidence, so the unmeasured value is not alive.
    func testATapThatWasNeverMeasuredDoesNotReadHealthy() {
        let prober = HealthProber(
            readTapLiveness: { TapLiveness() },
            hasOpenAIKey: { true },
            store: Self.emptyStore()
        )
        XCTAssertNotEqual(tapResult(prober).status, .ok)
    }

    // MARK: - #94: under secure input the tap probe must not render a verdict

    /// The 13 stall/resume flaps: under secure input the old verdict was a
    /// function of whether the user had paused typing for 30 s, so it read `.failed`
    /// — "Fn key not working" — to a user whose Fn key worked 28 times that session.
    /// Now the two inputs that encode that pause cannot move the verdict at all, and
    /// `.warning` is not `.failed`, the only status `isCritical` summons on.
    func testUnderSecureInputTheTapVerdictIsIndependentOfTheStallHeuristic() {
        let verdicts = [(true, true), (true, false), (false, true), (false, false)].map {
            tapResult(prober(alive: $0.0, stalled: $0.1, secureInput: true)).status
        }
        XCTAssertEqual(verdicts, Array(repeating: .warning, count: 4),
                       "a verdict we cannot measure must not depend on the user's typing pauses")
    }

    /// The contradiction the user actually hit: the banner sent them to a panel
    /// that read "Keyboard tap: green — Live, receiving key events". The row may
    /// not read healthy while the condition is up, and `secureInputActive` must
    /// reach the catalog for a `.warning` tap — before #94 only `.failed` got there.
    func testUnderSecureInputTheTapRowCannotReadGreenAndNamesTheCause() {
        let tap = prober(alive: true, stalled: false, secureInput: true)
            .probe().items.first { $0.id == .tap }!
        XCTAssertNotEqual(tap.status, .ok, "the panel must not contradict the banner")
        XCTAssertFalse(tap.detail.contains("Live"), "the green-state copy must not render")
        XCTAssertTrue(tap.detail.contains("secure input"), "the row names the real condition")
    }

    /// The whole round-trip of the false banner, inverted: a password is typed, the
    /// field closes, and the panel is opened. Under secure input our tap starves
    /// while the session is fed — the exact shape of a starvation — and the #94 gate
    /// above hides it only while the condition is up. If that verdict were drawn it
    /// would latch, and `.failed` is what summons the notch, so the user would be
    /// told their keyboard is broken for having entered a password (#97).
    func testAStarvationTheSecureInputWindowWouldHaveProducedNeverSurvivesIt() {
        var measured = TapLiveness()
        _ = measured.observe(isAlive: true, hasReceivedKeyDown: true,
                             tapSilent: TapLiveness.threshold + 1, sessionSilent: 0,
                             secureInputActive: true)
        let prober = HealthProber(
            readTapLiveness: { measured },
            readSecureInput: { Self.secureInputState(active: false) },
            hasOpenAIKey: { true },
            store: Self.emptyStore()
        )
        XCTAssertEqual(tapResult(prober).status, .ok,
                       "secure input clearing must not reveal a verdict it was never possible to measure")
    }

    /// `SecureInput.read()` evaluates the flag before walking the registry, so a
    /// holder appearing between the two reads yields `active: false, pid: n` for one
    /// tick. #92's point is that a report's reader can decode `holderPID`
    /// unambiguously; a pid on an `ok` row is noise in exactly that way.
    func testAnInactiveSecureInputRowCarriesNoHolderPID() {
        let prober = HealthProber(
            readTapLiveness: { TapLiveness() },
            readSecureInput: { Self.secureInputState(active: false, pid: 4242, attribution: .process(4242)) },
            hasOpenAIKey: { true },
            store: Self.emptyStore()
        )
        let row = prober.probe().snapshot.results.first { $0.id == .secureInput }!
        XCTAssertEqual(row.status, .ok)
        XCTAssertNil(row.secureInputHolderPID, "a pid on an ok row is noise to a report's reader")
    }

    // MARK: - #98: the lock state separates "working as designed" from "stuck"

    private func secureInputProbe(_ state: SecureInput.State) -> (row: HealthResult, item: HealthItem) {
        let prober = HealthProber(
            readTapLiveness: { TapLiveness() },
            readSecureInput: { state },
            hasOpenAIKey: { true },
            store: Self.emptyStore()
        )
        let (snapshot, items) = prober.probe()
        return (snapshot.results.first { $0.id == .secureInput }!,
                items.first { $0.id == .secureInput }!)
    }

    /// loginwindow holding secure input behind a locked console is the lock
    /// screen protecting the password field — nothing is wrong, nothing surfaces,
    /// and no notch summons at every lock screen.
    func testTheLockScreenHoldingSecureInputIsNotAProblem() {
        let (row, item) = secureInputProbe(Self.secureInputState(
            active: true, pid: 422, consoleLocked: true, attribution: .misattributed))
        XCTAssertEqual(row.status, .ok, "the lock screen doing its job is not an issue")
        XCTAssertNil(row.secureInputHolderPID, "a pid appears iff the row is a problem (#92)")
        XCTAssertNil(item.remedy)
        // The flag IS up, and the tap row (gated on the raw flag) says so — this
        // row's ok copy must not contradict it by claiming "Inactive".
        XCTAssertFalse(item.detail.contains("Inactive"),
                       "ok-while-active must not render the inactive copy")
        XCTAssertTrue(item.detail.contains("lock screen"))
    }

    /// The same holder with the console unlocked is the field bug (#98): name
    /// AND pid suppressed on the panel, while the report keeps the raw pid —
    /// suppression is a display rule, mirroring #92's SecurityAgent decision.
    func testAMisattributedHolderOnAnUnlockedConsoleIsAProblemTheReportKeepsAndThePanelDoesNotBlame() {
        let (row, item) = secureInputProbe(Self.secureInputState(
            active: true, pid: 422, consoleLocked: false, attribution: .misattributed))
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.secureInputHolderPID, 422, "the report keeps the raw pid")
        XCTAssertTrue(item.detail.contains("won't name"), "an honest unknown beats a confident wrong answer")
        XCTAssertFalse(item.detail.contains("422"), "the pid is a misattribution sink's — not shown")
        XCTAssertFalse(item.detail.contains("loginwindow"), "and neither is the name")
    }

    /// The locked console exonerates regardless of attribution: `.nobody` is the
    /// case that matters — the registry can attribute the flag to no one at the
    /// lock screen, and a `.failed` there would summon the notch at every lock
    /// screen, exactly what the exoneration exists to prevent. A stuck flag
    /// resurfaces on the first tick after unlock (lock state is re-read each
    /// cycle), which is also when the panel becomes readable again.
    func testALockedConsoleExoneratesRegardlessOfAttribution() {
        for attribution in [SecureInput.Attribution.nobody, .app("1Password")] {
            let (row, _) = secureInputProbe(Self.secureInputState(
                active: true, pid: nil, consoleLocked: true, attribution: attribution))
            XCTAssertEqual(row.status, .ok, "\(attribution): locked console is by design")
        }
        // Unlock is what reveals a stuck flag.
        let (row, _) = secureInputProbe(Self.secureInputState(
            active: true, pid: nil, consoleLocked: false, attribution: .nobody))
        XCTAssertEqual(row.status, .failed)
    }

    /// The single-source-of-truth guard: `HealthProbeID.cost` is the ONE place
    /// that decides cheap (auto-run) vs expensive (Test-now-only). `readings()`
    /// dispatches on it, `countsInFooter` excludes untested expensive warnings by
    /// it, and the remedy copy routes by it — but each needs a per-id extractor /
    /// labels table. This pins the extractor table's key set to the cost set, so
    /// a new expensive probe cannot be added to one without the other, which is
    /// exactly the drift that would silently reintroduce the footer cry-wolf.
    func testExpensiveExtractorSetEqualsCost() {
        XCTAssertEqual(
            Set(HealthProber.expensiveOutcome.keys),
            Set(HealthProbeID.allCases.filter { $0.cost == .expensive }),
            "the readings() Test-now-only set must equal { id.cost == .expensive }"
        )
    }

    /// The same invariant, observed through the remedy layer: the expensive
    /// probes carry a `Test now` action for their own id — except `.systemAudio`,
    /// which is observable only during a real meeting recording (there is no
    /// on-demand test for it, #88), so it stays `.expensive` in cost yet carries
    /// no button. This guards issue 2 against regression.
    func testOnlyExpensiveProbesCarryTheirOwnTestNowRemedy() {
        for id in HealthProbeID.allCases {
            let item = HealthCatalog.describe(HealthResult(id: id, status: .warning))
            let hasOwnTestNow = item.remedy?.actions.contains(.testNow(id)) ?? false
            let expectsTestNow = id.cost == .expensive && id != .systemAudio
            XCTAssertEqual(hasOwnTestNow, expectsTestNow,
                           "\(id.rawValue): own Test-now action ⟺ expensive and not systemAudio")
        }
    }

    /// Issue 2 (#88), pinned directly: systemAudio carries NO Test-now action in
    /// any state (a button that can't run is not honest), while the other three
    /// expensive probes always do.
    func testSystemAudioHasNoTestNowButOtherExpensiveProbesDo() {
        let systemAudio = HealthCatalog.describe(HealthResult(id: .systemAudio, status: .warning))
        XCTAssertFalse(systemAudio.remedy?.actions.contains(.testNow(.systemAudio)) ?? false,
                       "systemAudio must not offer a Test-now it can't run")
        for id in [HealthProbeID.micCapture, .modelWarmup, .openAILiveness] {
            let item = HealthCatalog.describe(HealthResult(id: id, status: .warning))
            XCTAssertEqual(try! XCTUnwrap(item.remedy).actions, [.testNow(id)],
                           "\(id.rawValue) keeps its on-demand Test now")
        }
    }

    /// Issue 1 (#88): the panel's spinner is driven by `monitor.testing`, which
    /// must contain a probe's id for the whole duration of its `testNow` and drop
    /// it only after it finishes. A gated injected closure lets us observe the
    /// membership mid-flight deterministically, without racing a sleep.
    func testTestingFlagIsHeldDuringTheTestAndClearedAfter() async {
        let monitor = HealthMonitor(prober: prober(alive: true, stalled: false))
        XCTAssertFalse(monitor.testing.contains(.micCapture))

        var resume: (() -> Void)?
        monitor.runMicCaptureTest = {
            await withCheckedContinuation { cont in resume = { cont.resume() } }
        }

        let task = Task { await monitor.testNow(.micCapture) }
        // Yield until testNow has inserted the id and suspended inside the closure.
        while resume == nil { await Task.yield() }
        XCTAssertTrue(monitor.testing.contains(.micCapture), "in-flight flag set while the test runs")

        resume?()
        await task.value
        XCTAssertFalse(monitor.testing.contains(.micCapture), "in-flight flag cleared after the test completes")
    }

    /// Two rows' tests can overlap: each id must track independently so neither
    /// clears the other (the single-`id?` bug where a second test flipped the
    /// first row's spinner off and the first to finish cleared both).
    func testTwoConcurrentTestsTrackIndependently() async {
        let monitor = HealthMonitor(prober: prober(alive: true, stalled: false))

        var resumeMic: (() -> Void)?
        monitor.runMicCaptureTest = {
            await withCheckedContinuation { cont in resumeMic = { cont.resume() } }
        }
        var resumeAPI: (() -> Void)?
        monitor.runOpenAITest = {
            await withCheckedContinuation { cont in resumeAPI = { cont.resume() } }
        }

        let micTask = Task { await monitor.testNow(.micCapture) }
        while resumeMic == nil { await Task.yield() }
        let apiTask = Task { await monitor.testNow(.openAILiveness) }
        while resumeAPI == nil { await Task.yield() }

        XCTAssertEqual(monitor.testing, [.micCapture, .openAILiveness],
                       "both overlapping tests are in flight")

        resumeMic?()
        await micTask.value
        XCTAssertFalse(monitor.testing.contains(.micCapture), "the finished test drops its own id")
        XCTAssertTrue(monitor.testing.contains(.openAILiveness),
                      "the still-running test keeps its flag")

        resumeAPI?()
        await apiTask.value
        XCTAssertTrue(monitor.testing.isEmpty, "both flags cleared once both finish")
    }

    // MARK: - #97: the verdict is measured, and the measurement is readable

    /// The user on the affected machine will not run a script on their work machine
    /// — a reasonable boundary, and it makes the app the only instrument that can
    /// reach the failure. So the row shows what was measured on both sides, not
    /// just the conclusion: our tap's silence, and the session's key-downs meanwhile.
    /// At the first tick that can latch, both sides fall inside `relativeAge`'s
    /// "just now" bucket (#88) — the row would have refuted itself for the whole
    /// window in which the banner is read, so the evidence renders as durations.
    /// And the line states the *direction*, not two numbers to subtract (#99).
    func testAStarvedTapRowShowsTheMeasurementItsVerdictCameFrom() {
        let tap = prober(alive: true, stalled: true).probe().items.first { $0.id == .tap }!
        XCTAssertEqual(tap.status, .failed)
        XCTAssertTrue(tap.detail.contains("reaching the Mac but not Lore"),
                      "the row states what the gap means, not arithmetic for the reader to get wrong")
        XCTAssertTrue(tap.detail.contains("silent for 31s"),
                      "the row states how long our tap has gone without a keystroke")
        XCTAssertTrue(tap.detail.contains("keystroke was 0s ago"),
                      "beside the session's, so the gap the verdict came from is legible")
        XCTAssertFalse(tap.detail.contains("just now"),
                       "a 31 s silence rendered as “just now” is the row refuting itself")
    }

    /// Secure input off and the tap starved: the cause is that Lore is not being
    /// given keystrokes at all. Both permission probes above read `ok` on the
    /// affected machine throughout the incident, so this row may not defer to them
    /// — and the remedy has to be the one that actually clears a stale grant.
    func testAStarvedTapWithoutSecureInputBlamesPermissionsAndSaysHowToClearThem() {
        let tap = prober(alive: true, stalled: true).probe().items.first { $0.id == .tap }!
        let remedy = try! XCTUnwrap(tap.remedy)
        XCTAssertTrue(remedy.actions.contains(.openSettings(.accessibility)))
        XCTAssertTrue(remedy.actions.contains(.openSettings(.inputMonitoring)))
        XCTAssertFalse(remedy.actions.contains(.restartApp),
                       "a restart does not clear a stale grant")
        XCTAssertTrue(remedy.instruction.localizedCaseInsensitiveContains("remove"),
                      "removing the entry is the step that works")
        XCTAssertTrue(remedy.instruction.localizedCaseInsensitiveContains("does not clear it"),
                      "and toggling — what the user will try first — is called out as not working")
    }

    /// End to end: a stalled-tap verdict drives the monitor to summon the notch.
    func testStalledTapTriggersTheSummon() {
        let monitor = HealthMonitor(prober: prober(alive: true, stalled: true), summonThreshold: 1)
        var summoned: HealthSummon?
        monitor.onSummon = { summoned = $0 }

        monitor.refresh()

        XCTAssertNotNil(summoned, "a starved tap must summon the notch")
    }
}
