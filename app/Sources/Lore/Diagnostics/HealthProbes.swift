import ApplicationServices
import CoreGraphics
import FluidAudio
import Foundation
import LoreCore

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
/// keyboard tap (`readTapLiveness` reads `HotkeyManager`'s existing state).
@MainActor
struct HealthProber {
    /// The tap's measured liveness (#97), injected like the rest. The whole value,
    /// for the reason `readSecureInput` returns one: the verdict, the panel's
    /// evidence line and the uploaded report are views of a single measurement and
    /// must not be able to disagree (#93).
    var readTapLiveness: () -> TapLiveness
    /// The secure-input read, injected like the rest — the `.tap` verdict is
    /// gated on it (#94), so it has to be drivable from a test. It returns the
    /// whole `State`, not a bool, because the same reading feeds the tap gate as
    /// well as the `.secureInput` row.
    var readSecureInput: () -> SecureInput.State
    var hasOpenAIKey: () -> Bool
    /// The signing-identity migration (#135, rationale on `SigningIdentityLedger`).
    /// The ledger itself, injected once and shared with `HealthMonitor`, which
    /// reads it from here — one owner, so the row and the acknowledge cannot
    /// disagree about which ledger they mean.
    var signingLedger: SigningIdentityLedger?
    /// The notes-folder leftover the move reported (#148) — a marker read, no
    /// filesystem: the folder it names is in `~/Documents`, and probing runs at
    /// launch. `HealthMonitor.verifyNotesLeftover` does the real check when the
    /// panel is on screen. Unwired defaults to silence, never to a claim.
    var readNotesLeftover: () -> NotesLeftover?
    var store: DiagStore
    var now: () -> Date
    /// Whether the voice-activity model is complete on disk; injected so the
    /// row's rule is testable without this machine's model folder.
    var vadModelPresent: () -> Bool
    /// The keycap of the key held to talk, named in the Keyboard shortcuts row
    /// while secure input is on (#341).
    var readTalkKey: () -> String

    init(
        readTapLiveness: @escaping () -> TapLiveness,
        readSecureInput: @escaping () -> SecureInput.State = SecureInput.read,
        hasOpenAIKey: @escaping () -> Bool,
        signingLedger: SigningIdentityLedger? = nil,
        readNotesLeftover: @escaping () -> NotesLeftover? = { nil },
        store: DiagStore = .shared,
        now: @escaping () -> Date = Date.init,
        vadModelPresent: @escaping () -> Bool = { SileroVAD.isPresent },
        readTalkKey: @escaping () -> String = { HotkeyKey.fn.shortName }
    ) {
        self.readTapLiveness = readTapLiveness
        self.readSecureInput = readSecureInput
        self.hasOpenAIKey = hasOpenAIKey
        self.signingLedger = signingLedger
        self.readNotesLeftover = readNotesLeftover
        self.store = store
        self.now = now
        self.vadModelPresent = vadModelPresent
        self.readTalkKey = readTalkKey
    }

    /// A probe result plus the machine-local notes (holder attribution, signing
    /// team) that render in the panel but must never enter the serialized snapshot.
    private struct Reading {
        var result: HealthResult
        var holder: SecureInput.Attribution?
        var teamID: String?
        /// The leftover folder and its cause (#148) — the row names it, its
        /// button reveals it, and its remedy differs by cause. Like the holder
        /// name, none of it reaches the snapshot.
        var notesLeftover: NotesLeftover?
    }

    /// The snapshot and the renderable items in one pass — the monitor uses this
    /// so a health cycle probes the OS once, not twice.
    ///
    /// - Parameter permissionsBlocked: the blocked condition stands (#338). The
    ///   monitor owns it, and passes it in so the rows and the mark are
    ///   published from one pass.
    func probe(permissionsBlocked: Bool = false) -> (snapshot: HealthSnapshot, items: [HealthItem]) {
        // One read per cycle, shared: the `.secureInput` row, the `.tap` gate and
        // the hiding of the tap row are views of the same fact and must never
        // disagree (#93).
        let secureInput = readSecureInput()
        let readings = readings(secureInput, permissionsBlocked: permissionsBlocked)
        let snapshot = HealthSnapshot(
            marketingVersion: Self.marketingVersion,
            build: Self.build,
            results: readings.map(\.result)
        )
        // The `.secureInput` row can read `.ok` while the flag is up (benign
        // behind a locked console, #98), and its ok copy must not claim
        // "Inactive" then.
        let talkKey = readTalkKey()
        let items = readings
            // While secure input stands, its row carries the condition under the
            // name "Keyboard shortcuts" (#341) and a live tap's row, whose verdict
            // it makes unmeasurable, is not shown: the header counts exactly the
            // rows shown (the tap's `.warning` never counts). A dead tap stays.
            .filter { !(secureInput.isProblem && $0.result.id == .tap && $0.result.status != .failed) }
            .map { reading in
                HealthCatalog.describe(
                    reading.result,
                    secureInputHolder: reading.holder,
                    teamID: reading.teamID,
                    secureInputActive: reading.result.id == .secureInput && secureInput.active,
                    notesLeftover: reading.notesLeftover,
                    talkKey: talkKey
                )
            }
        return (snapshot, items)
    }

