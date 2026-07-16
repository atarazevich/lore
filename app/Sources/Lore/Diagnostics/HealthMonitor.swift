import Foundation
import Observation

/// The notch self-summon payload: which critical link failed, and the copy the
/// notch shows ("Keyboard shortcuts not working" / "Fix it").
struct HealthSummon: Equatable, Sendable {
    let probe: HealthProbeID

    /// `"<shortName> not working"` fits every critical link but one: secure input
    /// *working* is the problem, so the template renders nonsense for it (#94). A
    /// `switch` with a `default`, not a table — this is one exception, and there
    /// are already three per-probe copy catalogs (`ProblemReport.swift:142-145`).
    ///
    /// The notch renders this line plus "Fix it" and nothing else, so it carries
    /// the system-wide fact and hands off; the panel's `.secureInput` row carries
    /// the remedy (and that restarting Lore will not help while it is on).
    var title: String {
        switch probe {
        case .secureInput: return "Secure input is on — no app is receiving keys"
        default: return "\(probe.shortName) not working"
        }
    }
}

/// Debounce for the notch self-summon: a critical failure must persist across
/// `threshold` consecutive health cycles before it summons, so a transient flap
/// (a permission blip while a certificate refreshes) stays silent. It fires once
/// per outage and re-arms only after a clear cycle.
struct SummonDebouncer {
    let threshold: Int
    private var consecutive = 0
    private var fired = false

    init(threshold: Int = 2) {
        self.threshold = max(1, threshold)
    }

    /// Feed one cycle's verdict; returns `true` on the single cycle it should
    /// summon.
    mutating func record(hasCriticalFailure: Bool) -> Bool {
        guard hasCriticalFailure else {
            consecutive = 0
            fired = false
            return false
        }
        consecutive += 1
        guard consecutive >= threshold, !fired else { return false }
        fired = true
        return true
    }
}

/// Owns the live health state: re-probes the cheap chain every cycle so the
/// footer turns red within one cycle of a permission dropping, publishes the
/// snapshot and rendered items for the panel, and raises the notch (debounced)
/// when a critical link fails. Created at launch and kept running even when the
/// window is closed — the "Fn dead" incident happens with no window open.
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
    @ObservationIgnored private var debouncer: SummonDebouncer
    @ObservationIgnored private var timer: Task<Void, Never>?

    /// Fired (debounced) when a critical link fails — wired to the notch.
    @ObservationIgnored var onSummon: (HealthSummon) -> Void = { _ in }

    /// The three expensive "Test now" actions, injected because they reach for
    /// the mic, the model cache and the network. Each records a `DiagEvent`;
    /// `refresh()` afterwards reads the new last-attempt.
    @ObservationIgnored var runMicCaptureTest: () async -> Void = {}
    @ObservationIgnored var runModelWarmupTest: () async -> Void = {}
    @ObservationIgnored var runOpenAITest: () async -> Void = {}

    init(prober: HealthProber, summonThreshold: Int = 2) {
        self.prober = prober
        self.debouncer = SummonDebouncer(threshold: summonThreshold)
        let initial = prober.probe()
        self.snapshot = initial.snapshot
        self.items = initial.items
    }

    /// Begin the periodic cheap-probe cycle. Idempotent.
    func start(interval: Duration = .seconds(5)) {
        guard timer == nil else { return }
        refresh()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { break }
                self.refresh()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Re-run the cheap chain, publish, and evaluate the self-summon.
    func refresh() {
        let report = prober.probe()
        snapshot = report.snapshot
        items = report.items
        let critical = snapshot.criticalFailures
        if debouncer.record(hasCriticalFailure: !critical.isEmpty), let first = critical.first {
            onSummon(HealthSummon(probe: first))
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
