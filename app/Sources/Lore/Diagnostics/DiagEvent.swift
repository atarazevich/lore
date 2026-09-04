import Foundation

/// Coarse grouping for the health panel's readiness chain (#83) and the
/// problem report's timeline (#84).
enum DiagSubsystem: String, Codable, Sendable, CaseIterable {
    case app
    case input
    case audio
    case transcription
    case intelligence
    case dictation
    case meetings
    case storage
}

/// The only diagnostic record the app keeps (design: docs/design/diagnostics.md §4).
///
/// **Leakage is prevented by type, not by policy.** No case carries a free-form
/// `String`: there is no field a transcript, a device name, a file name, an app
/// name or an API key fits into. Every payload is a number, a `Bool` or a closed
/// enum. `DiagEventPrivacyTests.testNoAssociatedValueIsAFreeFormString` reflects
/// over a sample of every case and fails if that ever stops being true.
///
/// Anything that needs the actual text belongs in `os.Logger` with
/// `privacy: .private` (§5, tier 2), never here.
///
/// Two independent compile-time forcing functions keep this honest: `caseName`
/// below (production), and `DiagEventPrivacyTests.sample(for:)` (tests), which
/// must *return a real `DiagEvent`* for every case. A new case builds in
/// neither until it has been named and given a value.
enum DiagEvent: Codable, Sendable, Equatable {

    // MARK: - Supporting types
    //
    // Nested rather than top-level: `Outcome`, `Permission` and `Endpoint` are
    // names a shared module should not claim outright.

    enum Outcome: String, Codable, Sendable, CaseIterable {
        case ok
        case failed
        /// The attempt completed but produced no verdict — a network flake, a
        /// timeout, a 5xx. Distinct from `.failed` on purpose: a report that
        /// answers "what broke" must not read a flaky connection as a dead API
        /// key (`KeyHealthStatus.unknown`, #50).
        case unknown
    }

    /// A device's transport class. The device *name* never exists in an event —
    /// "Sam's AirPods Pro" collapses to `.wireless`.
    ///
    /// The CoreAudio transport → `DeviceKind` classifier lives beside the
    /// recording allowlist it must agree with, in `AudioBus` (#39). This file
    /// stays free of `import CoreAudio` and of a second transport table.
    enum DeviceKind: String, Codable, Sendable, CaseIterable {
        case builtIn
        case wireless
        case wired
        case virtual
    }

    enum Permission: String, Codable, Sendable, CaseIterable {
        case accessibility
        case inputMonitoring
        case microphone
        case notifications
    }

    /// Which screen of the first-run flow was reached (#150). A closed enum, so
    /// the timeline can say where a machine stopped setting itself up without
    /// any of the flow's copy entering the event stream.
    enum OnboardingStep: String, Codable, Sendable, CaseIterable {
        case welcome
        case permissions
        case fnKey
        case tryIt
        case ready
    }

    /// Which API call was made — never the prompt, never the response. Also
    /// names which dictation upgrade ran (`.cleanup` / `.translate`): an
    /// upgrade *is* one of these calls, so it needs no parallel enum.
    enum Endpoint: String, Codable, Sendable, CaseIterable {
        case cleanup
        case translate
        case askLore
        case refinement
        case keyHealth
        /// Speechify TTS synthesis (#105) — never the selected text.
        case readAloud
    }

    enum ModelKind: String, Codable, Sendable, CaseIterable {
        case asr
        case vad
    }

    /// Where a HAL capture attempt died. Pairs with an `OSStatus`.
    enum CaptureStage: String, Codable, Sendable, CaseIterable {
        case noDefaultDevice
        case invalidFormat
        case createIOProc
        case startDevice
        case installFormatListener
        case queryStreamFormat
    }

    enum CaptureStopReason: String, Codable, Sendable, CaseIterable {
        case lastConsumerLeft
        case deviceSwitch
        case reconfigure
    }

