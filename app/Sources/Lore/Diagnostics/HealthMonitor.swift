import Foundation
import LoreCore
import Observation

extension DiagEvent.HealthTrigger {
    /// Whether a standing observation of this condition goes stale (#151). The
    /// event-derived four age out with the panel's 24 h ceiling, because the row
    /// behind each of them does. `.identityMigration` is re-derived live from
    /// the ledger at every launch and its row never stales, so neither does it.
    var ages: Bool { ![.identityMigration, .permissionsBlocked].contains(self) }

    /// Shown at once rather than after it has stood (#338): an effect already
    /// proved the claim, and someone whose keys are dead needs to hear it now.
    var showsAtOnce: Bool { self == .permissionsBlocked }

    /// What the mark's tooltip names when this condition stands alone. A
    /// *subject*, never a diagnosis: the dot may say where to look (a proxy
    /// summons a check, `no-false-positives` §3) and the panel says what.
    var subject: String {
        switch self {
        case .identityMigration: return "permissions"
        case .captureFailed: return "recording"
        case .systemAudioFailed: return "meeting audio"
        case .pasteFailed: return "paste"
        case .modelLoadFailed: return "transcription"
        case .permissionsBlocked: return HealthSummary.blockedName
        // Never raised by this build; a decoded one names nothing in particular.
        case .unknown: return "something"
        }
    }

    /// What the mark says when this condition stands alone. The blocked
    /// condition says what is happening (#338): the effect proved it, so it is
    /// a statement and not a summons to check.
    var standingLine: String {
        switch self {
        case .permissionsBlocked: return "macOS is blocking shortcuts and paste"
        default: return "\(subject) needs a look"
        }
    }
}

/// Where the blocked condition's fix stands (#338) — what the popover's message
/// says and offers. Nil on the monitor whenever the condition does not stand.
enum PermissionsBlock: String, Equatable, Sendable {
    /// An effect proved macOS is ignoring lore's switches.
    case blocked
    /// "Fix permissions" cleared lore's entries and asked again; the switches
    /// are the user's to turn on.
    case waiting
    /// The switches are on and the key listener still fails after its retries.
    case restart

    /// The popover's message, byte-identical to the board's copy table.
    var message: String {
        switch self {
        case .blocked: return "macOS is blocking \(LoreBrand.wordmark)'s shortcuts and paste."
        case .waiting: return "Switch \(LoreBrand.wordmark) on in System Settings."
        case .restart: return "Restart \(LoreBrand.wordmark) to finish."
        }
    }

    var hint: String? {
        switch self {
        case .blocked: return HealthCatalog.blockedHint
        case .waiting: return "Under Accessibility and Input Monitoring."
        case .restart: return nil
        }
    }

    /// The message's one primary button, the panel's own actions.
    var action: HealthRemedyAction {
        switch self {
        case .blocked: return .fixPermissions
        // The Accessibility pane — the first of the two switches.
        case .waiting: return .openSettings(.accessibility)
        case .restart: return .restartApp
        }
    }

    /// The button's words. The waiting stage names System Settings, not the
    /// pane: the person is looking for two switches, not one (board copy table).
    var actionLabel: String {
        self == .waiting ? "Open System Settings" : action.buttonLabel
    }

    /// The stage as the event stream names it; `.blocked` is the condition's
    /// own `healthConditionSustained`, not a stage.
    var traced: DiagEvent.PermissionFixStage? { DiagEvent.PermissionFixStage(rawValue: rawValue) }
}

/// The reads that confirm or clear the blocked condition (#338), taken at the
/// moment of the event that asks — never stored.
struct TrustReading: Equatable, Sendable {
    var accessibility: Bool
    var inputMonitoring: Bool
    /// The key listener exists and is enabled.
    var tapAlive: Bool

    var grantReadsOff: Bool { !accessibility || !inputMonitoring }
    /// Lore is allowed again and its key listener is live.
    var isClear: Bool { accessibility && inputMonitoring && tapAlive }
}

