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
        case undoAndPaste
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

    /// What summoned the health notch (#140): a user action that just failed, or
    /// the launch identity migration (#135). Never a bare state bit — permission
    /// flags and secure input are explanations, not triggers.
    enum SummonTrigger: String, Codable, Sendable, CaseIterable {
        case identityMigration
        case captureFailed
        /// The system-audio tap, not the microphone (#149) — different remedy,
        /// so a different sentence.
        case systemAudioFailed
        case pasteFailed
        case modelLoadFailed
    }

    /// Why a summon left the screen (#149). Every exit is traced, not only the
    /// fact of one, because a summon that appeared with no `healthSummonFired`
    /// behind it is exactly the incident this pays for: `.sweptGhost` is the
    /// only reason nobody in this app chose — the notch library re-fronted a
    /// panel on a screen-parameter change and it rendered latched content.
    enum SummonWithdrawal: String, Codable, Sendable, CaseIterable {
        case recovered
        case timedOut
        case dismissed
        case displaced
        case sweptGhost
    }

    // MARK: - App

    case appLaunched(build: Int)
    /// The health notch went up / came down (#140) — without these, summon
    /// history was unrecoverable from events.json.
    case healthSummonFired(trigger: SummonTrigger)
    /// Which summon left, and why (#149).
    case healthSummonWithdrawn(trigger: SummonTrigger, reason: SummonWithdrawal)
    /// Retired (#149): superseded by `healthSummonWithdrawn`, which names the
    /// trigger and the reason instead of only the fact. Kept so a persisted
    /// events.json carrying it still decodes rather than being moved aside as
    /// corrupt — the same reason `tapEventsStalled` survives.
    case healthSummonCleared

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

    // MARK: - Transcription

    case modelLoad(model: ModelKind, outcome: Outcome, seconds: Double, fromCache: Bool)
    case modelCacheCleared
    case transcribed(chunks: Int, failedChunks: Int, samples: Int, characters: Int, ms: Int)
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

    // MARK: - Meetings

    case detectionLifecycle(running: Bool)
    case detectionDeviceListChanged(added: Int, removed: Int, monitored: Int)
    case detectionListenerFailed(osStatus: Int32)
    case detectionSignal(active: Bool)
    case detectionAppScan(found: Bool)
    case detectionPrompt(disposition: PromptDisposition)
    case notificationAuthorization(outcome: Outcome)
    case notificationPosted(outcome: Outcome)

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
        case .appLaunched, .healthSummonFired, .healthSummonWithdrawn, .healthSummonCleared:
            return .app

        case .permissionTransition, .tapCreate, .tapReinstall, .tapDisabledByOS,
             .tapDiedDuringRecording, .tapEventsStalled, .tapEventsResumed,
             .tapGaveUp, .secureInputChanged, .pasteAttempt:
            return .input

        case .captureStart, .captureFailed, .captureStopped, .captureRetryScheduled,
             .captureGaveUp, .captureReconfigured, .inputDeviceSelected, .deviceSwitched,
             .noFramesRecovery, .micStalled, .micRecovered, .micFramesFlowing,
             .systemAudioCapture, .systemAudioGaveUp, .recordingSaved:
            return .audio

        case .modelLoad, .modelCacheCleared, .transcribed, .echoSuppressed:
            return .transcription

        case .apiCall:
            return .intelligence

        case .dictationRecorded, .dictationZeroFrames, .dictationPasted,
             .dictationUpgrade, .dictationDiscarded:
            return .dictation

        case .detectionLifecycle, .detectionDeviceListChanged, .detectionListenerFailed,
             .detectionSignal, .detectionAppScan, .detectionPrompt,
             .notificationAuthorization, .notificationPosted:
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
        case .healthSummonFired: return "healthSummonFired"
        case .healthSummonWithdrawn: return "healthSummonWithdrawn"
        case .healthSummonCleared: return "healthSummonCleared"
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
        case .modelLoad: return "modelLoad"
        case .modelCacheCleared: return "modelCacheCleared"
        case .transcribed: return "transcribed"
        case .echoSuppressed: return "echoSuppressed"
        case .apiCall: return "apiCall"
        case .dictationRecorded: return "dictationRecorded"
        case .dictationZeroFrames: return "dictationZeroFrames"
        case .dictationPasted: return "dictationPasted"
        case .dictationUpgrade: return "dictationUpgrade"
        case .dictationDiscarded: return "dictationDiscarded"
        case .detectionLifecycle: return "detectionLifecycle"
        case .detectionDeviceListChanged: return "detectionDeviceListChanged"
        case .detectionListenerFailed: return "detectionListenerFailed"
        case .detectionSignal: return "detectionSignal"
        case .detectionAppScan: return "detectionAppScan"
        case .detectionPrompt: return "detectionPrompt"
        case .notificationAuthorization: return "notificationAuthorization"
        case .notificationPosted: return "notificationPosted"
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
