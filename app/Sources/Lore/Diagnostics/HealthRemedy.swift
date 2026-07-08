import Foundation

/// A System Settings pane a remedy can deep-link to. The URL is the documented
/// `x-apple.systempreferences:` scheme already used by `DictationOnboardingView`.
enum SettingsPane: String, Equatable, Sendable {
    case accessibility
    case inputMonitoring
    case microphone

    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    var buttonLabel: String {
        switch self {
        case .accessibility: return "Open Accessibility"
        case .inputMonitoring: return "Open Input Monitoring"
        case .microphone: return "Open Microphone"
        }
    }
}

/// A concrete action a remedy button performs — a *kind*, not a closure. The
/// view resolves each to a button plus a handler, which keeps the whole
/// status→remedy mapping a pure, unit-tested function and keeps the side effects
/// (opening a URL, relaunching, opening the mic) in the UI layer where they
/// belong.
enum HealthRemedyAction: Equatable, Sendable {
    case openSettings(SettingsPane)
    case restartApp
    case openLoreSettings
    case testNow(HealthProbeID)

    var buttonLabel: String {
        switch self {
        case .openSettings(let pane): return pane.buttonLabel
        case .restartApp: return "Restart Lore"
        case .openLoreSettings: return "Open Settings"
        case .testNow: return "Test now"
        }
    }
}

/// The specific instruction plus buttons for a failing probe; `nil` for a
/// healthy one. Failure-specific per design §6 — Accessibility-false-while-macOS-
/// shows-it-enabled reads differently from never-granted.
struct Remedy: Equatable, Sendable {
    let instruction: String
    let actions: [HealthRemedyAction]
}

/// The human face of a probe result: title, the one-line detail, and the
/// failure-specific remedy. Pure — everything the panel renders derives from the
/// (Codable, PII-free) `HealthResult` plus machine-local notes passed in
/// (a secure-input holder name, a signing team) that never touch the snapshot.
struct HealthItem: Identifiable, Equatable {
    let result: HealthResult
    let title: String
    let detail: String
    let remedy: Remedy?

    var id: HealthProbeID { result.id }
    var status: HealthStatus { result.status }
    var section: HealthSection { result.id.section }
}

/// The pure mapping from a probe result to what the panel shows. This is the
/// heart the tests pin down: every failing probe carries a specific remedy, and
/// the critical ones carry actionable buttons.
enum HealthCatalog {

    /// - Parameters:
    ///   - result: the PII-free probe result.
    ///   - holderName: secure-input holder process name — machine-local, shown
    ///     in the detail line, never serialized.
    ///   - teamID: signing team identifier, shown in the detail line only.
    ///   - secureInputActive: when the `tap` probe is failing *and* secure input
    ///     is active, that is the cause — the tap remedy points at it instead of
    ///     offering a restart that would not help.
    static func describe(
        _ result: HealthResult,
        holderName: String? = nil,
        teamID: String? = nil,
        secureInputActive: Bool = false
    ) -> HealthItem {
        let (title, detail, remedy) = copy(
            for: result, holderName: holderName, teamID: teamID, secureInputActive: secureInputActive
        )
        return HealthItem(result: result, title: title, detail: detail, remedy: remedy)
    }