/// Owns the health state as an **on-open fact sheet** (#140) and the menu-bar
/// mark's amber state (#151): probes never run on a timer, and the mark speaks
/// only once a failure has *stood*. Why either is shaped this way:
/// docs/design/diagnostics.md §6.
@MainActor
@Observable
final class HealthMonitor {
    private(set) var snapshot: HealthSnapshot
    private(set) var items: [HealthItem]

    /// The probes whose expensive Test-now is running right now, so each row can
    /// show a spinner and disable its own button for the ~2s the test takes. A
    /// set, not a single id, because two rows' tests can overlap — each inserts
    /// its id before the await and removes it after, so neither clears the other.
    private(set) var testing: Set<HealthProbeID> = []

    var summary: HealthSummary { HealthSummary(snapshot) }

    @ObservationIgnored private let prober: HealthProber

    // MARK: - The menu-bar mark's amber state (#151, docs/design/diagnostics.md §6)

    /// How long a failure must stand before the mark says anything — the owner's
    /// persistence rule: what heals itself never interrupts.
    static let sustainedFailureDelay: TimeInterval = 60

    @ObservationIgnored private let sustainedDelay: TimeInterval
    @ObservationIgnored private let now: () -> Date
    /// The wake's sleep, injectable so a test can drive a crossing without
    /// spending a minute on it.
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void

    /// When each still-unresolved failure was *first* seen. A repeat does not
    /// restart the clock (the condition never went away); a recovery removes the
    /// entry. Not persisted — a fresh launch has no claim until one happens.
    @ObservationIgnored private(set) var failingSince: [DiagEvent.HealthTrigger: Date] = [:]

    /// The conditions that have crossed the window. Kept so each one's crossing
    /// can be traced at its own instant — two failures standing at once are two
    /// traces, not one arbitrated winner.
    /// Observed, so the mark's tooltip follows a second condition arriving
    /// while the dot is already lit (#338).
    private var sustained: Set<DiagEvent.HealthTrigger> = []

    /// One-shot re-read at the next crossing. Internal so a test can await it.
    @ObservationIgnored private(set) var sustainWake: Task<Void, Never>?

    /// Published: the mark is carrying a health claim. A `Bool`, because the mark
    /// has one bead slot and cannot say *which* — naming the subject is the
    /// tooltip's job (`sustained`) and explaining it is the panel's.
    private(set) var hasSustainedFailure = false

    /// The subjects standing right now, for the mark's tooltip and VoiceOver
    /// label. A set: with no ordering there is nothing to arbitrate.
    var sustainedSubjects: Set<DiagEvent.HealthTrigger> { sustained }

    /// A fresh signal that a tap blocked on a permission may install now — the
    /// user opened the health panel to fix exactly that (#149). Wired to
    /// `HotkeyManager`; the timer-driven repair path never calls it.
    @ObservationIgnored var refillTapRepairs: () -> Void = {}

    /// The three expensive "Test now" actions, injected because they reach for
    /// the mic, the model cache and the network. Each records a `DiagEvent`;
    /// `refresh()` afterwards reads the new last-attempt.
    @ObservationIgnored var runMicCaptureTest: () async -> Void = {}
    @ObservationIgnored var runModelWarmupTest: () async -> Void = {}
    @ObservationIgnored var runVADLoadTest: () async -> Void = {}
    @ObservationIgnored var runOpenAITest: () async -> Void = {}

    /// Re-checks the folder the #148 move could not empty, clearing its marker
    /// when the files are gone. Injected and side-effecting for the same reason
    /// the three tests above are: it reads a TCC-protected folder, so it may
    /// run only with the panel on screen — never from `init`, which is launch.
    @ObservationIgnored var verifyNotesLeftover: () -> Void = {}

    // MARK: - macOS blocking lore (#338)

