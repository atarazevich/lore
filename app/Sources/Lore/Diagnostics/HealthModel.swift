import Foundation

/// One probe's verdict. Three-valued on purpose: `warning` is "works but
/// degraded" (low disk, an expensive probe never tested), distinct from
/// `failed` (the link is dead). Mirrors `DiagEvent.Outcome`'s refusal to
/// collapse "no verdict" into "broken".
enum HealthStatus: String, Codable, Sendable, CaseIterable {
    case ok
    case warning
    case failed
}

/// The readiness chain, top to bottom. Lower sections are meaningless when an
/// upper one fails, so the panel renders in this order (design §6).
enum HealthSection: String, Codable, Sendable, CaseIterable {
    case installIdentity
    case input
    case audio
    case transcription
    case cleanup
    case meetings

    /// Section heading in the panel.
    var title: String {
        switch self {
        case .installIdentity: return "Install & identity"
        case .input: return "Input"
        case .audio: return "Audio"
        case .transcription: return "Transcription"
        case .cleanup: return "Cleanup & Ask \(LoreTheme.wordmark)"
        case .meetings: return "Meetings"
        }
    }
}

/// Cost of running a probe (design §6). `cheap` probes are pure OS queries with
/// no side effect — run at launch, on panel open, and after a failed user
/// action (#140; the 5 s cycle is gone). `expensive` probes open the mic, load
/// ~1 GB, or hit the network, so they run only on an explicit "Test now";
/// between presses the panel shows the last real outcome pulled from the
/// `DiagEvent` stream.
enum HealthCost: String, Codable, Sendable {
    case cheap
    case expensive
}

/// Every link in the readiness chain. `String`-raw + `CaseIterable` so the
/// snapshot is PII-free by the same discipline as `DiagEvent`, so the footer
/// can order issues by chain position, and so tests enumerate them.
///
/// Declaration order **is** chain order (used by `HealthSummary` to name the
/// most upstream issue): a failed upper link makes the lower ones meaningless.
enum HealthProbeID: String, Codable, Sendable, CaseIterable {
    // Install & identity. `.urlScheme` was deleted in #140: deep links are a
    // convenience, not a readiness link, and the probe re-ran an
    // NSWorkspace/LaunchServices query every cycle for a row nobody acted on.
    case signing
    case diskSpace
    // Input. Secure input sits above the tap: while it is on, the tap's verdict is
    // unmeasurable and its failure is a symptom — the upper link makes the lower
    // one meaningless, which is what this order is for (#94).
    case accessibility
    case inputMonitoring
    case secureInput
    case tap
    // Audio
    case microphone
    case micCapture
    // Transcription
    case asrModel
    case vadModel
    case modelWarmup
    // Cleanup & Ask Lore
    case openAIKey
    case openAILiveness
    // Meetings
    case systemAudio

    var section: HealthSection {
        switch self {
        case .signing, .diskSpace: return .installIdentity
        case .accessibility, .inputMonitoring, .secureInput, .tap: return .input
        case .microphone, .micCapture: return .audio
        case .asrModel, .vadModel, .modelWarmup: return .transcription
        case .openAIKey, .openAILiveness: return .cleanup
        case .systemAudio: return .meetings
        }
    }

    var cost: HealthCost {
        switch self {
        case .micCapture, .modelWarmup, .openAILiveness, .systemAudio: return .expensive
        default: return .cheap
        }
    }

    /// A failure here means the core hold-to-talk loop is dead. Since #140 this
    /// no longer summons anything — summons fire only from failed user actions
    /// (`HealthMonitor.noteFailure`) — it drives the footer's red-vs-amber dot
    /// via `HealthSnapshot.criticalFailures`.
    ///
    /// #83 excluded `.secureInput` as a curiosity; report 8763HGZT showed a
    /// system-wide outage, so it joined the set (#94).
    var isCritical: Bool {
        switch self {
        case .accessibility, .inputMonitoring, .tap, .secureInput, .microphone: return true
        default: return false
        }
    }

    /// Short label for the footer's "1 issue — <name>" and the notch message.
    ///
    /// `.tap` was "Fn key" until #97, which is the lie at the root of the whole
    /// complaint: Fn hold-to-talk runs entirely on the NSEvent monitors, and the
    /// tap carries only the keys Lore intercepts while another app is focused
    /// (Space to lock, Esc to discard, Fn+V/T — `HotkeyManager.installEventTap`).
    /// The probe could never answer for the Fn key, yet spoke in its name — so it
    /// told a user whose Fn key demonstrably worked that it did not. Every fix
    /// before this one plumbed around the name instead of correcting it.
    var shortName: String {
        switch self {
        case .signing: return "Signing"
        case .diskSpace: return "Disk space"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .tap: return "Keyboard shortcuts"
        case .secureInput: return "Secure input"
        case .microphone: return "Microphone"
        case .micCapture: return "Mic capture"
        case .asrModel: return "Model"
        case .vadModel: return "Voice model"
        case .modelWarmup: return "Model warm-up"
        case .openAIKey: return "OpenAI key"
        case .openAILiveness: return "OpenAI"
        case .systemAudio: return "System audio"
        }
    }
}

/// The signing certificate class of the running binary, surfaced so a remote
/// user's build is unambiguous (free Apple Development vs Developer ID vs
/// ad-hoc). Not PII — it identifies the build, not the user (design §9).
enum SigningCertKind: String, Codable, Sendable {
    case appleDevelopment
    case developerID
    case adHoc
    case unknown
}

/// The last real outcome of an expensive probe, read from the `DiagEvent`
/// stream — "last capture 4 min ago, ok" — so the panel shows it without
/// re-running the side effect.
struct HealthLastAttempt: Codable, Sendable, Equatable {
    let outcome: DiagEvent.Outcome
    let ageSeconds: Int

