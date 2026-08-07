import Foundation
import Observation

/// The notch self-summon payload (#140): which user action failed (or that the
/// launch found an identity migration), plus the state bit that explains it when
/// one is red right now. The trigger is always a failure the user just felt —
/// state bits (permissions, secure input) are the *explanation*, never the
/// trigger, because they flap (16 "lost" transitions vs 1 "granted" in 3 days of
/// events.json) and because a bit being red costs the user nothing until an
/// action fails on it.
struct HealthSummon: Equatable, Sendable {
    let trigger: DiagEvent.SummonTrigger
    /// The chain link that explains the failure — `.microphone` behind a failed
    /// capture, `.accessibility` behind a failed paste — or `nil` when the state
    /// bits all read fine and the failure speaks for itself.
    var explanation: HealthProbeID? = nil

    /// A failed user action always displaces the launch migration notice on the
    /// notch (`HealthNotchPresenter`): the notice is advice, the failure is now.
    var isCritical: Bool { trigger != .identityMigration }

    /// The notch renders this line plus "Fix it" and nothing else — the panel's
    /// rows carry the remedies. Deliberately NOT merged into `HealthCatalog`'s
    /// copy tables: the notch line is a one-glance alert with its own tone and
    /// length budget, not a panel row's detail — don't "deduplicate" it there.
    var title: String {
        switch trigger {
        // Raised by the launch check alone (#135): the condition is a change,
        // not a fault, so no "not working" template fits it.
        case .identityMigration:
            return "\(LoreTheme.wordmark)'s signature changed — permissions need a re-grant"
        case .captureFailed:
            return explanation == .microphone
                ? "Recording failed — microphone access is off"
                : "Recording failed — the microphone produced no audio"
        // Never folded into `.captureFailed` (#149): a different grant, so a
        // different sentence.
        case .systemAudioFailed:
            return "Meeting audio incomplete — system audio wasn't captured"
        case .pasteFailed:
            return explanation == .accessibility
                ? "Paste failed — Accessibility permission is off"
                : "Paste failed — your text is still on the clipboard"
        case .modelLoadFailed:
            return "Transcription failed — the model did not load"
        }
    }
}

/// Owns the health state as an **on-open fact sheet** (#140): probes run once at
/// launch and whenever the panel opens (plus after a Test-now), never on a
/// timer — the 5 s verdict loop interrupted with conclusions its evidence could
/// not support (30 s of keyboard silence read as "shortcuts not working" after
/// an 8.8-hour idle gap). Summons now arrive through `noteFailure`, fed by the
/// `DiagStore` observer: a summon fires only when a user action just failed.
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

    /// Fired when a user action failed (or the launch found a migration) —
    /// wired to the notch.
    @ObservationIgnored var onSummon: (HealthSummon) -> Void = { _ in }

    /// The same door in reverse: the condition behind a summon just cleared, so
    /// a notch still claiming it withdraws (#149).
    @ObservationIgnored var onRecovery: (DiagEvent.SummonTrigger) -> Void = { _ in }

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

    init(prober: HealthProber) {
        self.prober = prober
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
    /// open, after a Test-now, and by `noteFailure` so a summon's explanation is
    /// read off fresh state — never on a timer.
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
        // Acknowledged *after* the probe (#144): "Fix it" opens the panel onto
        // a signing row that still explains what changed; the next refresh
        // publishes the clear. The notch withdraws through the ledger's
        // `onMigrationClosed`, not through this snapshot.
        if let ledger = prober.signingLedger, ledger.migrationPending,
           prober.readTapLiveness().hasReceivedKeyDown == true {
            ledger.acknowledge()
        }
    }

    /// One event's bearing on one summon: which condition it speaks to, and
    /// whether it says the condition is over.
    struct SummonSignal: Equatable, Sendable {
        let trigger: DiagEvent.SummonTrigger
        let succeeded: Bool
    }

    /// The only events that move a summon — a user action that just failed, or
    /// the one that proves it works again. One table, so a trigger cannot gain a
    /// failure without a way to clear (rule 2 of `no-false-positives`) and the two
    /// halves cannot drift. `nonisolated` and cheap: the `DiagStore` observer runs
    /// it on the recording thread and hops to the main actor only for a match.
    nonisolated static func summonSignal(for event: DiagEvent) -> SummonSignal? {
        switch event {
        // AudioBus is mic-only, so its give-up is unambiguously the microphone —
        // and the system-audio tap next to it is unambiguously not (#149).
        case .captureGaveUp:
            return SummonSignal(trigger: .captureFailed, succeeded: false)
        // Frames arriving, never `captureStart`: `AudioDeviceStart` returns noErr
        // for the wedged device the no-frames watchdog then gives up on (#149).
        case .micFramesFlowing:
            return SummonSignal(trigger: .captureFailed, succeeded: true)
        // The give-up edge only, so one cause produces one report however many
        // times an unattended re-drive retried it (#149).
        case .systemAudioGaveUp:
            return SummonSignal(trigger: .systemAudioFailed, succeeded: false)
        case .systemAudioCapture(.ok, _):
            return SummonSignal(trigger: .systemAudioFailed, succeeded: true)
        case .pasteAttempt(_, let created, _):
            return SummonSignal(trigger: .pasteFailed, succeeded: created)
        case .modelLoad(.asr, let outcome, _, _) where outcome != .unknown:
            return SummonSignal(trigger: .modelLoadFailed, succeeded: outcome == .ok)
        default:
            return nil
        }
    }

    /// The single ordered path both halves take: re-probe so the panel is fresh
    /// behind whatever happens next, then either summon or withdraw. One hop, so
    /// a present and a clear can never race each other onto the notch.
    func note(_ signal: SummonSignal) {
        refresh()
        guard !signal.succeeded else {
            onRecovery(signal.trigger)
            return
        }
        onSummon(HealthSummon(trigger: signal.trigger, explanation: explanation(for: signal.trigger)))
    }

    /// The most likely chain link behind a failed action, iff it reads `.failed`
    /// right now. One link per trigger, not a scan: naming an unrelated red bit
    /// would be the state-bit-as-verdict pattern this rework removes.
    private func explanation(for trigger: DiagEvent.SummonTrigger) -> HealthProbeID? {
        let candidate: HealthProbeID?
        switch trigger {
        case .captureFailed: candidate = .microphone
        case .pasteFailed: candidate = .accessibility
        // `.systemAudioFailed` names its own subject already (#149).
        case .systemAudioFailed, .modelLoadFailed, .identityMigration: candidate = nil
        }
        guard let candidate,
              snapshot.results.first(where: { $0.id == candidate })?.status == .failed
        else { return nil }
        return candidate
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