    /// Where the blocked condition's fix stands; nil while it does not stand.
    private(set) var permissionsBlock: PermissionsBlock?

    /// The live reads behind the blocked condition. Unwired, they read healthy:
    /// a refused tap then confirms nothing, so an unwired monitor never claims.
    @ObservationIgnored var readTrust: () -> TrustReading = {
        TrustReading(accessibility: true, inputMonitoring: true, tapAlive: true)
    }
    /// Both grants read by a process that did not exist a moment ago
    /// (`GrantCheck`), so an in-process cache cannot answer. Nil when no such
    /// read could be had.
    @ObservationIgnored var readFreshGrants: @Sendable () async -> Bool? = { nil }
    /// Removes lore's own two entries (`PermissionReset`). Injected: a test
    /// must never run tccutil.
    @ObservationIgnored var resetPermissions: () async -> Void = {}
    /// Asks macOS again for both grants, so its own prompt appears.
    @ObservationIgnored var requestPermissions: () -> Void = {}

    /// The wait for the switches, after "Fix permissions". Internal so a test
    /// can await it.
    @ObservationIgnored private(set) var waitTask: Task<Void, Never>?
    @ObservationIgnored private var fixing = false

    /// How often the wait reads the switches, and for how long at most: a
    /// spawned read every few seconds while someone is in System Settings, and
    /// none once they have plainly walked away. The event path clears the
    /// condition with or without it.
    static let waitInterval: Duration = .seconds(3)
    static let waitTicks = 200
    /// Reads in a row with both switches on and the listener still dead before
    /// lore asks for a restart (#303): one read can land between the two flips.
    static let staleTicksBeforeRestart = 2

    init(
        prober: HealthProber,
        sustainedDelay: TimeInterval = HealthMonitor.sustainedFailureDelay,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.prober = prober
        self.sustainedDelay = sustainedDelay
        self.now = now
        self.sleep = sleep
        let initial = prober.probe(permissionsBlocked: false)
        self.snapshot = initial.snapshot
        self.items = initial.items
    }

    /// The panel just opened: verify what only a visible panel may verify, then
    /// publish. The split exists because `refresh()` also runs at launch, and
    /// the notes-leftover check reads a TCC-protected folder (#148).
    func refreshForPanel() {
        refillTapRepairs()
        verifyNotesLeftover()
        // An open panel is a fresh read: the switches may have just come on.
        if permissionsBlock != nil { note(.mayHaveCleared) }
        refresh()
    }

    /// Re-run the cheap chain and publish. Called at launch (init), on panel
    /// open, after a Test-now, and by `note` so the panel behind a condition is
    /// as fresh as the condition — never on a timer.
    func refresh() {
        let report = prober.probe(permissionsBlocked: permissionsBlock != nil)
        snapshot = report.snapshot
        items = report.items
        // Close the signing-identity migration (#135, rationale on
        // `SigningIdentityLedger`) on the one fact a cert change cannot fake: a
        // key-down that actually reached our tap — and only a real one; Lore's
        // own synthetic Cmd+V never stamps it (#140, `SyntheticKeyEvent`). Not
        // the permission flags — they are the part that lies — and not the
        // tap's `.ok`, which a fresh launch reads on mere aliveness.
        // Acknowledged *after* the probe (#144), so the panel a user opens next
        // still shows the signing row explaining what changed; the following
        // refresh publishes the clear. The migration's failure clock stops
        // through the ledger's `onMigrationClosed`, not through this snapshot.
        if let ledger = prober.signingLedger, ledger.migrationPending,
           prober.readTapLiveness().hasReceivedKeyDown == true {
            ledger.acknowledge()
        }
    }

    /// One event's bearing on one condition: which one it speaks to, and whether
    /// it says the condition is over.
    struct HealthSignal: Equatable, Sendable {
        let trigger: DiagEvent.HealthTrigger
        let succeeded: Bool
    }