    enum ReconfigureReason: String, Codable, Sendable, CaseIterable {
        case streamFormatChanged
        case silentTooLong
        case noFramesEver
    }

    /// Which of the three echo-suppression paths fired (all numbers, no text).
    enum EchoPath: String, Codable, Sendable, CaseIterable {
        case liveForward
        case retroactive
        case batch
    }

    enum PasteKind: String, Codable, Sendable, CaseIterable {
        case paste
        /// Retired (#209) with the post-paste upgrade panel, the only thing that
        /// ever posted a Cmd+Z before a Cmd+V. Nothing produces this any more;
        /// it stays so a persisted events.json carrying it still decodes rather
        /// than being moved aside as corrupt — the same reason
        /// `tapEventsStalled` survives.
        case undoAndPaste
    }

    /// Which pasteboard read the paste-protection probe made (#192, step 0).
    /// Removable with `ClipboardProbe` itself.
    enum ClipboardRead: String, Codable, Sendable, CaseIterable {
        case changeCount
        case types
        case data
    }

    /// Why a detection prompt did or did not reach the user.
    enum PromptDisposition: String, Codable, Sendable, CaseIterable {
        case shown
        /// Shown with no attributed app (#101): the known-list scan missed and
        /// the frontmost fallback was Lore or nil, so the dismiss buttons have
        /// no bundle ID to key on. Distinguished from `.shown` so a report can
        /// tell an actionable prompt from one whose suppression cannot persist.
        case shownUnattributed
        case accepted
        case dismissed
        case notAMeeting
        case appIgnoredPermanently
        case timedOut
        case suppressedSessionActive
        case suppressedDismissedEarlier
        case suppressedAppIgnored
    }

    /// The meeting prompt's own window-level lifecycle (#227) — traced
    /// independently of `PromptDisposition` above, which speaks for the
    /// *detection loop's* decisions and never runs for a re-front
    /// DynamicNotchKit fires on its own: a screen-parameter change can
    /// recreate and front the prompt's window without `MeetingDetectionController`
    /// ever being asked, the ghost class `SummonWithdrawal.sweptGhost` names
    /// for the health surface (#149) before that surface was retired (#151).
    /// The meeting prompt cannot be retired the same way, so it is traced
    /// instead.
    enum PromptWindowEvent: String, Codable, Sendable, CaseIterable {
        /// `present()` refused because meetings is off — defense in depth
        /// (#227); unreachable today, since the whole detection pipeline
        /// tears down with the master switch.
        case presentRefusedMeetingsOff
        /// The screen-parameter sweep found the surface live and re-applied
        /// the window policy (#145) — not a ghost, the same window it
        /// already was.
        case sweepReaffirmedLive
        /// The sweep found the surface should not be showing and ordered a
        /// DynamicNotchKit re-front back out — the trace that makes an
        /// otherwise invisible ghost visible in the ring.
        case sweepOrderedGhostOut
    }

    /// Which on-disk artifact was found corrupt and moved aside. A closed set —
    /// never the file's path, which can carry a session id.
    enum Artifact: String, Codable, Sendable, CaseIterable {
        case chatJSON
        case historyEntry
        case legacyHistoryBlob
        case eventsJSON
    }

    /// How the one-time notes-folder move (#148) ended. `alreadyDone` is the
    /// one value never emitted: it is every launch after the first, and one
    /// event per launch forever would evict the trace it belongs to.
    enum NotesMigration: String, Codable, Sendable, CaseIterable {
        case alreadyDone
        /// The setting already names the app's own folder while the marker is
        /// still down — a launch killed between the move's repoint and its
        /// marker. Recorded (unlike `alreadyDone`, which is every later launch)
        /// and deliberately not `customPathRespected`: the app's own folder is
        /// never traced as the user's choice.
        case alreadyAtTarget
        case freshInstall
        case customPathRespected
        case nothingToMove
        case moved
    }