    // MARK: - Probes, in chain order

    /// `HealthProbeID.cost` is the single source of truth for the cheap /
    /// expensive split. `countsInFooter` reads the same property, so a probe's
    /// auto-run-at-open verdict and its footer-cry-wolf exclusion cannot drift.
    /// `allCases` is declared in chain order, so this preserves the panel order.
    private func readings(_ secureInput: SecureInput.State, permissionsBlocked: Bool) -> [Reading] {
        HealthProbeID.allCases.map { id in
            var reading = switch id {
            case .accessibility: accessibilityReading(blocked: permissionsBlocked)
            case .paste: pasteReading()
            default: id.cost == .expensive ? expensiveReading(id) : cheapReading(id, secureInput)
            }
            // The rows the block explains carry it too, so they point at the
            // one row with the fix (#338).
            if permissionsBlocked, HealthProbeID.explainedByTheBlock.contains(id) {
                reading.result.blockedByMacOS = true
            }
            return reading
        }
    }

    /// The grant's read, or the blocked condition when it stands (#338): an
    /// effect has proved macOS ignores the switches, so the row fails whatever
    /// the read says, and it is the one row that carries the fix.
    private func accessibilityReading(blocked: Bool) -> Reading {
        let granted = PermissionReader.accessibilityGranted()
        return Reading(result: HealthResult(
            id: .accessibility,
            status: granted && !blocked ? .ok : .failed,
            blockedByMacOS: blocked ? true : nil
        ))
    }

    /// The last paste, read from the stream like every last-attempt row — or,
    /// when the blocked condition cleared after it, nothing since the fix
    /// (#338): a paste macOS dropped before the fix is not a verdict on the
    /// paste after it.
    private func pasteReading() -> Reading {
        let latest = store.last { Self.isPasteOrFix($0.event) }
        if let latest, case .healthConditionCleared = latest.event,
           now().timeIntervalSince(latest.lastAt) <= TimeInterval(HealthLastAttempt.maxFreshAgeSeconds) {
            return Reading(result: HealthResult(id: .paste, status: .ok, pasteNote: .nothingSinceFix))
        }
        var reading = expensiveReading(.paste)
        if let latest, case .pasteAttempt(_, _, false) = latest.event,
           reading.result.lastAttempt?.isStale == false {
            reading.result.pasteNote = .blocked
        }
        return reading
    }

    nonisolated private static func isPasteOrFix(_ event: DiagEvent) -> Bool {
        switch event {
        case .pasteAttempt, .healthConditionCleared(trigger: .permissionsBlocked): return true
        default: return false
        }
    }

    /// The cheap OS probes, each with its own read. Exhaustive: a new probe does
    /// not compile until it is placed here or, if `cost == .expensive`, given an
    /// extractor in `expensiveOutcome` (the `preconditionFailure` arm is
    /// unreachable because `readings()` routes expensive ids away by cost).
    private func cheapReading(_ id: HealthProbeID, _ secureInput: SecureInput.State) -> Reading {
        switch id {
        case .signing: return signingReading()
        case .diskSpace: return diskReading()
        // Both grants through `PermissionReader`, the app's one reader (#150):
        // the panel is the only repair surface once setup is done, and it must
        // not disagree with the flow that collected the grant.
        case .inputMonitoring: return plain(id, PermissionReader.inputMonitoringGranted() ? .ok : .failed)
        case .tap: return tapReading(secureInput)
        case .secureInput: return secureInputReading(secureInput)
        case .microphone: return plain(id, Self.microphoneStatus())
        case .asrModel: return plain(id, ParakeetBackend().checkStatus() == .ready ? .ok : .failed)
        case .vadModel: return plain(id, vadStatus())
        case .openAIKey: return plain(id, hasOpenAIKey() ? .ok : .failed)
        case .notesFolder: return notesFolderReading()
        case .micCapture, .modelWarmup, .openAILiveness, .systemAudio, .paste:
            preconditionFailure("expensive probe \(id.rawValue) routed to cheapReading — check id.cost")
        case .accessibility:
            preconditionFailure("accessibility is read by accessibilityReading — see readings()")
        }
    }

    private func plain(_ id: HealthProbeID, _ status: HealthStatus) -> Reading {
        Reading(result: HealthResult(id: id, status: status))
    }