    /// The only events that move a health condition — a user action that just
    /// failed, or the one that proves it works again. One table, so a trigger
    /// cannot gain a failure without a way to clear (rule 2 of
    /// `no-false-positives`) and the two halves cannot drift. `nonisolated` and
    /// cheap: the `DiagStore` observer runs it on the recording thread and hops
    /// to the main actor only for a match.
    nonisolated static func healthSignal(for event: DiagEvent) -> HealthSignal? {
        switch event {
        // AudioBus is mic-only, so its give-up is unambiguously the microphone —
        // and the system-audio tap next to it is unambiguously not (#149).
        case .captureGaveUp:
            return HealthSignal(trigger: .captureFailed, succeeded: false)
        // Frames arriving, never `captureStart`: `AudioDeviceStart` returns noErr
        // for the wedged device the no-frames watchdog then gives up on (#149).
        case .micFramesFlowing:
            return HealthSignal(trigger: .captureFailed, succeeded: true)
        // The give-up edge only, so one cause produces one report however many
        // times an unattended re-drive retried it (#149).
        case .systemAudioGaveUp:
            return HealthSignal(trigger: .systemAudioFailed, succeeded: false)
        case .systemAudioCapture(.ok, _):
            return HealthSignal(trigger: .systemAudioFailed, succeeded: true)
        // A paste posted while lore was untrusted is the blocked condition's
        // (`blockEvidence`), not a paste failure of its own: one cause, one
        // report (#338).
        case .pasteAttempt(_, let created, true):
            return HealthSignal(trigger: .pasteFailed, succeeded: created)
        // A real load attempt only: a cache hit loaded nothing and cannot clear
        // a leg whose own load failed (#169) — see `HealthProbes.modelWarmupOutcome`.
        case .modelLoad(.asr, let outcome, _, false, _) where outcome != .unknown:
            return HealthSignal(trigger: .modelLoadFailed, succeeded: outcome == .ok)
        default:
            return nil
        }
    }

    /// One event's bearing on the blocked condition (#338).
    enum BlockEvidence: Equatable, Sendable {
        /// A paste was posted while macOS reported lore untrusted, so macOS
        /// dropped it. The event carries its own read, so it is proof alone.
        case pasteDropped
        /// The key listener could not be created. A block only when a grant
        /// reads off at that moment; otherwise the repair budget's business.
        case tapRefused
        /// Something that needs the grants just worked, so the condition may be
        /// over. Cleared only if the reads say so now.
        case mayHaveCleared
        /// The key listener still fails after its retries, with the grants on.
        case tapGaveUp
    }

    /// The blocked condition's own table, beside `healthSignal`: the effects
    /// that raise it, the events after which it may be over, and the one that
    /// asks for a restart. A permission read alone appears only as a chance to
    /// clear — never to raise (#303: reads can be stale while things work).
    nonisolated static func blockEvidence(for event: DiagEvent) -> BlockEvidence? {
        switch event {
        case .pasteAttempt(_, _, false): return .pasteDropped
        case .tapCreate(.failed, _): return .tapRefused
        case .tapCreate(.ok, _), .pasteAttempt(_, true, true),
             .permissionTransition(_, granted: true):
            return .mayHaveCleared
        case .tapGaveUp: return .tapGaveUp
        default: return nil
        }
    }

    /// Move the blocked condition on one piece of evidence, confirmed by the
    /// reads where the evidence alone is not proof.
    func note(_ evidence: BlockEvidence) {
        switch evidence {
        case .pasteDropped:
            raiseBlock()
        case .tapRefused:
            if readTrust().grantReadsOff { raiseBlock() }
        case .mayHaveCleared:
            if permissionsBlock != nil, readTrust().isClear { clearBlock() }
        case .tapGaveUp:
            if permissionsBlock != nil, !readTrust().grantReadsOff { enter(.restart) }
        }
    }