    /// Which health condition a report is about (#140): a user action that just
    /// failed, or the launch identity migration (#135). Never a bare state bit —
    /// permission flags and secure input are explanations, not triggers.
    ///
    /// Named for the condition, not the surface (#151): the notch summon it was
    /// born on is gone, the menu-bar mark's amber state carries these now, and
    /// the raw values are unchanged so a persisted events.json still decodes.
    enum HealthTrigger: String, Codable, Sendable, CaseIterable {
        case identityMigration
        case captureFailed
        /// The system-audio tap, not the microphone (#149) — different remedy,
        /// so a different sentence.
        case systemAudioFailed
        case pasteFailed
        case modelLoadFailed
    }

    /// What summoned a transcript repair job (#166). A closed set — never the
    /// session id, which embeds the meeting's date and time.
    enum RepairReason: String, Codable, Sendable, CaseIterable {
        case launchSweep
        case openedMeeting
        case meetingEnded
        case importRequested
        case retry
    }

    /// How a repair run (or assessment) ended (#166). Its own enum, not
    /// `Outcome` — whose `.unknown` means "completed without a verdict"
    /// (network flake), while `.unavailable` here IS the verdict: nothing to
    /// show and nothing to make it from.
    enum RepairOutcome: String, Codable, Sendable, CaseIterable {
        case repaired
        case failed
        case unavailable
    }

    /// Why a summon left the screen (#149). Retired with the surface (#151) and
    /// kept for the same reason as the events that carry it: a persisted
    /// events.json must keep decoding. `.sweptGhost` was the reason nobody in
    /// this app chose — the notch library re-fronted a panel on a
    /// screen-parameter change and it rendered latched content, which is the
    /// class of fault that ended the surface.
    enum SummonWithdrawal: String, Codable, Sendable, CaseIterable {
        case recovered
        case timedOut
        case dismissed
        case displaced
        case sweptGhost
    }

    /// Why a hint left the card slot (#235) — the shape of `SummonWithdrawal`
    /// above, for a surface that is not a summon.
    ///
    /// `displaced` is the slot being taken by something with more right to it:
    /// the pointer's own tooltip, a failure face, or the paused face. A
    /// displaced hint still counts as shown.
    ///
    /// `actionPerformed` is a *lesson* retiring because the user did the thing
    /// it teaches. `conditionCleared` is the silent-microphone report's own
    /// exit — sound arrived, so the card has nothing left to say. They are two
    /// reasons because they answer two different questions of the stream: how
    /// often a hint taught something, and how long a microphone was silent.
    enum HintWithdrawal: String, Codable, Sendable, CaseIterable {
        case timedOut
        case closed
        case actionPerformed
        case conditionCleared
        case recordingEnded
        case displaced
    }

    // MARK: - App

    case appLaunched(build: Int)

    /// A second `com.lore.app` process found one already running and exited
    /// instead of standing up its own event tap, mic subscription and
    /// menu-bar mark (#193). The running instance was activated in its place
    /// and records this on the refused process's behalf, since the refused
    /// process's own ring never survives to a flush. `build` names which
    /// build tried to launch, matching its sibling `appLaunched(build:)`.
    case appLaunchRefused(build: Int)

    /// A health condition crossed / left the persistence window (#151) — one
    /// pair per condition, at that condition's own crossing, so two failures
    /// standing at once are two traces rather than one arbitrated winner.
    ///
    /// Deliberately about the **condition, not the pixel**. What the menu-bar
    /// mark actually shows is `condition ∧ ¬recording` (the mark has one bead
    /// slot and a recording outranks amber in it, `MenuBarBead`), and the
    /// recording half is already in the stream — so the dot's visibility over a
    /// session is reconstructable without tracing presentation, which is the
    /// layer that lied in #149.
    case healthConditionSustained(trigger: HealthTrigger)
    case healthConditionCleared(trigger: HealthTrigger)