    /// The measurement rides along on the result, so the panel and the report show
    /// the evidence the verdict came from, not only the conclusion (#97).
    private func tapReading(_ secureInput: SecureInput.State) -> Reading {
        let liveness = readTapLiveness()
        return Reading(result: HealthResult(
            id: .tap,
            status: tapStatus(liveness, secureInputProblem: secureInput.isProblem),
            tapLiveness: liveness
        ))
    }

    /// `.failed` means the tap object is genuinely gone — the one tap state a
    /// user action can be blamed on and a restart repairs. A measured starvation
    /// is `.warning` (#140): it is inferred from keyboard silence, evidence too
    /// weak for an outage verdict — the recorded 8.8-hour "stall" was a user who
    /// slept — so it colors the panel row amber without counting in the footer
    /// (`countsInFooter` excludes `.tap` warnings) and summons nothing. Under
    /// secure input even that much is unmeasurable: every app is starved, so the
    /// starvation says nothing about *our* tap (#94, #97) and the row says
    /// so (#341). Behind a locked console the flag is the lock screen's and
    /// `TapLiveness` draws no verdict anyway, so the row reads as usual.
    private func tapStatus(_ liveness: TapLiveness, secureInputProblem: Bool) -> HealthStatus {
        // A dead tap is dead whatever else is true: it stays `.failed`, shown
        // and counted with its own remedy, secure input or not.
        guard liveness.isAlive else { return .failed }
        guard !secureInputProblem else { return .warning }
        // `isStarved` is tri-state (#99); "no verdict drawn" is not degradation.
        return liveness.isStarved == true ? .warning : .ok
    }

    private func signingReading() -> Reading {
        let info = SigningIdentity.current()
        // A pending identity migration (#135) degrades even a well-signed build
        // to `.warning`: a cheap warning counts in the footer, so "1 issue —
        // Signing" shows amber until it is acknowledged. Never `.failed` —
        // `.signing` is not critical, and the guided flow is summoned directly
        // at launch, not through the debouncer.
        let changed = signingLedger?.migrationPending ?? false
        let status: HealthStatus
        switch info.certKind {
        case .appleDevelopment, .developerID: status = changed ? .warning : .ok
        case .adHoc: status = .warning
        case .unknown: status = .warning
        }
        return Reading(
            result: HealthResult(id: .signing, status: status, signingCert: info.certKind,
                                 signingIdentityChanged: changed ? true : nil),
            teamID: info.teamID
        )
    }

    /// The migration's own count of what it could not move (#148), carried on
    /// the reading so the row can name the folder and offer to reveal it. The
    /// folder itself is re-read only when the panel opens
    /// (`HealthMonitor.verifyNotesLeftover`), which is what keeps a probe that
    /// also runs at launch clear of `~/Documents`.
    private func notesFolderReading() -> Reading {
        let leftover = readNotesLeftover()
        return Reading(
            result: HealthResult(id: .notesFolder, status: leftover == nil ? .ok : .warning),
            notesLeftover: leftover
        )
    }

    private func diskReading() -> Reading {
        let gb = Self.freeDiskGB()
        // Below 5 GB the transcript/recording writes start to risk failing.
        let status: HealthStatus = (gb ?? .max) < 5 ? .warning : .ok
        return Reading(result: HealthResult(id: .diskSpace, status: status, freeDiskGB: gb))
    }

    /// The state is read once per cycle in `probe()` and passed in.
    private func secureInputReading(_ state: SecureInput.State) -> Reading {
        // Secure input behind a locked console is the lock screen doing its job —
        // working as designed whoever the registry credits (an attribution
        // rdar://48953777 makes unreliable anyway), and the panel is unreadable
        // there, so nothing is surfaced at every lock screen (#98).
        // A genuinely stuck flag resurfaces on the first tick
        // after unlock: the lock state is re-read every cycle.
        let problem = state.isProblem
        return Reading(
            result: HealthResult(
                id: .secureInput,
                // A warning, not a failure (#341): only the shortcuts stop. It
                // counts once in the header, as "Keyboard shortcuts" (`shortName`).
                status: problem ? .warning : .ok,
                // The pid rides iff the row is a problem, so a report's reader can
                // decode `holderPID` unambiguously (#92) — `read()` checks the flag
                // before walking the registry, so a holder appearing between the
                // two yields `active: false, pid: n` for one tick, and a pid on an
                // `ok` row would be noise. It rides for loginwindow and SecurityAgent
                // too: not naming them is a display rule, and the report keeps
                // the truth.
                secureInputHolderPID: problem ? state.pid : nil
            ),
            holder: problem ? state.attribution : nil
        )
    }

