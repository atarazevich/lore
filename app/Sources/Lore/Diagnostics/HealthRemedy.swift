import Foundation

/// A System Settings pane a remedy can deep-link to. The URL is the documented
/// `x-apple.systempreferences:` scheme; the onboarding permission cards
/// (`RequiredGrant.pane`, #150) link through here too.
enum SettingsPane: String, CaseIterable, Equatable, Sendable {
    case accessibility
    case inputMonitoring
    case microphone
    /// "Screen & System Audio Recording" — the pane that gates the Core Audio
    /// process tap (#149). `Privacy_ScreenCapture` is still the anchor macOS
    /// answers to; the pane's *title* gained "& System Audio" in macOS 15, and
    /// the button below uses that title so the user reads what they will see.
    case screenRecording
    /// Not a privacy grant but the same kind of round trip: the Fn-key behaviour
    /// the onboarding step watches lives here (#150).
    case keyboard

    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .keyboard:
            return URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        }
    }

    var buttonLabel: String {
        switch self {
        case .accessibility: return "Open Accessibility"
        case .inputMonitoring: return "Open Input Monitoring"
        case .microphone: return "Open Microphone"
        case .screenRecording: return "Open Screen & System Audio Recording"
        case .keyboard: return "Open Keyboard Settings"
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
    /// Open Finder on a folder the row names (#148). The path is machine-local
    /// and rides on the action, not on the serialized result.
    case revealInFinder(String)

    var buttonLabel: String {
        switch self {
        case .openSettings(let pane): return pane.buttonLabel
        case .restartApp: return "Restart \(LoreTheme.wordmark)"
        case .openLoreSettings: return "Open Settings"
        case .testNow: return "Test now"
        case .revealInFinder: return "Show in Finder"
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

    /// The one procedure that re-binds a TCC grant: macOS keys the grant to the
    /// signature, so toggling off and on reuses the stale binding while removing
    /// and re-adding forces a fresh one. Two rows reach the same dead end — a
    /// measured stale grant on `.tap`, and a signature change on `.signing`
    /// (#135) — and must not drift apart in wording.
    private static let reGrantWalkthrough = "Remove \(LoreTheme.wordmark) from Privacy & Security → Accessibility with the “−” button, do the same under Input Monitoring, quit \(LoreTheme.wordmark), then add it back to both and open it again."

    /// - Parameters:
    ///   - result: the PII-free probe result.
    ///   - secureInputHolder: who the panel may say holds secure input —
    ///     machine-local, shown in the detail line, never serialized (#98).
    ///   - teamID: signing team identifier, shown in the detail line only.
    ///   - secureInputActive: secure input starves the tap, so it is the cause of
    ///     the tap's non-ok state — which under it is `.warning`, never `.failed`
    ///     (#94). The tap remedy points at it instead of offering a useless
    ///     restart. Also set for the `.secureInput` row itself, whose ok copy must
    ///     not read "Inactive" while the flag is up (benign locked console, #98).
    ///   - notesLeftover: the folder the #148 move could not empty and why —
    ///     named in the detail line, revealed by the remedy's button, and the
    ///     cause picks the remedy. Machine-local, never serialized.
    static func describe(
        _ result: HealthResult,
        secureInputHolder: SecureInput.Attribution? = nil,
        teamID: String? = nil,
        secureInputActive: Bool = false,
        notesLeftover: NotesLeftover? = nil
    ) -> HealthItem {
        let (title, detail, remedy) = copy(
            for: result, holder: secureInputHolder, teamID: teamID,
            secureInputActive: secureInputActive, notesLeftover: notesLeftover
        )
        return HealthItem(result: result, title: title, detail: detail, remedy: remedy)
    }

    private static func copy(
        for result: HealthResult,
        holder: SecureInput.Attribution?,
        teamID: String?,
        secureInputActive: Bool,
        notesLeftover: NotesLeftover?
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
                // The identity changed since the last launch (#135, rationale on
                // `SigningIdentityLedger`): the guided re-grant, gated on the
                // *current* cert being a signed one — a build that migrated INTO
                // ad-hoc takes the arm below, whose answer is to reinstall, not
                // to re-grant permissions macOS will drop again next launch.
                if result.signingIdentityChanged == true {
                    return (title,
                            "\(LoreTheme.wordmark)'s signature changed since the last launch — macOS drops permission grants when that happens, even where the toggles still look on.",
                            Remedy(instruction: "\(LoreTheme.wordmark) is signed with a different certificate than last time, and macOS tied its Accessibility and Input Monitoring grants to the old one. \(reGrantWalkthrough) This row clears itself as soon as a keystroke actually reaches \(LoreTheme.wordmark).",
                                   actions: [.openSettings(.accessibility), .openSettings(.inputMonitoring), .restartApp]))
                }
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

        case .diskSpace:
            let free = result.freeDiskGB.map { "\($0) GB free." } ?? "Free space unknown."
            if ok { return ("Disk space", free, nil) }
            return ("Disk space",
                    "Low disk space — \(free) Transcripts and recordings may fail to save.",
                    Remedy(instruction: "Free up disk space; recordings and transcripts need room to save.",
                           actions: []))

        // MARK: Input

        case .accessibility:
            if ok { return ("Accessibility", "Granted — \(LoreTheme.wordmark) can post keystrokes.", nil) }
            return ("Accessibility",
                    "macOS reports Accessibility as off for \(LoreTheme.wordmark). If the toggle looks on, macOS no longer recognizes this build.",
                    Remedy(instruction: "macOS shows \(LoreTheme.wordmark) as enabled but no longer recognizes it. Turn \(LoreTheme.wordmark) off, then on again in Privacy & Security → Accessibility, then restart \(LoreTheme.wordmark).",
                           actions: [.openSettings(.accessibility), .restartApp]))

        case .inputMonitoring:
            if ok { return ("Input Monitoring", "Granted — \(LoreTheme.wordmark) receives the Fn key.", nil) }
            return ("Input Monitoring",
                    "Input Monitoring is off, so the Fn hotkey never reaches \(LoreTheme.wordmark).",
                    Remedy(instruction: "Enable \(LoreTheme.wordmark) under Privacy & Security → Input Monitoring, then restart \(LoreTheme.wordmark).",
                           actions: [.openSettings(.inputMonitoring), .restartApp]))

        case .tap:
            let title = "Keyboard shortcuts"
            if ok {
                let age = result.tapLiveness.map { "last key event \(relativeAge($0.tapSilentSeconds))" }
                    ?? "receiving key events"
                return (title, "Live — \(age).", nil)
            }
            // Secure input starves every tap on the machine by design, so whether
            // *ours* is otherwise healthy cannot be measured while it is on —
            // `TapLiveness.observe` deliberately draws no verdict there (#97). The
            // row says so instead of asserting a conclusion it never drew (#99),
            // and surfaces the cause rather than a restart that cannot help.
            if secureInputActive {
                return (title,
                        "Can't be measured while secure input is on — it starves every app's keyboard tap by design. See Secure input above.",
                        Remedy(instruction: "Secure input is holding the keyboard; that is what stops \(LoreTheme.wordmark)'s shortcuts. Release it (see the Secure input item above) — restarting \(LoreTheme.wordmark) will not help while it is on.",
                               actions: []))
            }
            // A live tap that is starved is the *only* case a restart cannot fix:
            // the session is being given key-downs and we are not. That is a
            // permissions problem *whatever* AXIsProcessTrusted() and
            // CGPreflightListenEventAccess() claim — both read `ok` on the affected
            // machine throughout the incident, which is why the `.accessibility` /
            // `.inputMonitoring` rows above stay green and this row must not defer
            // to them (#97). A tap that is gone (`!isAlive`) takes the arm below
            // even if a starvation was measured too — it is genuinely not
            // installed, and reinstalling it is what a restart does.
            // The evidence line states the direction, not two numbers whose
            // subtraction the reader can get sign-wrong (#99).
            if let liveness = result.tapLiveness, liveness.isStarved == true, liveness.isAlive {
                return (title,
                        "Keystrokes are reaching the Mac but not \(LoreTheme.wordmark) — the Mac's last keystroke was \(silence(liveness.sessionSilentSeconds)) ago, while \(LoreTheme.wordmark)'s tap has been silent for \(silence(liveness.tapSilentSeconds)).",
                        Remedy(instruction: "macOS reports Accessibility and Input Monitoring as granted, yet no keystroke is reaching \(LoreTheme.wordmark) — that is what a stale permission grant looks like, and toggling the switch off and on does not clear it. \(reGrantWalkthrough)",
                               actions: [.openSettings(.accessibility), .openSettings(.inputMonitoring)]))
            }
            return (title,
                    "\(LoreTheme.wordmark)'s keyboard tap isn't installed.",
                    Remedy(instruction: "Restart \(LoreTheme.wordmark) to reinstall the keyboard tap. If it keeps failing, check Input Monitoring above.",
                           actions: [.restartApp, .openSettings(.inputMonitoring)]))

        case .secureInput:
            if ok {
                // `.ok` while the flag is up is the benign locked-console case
                // (#98); claiming "Inactive" there would contradict the tap row,
                // which is gated on the raw flag and says secure input is on.
                return secureInputActive
                    ? ("Secure input", "Active, held by the lock screen — normal while the console is locked.", nil)
                    : ("Secure input", "Inactive — the Fn key isn't being starved.", nil)
            }
            // A misattributed holder gets no name, no pid, and a procedure instead
            // of a target (#98). The panel itself is the bisection instrument:
            // the health loop re-probes every few seconds, so the row clears
            // almost immediately when the real holder quits.
            if holder == .misattributed {
                return ("Secure input",
                        "Secure input is active, held by a process macOS won't name — the recorded holder is a system process that was merely in front when the flag was grabbed. While on, no app — including \(LoreTheme.wordmark) — receives keystrokes.",
                        Remedy(instruction: "Quit likely holders one at a time while watching this panel — this row clears within about 5 seconds of quitting the right one. Prime suspects: Electron and Chromium apps, password managers, and Terminal or iTerm with Secure Keyboard Entry enabled. If nothing clears it, log out or restart the Mac; locking and unlocking the screen does not release it.",
                               actions: []))
            }
            // The pid is a hint, not an identification: macOS records whichever app
            // was frontmost when secure input went on, which per rdar://48953777 is
            // often not the caller. So the copy suggests where to look; it does not
            // accuse a named app of holding the user's keyboard. A CLI or daemon
            // holder has no `NSRunningApplication`, so the pid stands in — and a
            // daemon holding the flag is the case where the user most needs the
            // hint (we hit it live twice) (#92).
            let hintTarget: String? = switch holder {
            case .app(let name): name
            case .process(let pid): "process \(pid)"
            case .misattributed, .nobody, nil: nil
            }
            let hint = hintTarget.map {
                ", and macOS associates it with \($0) — though it names whichever app was in front, which may not be the one responsible"
            } ?? ""
            return ("Secure input",
                    "Secure input is active\(hint). While on, no app — including \(LoreTheme.wordmark) — receives keystrokes.",
                    Remedy(instruction: "A password field or app has locked keyboard input. Close it (or click out of the password field) to release the Fn key.",
                           actions: []))

        // MARK: Audio

        case .microphone:
            if ok { return ("Microphone permission", "Granted.", nil) }
            // `.notDetermined` (#140): nothing is broken — macOS simply hasn't
            // asked yet, and the first recording triggers the prompt.
            if result.status == .warning {
                return ("Microphone permission",
                        "Not requested yet — macOS asks the first time \(LoreTheme.wordmark) records.",
                        nil)
            }
            return ("Microphone permission",
                    "Microphone access is off, so dictation and meetings can't record.",
                    Remedy(instruction: "Enable \(LoreTheme.wordmark) under Privacy & Security → Microphone.",
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

        // MARK: Cleanup & Ask lore

        case .openAIKey:
            if ok { return ("OpenAI key", "Present in Keychain.", nil) }
            return ("OpenAI key",
                    "No OpenAI key is set, so cleanup, translate and Ask \(LoreTheme.wordmark) are unavailable.",
                    Remedy(instruction: "Add your OpenAI API key in Settings to enable cleanup and Ask \(LoreTheme.wordmark).",
                           actions: [.openLoreSettings]))

        // MARK: Meetings

        // Retires with `NotesFolderMigration`: when the one-time move is
        // deleted, this row goes with it.
        case .notesFolder:
            let title = "Notes folder"
            if ok { return (title, "Meeting notes are stored inside \(LoreTheme.wordmark)'s own folder.", nil) }
            // Never phrased as loss: nothing was deleted, and the row withdraws
            // itself once that folder is empty. The cause picks the instruction —
            // an iCloud placeholder is this Mac's only handle on the recording,
            // so that copy never suggests deleting anything.
            let folder = notesLeftover.map { " (\(($0.path as NSString).abbreviatingWithTildeInPath))" } ?? ""
            let instruction = notesLeftover?.hasEvicted == true
                ? "Those files are stored in iCloud and haven't been downloaded to this Mac, so \(LoreTheme.wordmark) left them where they are rather than pulling them down. Open the folder and download them, then move them into the new notes folder — or leave them; nothing else is waiting on it."
                : "\(LoreTheme.wordmark) now keeps meeting notes in its own folder. A few files there had the same name as files already in the new one, so both copies were kept. Move or delete the leftovers and this row clears itself."
            return (title,
                    "Some meeting files couldn't be moved out of your old notes folder\(folder) — they're still there, nothing was deleted.",
                    Remedy(instruction: instruction,
                           actions: notesLeftover.map { [.revealInFinder($0.path)] } ?? []))

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
        let title, okDetail, failDetail, warnDetail: String
        /// What a "Test now" would do to the machine — `nil` for a probe that has
        /// no on-demand test, whose card then offers no button anywhere.
        var sideEffect: String? = nil
        /// A failure with a known cause the panel cannot re-test gets its own
        /// remedy instead of the shared "Test now" (#149).
        var failureRemedy: Remedy? = nil
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
                         sideEffect: "loads the model (~1 GB) if it isn't already in memory — instant if already warm")
        case .openAILiveness:
            return .init(title: "OpenAI reachability", okDetail: "Key accepted",
                         failDetail: "Key rejected (HTTP 401)", warnDetail: "Not checked yet.",
                         sideEffect: "makes a network request")
        case .systemAudio:
            // No sideEffect: observable only during a real meeting, so the card
            // offers no button a press could honour. A failure, though, has one
            // overwhelmingly likely cause and a remedy to act on now (#149).
            return .init(title: "System-audio capture", okDetail: "Last capture succeeded",
                         failDetail: "Last capture failed", warnDetail: "No meeting recorded yet.",
                         failureRemedy: Remedy(
                            instruction: "macOS gates system-audio capture behind Screen & System Audio Recording — a separate grant from the microphone, and the one a fresh install is missing. Enable \(LoreTheme.wordmark) under Privacy & Security → Screen & System Audio Recording, then start the meeting again.",
                            actions: [.openSettings(.screenRecording)]))
        case .signing, .diskSpace, .accessibility, .inputMonitoring,
             .tap, .secureInput, .microphone, .asrModel, .vadModel, .openAIKey,
             .notesFolder:
            preconditionFailure("cheap probe \(id.rawValue) has no expensive labels")
        }
    }

    /// Shared shape for the expensive probes: the panel shows the last real
    /// outcome from the event stream plus a "Test now" that warns about the side
    /// effect. A probe with no `sideEffect` has no on-demand test — systemAudio is
    /// observable only during a real meeting (`HealthMonitor.testNow` has no case
    /// for it), and a button that can't run is not honest. It stays `.expensive`
    /// in cost — the #83 split is unchanged; it simply lacks a test.
    private static func expensiveCopy(_ result: HealthResult) -> (String, String, Remedy?) {
        let labels = expensiveLabels(result.id)
        func remedy(_ lead: String) -> Remedy? {
            labels.sideEffect.map {
                Remedy(instruction: "\(lead) — \($0).", actions: [.testNow(result.id)])
            }
        }
        guard let last = result.lastAttempt else {
            return (labels.title, labels.warnDetail, remedy("Test now"))
        }
        let age = relativeAge(last.ageSeconds)
        // Past the age ceiling (#140) the outcome is history, not a verdict:
        // the card says so instead of staying red or green forever.
        if last.isStale {
            return (labels.title, "Not tested recently — last attempt \(age).", remedy("Test now"))
        }
        switch last.outcome {
        case .ok:
            return (labels.title, "\(labels.okDetail) \(age).", remedy("Re-test"))
        case .unknown:
            return (labels.title, "Inconclusive \(age) — no verdict.", remedy("Test now"))
        case .failed:
            return (labels.title, "\(labels.failDetail) \(age).",
                    labels.failureRemedy ?? remedy("Test now to re-check"))
        }
    }

    /// "34s" / "2 min" — a duration, second-accurate under a minute. The tap row's
    /// evidence lives in the gap between two silences, and the first tick that can
    /// latch a starvation sits at 30–35 s: `relativeAge` would render both sides of
    /// it as "just now" (its whole first minute is one bucket, #88), so the row
    /// would refute itself for the ~30 s in which the user reads it.
    static func silence(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        if seconds < 86400 { return "\(seconds / 3600) h" }
        return "\(seconds / 86400) d"
    }

    /// "4 min ago" / "just now" — coarse, no personal data. "just now" spans the
    /// whole first minute so a successful re-test reads as distinct from the prior
    /// "1 min ago" (#88).
    static func relativeAge(_ seconds: Int) -> String {
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(max(1, seconds / 60)) min ago" }
        if seconds < 86400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86400) d ago"
    }
}