    /// Retired (#151) with the notch summon surface itself: no code fires these
    /// any more. Kept so a persisted events.json carrying them still decodes
    /// rather than being moved aside as corrupt — the same reason
    /// `tapEventsStalled` survives.
    case healthSummonFired(trigger: HealthTrigger)
    case healthSummonWithdrawn(trigger: HealthTrigger, reason: SummonWithdrawal)
    /// Retired earlier still (#149): superseded by `healthSummonWithdrawn`,
    /// which named the trigger and the reason instead of only the fact.
    case healthSummonCleared

    /// The exclusive setup state opened (#150) — the boundary that says this
    /// launch had no subsystems running, so an absence of capture/detection
    /// events after it is the design rather than a fault.
    case onboardingStarted
    case onboardingStepShown(step: OnboardingStep)
    /// The guided dictation actually put text at the cursor: mic, event tap and
    /// insertion confirmed by one act.
    case onboardingDictationLanded
    /// Setup finished and the app booted its subsystems.
    case onboardingCompleted

    // MARK: - Input (hotkey, permissions, paste)

    case permissionTransition(permission: Permission, granted: Bool)
    case tapCreate(outcome: Outcome, osStatus: Int32?)
    case tapReinstall(outcome: Outcome)
    case tapDisabledByOS
    case tapDiedDuringRecording
    /// Retired (#140): the starvation edge was silence-as-failure by
    /// construction, so it is no longer recorded. The cases stay so a persisted
    /// events.json that carries them keeps decoding instead of being moved
    /// aside as corrupt (the same reason the notification cases below survive
    /// Notification Center's removal).
    case tapEventsStalled(seconds: Int)
    case tapEventsResumed
    /// The health cycle stopped rebuilding a tap that will not install (#149) —
    /// otherwise a retry run's end is indistinguishable from the app being quit.
    case tapGaveUp(attempts: Int)
    case secureInputChanged(active: Bool, holderPID: Int32?)
    /// `eventsCreated` is the only fact this attempt can observe: `CGEvent.post`
    /// returns nothing, so a paste that reached no app is indistinguishable from
    /// one that landed. There is deliberately no `Outcome` here — an `.ok` would
    /// have read "fine" in exactly the incident this feature exists to diagnose.
    case pasteAttempt(kind: PasteKind, eventsCreated: Bool, accessibilityTrusted: Bool)

    // MARK: - Audio

    /// Success only. A failed start is `captureFailed`, which carries the stage
    /// and the OSStatus that `captureStart` has nowhere to put.
    case captureStart(deviceKind: DeviceKind, ms: Int)
    case captureFailed(stage: CaptureStage, osStatus: Int32?)
    case captureStopped(reason: CaptureStopReason)
    case captureRetryScheduled(attempt: Int, maxAttempts: Int)
    case captureGaveUp(attempts: Int)
    case captureReconfigured(reason: ReconfigureReason, running: Bool)
    case inputDeviceSelected(kind: DeviceKind, redirectedToBuiltIn: Bool)
    case deviceSwitched(kind: DeviceKind)
    case noFramesRecovery(attempt: Int, maxAttempts: Int)
    /// Health transitions, emitted on the edge only.
    case micStalled(seconds: Int)
    case micRecovered
    case systemAudioCapture(outcome: Outcome, osStatus: Int32?)
    /// The mic delivered its first buffer of this capture — the only proof the
    /// device is live, and so the evidence `.micCapture` reads as ok (#149).
    case micFramesFlowing
    /// The system-audio capture stopped retrying (#149). Kept apart from the
    /// mic's `captureGaveUp` so a summon can name the side that failed.
    case systemAudioGaveUp(attempts: Int)
    /// Latched: at most one per recording, never one per audio buffer.
    case recordingSaved(outcome: Outcome, frames: Int)
    /// The meeting asked for audio and none will be captured: capture started
    /// with no session to own the tracks, so the recorder was never armed
    /// (#177). Not a `recordingSaved(.failed)` — nothing was saved and nothing
    /// was attempted, and reusing a save outcome here would put a second one in
    /// the ring for a meeting that still records its own.
    case recordingUnowned