    private static func copy(
        for result: HealthResult,
        holderName: String?,
        teamID: String?,
        secureInputActive: Bool
    ) -> (title: String, detail: String, remedy: Remedy?) {
        // Expensive probes share one card shape (last outcome + Test now),
        // dispatched by `cost` so a new expensive probe can't land in the cheap
        // switch and silently lose its Test-now affordance (the same single
        // source of truth `readings()` and `countsInFooter` read).
        if result.id.cost == .expensive {
            return expensiveCopy(result)
        }
        let ok = result.status == .ok
        switch result.id {

        // MARK: Install & identity

        case .signing:
            let title = "Code signature"
            switch result.signingCert {
            case .appleDevelopment, .developerID:
                let kind = result.signingCert == .developerID ? "Developer ID" : "Apple Development"
                let team = teamID.map { " (team \($0))" } ?? ""
                return (title, "Signed with \(kind)\(team).", nil)
            case .adHoc, .none:
                return (title,
                        "Ad-hoc signed — macOS resets permissions on every launch. Reinstall a properly signed build.",
                        Remedy(instruction: "This build isn't signed with a developer certificate, so macOS forgets its permission grants each launch. Reinstall the signed release.",
                               actions: []))
            case .unknown:
                return (title, "Signature could not be read.", nil)
            }

        case .urlScheme:
            if ok { return ("Deep links", "lore:// is registered.", nil) }
            return ("Deep links",
                    "The lore:// URL scheme isn't registered to this build; menu-bar and notification deep links won't open.",
                    Remedy(instruction: "Reinstall Lore so macOS re-registers the lore:// scheme.",
                           actions: [.restartApp]))

        case .diskSpace:
            let free = result.freeDiskGB.map { "\($0) GB free." } ?? "Free space unknown."
            if ok { return ("Disk space", free, nil) }
            return ("Disk space",
                    "Low disk space — \(free) Transcripts and recordings may fail to save.",
                    Remedy(instruction: "Free up disk space; recordings and transcripts need room to save.",
                           actions: []))

        // MARK: Input

        case .accessibility:
            if ok { return ("Accessibility", "Granted — Lore can post keystrokes.", nil) }
            return ("Accessibility",
                    "macOS reports Accessibility as off for Lore. If the toggle looks on, macOS no longer recognizes this build.",
                    Remedy(instruction: "macOS shows Lore as enabled but no longer recognizes it. Turn Lore off, then on again in Privacy & Security → Accessibility, then restart Lore.",
                           actions: [.openSettings(.accessibility), .restartApp]))

        case .inputMonitoring:
            if ok { return ("Input Monitoring", "Granted — Lore receives the Fn key.", nil) }
            return ("Input Monitoring",
                    "Input Monitoring is off, so the Fn hotkey never reaches Lore.",
                    Remedy(instruction: "Enable Lore under Privacy & Security → Input Monitoring, then restart Lore.",
                           actions: [.openSettings(.inputMonitoring), .restartApp]))

        case .tap:
            if ok { return ("Keyboard tap", "Live — receiving key events.", nil) }
            // Secure input starves the tap: fixing that unstarves it, so surface
            // the cause rather than a restart that cannot help.
            if secureInputActive {
                return ("Keyboard tap",
                        "The Fn key isn't reaching Lore because secure input is active — see Secure input below.",
                        Remedy(instruction: "Secure input is holding the keyboard; that is what stops the Fn key. Release it (see the Secure input item below) — restarting Lore will not help while it is on.",
                               actions: []))
            }
            return ("Keyboard tap",
                    "The keyboard event tap exists but no key events are flowing.",
                    Remedy(instruction: "Restart Lore to reinstall the keyboard tap. If it keeps failing, check Input Monitoring above.",
                           actions: [.restartApp, .openSettings(.inputMonitoring)]))

        case .secureInput:
            if ok { return ("Secure input", "Inactive — the Fn key isn't being starved.", nil) }
            let holder = holderName.map { " held by \($0)" } ?? ""
            return ("Secure input",
                    "Secure input is active\(holder). While on, no app — including Lore — receives keystrokes.",
                    Remedy(instruction: "A password field or app has locked keyboard input\(holder). Close it (or click out of the password field) to release the Fn key.",
                           actions: []))

        // MARK: Audio

        case .microphone:
            if ok { return ("Microphone permission", "Granted.", nil) }
            return ("Microphone permission",
                    "Microphone access is off, so dictation and meetings can't record.",
                    Remedy(instruction: "Enable Lore under Privacy & Security → Microphone.",
                           actions: [.openSettings(.microphone), .restartApp]))

        // MARK: Transcription

        case .asrModel:
            if ok { return ("Transcription model", "Downloaded and ready.", nil) }
            return ("Transcription model",
                    "The Parakeet model isn't on disk yet.",
                    Remedy(instruction: "The model downloads (~1 GB) on first use. Start a dictation, or warm it up now.",
                           actions: [.testNow(.modelWarmup)]))

        case .vadModel:
            if ok { return ("Voice-activity model", "Downloaded and ready.", nil) }
            return ("Voice-activity model",
                    "The Silero VAD model isn't on disk yet.",
                    Remedy(instruction: "It downloads alongside the transcription model on first use.",
                           actions: [.testNow(.modelWarmup)]))

        // MARK: Cleanup & Ask Lore

        case .openAIKey:
            if ok { return ("OpenAI key", "Present in Keychain.", nil) }
            return ("OpenAI key",
                    "No OpenAI key is set, so cleanup, translate and Ask Lore are unavailable.",
                    Remedy(instruction: "Add your OpenAI API key in Settings to enable cleanup and Ask Lore.",
                           actions: [.openLoreSettings]))

        // Expensive probes are dispatched by cost at the top of `copy`; this arm
        // is unreachable but keeps the switch exhaustive, so a new expensive
        // probe forces a categorization decision here as well.
        case .micCapture, .modelWarmup, .openAILiveness, .systemAudio:
            preconditionFailure("expensive probe \(result.id.rawValue) handled above via cost")
        }
    }