    private func raiseBlock() {
        if permissionsBlock == nil { permissionsBlock = .blocked }
        noteFailure(.permissionsBlocked)
        refresh()
    }

    private func clearBlock() {
        waitTask?.cancel()
        waitTask = nil
        permissionsBlock = nil
        clearFailure(.permissionsBlocked)
        refresh()
    }

    private func enter(_ stage: PermissionsBlock) {
        guard permissionsBlock != nil, permissionsBlock != stage else { return }
        permissionsBlock = stage
        if let traced = stage.traced { DiagStore.record(.permissionFixStage(stage: traced)) }
    }

    /// "Fix permissions" (#338): remove lore's own two entries, ask macOS
    /// again, and wait for the switches. Runs on the user's click only — from
    /// the blocked condition, or from a stale-grant row (signing, tap) where no
    /// block stands. The reset switches both grants off either way, so the
    /// condition stands from here and the wait follows it to clear or restart.
    func fixPermissions() async {
        guard !fixing else { return }
        fixing = true
        defer { fixing = false }
        await resetPermissions()
        requestPermissions()
        if permissionsBlock == nil {
            permissionsBlock = .blocked
            noteFailure(.permissionsBlocked)
        }
        enter(.waiting)
        refresh()
        startWaiting()
    }

    /// Read the switches from a fresh process while the user is in System
    /// Settings. Both on: retry the key listener at once, then either the reads
    /// clear the condition, or — after a second such read — the listener is
    /// dead with the grants on and only a restart is left (#303).
    private func startWaiting() {
        waitTask?.cancel()
        waitTask = Task { [weak self, sleep] in
            var staleTicks = 0
            for _ in 0..<Self.waitTicks {
                await sleep(Self.waitInterval)
                guard !Task.isCancelled, let fresh = self?.readFreshGrants else { return }
                let granted = await fresh()
                guard !Task.isCancelled, let self, self.permissionsBlock == .waiting else { return }
                guard granted == true else {
                    staleTicks = 0
                    continue
                }
                self.refillTapRepairs()
                if self.readTrust().isClear {
                    self.clearBlock()
                    return
                }
                staleTicks += 1
                if staleTicks >= Self.staleTicksBeforeRestart {
                    self.enter(.restart)
                    return
                }
            }
            // Out of reads, the stage stays waiting: HotkeyManager's 5 s cycle
            // still rebuilds the tap on the grant's edge and clears it then.
        }
    }

    /// Events that move no condition but change a panel row read from disk: a
    /// VAD load lands (or fails), so the voice-activity row re-reads at once
    /// instead of waiting for the next open (rule 2 of `no-false-positives`).
    nonisolated static func refreshesPanel(for event: DiagEvent) -> Bool {
        if case .modelLoad(.vad, _, _, _, _) = event { return true }
        return false
    }

    /// The single ordered path both halves take: re-probe so the panel is fresh,
    /// then move the condition's clock. One hop, so the panel's rows and the
    /// mark's dot are always published from the same pass and cannot disagree.
    func note(_ signal: HealthSignal) {
        if signal.succeeded { clearFailure(signal.trigger) } else { noteFailure(signal.trigger) }
        // After the clock, so a clear the paste row reads (#338) is already in
        // the stream when the row is re-read.
        refresh()
    }

    /// Start a failure's clock, or leave a running one alone. Also the entry for
    /// the one condition no `DiagEvent` carries: the #144 identity migration,
    /// re-derived from the ledger at every launch.
    func noteFailure(_ trigger: DiagEvent.HealthTrigger) {
        if failingSince[trigger] == nil { failingSince[trigger] = now() }
        publishSustained()
    }

    /// The condition is over. Separate from `note` because the identity
    /// migration's recovery arrives from inside `refresh()` (the ledger's
    /// acknowledge), where a second `refresh()` would re-enter.
    func clearFailure(_ trigger: DiagEvent.HealthTrigger) {
        failingSince.removeValue(forKey: trigger)
        publishSustained()
    }