    // MARK: - Transcription

    case modelLoad(model: ModelKind, outcome: Outcome, seconds: Double, fromCache: Bool)
    case modelCacheCleared
    case transcribed(chunks: Int, failedChunks: Int, samples: Int, characters: Int, ms: Int)
    /// A transcript repair job entered the healer's queue (#166) — the trace
    /// behind every Preparing face, since a self-healing engine that leaves
    /// no events cannot be debugged or trusted.
    case transcriptRepairQueued(reason: RepairReason)
    /// One repair run (or assessment) reached its verdict: `.repaired` a
    /// readable transcript is on disk, `.failed` the pass failed (a bounded
    /// retry may follow), `.unavailable` there is nothing to make a
    /// transcript from — the meeting settles into the one sentence.
    case transcriptRepairSettled(outcome: RepairOutcome)
    /// Per-session (or per-batch-pass) summary, never per suppressed utterance —
    /// an echoey meeting would otherwise evict the whole ring. Numbers only:
    /// never `you='…' them='…'`.
    case echoSuppressed(path: EchoPath, count: Int, meanJaccard: Double)

    // MARK: - Intelligence (OpenAI)

    case apiCall(endpoint: Endpoint, outcome: Outcome, httpStatus: Int?, ms: Int)

    // MARK: - Dictation

    case dictationRecorded(samples: Int, durationMs: Int)
    case dictationZeroFrames
    case dictationPasted(characters: Int, cleaned: Bool)
    case dictationUpgrade(endpoint: Endpoint, outcome: Outcome)
    case dictationDiscarded(state: DictationState)
    /// Esc suspended capture in place, and `Continue` (or a second Esc) brought
    /// it back (#206). The pair replaces what Esc used to leave behind — a
    /// `dictationDiscarded{state: recording}` and no recording — so a pause is
    /// legible in the stream as the reversible thing it is.
    case dictationPaused
    case dictationResumed
    /// A recording went hands-free (#235) — by Space or by a click on the lock.
    /// Without it a locked dictation is invisible in the stream:
    /// `dictationRecorded` carries only samples and a duration, so "did the lock
    /// hint change anything" could not be answered at all.
    case dictationLocked

    /// A hint spoke from its element, and left again (#235). The `hint` is a
    /// closed enum and so is the reason, so no sentence enters the stream — only
    /// which of the five it was.
    case hintShown(hint: DictationHint)
    case hintWithdrawn(hint: DictationHint, reason: HintWithdrawal)

    /// Rich input (#192). What was copied is never in the stream — only which
    /// of the four kinds it was, and, for an image, how many bytes came off the
    /// clipboard. `DictationItemKind` is closed by construction.
    case dictationItemCollected(kind: DictationItemKind, bytes: Int)
    /// A row in the opened list was switched: the item's state after the click.
    case dictationItemSwitched(kind: DictationItemKind, included: Bool)
    /// The paste carried `included` of `items`, in the form `target` reads
    /// (#195) — the receipt for what actually travelled, which the panel
    /// deliberately does not restate on screen. `PasteTarget` is closed by
    /// construction, so naming the class names no app.
    case dictationItemsPasted(items: Int, included: Int, target: PasteTarget)
    /// The collected images were pruned back under the ceiling (#196): how
    /// many files went, and how many bytes came back. Never which — a path is
    /// a name, and names do not enter the stream.
    case dictationItemsPruned(deleted: Int, bytesFreed: Int)
    /// Fn+S posted the system's copy-region-to-clipboard chord. `eventsCreated`
    /// is all this can observe, for the same reason `pasteAttempt` says so:
    /// `CGEvent.post` returns nothing.
    case dictationScreenshotChord(eventsCreated: Bool)
    /// A system screenshot shortcut pressed during a dictation was redirected
    /// to its clipboard variant, so the picture joins the prompt (#199). The
    /// one place lore changes system behaviour, and it says so every time.
    case dictationScreenshotRedirected(fullScreen: Bool)
    /// The paste-protection probe (#192, step 0) — one per read. `result` is
    /// what that read returned: the change count, the number of types, or the
    /// number of bytes. Removable with `ClipboardProbe`.
    case clipboardProbeRead(read: ClipboardRead, result: Int)

