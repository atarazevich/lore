import AppKit
import ApplicationServices
import CoreGraphics
import FluidAudio
import Foundation

/// Runs the readiness chain's probes and assembles a `HealthSnapshot`.
///
/// **Cheap probes are pure OS queries with no side effect** (design §6): they
/// read a permission flag, a signature, a file's existence — they never open the
/// mic or load a model. **Expensive outcomes are not re-run here**; the last real
/// attempt is read from the `DiagEvent` stream ("last capture 4 min ago, ok"),
/// and a "Test now" button (wired by `HealthMonitor`) triggers the real thing.
///
/// Dependencies are injected as closures rather than reached through singletons,
/// so the engine is testable and so it reuses — never re-creates — the live
/// keyboard tap (`isEventTapAlive` reads `HotkeyManager`'s existing state).
@MainActor
struct HealthProber {
    var isEventTapAlive: () -> Bool
    var isEventTapStalled: () -> Bool
    var hasOpenAIKey: () -> Bool
    var store: DiagStore
    var now: () -> Date

    init(
        isEventTapAlive: @escaping () -> Bool,
        isEventTapStalled: @escaping () -> Bool,
        hasOpenAIKey: @escaping () -> Bool,
        store: DiagStore = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.isEventTapAlive = isEventTapAlive
        self.isEventTapStalled = isEventTapStalled
        self.hasOpenAIKey = hasOpenAIKey
        self.store = store
        self.now = now
    }

    /// A probe result plus the machine-local notes (holder name, signing team)
    /// that render in the panel but must never enter the serialized snapshot.
    private struct Reading {
        let result: HealthResult
        var holderName: String?
        var teamID: String?
    }

    /// The snapshot and the renderable items in one pass — the monitor uses this
    /// so a health cycle probes the OS once, not twice.
    func probe() -> (snapshot: HealthSnapshot, items: [HealthItem]) {
        let readings = readings()
        let snapshot = HealthSnapshot(
            marketingVersion: Self.marketingVersion,
            build: Self.build,
            results: readings.map(\.result)
        )
        // Secure input active is the likeliest CAUSE of a starved tap, so the
        // tap item's remedy points at it rather than at a useless restart.
        let secureInputActive = readings.first { $0.result.id == .secureInput }?.result.status == .failed
        let items = readings.map { reading in
            HealthCatalog.describe(
                reading.result,
                holderName: reading.holderName,
                teamID: reading.teamID,
                secureInputActive: reading.result.id == .tap && secureInputActive
            )
        }
        return (snapshot, items)
    }

    // MARK: - Probes, in chain order

    /// `HealthProbeID.cost` is the single source of truth for the cheap /
    /// expensive split. `countsInFooter` reads the same property, so a probe's
    /// auto-run-at-open verdict and its footer-cry-wolf exclusion cannot drift.
    /// `allCases` is declared in chain order, so this preserves the panel order.
    private func readings() -> [Reading] {
        HealthProbeID.allCases.map { id in
            id.cost == .expensive ? expensiveReading(id) : cheapReading(id)
        }
    }

    /// The cheap OS probes, each with its own read. Exhaustive: a new probe does
    /// not compile until it is placed here or, if `cost == .expensive`, given an
    /// extractor in `expensiveOutcome` (the `preconditionFailure` arm is
    /// unreachable because `readings()` routes expensive ids away by cost).
    private func cheapReading(_ id: HealthProbeID) -> Reading {
        switch id {
        case .signing: return signingReading()
        case .urlScheme: return plain(id, Self.urlSchemeRegistered() ? .ok : .failed)
        case .diskSpace: return diskReading()
        case .accessibility: return plain(id, AXIsProcessTrusted() ? .ok : .failed)
        case .inputMonitoring: return plain(id, CGPreflightListenEventAccess() ? .ok : .failed)
        // Enabled AND flowing. A tap that exists but is starved (secure input,
        // the reported incident) is a failure, not health.
        case .tap: return plain(id, (isEventTapAlive() && !isEventTapStalled()) ? .ok : .failed)
        case .secureInput: return secureInputReading()
        case .microphone: return plain(id, MicrophonePermission.status == .authorized ? .ok : .failed)
        case .asrModel: return plain(id, ParakeetBackend().checkStatus() == .ready ? .ok : .failed)
        case .vadModel: return plain(id, Self.vadModelPresent() ? .ok : .failed)
        case .openAIKey: return plain(id, hasOpenAIKey() ? .ok : .failed)
        case .micCapture, .modelWarmup, .openAILiveness, .systemAudio:
            preconditionFailure("expensive probe \(id.rawValue) routed to cheapReading — check id.cost")
        }
    }

    private func plain(_ id: HealthProbeID, _ status: HealthStatus) -> Reading {
        Reading(result: HealthResult(id: id, status: status))
    }

