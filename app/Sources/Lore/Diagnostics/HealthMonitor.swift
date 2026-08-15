import Foundation
import Observation

extension DiagEvent.HealthTrigger {
    /// Whether a standing observation of this condition goes stale (#151). The
    /// event-derived four age out with the panel's 24 h ceiling, because the row
    /// behind each of them does. `.identityMigration` is re-derived live from
    /// the ledger at every launch and its row never stales, so neither does it.
    var ages: Bool { self != .identityMigration }

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
        }
    }
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
    @ObservationIgnored private var sustained: Set<DiagEvent.HealthTrigger> = []

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
    @ObservationIgnored var runOpenAITest: () async -> Void = {}

    /// Re-checks the folder the #148 move could not empty, clearing its marker
    /// when the files are gone. Injected and side-effecting for the same reason
    /// the three tests above are: it reads a TCC-protected folder, so it may
    /// run only with the panel on screen — never from `init`, which is launch.
    @ObservationIgnored var verifyNotesLeftover: () -> Void = {}

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
        let initial = prober.probe()
        self.snapshot = initial.snapshot
        self.items = initial.items
    }

    /// The panel just opened: verify what only a visible panel may verify, then
    /// publish. The split exists because `refresh()` also runs at launch, and
    /// the notes-leftover check reads a TCC-protected folder (#148).
    func refreshForPanel() {
        refillTapRepairs()
        verifyNotesLeftover()
        refresh()
    }

    /// Re-run the cheap chain and publish. Called at launch (init), on panel
    /// open, after a Test-now, and by `note` so the panel behind a condition is
    /// as fresh as the condition — never on a timer.
    func refresh() {
        let report = prober.probe()
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
        case .pasteAttempt(_, let created, _):
            return HealthSignal(trigger: .pasteFailed, succeeded: created)
        // A real load attempt only: a cache hit loaded nothing and cannot clear
        // a leg whose own load failed (#169) — see `HealthProbes.modelWarmupOutcome`.
        case .modelLoad(.asr, let outcome, _, false) where outcome != .unknown:
            return HealthSignal(trigger: .modelLoadFailed, succeeded: outcome == .ok)
        default:
            return nil
        }
    }

    /// The single ordered path both halves take: re-probe so the panel is fresh,
    /// then move the condition's clock. One hop, so the panel's rows and the
    /// mark's dot are always published from the same pass and cannot disagree.
    func note(_ signal: HealthSignal) {
        refresh()
        if signal.succeeded { clearFailure(signal.trigger) } else { noteFailure(signal.trigger) }
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
            now.timeIntervalSince(since) >= delay && isFresh(trigger, since: since, at: now)
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
        guard let deadline = failingSince.values
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
        case .modelWarmup, .asrModel, .vadModel:
            await runModelWarmupTest()
        case .openAILiveness:
            await runOpenAITest()
        default:
            break
        }
        refresh()
    }
}