    // MARK: - Meetings

    case detectionLifecycle(running: Bool)
    case detectionDeviceListChanged(added: Int, removed: Int, monitored: Int)
    case detectionListenerFailed(osStatus: Int32)
    case detectionSignal(active: Bool)
    case detectionAppScan(found: Bool)
    case detectionPrompt(disposition: PromptDisposition)
    /// The meeting prompt's window-level show/order-out (#227) — see
    /// `PromptWindowEvent`'s own comment for why this is not folded into
    /// `detectionPrompt` above.
    case promptWindow(PromptWindowEvent)
    case notificationAuthorization(outcome: Outcome)
    case notificationPosted(outcome: Outcome)
    /// The user suspended and continued a meeting (#153). The pair is what
    /// makes a gap in a session's audio reconstructable afterwards: without it,
    /// a resumed meeting is indistinguishable from one whose capture died and
    /// recovered. The gap's length is the two records' own timestamps — it is
    /// not a payload, because a second copy of it could disagree with them.
    case sessionPaused
    case sessionResumed
    /// A resume could not bring capture back, so the session returned to
    /// paused. Its own case rather than a second `sessionPaused`, which would
    /// read as a pause the user asked for — and, following a `sessionResumed`,
    /// as a resume that hung.
    case sessionResumeFailed

    // MARK: - Storage

    /// Failure only — a successful history write is the unremarkable case, and
    /// recording one per dictation would crowd the ring.
    case historyWriteFailed
    case historyMigrated(entries: Int, written: Int)
    /// The move began, with the number of entries it is about to walk (#148).
    /// The pair to `notesFolderMigrated`: a move that blocks — a directory of
    /// iCloud placeholders is accepted as able to — leaves this and no
    /// completion, which is the only way to tell a stuck move from a launch
    /// that had nothing to do (`no-false-positives.md` §5).
    case notesFolderMoveStarted(entries: Int)
    /// The one-time notes-folder move into the app's domain (#148), on every
    /// branch that decided something — a migration that cannot be re-run has
    /// to stay answerable afterwards. A disposition and counts; never the
    /// folder, which embeds the user's home directory.
    case notesFolderMigrated(
        disposition: NotesMigration, moved: Int, leftBehind: Int, unverified: Int, evicted: Int
    )
    /// The leftovers the move reported are gone, so the health row withdraws
    /// itself. The clear half of the fire/clear pair the no-false-positives
    /// rule requires: without it, a row's disappearance is undebuggable.
    case notesFolderLeftoverCleared
    case corruptFileAside(artifact: Artifact)
    /// Failure only. A *preempted* import (`.cancelled`, #43) is the normal
    /// "a recording started" path and is not recorded at all.
    case sessionImportFailed
}

// MARK: - Grouping

