import Foundation

/// The exact artifact a "Report a problem" upload sends (#84, design §7): the
/// user's own message plus the diagnostic payload — a fresh `HealthSnapshot`,
/// the last N typed `DiagEvent`s, and a handful of PII-free environment facts.
///
/// **The honesty contract lives in one place.** The report is `Codable` and is
/// serialized through exactly one encoder (`encoded()`). The preview's *Raw
/// data* tab renders those same bytes, and `ReportUploader` posts those same
/// bytes — there is no second serialization that could drift from what the user
/// was shown. `ProblemReportPreviewEqualsPostedTests` pins this.
///
/// **Privacy is by construction, not by review.** Every field except `message`
/// is either the `HealthSnapshot` or the `DiagEvent` stream — both already
/// PII-free by their own type discipline and witnessed by
/// `HealthSnapshotPrivacyTests` / `DiagEventPrivacyTests` — or an `Environment`
/// fact that is a build/machine identifier, never a personal one (`hw.model` is
/// "Mac15,3"; the user-set computer name is never read). `message` is the user's
/// own words, which they chose to send. `ProblemReportPrivacyTests` is the third
/// guardrail on the same promise.
struct ProblemReport: Codable, Sendable, Equatable {
    /// The user's free-text "What happened?". Their own words — the one field
    /// that is deliberately not machine-generated.
    let message: String
    /// A fresh readiness chain (the caller runs `HealthProber` before building).
    let health: HealthSnapshot
    /// The most recent typed events, oldest → newest. See `eventLimit`.
    let events: [DiagRecord]
    /// PII-free machine and build identity.
    let environment: Environment

    /// How many events ride along. 500 is far more than any single incident
    /// needs and keeps the encoded body two orders of magnitude under the
    /// server's 1 MiB cap (measured in `ProblemReportSizeTests`); the ring holds
    /// at most `DiagStore.capacity` (2000) anyway.
    static let eventLimit = 500

    /// The client-side hard ceiling, matched to the receiver's `MAX_BODY_BYTES`
    /// (1 MiB). `ReportUploader` refuses to send a body larger than this rather
    /// than letting the server reject it with a 413.
    static let maxPayloadBytes = 1_048_576

    /// PII-free environment facts (design §7). A model identifier and OS/app
    /// versions identify *the build and the machine class*, never the person.
    /// The versions intentionally repeat `HealthSnapshot`'s (which carries them
    /// for the panel header): this block is the report's self-contained "what
    /// machine" record, read without cross-referencing the snapshot.
    struct Environment: Codable, Sendable, Equatable {
        /// `hw.model`, e.g. "Mac15,3". Not the user-set computer name.
        let macModel: String
        /// e.g. "26.0.0".
        let macOSVersion: String
        /// `CFBundleShortVersionString` — the marketing version (design §9).
        let appVersion: String
        /// `CFBundleVersion` — maps the build to an exact commit (design §9).
        let appBuild: String

        static func current() -> Environment {
            // Versions reuse `HealthProber`'s readers (the single bundle-version
            // source, #83) rather than adding a fourth Info.plist reader.
            Environment(
                macModel: sysctlString("hw.model"),
                macOSVersion: osVersionString,
                appVersion: HealthProber.marketingVersion,
                appBuild: HealthProber.build
            )
        }

        private static func sysctlString(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
            return String(cString: buffer)
        }

        private static var osVersionString: String {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }
    }

    /// Assemble a report from a snapshot the caller has already probed plus the
    /// tail of the event stream. Pure and side-effect free — it never touches the
    /// mic or the model — so the privacy and size tests can build one directly.
    static func build(
        message: String,
        health: HealthSnapshot,
        store: DiagStore = .shared,
        eventLimit: Int = eventLimit
    ) -> ProblemReport {
        ProblemReport(
            message: message,
            health: health,
            events: store.recent(eventLimit),
            environment: .current()
        )
    }

    /// The one serialization. Both the preview and the uploader call this — the
    /// bytes the user sees are the bytes on the wire. Pretty-printed and
    /// key-sorted so the *Raw data* tab is legible and the output is
    /// deterministic (the equality tests depend on it); the receiver stores the
    /// body verbatim, so pretty JSON is exactly what lands on disk.
    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

// MARK: - "What this means" plain-language summary

/// The report preview's *What this means* tab (design §7): the health snapshot
/// rendered as plain sentences, so the user reads a diagnosis, not a probe
/// table. Pure — `ProblemReportSummaryTests` maps snapshot states to sentences.
enum ProblemReportSummary {
    /// One sentence per real issue, in chain order; a single reassuring line
    /// when nothing is wrong.
    static func lines(for snapshot: HealthSnapshot) -> [String] {
        let issues = snapshot.results
            .sorted { HealthProbeID.order($0.id) < HealthProbeID.order($1.id) }
            .compactMap(\.plainLanguageIssue)
        return issues.isEmpty
            ? ["All checks pass — input, audio, transcription and cleanup are working."]
            : issues
    }
}

extension HealthResult {
    /// A plain-language sentence for the summary, or `nil` when this link is not
    /// a real issue. "Real issue" is `HealthSummary.countsInFooter` — the same
    /// rule the footer uses, so an expensive probe that was simply never run
    /// (a `.warning` meaning "not tested") never reads as a problem here either.
    ///
    /// This is the third per-probe copy catalog, each a distinct register:
    /// `HealthProbeID.shortName` (footer/notch label), `HealthCatalog` (the
    /// panel's title + remedy), and this (a user-facing diagnosis sentence). The
    /// `switch id` below is exhaustive with no `default`, so adding a probe forces
    /// a sentence here at compile time — but the other two must be updated too.
    var plainLanguageIssue: String? {
        guard HealthSummary.countsInFooter(self) else { return nil }
        switch id {
        case .signing: return "The app isn't signed with a recognized certificate."
        case .urlScheme: return "Deep links (lore://) aren't registered with macOS."
        case .diskSpace: return "Free disk space is low."
        case .accessibility: return "Accessibility permission isn't granted — the Fn key can't insert text."
        case .inputMonitoring: return "Input Monitoring permission isn't granted — the hotkey can't be seen."
        case .tap: return "Lore's shortcuts aren't reaching it while other apps are focused (the event tap is dead or starved)."
        case .secureInput: return "Secure input is active, blocking the hotkey."
        case .microphone: return "Microphone permission isn't granted."
        case .micCapture: return "The last microphone capture failed."
        case .asrModel: return "The transcription model isn't installed."
        case .vadModel: return "The voice-activity model isn't installed."
        case .modelWarmup: return "The last model warm-up failed."
        case .openAIKey: return "No OpenAI key is set — cleanup, translation and Ask Lore are off."
        case .openAILiveness: return "The last OpenAI check failed."
        case .systemAudio: return "The last system-audio capture failed."
        }
    }
}
