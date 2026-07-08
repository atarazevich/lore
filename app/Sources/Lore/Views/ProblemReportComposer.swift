import Foundation
import Observation

/// The state and logic behind `ProblemReportView`, extracted so the honesty
/// invariant is unit-testable (#84, design §7).
///
/// **The invariant: what the user reviews is byte-for-byte what is sent.** The
/// volatile diagnostic state — a fresh `HealthSnapshot` and the tail of the
/// event stream — is captured exactly once, on `prepare()`, and frozen. Both the
/// preview (raw tab + plain-language summary) and `send()` read the one
/// `report()` built from that capture, so the snapshot and events can never
/// drift between the Raw-data tab and the POST. `send()` never re-probes; a
/// re-capture is an explicit user action (`recapture()`) that visibly re-renders
/// the preview. `ProblemReportComposerTests` pins this against a store that
/// changes underfoot.
@MainActor
@Observable
final class ProblemReportComposer {
    /// The user's free text. Editing it invalidates only the *built* report (so
    /// the message stays live), never the frozen diagnostics.
    var message: String = "" {
        didSet { built = nil }
    }

    private(set) var phase: Phase = .editing

    enum Phase: Equatable {
        case editing
        case sending
        case sent(id: String)
        case failed(message: String)
    }

    @ObservationIgnored private let healthMonitor: HealthMonitor
    @ObservationIgnored private let uploader: ReportUploader
    @ObservationIgnored private let store: DiagStore

    /// The frozen diagnostic capture — one probe, one event-tail read.
    @ObservationIgnored private var frozen: (snapshot: HealthSnapshot, events: [DiagRecord])?
    /// The cached report built from `frozen` + the current message. Both preview
    /// and upload use this identical value.
    @ObservationIgnored private var built: ProblemReport?

    init(
        healthMonitor: HealthMonitor,
        uploader: ReportUploader = ReportUploader(),
        store: DiagStore = .shared
    ) {
        self.healthMonitor = healthMonitor
        self.uploader = uploader
        self.store = store
    }

    /// Freeze the diagnostic state once, when the flow opens. Idempotent: a
    /// second call is a no-op, so it is safe to call from `.onAppear` and from
    /// `report()`'s lazy path. This is the single `refresh()` — the only place
    /// the probes run for this report.
    func prepare() {
        guard frozen == nil else { return }
        healthMonitor.refresh()
        frozen = (healthMonitor.snapshot, store.recent(ProblemReport.eventLimit))
    }

    /// The one report the preview renders and `send()` posts. Built from the
    /// frozen diagnostics and the current message, then cached until the message
    /// changes. Reading it is pure once `prepare()` has run.
    func report() -> ProblemReport {
        if let built { return built }
        prepare()
        let frozen = frozen!  // prepare() guarantees this is set
        let report = ProblemReport(
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            health: frozen.snapshot,
            events: frozen.events,
            environment: .current()
        )
        built = report
        return report
    }

    /// Explicit user re-capture: re-freeze the diagnostics so the preview shows
    /// the current runtime state. Never called implicitly at send time.
    func recapture() {
        frozen = nil
        built = nil
        prepare()
    }

    var canSend: Bool {
        phase != .sending && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Post the cached report. On failure the phase becomes `.failed` and the
    /// cache is kept, so a retry resends the *same* bytes rather than rebuilding.
    func send() async {
        guard phase != .sending else { return }
        let report = report()
        phase = .sending
        do {
            let id = try await uploader.upload(report)
            phase = .sent(id: id)
        } catch let error as ReportUploader.UploadError {
            phase = .failed(message: error.errorDescription ?? Self.genericFailure)
        } catch {
            phase = .failed(message: Self.genericFailure)
        }
    }

    private static let genericFailure = "Couldn't send the report. Please try again."
}