extension DiagEvent {
    var subsystem: DiagSubsystem {
        switch self {
        case .appLaunched, .appLaunchRefused, .healthConditionSustained, .healthConditionCleared,
             .healthSummonFired, .healthSummonWithdrawn, .healthSummonCleared,
             .onboardingStarted, .onboardingStepShown, .onboardingDictationLanded,
             .onboardingCompleted:
            return .app

        case .permissionTransition, .tapCreate, .tapReinstall, .tapDisabledByOS,
             .tapDiedDuringRecording, .tapEventsStalled, .tapEventsResumed,
             .tapGaveUp, .secureInputChanged, .pasteAttempt:
            return .input

        case .captureStart, .captureFailed, .captureStopped, .captureRetryScheduled,
             .captureGaveUp, .captureReconfigured, .inputDeviceSelected, .deviceSwitched,
             .noFramesRecovery, .micStalled, .micRecovered, .micFramesFlowing,
             .systemAudioCapture, .systemAudioGaveUp, .recordingSaved,
             .recordingUnowned:
            return .audio

        case .modelLoad, .modelCacheCleared, .transcribed, .echoSuppressed,
             .transcriptRepairQueued, .transcriptRepairSettled:
            return .transcription

        case .apiCall:
            return .intelligence

        case .dictationRecorded, .dictationZeroFrames, .dictationPasted,
             .dictationUpgrade, .dictationDiscarded,
             .dictationPaused, .dictationResumed, .dictationLocked,
             .hintShown, .hintWithdrawn, .dictationItemCollected,
             .dictationItemSwitched, .dictationItemsPasted, .dictationItemsPruned,
             .dictationScreenshotChord, .dictationScreenshotRedirected,
             .clipboardProbeRead:
            return .dictation

        case .detectionLifecycle, .detectionDeviceListChanged, .detectionListenerFailed,
             .detectionSignal, .detectionAppScan, .detectionPrompt, .promptWindow,
             .notificationAuthorization, .notificationPosted,
             .sessionPaused, .sessionResumed, .sessionResumeFailed:
            return .meetings

        case .historyWriteFailed, .historyMigrated, .notesFolderMoveStarted,
             .notesFolderMigrated, .notesFolderLeftoverCleared, .corruptFileAside,
             .sessionImportFailed:
            return .storage
        }
    }

    /// Stable identifier for one case, independent of its payload. Used by the
    /// health panel to find "the last event of this kind" and by the report's
    /// timeline as a label.
    ///
    /// Exhaustive on purpose: this is the compile-time forcing function in
    /// production. A new case does not build until it is named here.
    var caseName: String {
        switch self {
        case .appLaunched: return "appLaunched"
        case .appLaunchRefused: return "appLaunchRefused"
        case .healthConditionSustained: return "healthConditionSustained"
        case .healthConditionCleared: return "healthConditionCleared"
        case .healthSummonFired: return "healthSummonFired"
        case .healthSummonWithdrawn: return "healthSummonWithdrawn"
        case .healthSummonCleared: return "healthSummonCleared"
        case .onboardingStarted: return "onboardingStarted"
        case .onboardingStepShown: return "onboardingStepShown"
        case .onboardingDictationLanded: return "onboardingDictationLanded"
        case .onboardingCompleted: return "onboardingCompleted"
        case .permissionTransition: return "permissionTransition"
        case .tapCreate: return "tapCreate"
        case .tapReinstall: return "tapReinstall"
        case .tapDisabledByOS: return "tapDisabledByOS"
        case .tapDiedDuringRecording: return "tapDiedDuringRecording"
        case .tapEventsStalled: return "tapEventsStalled"
        case .tapEventsResumed: return "tapEventsResumed"
        case .tapGaveUp: return "tapGaveUp"
        case .secureInputChanged: return "secureInputChanged"
        case .pasteAttempt: return "pasteAttempt"
        case .captureStart: return "captureStart"
        case .captureFailed: return "captureFailed"
        case .captureStopped: return "captureStopped"
        case .captureRetryScheduled: return "captureRetryScheduled"
        case .captureGaveUp: return "captureGaveUp"
        case .captureReconfigured: return "captureReconfigured"
        case .inputDeviceSelected: return "inputDeviceSelected"
        case .deviceSwitched: return "deviceSwitched"
        case .noFramesRecovery: return "noFramesRecovery"
        case .micStalled: return "micStalled"
        case .micRecovered: return "micRecovered"
        case .micFramesFlowing: return "micFramesFlowing"
        case .systemAudioCapture: return "systemAudioCapture"
        case .systemAudioGaveUp: return "systemAudioGaveUp"
        case .recordingSaved: return "recordingSaved"
        case .recordingUnowned: return "recordingUnowned"
        case .modelLoad: return "modelLoad"
        case .modelCacheCleared: return "modelCacheCleared"
        case .transcribed: return "transcribed"
        case .echoSuppressed: return "echoSuppressed"
        case .transcriptRepairQueued: return "transcriptRepairQueued"
        case .transcriptRepairSettled: return "transcriptRepairSettled"
        case .apiCall: return "apiCall"
        case .dictationRecorded: return "dictationRecorded"
        case .dictationZeroFrames: return "dictationZeroFrames"
        case .dictationPasted: return "dictationPasted"
        case .dictationUpgrade: return "dictationUpgrade"
        case .dictationDiscarded: return "dictationDiscarded"
        case .dictationPaused: return "dictationPaused"
        case .dictationResumed: return "dictationResumed"
        case .dictationLocked: return "dictationLocked"
        case .hintShown: return "hintShown"
        case .hintWithdrawn: return "hintWithdrawn"
        case .dictationItemCollected: return "dictationItemCollected"
        case .dictationItemSwitched: return "dictationItemSwitched"
        case .dictationItemsPasted: return "dictationItemsPasted"
        case .dictationItemsPruned: return "dictationItemsPruned"
        case .dictationScreenshotChord: return "dictationScreenshotChord"
        case .dictationScreenshotRedirected: return "dictationScreenshotRedirected"
        case .clipboardProbeRead: return "clipboardProbeRead"
        case .detectionLifecycle: return "detectionLifecycle"
        case .detectionDeviceListChanged: return "detectionDeviceListChanged"
        case .detectionListenerFailed: return "detectionListenerFailed"
        case .detectionSignal: return "detectionSignal"
        case .detectionAppScan: return "detectionAppScan"
        case .detectionPrompt: return "detectionPrompt"
        case .promptWindow: return "promptWindow"
        case .notificationAuthorization: return "notificationAuthorization"
        case .notificationPosted: return "notificationPosted"
        case .sessionPaused: return "sessionPaused"
        case .sessionResumed: return "sessionResumed"
        case .sessionResumeFailed: return "sessionResumeFailed"
        case .historyWriteFailed: return "historyWriteFailed"
        case .historyMigrated: return "historyMigrated"
        case .notesFolderMoveStarted: return "notesFolderMoveStarted"
        case .notesFolderMigrated: return "notesFolderMigrated"
        case .notesFolderLeftoverCleared: return "notesFolderLeftoverCleared"
        case .corruptFileAside: return "corruptFileAside"
        case .sessionImportFailed: return "sessionImportFailed"
        }
    }
}

