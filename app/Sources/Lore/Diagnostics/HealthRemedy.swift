import AppKit
import Foundation
import LoreCore

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
    /// Privacy & Security › Files & Folders, where lore's iCloud Drive access
    /// lives (#309). The anchor is in macOS 27's Privacy & Security extension.
    case filesAndFolders

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
        case .filesAndFolders:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        }
    }

    /// The one line that opens a pane, wherever the offer is made (#209): the
    /// health panel's remedy button and the bubble's paste-failed face go to the
    /// same place by the same route. Only the opening lives here — which pane a
    /// failure deserves is still decided by a pure mapping (`HealthRemedyAction`,
    /// `DictationFace`) that this never reaches back into.
    @MainActor func open() {
        guard let url = settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    var buttonLabel: String {
        switch self {
        case .accessibility: return "Open Accessibility"
        case .inputMonitoring: return "Open Input Monitoring"
        case .microphone: return "Open Microphone"
        case .screenRecording: return "Open Screen & System Audio Recording"
        case .keyboard: return "Open Keyboard Settings"
        case .filesAndFolders: return "Open System Settings"
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
    /// Remove lore's own Accessibility and Input Monitoring entries and ask
    /// macOS again (#338). The one primary action of the panel, the popover
    /// and the bubble's blocked-paste face, under one name.
    case fixPermissions

    var buttonLabel: String {
        switch self {
        case .openSettings(let pane): return pane.buttonLabel
        case .restartApp: return "Restart \(LoreBrand.wordmark)"
        case .openLoreSettings: return "Open Settings"
        case .testNow: return "Test now"
        case .revealInFinder: return "Show in Finder"
        case .fixPermissions: return "Fix permissions"
        }
    }
}

/// The specific instruction plus buttons for a failing probe; `nil` for a
/// healthy one. Failure-specific per design §6 — Accessibility-false-while-macOS-
/// shows-it-enabled reads differently from never-granted.
struct Remedy: Equatable, Sendable {
    let instruction: String
    var actions: [HealthRemedyAction] = []
    /// The same fix done by hand, behind a "Do it by hand" disclosure (#338) —
    /// for whoever prefers to do it themselves. Empty for every other remedy.
    var manualSteps: [String] = []
    /// A hedged hint at why, drawn faint above the instruction (#341: "Probably
    /// caused by Terminal."). `nil` for every remedy that has none.
    var cause: String? = nil

    /// The disclosure's label, in the board's copy table.
    static let manualStepsLabel = "Do it by hand"
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
    /// The blocked condition explains this row (#338): it reads neutral and
    /// points at the Accessibility row instead of counting as its own issue.
    var isDependent = false

    var id: HealthProbeID { result.id }
    var status: HealthStatus { result.status }
    var section: HealthSection { result.id.section }
}

/// The lore keys that cannot work while another app holds secure input
/// (#346): everything else arrives as a system hot key then. Machine-local,
/// never serialized.
struct DeadShortcuts: Equatable, Sendable {
    /// The talk key is a recorded key that is not a modifier: only the tap
    /// reads it, so hold-to-talk is dead.
    var talkKey = false
    /// Hot keys lore wanted and the system refused (another app holds the
    /// same combination), as Settings prints them.
    var keys: [String] = []

    var isEmpty: Bool { !talkKey && keys.isEmpty }
}

/// The pure mapping from a probe result to what the panel shows. This is the
/// heart the tests pin down: every failing probe carries a specific remedy, and
/// the critical ones carry actionable buttons.
enum HealthCatalog {

    /// The blocked condition's copy (#338), byte-identical to the board's copy
    /// table (`untrusted-after-reinstall.html`). The popover's hint and the
    /// Accessibility row's line are one sentence, so they are one constant.
    static let blockedDetail = "Blocked by macOS."
    static let blockedHint = "The switches in System Settings look on, but macOS kept an old permission."

    /// The one procedure that re-binds a stale TCC grant, by hand: macOS keys
    /// the grant to the signature, so toggling off and on reuses the stale
    /// binding while removing and re-adding forces a fresh one. Every row that
    /// reaches that dead end — the blocked condition (#338), a measured stale
    /// grant on `.tap`, a signature change on `.signing` (#135), a failed paste
    /// — shows these steps behind "Do it by hand", and all but the paste offer
    /// Fix permissions, which does the same thing.
    static let staleGrantSteps = [
        "In System Settings \u{2192} Privacy & Security \u{2192} Accessibility, select \(LoreBrand.wordmark) and click \u{2212}.",
        "Do the same under Input Monitoring.",
        "Add \(LoreBrand.wordmark) back to both with +.",
    ]
    static let seeAccessibility = "See Accessibility."
    static let pasteBlockedSeeAccessibility = "Last paste was blocked \u{2014} see Accessibility."
    static let nothingPastedSinceFix = "Nothing pasted since the fix."

    // MARK: Keyboard shortcuts under secure input (#341, #342)

    /// The row's detail while another app holds secure input and a lore key
    /// truly cannot work (#346, board `secure-input.html` v5): the talk key,
    /// and the keys named as Settings prints them. The one place it lives.
    static func shortcutsOffDetail(_ dead: DeadShortcuts) -> String {
        let subjects = (dead.talkKey ? ["Your talk key"] : []) + dead.keys
        let list = subjects.count <= 1
            ? subjects.joined()
            : subjects.dropLast().joined(separator: ", ") + " and " + subjects.last!
        return list + (subjects.count == 1 ? " doesn't work right now." : " don't work right now.")
    }

    static let unknownHolderStep = "Close the password field or password manager. Still not working? Turn off Secure Keyboard Entry in Terminal or iTerm2."
    static let unknownHolderCause = "Probably caused by a password field or password manager."

    /// What the row says about who probably holds secure input and how to turn
    /// it off. The holder is a hint (rdar://48953777), so every cause is
    /// "Probably"; with nothing to go on, every likely cause is one step.
    static func secureInputRemedy(_ holder: SecureInput.Attribution?) -> Remedy {
        switch holder {
        case .terminal(let name):
            return Remedy(instruction: "Turn off Secure Keyboard Entry in the \(name) menu.",
                          cause: "Probably caused by \(name).")
        case .app(let name):
            return Remedy(instruction: "Click out of the password field in \(name), or quit \(name).",
                          cause: "Probably caused by \(name).")
        case .process:
            return Remedy(instruction: unknownHolderStep, cause: "Probably caused by a background process.")
        case .lockScreen:
            return Remedy(instruction: "Lock and unlock the Mac (Control-Command-Q). Still not working? Restart the Mac.",
                          cause: "Probably caused by the lock screen.")
        case .nobody, nil:
            return Remedy(instruction: unknownHolderStep, cause: unknownHolderCause)
        }
    }

    /// - Parameters:
    ///   - result: the PII-free probe result.
    ///   - secureInputHolder: who the panel may say holds secure input —
    ///     machine-local, shown in the cause line, never serialized (#98).
    ///   - teamID: signing team identifier, shown in the detail line only.
    ///   - notesLeftover: the folder the #148 move could not empty and why —
    ///     named in the detail line, revealed by the remedy's button, and the
    ///     cause picks the remedy. Machine-local, never serialized.
    ///   - deadShortcuts: the lore keys secure input stops (#346), which the
    ///     row that carries secure input names.
    static func describe(
        _ result: HealthResult,
        secureInputHolder: SecureInput.Attribution? = nil,
        teamID: String? = nil,
        notesLeftover: NotesLeftover? = nil,
        deadShortcuts: DeadShortcuts = DeadShortcuts()
    ) -> HealthItem {
        let (title, detail, remedy) = copy(
            for: result, holder: secureInputHolder, teamID: teamID,
            notesLeftover: notesLeftover, deadShortcuts: deadShortcuts
        )
        // The block explains this row (#338): neutral, pointing at Accessibility,
        // so one cause reads as one issue.
        if result.blockedByMacOS == true, HealthProbeID.explainedByTheBlock.contains(result.id) {
            let pointer = result.pasteNote == .blocked ? pasteBlockedSeeAccessibility : seeAccessibility
            return HealthItem(result: result, title: title, detail: pointer, remedy: nil, isDependent: true)
        }
        return HealthItem(result: result, title: title, detail: detail, remedy: remedy)
    }

    private static func copy(
        for result: HealthResult,
        holder: SecureInput.Attribution?,
        teamID: String?,
        notesLeftover: NotesLeftover?,
        deadShortcuts: DeadShortcuts
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
                            "\(LoreBrand.wordmark)'s signature changed since the last launch — macOS drops permission grants when that happens, even where the toggles still look on.",
                            Remedy(instruction: "\(LoreBrand.wordmark) is signed with a different certificate than last time, and macOS tied its Accessibility and Input Monitoring grants to the old one. This row clears itself as soon as a keystroke actually reaches \(LoreBrand.wordmark).",
                                   actions: [.fixPermissions, .restartApp], manualSteps: staleGrantSteps))
                }
                let kind = result.signingCert == .developerID ? "Developer ID" : "Apple Development"
                let team = teamID.map { " (team \($0))" } ?? ""
                return (title, "Signed with \(kind)\(team).", nil)
            case .adHoc, .none:
                return (title,
                        "Ad-hoc signed — macOS resets permissions on every launch. Reinstall a properly signed build.",
                        Remedy(instruction: "This build isn't signed with a developer certificate, so macOS forgets its permission grants each launch. Reinstall the signed release."))
            case .unknown:
                return (title, "Signature could not be read.", nil)
            }

        case .diskSpace:
            let free = result.freeDiskGB.map { "\($0) GB free." } ?? "Free space unknown."
            if ok { return ("Disk space", free, nil) }
            return ("Disk space",
                    "Low disk space — \(free) Transcripts and recordings may fail to save.",
                    Remedy(instruction: "Free up disk space; recordings and transcripts need room to save."))

        // MARK: Input

        case .accessibility:
            if ok { return ("Accessibility", "Granted — \(LoreBrand.wordmark) can post keystrokes.", nil) }
            // Turning the switch off and on is the step that fails (#338): macOS
            // keeps the old entry. Removing it and asking again is the fix.
            return ("Accessibility", blockedDetail,
                    Remedy(instruction: blockedHint, actions: [.fixPermissions], manualSteps: staleGrantSteps))

        case .inputMonitoring:
            if ok { return ("Input Monitoring", "Granted — \(LoreBrand.wordmark) receives the Fn key.", nil) }
            return ("Input Monitoring",
                    "Input Monitoring is off, so the Fn hotkey never reaches \(LoreBrand.wordmark).",
                    Remedy(instruction: "Enable \(LoreBrand.wordmark) under Privacy & Security → Input Monitoring, then restart \(LoreBrand.wordmark).",
                           actions: [.openSettings(.inputMonitoring), .restartApp]))

        case .tap:
            let title = "Keyboard shortcuts"
            if ok {
                let age = result.tapLiveness.map { "last key event \(relativeAge($0.tapSilentSeconds))" }
                    ?? "receiving key events"
                return (title, "Live — \(age).", nil)
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
                        "Keystrokes are reaching the Mac but not \(LoreBrand.wordmark) — the Mac's last keystroke was \(silence(liveness.sessionSilentSeconds)) ago, while \(LoreBrand.wordmark)'s tap has been silent for \(silence(liveness.tapSilentSeconds)).",
                        Remedy(instruction: "macOS reports Accessibility and Input Monitoring as granted, yet no keystroke is reaching \(LoreBrand.wordmark) — that is what a stale permission grant looks like, and toggling the switch off and on does not clear it.",
                               actions: [.fixPermissions], manualSteps: staleGrantSteps))
            }
            return (title,
                    "\(LoreBrand.wordmark)'s keyboard tap isn't installed.",
                    Remedy(instruction: "Restart \(LoreBrand.wordmark) to reinstall the keyboard tap. If it keeps failing, check Input Monitoring above.",
                           actions: [.restartApp, .openSettings(.inputMonitoring)]))

        case .secureInput:
            // Shown only as a problem (#346, `HealthProber.probe`): while another
            // app holds secure input and a lore key truly cannot work. The row
            // takes the name of what stopped and carries the whole condition —
            // which keys, who probably caused it, how to turn it off (#341). The
            // tap row is not shown then: its verdict cannot be measured under
            // secure input (#97). No restart is offered; it cannot help.
            if ok { return ("Keyboard shortcuts", "", nil) }
            return ("Keyboard shortcuts", shortcutsOffDetail(deadShortcuts), secureInputRemedy(holder))

        // MARK: Audio

        case .microphone:
            if ok { return ("Microphone permission", "Granted.", nil) }
            // `.notDetermined` (#140): nothing is broken — macOS simply hasn't
            // asked yet, and the first recording triggers the prompt.
            if result.status == .warning {
                return ("Microphone permission",
                        "Not requested yet — macOS asks the first time \(LoreBrand.wordmark) records.",
                        nil)
            }
            return ("Microphone permission",
                    "Microphone access is off, so dictation and meetings can't record.",
                    Remedy(instruction: "Enable \(LoreBrand.wordmark) under Privacy & Security → Microphone.",
                           actions: [.openSettings(.microphone), .restartApp]))

        // MARK: Transcription

        case .asrModel:
            if ok { return ("Transcription model", "Downloaded and ready.", nil) }
            return ("Transcription model",
                    "The speech model isn't on disk yet.",
                    Remedy(instruction: "The model downloads (~630 MB) on first use. Start a dictation, or warm it up now.",
                           actions: [.testNow(.modelWarmup)]))

        case .vadModel:
            if ok { return ("Voice-activity model", "Downloaded and ready.", nil) }
            return ("Voice-activity model",
                    result.status == .failed
                        ? "The voice-activity model couldn't be loaded."
                        : "Not downloaded yet. Only meetings and file transcription use it.",
                    Remedy(instruction: result.status == .failed
                               ? "It loads again with the next meeting or file transcription, or now."
                               : "It downloads (about 1 MB) with the first meeting or file transcription, or now.",
                           actions: [.testNow(.vadModel)]))

        // MARK: Cleanup & Ask lore

        case .openAIKey:
            if ok { return ("OpenAI key", "Present in Keychain.", nil) }
            return ("OpenAI key",
                    "No OpenAI key is set, so cleanup, translate and Ask \(LoreBrand.wordmark) are unavailable.",
                    Remedy(instruction: "Add your OpenAI API key in Settings to enable cleanup and Ask \(LoreBrand.wordmark).",
                           actions: [.openLoreSettings]))

        // MARK: Meetings

        // Retires with `NotesFolderMigration`: when the one-time move is
        // deleted, this row goes with it.
        case .notesFolder:
            let title = "Notes folder"
            if ok { return (title, "Meeting notes are stored inside \(LoreBrand.wordmark)'s own folder.", nil) }
            // Never phrased as loss: nothing was deleted, and the row withdraws
            // itself once that folder is empty. The cause picks the instruction —
            // an iCloud placeholder is this Mac's only handle on the recording,
            // so that copy never suggests deleting anything.
            let folder = notesLeftover.map { " (\(($0.path as NSString).abbreviatingWithTildeInPath))" } ?? ""
            let instruction = notesLeftover?.hasEvicted == true
                ? "Those files are stored in iCloud and haven't been downloaded to this Mac, so \(LoreBrand.wordmark) left them where they are rather than pulling them down. Open the folder and download them, then move them into the new notes folder — or leave them; nothing else is waiting on it."
                : "\(LoreBrand.wordmark) now keeps meeting notes in its own folder. A few files there had the same name as files already in the new one, so both copies were kept. Move or delete the leftovers and this row clears itself."
            return (title,
                    "Some meeting files couldn't be moved out of your old notes folder\(folder) — they're still there, nothing was deleted.",
                    Remedy(instruction: instruction,
                           actions: notesLeftover.map { [.revealInFinder($0.path)] } ?? []))

        // Expensive probes are dispatched by cost at the top of `copy`; this arm
        // is unreachable but keeps the switch exhaustive, so a new expensive
        // probe forces a categorization decision here as well.
        case .micCapture, .modelWarmup, .openAILiveness, .systemAudio, .paste:
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
                         sideEffect: "loads the model (~630 MB) if it isn't already in memory — instant if already warm")
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
                            instruction: "macOS gates system-audio capture behind Screen & System Audio Recording — a separate grant from the microphone, and the one a fresh install is missing. Enable \(LoreBrand.wordmark) under Privacy & Security → Screen & System Audio Recording, then start the meeting again.",
                            actions: [.openSettings(.screenRecording)]))
        case .paste:
            // No sideEffect: a synthetic Cmd+V into whatever happens to be
            // focused is not something a diagnostics panel may do on a button
            // press. A failure has one overwhelmingly likely cause — the
            // Accessibility grant the post needs — and the pasted text is still
            // on the clipboard, which is the part the user can act on now.
            return .init(title: "Paste", okDetail: "Last paste posted its keystrokes",
                         failDetail: "Last paste posted nothing",
                         warnDetail: "Nothing pasted yet.",
                         failureRemedy: Remedy(
                            instruction: "\(LoreBrand.wordmark) pastes by posting Cmd+V, which macOS allows only with Accessibility. Your text is still on the clipboard — press Cmd+V yourself to recover it, then re-grant Accessibility so the next one lands.",
                            actions: [.openSettings(.accessibility)], manualSteps: staleGrantSteps))
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
        // The blocked condition cleared and nothing was pasted since (#338).
        if result.pasteNote == .nothingSinceFix {
            return (labels.title, nothingPastedSinceFix, nil)
        }
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