    /// An expensive probe's card is driven entirely by the last real attempt
    /// from the event stream; "never tested" is a `.warning`, not a failure —
    /// and so is an attempt past the age ceiling (#140): a day-old outcome is
    /// "not tested recently", whichever way it went.
    private func expensiveReading(_ id: HealthProbeID) -> Reading {
        let last = Self.expensiveOutcome[id].flatMap(lastAttempt)
        let status: HealthStatus
        switch last {
        case .some(let attempt) where attempt.isStale: status = .warning
        case .some(let attempt) where attempt.outcome == .ok: status = .ok
        case .some(let attempt) where attempt.outcome == .failed: status = .failed
        case .some, .none: status = .warning
        }
        return Reading(result: HealthResult(id: id, status: status, lastAttempt: last))
    }

    private func lastAttempt(_ outcomeOf: (DiagEvent) -> DiagEvent.Outcome?) -> HealthLastAttempt? {
        guard let record = store.last(where: { outcomeOf($0.event) != nil }),
              let outcome = outcomeOf(record.event) else { return nil }
        // `lastAt`, not `at`: a coalesced run of identical attempts (#149) is
        // dated from its first, and the 24 h staleness ceiling would then read a
        // failure that is still happening as "not tested recently".
        return HealthLastAttempt(
            outcome: outcome,
            ageSeconds: max(0, Int(now().timeIntervalSince(record.lastAt)))
        )
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
        .paste: pasteOutcome,
    ]

    /// The same fact the `pasteFailed` condition is derived from (#151), read
    /// through the same last-attempt path as every other card — so the row and
    /// the mark's dot cannot disagree, and both age out at the 24 h ceiling.
    /// `eventsCreated` is all the attempt can observe: `CGEvent.post` returns
    /// nothing, so this is "we managed to build and post the keystrokes", never
    /// "the text landed". A paste posted while lore was untrusted is a failure
    /// (#338): macOS drops it, and calling it ok was the false green.
    nonisolated private static func pasteOutcome(_ event: DiagEvent) -> DiagEvent.Outcome? {
        if case .pasteAttempt(_, let created, let trusted) = event {
            return DiagEvent.Outcome(success: created && trusted)
        }
        return nil
    }

    /// `.ok` is frames arriving, never `captureStart` (#149): `AudioDeviceStart`
    /// returns noErr for a wedged IOProc too — that is the device the no-frames
    /// watchdog gives up on — so a start would certify a mic that delivers
    /// nothing, and the panel would read green while the mark's amber dot said
    /// it failed. The dot reads the same rule in `HealthMonitor.healthSignal`.
    nonisolated private static func micCaptureOutcome(_ event: DiagEvent) -> DiagEvent.Outcome? {
        switch event {
        case .micFramesFlowing: return .ok
        case .captureFailed, .captureGaveUp: return .failed
        default: return nil
        }
    }

    /// Real load attempts only. A cache hit loaded nothing, so it can certify
    /// nothing — and the app prepares more than one ASR instance, so letting a
    /// hit on one speak for all of them is how a permanently broken leg read as
    /// green after any dictation (#169). The row's own copy already says the
    /// Test-now button is "instant if already warm": on a warm cache it now
    /// leaves the last real attempt standing instead of overwriting it with a
    /// load that never happened. Same rule in `HealthMonitor.healthSignal`.
    nonisolated private static func modelWarmupOutcome(_ event: DiagEvent) -> DiagEvent.Outcome? {
        if case .modelLoad(.asr, let outcome, _, false, _) = event { return outcome }
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

    /// The voice-activity model (#269). `.failed` only on a real VAD load that
    /// failed within the 24 h ceiling, file present or not (`no-false-positives`
    /// rules 1 and 3); a later success or the ceiling ends it. Otherwise the file
    /// decides: present is `.ok`, missing is `.warning` — a download the first
    /// meeting, file transcription or `lore transcribe` makes, and dictation
    /// never needs it. Every VAD load refreshes the panel.
    private func vadStatus() -> HealthStatus {
        if let last = lastAttempt(Self.vadLoadOutcome), last.outcome == .failed, !last.isStale { return .failed }
        return vadModelPresent() ? .ok : .warning
    }

    nonisolated private static func vadLoadOutcome(_ event: DiagEvent) -> DiagEvent.Outcome? {
        if case .modelLoad(.vad, let outcome, _, _, _) = event, outcome != .unknown { return outcome }
        return nil
    }

    private static func freeDiskGB() -> Int? {
        let url = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int(bytes / 1_000_000_000)
    }

    /// `.notDetermined` is a fresh install that has never recorded — macOS asks
    /// on the first capture. Not knowing the answer is not a dead link (#140).
    private static func microphoneStatus() -> HealthStatus {
        switch MicrophonePermission.status {
        case .authorized: return .ok
        case .notDetermined: return .warning
        default: return .failed
        }
    }
}