    private func signingReading() -> Reading {
        let info = SigningIdentity.current()
        let status: HealthStatus
        switch info.certKind {
        case .appleDevelopment, .developerID: status = .ok
        case .adHoc: status = .warning
        case .unknown: status = .warning
        }
        return Reading(
            result: HealthResult(id: .signing, status: status, signingCert: info.certKind),
            teamID: info.teamID
        )
    }

    private func diskReading() -> Reading {
        let gb = Self.freeDiskGB()
        // Below 5 GB the transcript/recording writes start to risk failing.
        let status: HealthStatus = (gb ?? .max) < 5 ? .warning : .ok
        return Reading(result: HealthResult(id: .diskSpace, status: status, freeDiskGB: gb))
    }

    private func secureInputReading() -> Reading {
        // The same reader `HotkeyManager`'s monitor uses, so the panel and the
        // event stream cannot disagree about whether input is withheld (#93).
        let state = SecureInput.read()
        return Reading(
            result: HealthResult(
                id: .secureInput,
                status: state.active ? .failed : .ok,
                secureInputHolderPID: state.pid
            ),
            holderName: state.name
        )
    }

    /// An expensive probe's card is driven entirely by the last real attempt
    /// from the event stream; "never tested" is a `.warning`, not a failure.
    private func expensiveReading(_ id: HealthProbeID) -> Reading {
        let last = Self.expensiveOutcome[id].flatMap(lastAttempt)
        let status: HealthStatus
        switch last?.outcome {
        case .ok: status = .ok
        case .failed: status = .failed
        case .unknown, .none: status = .warning
        }
        return Reading(result: HealthResult(id: id, status: status, lastAttempt: last))
    }

    private func lastAttempt(_ outcomeOf: (DiagEvent) -> DiagEvent.Outcome?) -> HealthLastAttempt? {
        guard let record = store.last(where: { outcomeOf($0.event) != nil }),
              let outcome = outcomeOf(record.event) else { return nil }
        return HealthLastAttempt(outcome: outcome, ageSeconds: max(0, Int(now().timeIntervalSince(record.at))))
    }

    // MARK: - Event → outcome extractors (static: pure, no captured state)

    /// The event-stream extractor for each expensive probe. Its key set **is**
    /// the expensive probes; `HealthProberTests.testExpensiveExtractorSetEqualsCost`
    /// pins it to `{ id where id.cost == .expensive }`, so this table, the
    /// `readings()` cost dispatch, and `countsInFooter` can never disagree.
    /// Internal (not private) so that guard test can read the key set.
    nonisolated static let expensiveOutcome: [HealthProbeID: @Sendable (DiagEvent) -> DiagEvent.Outcome?] = [
        .micCapture: micCaptureOutcome,
        .modelWarmup: modelWarmupOutcome,
        .openAILiveness: openAILivenessOutcome,
        .systemAudio: systemAudioOutcome,
    ]

    nonisolated private static func micCaptureOutcome(_ event: DiagEvent) -> DiagEvent.Outcome? {
        switch event {
        case .captureStart: return .ok
        case .captureFailed, .captureGaveUp: return .failed
        default: return nil
        }
    }

    nonisolated private static func modelWarmupOutcome(_ event: DiagEvent) -> DiagEvent.Outcome? {
        if case .modelLoad(let model, let outcome, _, _) = event, model == .asr { return outcome }
        return nil
    }

    nonisolated private static func openAILivenessOutcome(_ event: DiagEvent) -> DiagEvent.Outcome? {
        if case .apiCall(let endpoint, let outcome, _, _) = event, endpoint == .keyHealth { return outcome }
        return nil
    }

    nonisolated private static func systemAudioOutcome(_ event: DiagEvent) -> DiagEvent.Outcome? {
        if case .systemAudioCapture(let outcome, _) = event { return outcome }
        return nil
    }

    // MARK: - Static cheap reads

    /// `nonisolated` so the PII-free `ProblemReport.Environment` (#84) can read
    /// the same value off the main actor — one bundle-version reader, not two.
    nonisolated static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    nonisolated static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// VAD presence, off FluidAudio's own path and file constants so the two
    /// can't drift from where the library actually downloads the model — the ASR
    /// probe reuses `ParakeetBackend`/`AsrModels` for the same reason.
    private static func vadModelPresent() -> Bool {
        let file = MLModelConfigurationUtils
            .defaultModelsDirectory(for: .vad)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile, isDirectory: true)
        return FileManager.default.fileExists(atPath: file.path)
    }

    private static func freeDiskGB() -> Int? {
        let url = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int(bytes / 1_000_000_000)
    }

    /// True when macOS routes `lore://` to this exact build.
    private static func urlSchemeRegistered() -> Bool {
        guard let url = URL(string: "lore://health"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundle = Bundle(url: handler) else { return false }
        return bundle.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}
