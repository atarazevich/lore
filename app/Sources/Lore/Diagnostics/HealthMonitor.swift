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

    /// The three expensive "Test now" actions, injected because they reach for
    /// the mic, the model cache and the network. Each records a `DiagEvent`;
    /// `refresh()` afterwards reads the new last-attempt.
    @ObservationIgnored var runMicCaptureTest: () async -> Void = {}
    @ObservationIgnored var runModelWarmupTest: () async -> Void = {}
    @ObservationIgnored var runOpenAITest: () async -> Void = {}

    init(prober: HealthProber) {
        self.prober = prober
        let initial = prober.probe()
        self.snapshot = initial.snapshot
        self.items = initial.items
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

    /// The events that mean a user action just failed — the only things allowed
    /// to summon besides the launch migration. `nonisolated` and cheap: the
    /// `DiagStore` observer runs this filter on the recording thread and hops to
    /// the main actor only for a match.
    nonisolated static func failureTrigger(for event: DiagEvent) -> DiagEvent.SummonTrigger? {
        switch event {
        case .captureGaveUp:
            return .captureFailed
        case .pasteAttempt(_, false, _):
            return .pasteFailed
        case .modelLoad(.asr, .failed, _, _):
            return .modelLoadFailed
        default:
            return nil
        }
    }

    /// A user action failed: re-probe so the panel is fresh when "Fix it" opens
    /// it, name the failure, and attach the state bit that explains it.
    func noteFailure(_ trigger: DiagEvent.SummonTrigger) {
        refresh()
        onSummon(HealthSummon(trigger: trigger, explanation: explanation(for: trigger)))
    }

    /// The most likely chain link behind a failed action, iff it reads `.failed`
    /// right now. One link per trigger, not a scan: naming an unrelated red bit
    /// would be the state-bit-as-verdict pattern this rework removes.
    private func explanation(for trigger: DiagEvent.SummonTrigger) -> HealthProbeID? {
        let candidate: HealthProbeID?
        switch trigger {
        case .captureFailed: candidate = .microphone
        case .pasteFailed: candidate = .accessibility
        case .modelLoadFailed, .identityMigration: candidate = nil
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