    /// Per-id labels for the expensive-probe card. Exhaustive: a new probe does
    /// not compile until it is given labels here or listed as cheap.
    private struct ExpensiveLabels {
        let title, okDetail, failDetail, warnDetail, sideEffect: String
    }

    private static func expensiveLabels(_ id: HealthProbeID) -> ExpensiveLabels {
        switch id {
        case .micCapture:
            return .init(title: "Mic capture", okDetail: "Last capture succeeded",
                         failDetail: "Last capture failed", warnDetail: "Not tested yet.",
                         sideEffect: "opens the mic (orange dot)")
        case .modelWarmup:
            return .init(title: "Model warm-up", okDetail: "Last load succeeded",
                         failDetail: "Last load failed", warnDetail: "Not warmed up yet.",
                         sideEffect: "loads ~1 GB, takes seconds")
        case .openAILiveness:
            return .init(title: "OpenAI reachability", okDetail: "Key accepted",
                         failDetail: "Key rejected (HTTP 401)", warnDetail: "Not checked yet.",
                         sideEffect: "makes a network request")
        case .systemAudio:
            return .init(title: "System-audio capture", okDetail: "Last capture succeeded",
                         failDetail: "Last capture failed", warnDetail: "No meeting recorded yet.",
                         sideEffect: "requires a meeting recording")
        case .signing, .urlScheme, .diskSpace, .accessibility, .inputMonitoring,
             .tap, .secureInput, .microphone, .asrModel, .vadModel, .openAIKey:
            preconditionFailure("cheap probe \(id.rawValue) has no expensive labels")
        }
    }

    /// Shared shape for the expensive probes: the panel shows the last real
    /// outcome from the event stream plus a "Test now" that warns about the side
    /// effect. Every expensive item keeps a Test-now button so the user can
    /// re-check on demand.
    private static func expensiveCopy(_ result: HealthResult) -> (String, String, Remedy?) {
        let labels = expensiveLabels(result.id)
        let testNow = HealthRemedyAction.testNow(result.id)
        guard let last = result.lastAttempt else {
            return (labels.title, labels.warnDetail,
                    Remedy(instruction: "Test now — \(labels.sideEffect).", actions: [testNow]))
        }
        let age = relativeAge(last.ageSeconds)
        switch last.outcome {
        case .ok:
            return (labels.title, "\(labels.okDetail) \(age).",
                    Remedy(instruction: "Re-test — \(labels.sideEffect).", actions: [testNow]))
        case .unknown:
            return (labels.title, "Inconclusive \(age) — no verdict.",
                    Remedy(instruction: "Test now — \(labels.sideEffect).", actions: [testNow]))
        case .failed:
            return (labels.title, "\(labels.failDetail) \(age).",
                    Remedy(instruction: "Test now to re-check — \(labels.sideEffect).", actions: [testNow]))
        }
    }

    /// "4 min ago" / "just now" — coarse, no personal data.
    static func relativeAge(_ seconds: Int) -> String {
        if seconds < 45 { return "just now" }
        if seconds < 3600 { return "\(max(1, seconds / 60)) min ago" }
        if seconds < 86400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86400) d ago"
    }
}