    /// The age ceiling (#140): a day-old outcome — a 401 from last week, a
    /// captureFailed from before a reboot — is history, not a verdict. Past it
    /// the row reads "not tested recently" instead of staying red (or green)
    /// forever.
    var isStale: Bool { ageSeconds > Self.maxFreshAgeSeconds }
    static let maxFreshAgeSeconds = 24 * 3600
}

/// One probe result. Codable and PII-free **by construction**: every field is
/// an enum, a number or a Bool — the guarantee `DiagEvent` makes (design §4),
/// asserted for this type by `HealthSnapshotPrivacyTests`. A holder *pid* is
/// diagnostic (`DiagEvent.secureInputChanged` already carries it); a holder
/// *name* is machine-local and never enters here — it lives only on the runtime
/// `HealthItem.detail`, which is not serialized.
struct HealthResult: Codable, Sendable, Equatable {
    let id: HealthProbeID
    let status: HealthStatus
    var secureInputHolderPID: Int32? = nil
    var signingCert: SigningCertKind? = nil
    /// `.signing` only: the identity differs from the one seen at the previous
    /// launch (#135, rationale on `SigningIdentityLedger`). Rides only when true
    /// (the tri-state discipline `isStarved` set), a Bool, so the PII guarantee
    /// holds unchanged.
    var signingIdentityChanged: Bool? = nil
    var freeDiskGB: Int? = nil
    var lastAttempt: HealthLastAttempt? = nil
    /// `.tap` only: the evidence its verdict was derived from, so a report's reader
    /// can re-derive the conclusion instead of trusting it (#97). Bools and counts,
    /// so the guarantee above holds unchanged.
    var tapLiveness: TapLiveness? = nil
}

/// The whole chain plus the machine's identity. This is exactly what #84's
/// report serializes, so it is `Codable` and carries no PII by the same
/// discipline as `DiagEvent` — `HealthSnapshotPrivacyTests` is the witness.
struct HealthSnapshot: Codable, Sendable, Equatable {
    /// `CFBundleShortVersionString` — the human-facing marketing version (2.0.1).
    let marketingVersion: String
    /// `CFBundleVersion` — `MAJOR.MINOR.<git commit count>`; "the machine is the
    /// record" (design §9). A reviewer flagged this appears nowhere in the UI;
    /// the panel header now surfaces it beside the marketing version.
    let build: String
    let results: [HealthResult]

    /// Critical links (design §6) that are failing, in chain order — what turns
    /// the footer dot red (no longer a summon input, #140).
    var criticalFailures: [HealthProbeID] {
        results
            .filter { $0.status == .failed && $0.id.isCritical }
            .sorted { HealthProbeID.order($0.id) < HealthProbeID.order($1.id) }
            .map(\.id)
    }
}

extension HealthProbeID {
    /// Chain position, from declaration order. Used to name the most upstream
    /// issue and to sort critical failures.
    static func order(_ id: HealthProbeID) -> Int {
        allCases.firstIndex(of: id) ?? Int.max
    }
}

/// The sidebar footer's one-line health readout (design §6): a dot colour plus
/// "All systems ready" or "N issues — <first issue>". The named issue is the
/// most upstream one in chain order — the link worth fixing first.
struct HealthSummary: Equatable {
    let issueCount: Int
    let hasCriticalFailure: Bool
    let firstIssueShortName: String?

    init(_ snapshot: HealthSnapshot) {
        let issues = snapshot.results
            .filter(Self.countsInFooter)
            .sorted { HealthProbeID.order($0.id) < HealthProbeID.order($1.id) }
        issueCount = issues.count
        // One definition of "critical failure", shared with the notch summon.
        hasCriticalFailure = !snapshot.criticalFailures.isEmpty
        firstIssueShortName = issues.first?.id.shortName
    }

    /// A footer issue is any `.failed`, plus a `.warning` that means real
    /// degradation (low disk, an ad-hoc signature). A `.warning` meaning "no
    /// verdict" never counts — it stays visible inside the panel, but the
    /// always-visible footer would cry wolf. Two probes mean "no verdict":
    ///
    /// - Any *expensive* probe: `.warning` is "not tested yet" or "not tested
    ///   recently" (the #140 age ceiling). Otherwise a dictation-only user, whose
    ///   System audio and OpenAI liveness are never exercised, could never reach
    ///   "All systems ready" (the cry-wolf inversion).
    /// - `.tap`: `tapStatus()` returns `.warning` for the two silence-shaped
    ///   states — unmeasurable under secure input (#94), and a measured
    ///   starvation, demoted from `.failed` in #140 because it is inferred from
    ///   keyboard silence, not from a failed action. Neither is footer material:
    ///   the always-visible footer would cry wolf on every idle machine.
    ///
    /// - `.microphone`: `.warning` is `.notDetermined` — macOS was never asked
    ///   (#140). A fresh install is not an issue; the first recording prompts.
    ///
    /// A real recorded failure still lands as `.failed` and counts.
    static func countsInFooter(_ result: HealthResult) -> Bool {
        switch result.status {
        case .ok: return false
        case .failed: return true
        case .warning: return result.id.cost == .cheap && ![.tap, .microphone].contains(result.id)
        }
    }

    /// The dot's status: red on a critical failure, amber on any other issue,
    /// green when clear. Drives the shared `HealthStatusDot`.
    var status: HealthStatus {
        if hasCriticalFailure { return .failed }
        if issueCount > 0 { return .warning }
        return .ok
    }

    var text: String {
        guard issueCount > 0, let name = firstIssueShortName else {
            return "All systems ready"
        }
        let noun = issueCount == 1 ? "issue" : "issues"
        return "\(issueCount) \(noun) — \(name)"
    }
}