// MARK: - Convenience constructors

extension DiagEvent.Outcome {
    init(success: Bool) {
        self = success ? .ok : .failed
    }
}

/// One event plus when it happened. The subsystem is derived, never stored —
/// it cannot drift from the event it describes.
///
/// A record can stand for a *run* of the identical event rather than one
/// occurrence (#149, diagnostics.md §4). Both fold fields are optional and
/// therefore absent from a single occurrence's JSON — synthesized `Codable` uses
/// `encodeIfPresent`/`decodeIfPresent` — so events.json is unchanged for the
/// ordinary case and a pre-#149 file still decodes.
struct DiagRecord: Codable, Sendable, Equatable {
    let at: Date
    let event: DiagEvent
    /// Occurrences folded in; `nil` means the plain one.
    private(set) var count: Int?
    /// When the last of them happened; `nil` alongside `count`.
    private(set) var until: Date?

    var subsystem: DiagSubsystem { event.subsystem }

    var occurrences: Int { count ?? 1 }

    /// The most recent occurrence — what an age is measured from.
    var lastAt: Date { until ?? at }

    init(at: Date = Date(), event: DiagEvent) {
        self.at = at
        self.event = event
    }

    /// Fold another record of the same event into this one. Takes `other`'s
    /// occurrences rather than assuming one, so re-loading an already-folded
    /// events.json cannot drop a run's tally.
    mutating func merge(_ other: DiagRecord) {
        count = occurrences + other.occurrences
        until = Swift.max(lastAt, other.lastAt)
    }
}
