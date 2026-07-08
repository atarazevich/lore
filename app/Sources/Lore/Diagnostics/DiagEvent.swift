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

    /// Which LLM call was made — never the prompt, never the response. Also
    /// names which dictation upgrade ran (`.cleanup` / `.translate`): an
    /// upgrade *is* one of these calls, so it needs no parallel enum.
    enum Endpoint: String, Codable, Sendable, CaseIterable {
        case cleanup
        case translate
        case askLore
        case refinement
        case keyHealth
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

    // MARK: - App

    case appLaunched(build: Int)

    // MARK: - Input (hotkey, permissions, paste)

    case permissionTransition(permission: Permission, granted: Bool)
    case tapCreate(outcome: Outcome, osStatus: Int32?)
    case tapReinstall(outcome: Outcome)
    case tapDisabledByOS
    case tapDiedDuringRecording
    /// Emitted once when our modifier-event stream goes quiet *while the OS is
    /// still delivering key events elsewhere* — never on plain user idleness.
    case tapEventsStalled(seconds: Int)
    case tapEventsResumed
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
    case corruptFileAside(artifact: Artifact)
    /// Failure only. A *preempted* import (`.cancelled`, #43) is the normal
    /// "a recording started" path and is not recorded at all.
    case sessionImportFailed
}

// MARK: - Grouping

extension DiagEvent {
    var subsystem: DiagSubsystem {
        switch self {
        case .appLaunched:
            return .app

        case .permissionTransition, .tapCreate, .tapReinstall, .tapDisabledByOS,
             .tapDiedDuringRecording, .tapEventsStalled, .tapEventsResumed,
             .secureInputChanged, .pasteAttempt:
            return .input

        case .captureStart, .captureFailed, .captureStopped, .captureRetryScheduled,
             .captureGaveUp, .captureReconfigured, .inputDeviceSelected, .deviceSwitched,
             .noFramesRecovery, .micStalled, .micRecovered, .systemAudioCapture,
             .recordingSaved:
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

        case .historyWriteFailed, .historyMigrated, .corruptFileAside, .sessionImportFailed:
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
        case .permissionTransition: return "permissionTransition"
        case .tapCreate: return "tapCreate"
        case .tapReinstall: return "tapReinstall"
        case .tapDisabledByOS: return "tapDisabledByOS"
        case .tapDiedDuringRecording: return "tapDiedDuringRecording"
        case .tapEventsStalled: return "tapEventsStalled"
        case .tapEventsResumed: return "tapEventsResumed"
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
        case .systemAudioCapture: return "systemAudioCapture"
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
struct DiagRecord: Codable, Sendable, Equatable {
    let at: Date
    let event: DiagEvent

    var subsystem: DiagSubsystem { event.subsystem }

    init(at: Date = Date(), event: DiagEvent) {
        self.at = at
        self.event = event
    }
}