    /// The whole persistence rule in one pure expression: every condition old
    /// enough to matter and fresh enough to still be true. Clock-parametric so
    /// it is testable without spending a minute, static so no caller can shade
    /// it. The upper bound is the panel's own 24 h ceiling — the two surfaces
    /// must agree on the time axis as much as on the facts.
    static func sustainedFailures(
        among failingSince: [DiagEvent.HealthTrigger: Date],
        now: Date,
        delay: TimeInterval
    ) -> Set<DiagEvent.HealthTrigger> {
        Set(failingSince.filter { trigger, since in
            now.timeIntervalSince(since) >= (trigger.showsAtOnce ? 0 : delay)
                && isFresh(trigger, since: since, at: now)
        }.keys)
    }

    /// Still worth reading: everything but an observation aged past the ceiling.
    private static func isFresh(
        _ trigger: DiagEvent.HealthTrigger, since: Date, at: Date
    ) -> Bool {
        !trigger.ages
            || at.timeIntervalSince(since) <= TimeInterval(HealthLastAttempt.maxFreshAgeSeconds)
    }

    /// Re-derive what stands and trace every condition that changed side. Reads
    /// state and stores no verdict, so nothing can survive its own condition.
    private func publishSustained() {
        let at = now()
        let next = Self.sustainedFailures(among: failingSince, now: at, delay: sustainedDelay)
        // Per condition, at that condition's own crossing — both halves always
        // paired, because a claim with no trace cannot be debugged (rule 5).
        for gone in sustained.subtracting(next) {
            DiagStore.record(.healthConditionCleared(trigger: gone))
        }
        for arrived in next.subtracting(sustained) {
            DiagStore.record(.healthConditionSustained(trigger: arrived))
        }
        // An aged-out entry can never sustain again, so drop it rather than
        // re-filter it forever.
        failingSince = failingSince.filter { Self.isFresh($0.key, since: $0.value, at: at) }
        sustained = next
        hasSustainedFailure = !next.isEmpty
        scheduleSustainWake(from: at)
    }

    /// A crossing that happens while nothing else does is the one moment the
    /// derivation changes with no event to carry it, so one sleep covers the
    /// earliest uncrossed one. It concludes nothing — it re-runs the same
    /// expression every other read runs.
    ///
    /// Always armed against a freshly read clock: re-arming from a stored past
    /// instant would let the sleep drift shorter every hop. No wake for the 24 h
    /// ceiling — that bound is a read-time filter on both surfaces, and a
    /// day-long timer to anticipate it is the scheduled machinery this replaced.
    private func scheduleSustainWake(from at: Date) {
        sustainWake?.cancel()
        sustainWake = nil
        guard let deadline = failingSince
            .filter({ !$0.key.showsAtOnce })
            .values
            .map({ $0.addingTimeInterval(sustainedDelay) })
            .filter({ $0 > at })
            .min()
        else { return }
        let wait = Duration.seconds(deadline.timeIntervalSince(at))
        sustainWake = Task { [weak self, sleep] in
            await sleep(wait)
            guard !Task.isCancelled else { return }
            self?.publishSustained()
        }
    }

    /// Perform an expensive probe on the user's explicit request, then refresh
    /// so its fresh last-attempt shows. `testing` is held for the row's spinner
    /// across the whole await and cleared only after `refresh()` has published the
    /// just-run outcome, so the panel never shows an idle button over stale copy.
    func testNow(_ id: HealthProbeID) async {
        testing.insert(id)
        defer { testing.remove(id) }
        switch id {
        case .micCapture:
            await runMicCaptureTest()
        case .modelWarmup, .asrModel:
            await runModelWarmupTest()
        case .vadModel:
            await runVADLoadTest()
        case .openAILiveness:
            await runOpenAITest()
        default:
            break
        }
        refresh()
    }
}
