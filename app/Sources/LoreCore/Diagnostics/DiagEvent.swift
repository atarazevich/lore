import Foundation
import LoreFormat

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
    /// Agents' spoken replies read aloud by lore (#236).
    case agentReplies
    /// The iPhone recorder (#306). The Mac never records these.
    case phone
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
public enum DiagEvent: Codable, Sendable, Equatable {

    // MARK: - Supporting types
    //
    // Nested rather than top-level: `Outcome`, `Permission` and `Endpoint` are
    // names a shared module should not claim outright.

    public enum Outcome: String, Codable, Sendable, CaseIterable {
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
    /// One of a meeting's two recorded tracks.
    public typealias RecordingTrack = LoreFormat.RecordingTrack

    public enum DeviceKind: String, Codable, Sendable, CaseIterable {
        case builtIn
        case wireless
        case wired
        case virtual
    }

    public enum Permission: String, Codable, Sendable, CaseIterable {
        case accessibility
        case inputMonitoring
        case microphone
        case notifications
    }

    /// Which screen of the first-run flow was reached (#150). A closed enum, so
    /// the timeline can say where a machine stopped setting itself up without
    /// any of the flow's copy entering the event stream.
    public enum OnboardingStep: String, Codable, Sendable, CaseIterable {
        case welcome
        case permissions
        case fnKey
        case tryIt
        case ready
    }

    /// Where the drag card docked against the System Settings window (#300):
    /// under it, over its empty lower area, or pushed onto the screen when
    /// neither fits.
    public enum GrantCardDock: String, Codable, Sendable, CaseIterable {
        case below
        case inside
        case clamped
    }

    /// Why the drag card went without the grant being read.
    public enum GrantCardExit: String, Codable, Sendable, CaseIterable {
        /// System Settings' window was not found after Allow.
        case settingsNotFound
        /// System Settings' window went away while the card was up.
        case settingsClosed
        /// Onboarding moved on, or another card replaced this one.
        case onboardingMoved
    }

    /// Which API call was made — never the prompt, never the response. Also
    /// names which dictation upgrade ran (`.cleanup` / `.translate`): an
    /// upgrade *is* one of these calls, so it needs no parallel enum.
    public enum Endpoint: String, Codable, Sendable, CaseIterable {
        case cleanup
        case translate
        case askLore
        case refinement
        case keyHealth
        /// Speechify TTS synthesis (#105) — never the selected text.
        case readAloud
    }

    /// Why an answer the model gave was not used (#321, #322).
    public enum OutputRejection: String, Codable, Sendable, CaseIterable {
        /// A translation that is confidently not in the language asked for.
        case wrongLanguage
        /// The answer stopped at the output limit, cut off (#322).
        case cutOff
        /// The answer ended for any reason other than finishing, or gave none.
        case unfinished
        /// The answer carried no text.
        case empty
    }

    public enum ModelKind: String, Codable, Sendable, CaseIterable {
        case asr
        case vad
        /// Nemotron-3 speaker diarization: every speaker pass, the meeting's
        /// (#269), the phone's (#308) and `lore transcribe --speakers` (#276).
        case diarizer
        /// Retired (#328) with Community-1, which led the Mac's speaker passes
        /// in 3.8.26–3.8.29. Nothing loads it any more; it stays so a persisted
        /// events.json carrying it still decodes rather than being moved aside
        /// as corrupt — the same reason `tapEventsStalled` survives.
        case communityDiarizer
        /// CAM++ speaker embedding: the voiceprints of the speaker pass (#269).
        case voiceprint
    }

    /// Where a HAL capture attempt died. Pairs with an `OSStatus`.
    public enum CaptureStage: String, Codable, Sendable, CaseIterable {
        case noDefaultDevice
        case invalidFormat
        case createIOProc
        case startDevice
        case installFormatListener
        case queryStreamFormat
    }

    public enum CaptureStopReason: String, Codable, Sendable, CaseIterable {
        case lastConsumerLeft
        case deviceSwitch
        case reconfigure
    }

    public enum ReconfigureReason: String, Codable, Sendable, CaseIterable {
        case streamFormatChanged
        case silentTooLong
        case noFramesEver
    }

    /// Which of the three echo-suppression paths fired (all numbers, no text).
    public enum EchoPath: String, Codable, Sendable, CaseIterable {
        case liveForward
        case retroactive
        case batch
    }

    public enum PasteKind: String, Codable, Sendable, CaseIterable {
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
    public enum ClipboardRead: String, Codable, Sendable, CaseIterable {
        case changeCount
        case types
        case data
    }

    /// Why a detection prompt did or did not reach the user.
    public enum PromptDisposition: String, Codable, Sendable, CaseIterable {
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
    public enum PromptWindowEvent: String, Codable, Sendable, CaseIterable {
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

    /// Which gesture a confirmed dictation delete came from (#243): one row's
    /// trash or Delete, the select bar, or Delete All in Settings.
    public enum DictationDeleteScope: String, Codable, Sendable, CaseIterable {
        case one
        case several
        case all
        /// A scope a newer build knows and this one does not.
        case unknown

        /// A scope this version does not know reads as `.unknown`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = DictationDeleteScope(rawValue: raw) ?? .unknown
        }
    }

    /// Where a dictation was marked for later or unmarked (#324): K in the
    /// bubble (Fn+K or a click on the letter), the history row's bookmark, or
    /// the row's right-click menu.
    public enum MarkSource: String, Codable, Sendable, CaseIterable {
        case bubble
        case row
        case menu
        /// A source a newer build knows and this one does not.
        case unknown

        /// A source this version does not know reads as `.unknown`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = MarkSource(rawValue: raw) ?? .unknown
        }
    }

    /// Why a history write was refused (#265). A closed set read off the
    /// error's domain and code — never its description, which can name a path.
    public enum HistoryWriteReason: String, Codable, Sendable, CaseIterable {
        /// The volume or the user's quota is full.
        case noSpace
        /// The folder or the volume refuses writes: no permission, read-only.
        case permission
        case other

        /// Classify a write error, following underlying errors down: `Data`
        /// reports a full disk as a Cocoa error with the POSIX one beneath it.
        public init(error: any Error) {
            self = error.underlyingChain.lazy.compactMap(Self.reason(for:)).first ?? .other
        }

        private static func reason(for error: NSError) -> HistoryWriteReason? {
            switch (error.domain, error.code) {
            case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
                 (NSPOSIXErrorDomain, Int(ENOSPC)), (NSPOSIXErrorDomain, Int(EDQUOT)):
                .noSpace
            case (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
                 (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError),
                 (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM)),
                 (NSPOSIXErrorDomain, Int(EROFS)):
                .permission
            default: nil
            }
        }
    }

    /// Which on-disk artifact was found corrupt and moved aside. A closed set —
    /// never the file's path, which can carry a session id.
    public enum Artifact: String, Codable, Sendable, CaseIterable {
        case chatJSON
        case historyEntry
        case legacyHistoryBlob
        case eventsJSON
    }

    /// How the one-time notes-folder move (#148) ended. `alreadyDone` is the
    /// one value never emitted: it is every launch after the first, and one
    /// event per launch forever would evict the trace it belongs to.
    public enum NotesMigration: String, Codable, Sendable, CaseIterable {
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
    public enum HealthTrigger: String, Codable, Sendable, CaseIterable {
        case identityMigration
        case captureFailed
        /// The system-audio tap, not the microphone (#149) — different remedy,
        /// so a different sentence.
        case systemAudioFailed
        case pasteFailed
        case modelLoadFailed
        /// macOS is blocking lore's key listener and paste (#338): kept an old
        /// permission entry after a reinstall, so the switches look on and do
        /// nothing. Raised only by an effect — the listener refused while a
        /// grant reads off, or a paste posted while lore was untrusted — never
        /// by a permission read alone.
        case permissionsBlocked
        /// A trigger a newer build knows and this one does not.
        case unknown

        /// A trigger this version does not know reads as `.unknown`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = HealthTrigger(rawValue: raw) ?? .unknown
        }
    }

    /// Where "Fix permissions" has taken the blocked condition (#338): lore
    /// cleared its own entries and asked again, and waits for the switches; or
    /// the switches are on and the key listener still fails, so a restart is
    /// what is left.
    public enum PermissionFixStage: String, Codable, Sendable, CaseIterable {
        case waiting
        case restart
        /// A stage a newer build knows and this one does not.
        case unknown

        /// A stage this version does not know reads as `.unknown`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = PermissionFixStage(rawValue: raw) ?? .unknown
        }
    }

    /// Which audio stream a conversion failure hit: the 16 kHz conversion for
    /// transcription (#271), or the system tap's return to its declared rate
    /// (#272).
    public enum ResampleSource: String, Codable, Sendable, CaseIterable {
        case dictation
        case meetingMic
        case meetingSystem
        /// A recorded file read for batch transcription.
        case file
        /// The system tap read at its measured rate and resampled back to its
        /// declared one (#272). Here the buffer is not lost but passed through
        /// unconverted.
        case systemTapRate
        /// The iPhone's microphone, converted for its live text (#313 S13).
        case phone
    }

    /// Why a conversion failed. The 16 kHz conversion loses that audio
    /// (#271); the system tap's rate correction passes it through
    /// unconverted (#272).
    public enum ResampleFailure: String, Codable, Sendable, CaseIterable {
        /// No converter could be built for the input format.
        case converterUnavailable
        /// `AVAudioConverter.convert` returned an error; the converter is rebuilt.
        case converterError
        /// The converter returned without asking for the buffer.
        case bufferNotTaken
    }

    /// What summoned a transcript repair job (#166). A closed set — never the
    /// session id, which embeds the meeting's date and time.
    public enum RepairReason: String, Codable, Sendable, CaseIterable {
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
    public enum RepairOutcome: String, Codable, Sendable, CaseIterable {
        case repaired
        case failed
        case unavailable
    }

    /// Where the speaker pass stopped (#269). The pass never fails the
    /// transcript; this names what left the meeting without a speaker map.
    public enum SpeakerStage: String, Codable, Sendable, CaseIterable {
        /// The saved transcript and the lines kept for it do not match (or one is gone).
        case transcript
        /// A phone note's lines (where its words are) are gone or do not
        /// match its transcript (#308). Only a new transcription writes them,
        /// so running the pass again cannot help.
        case lines
        case models
        case diarization
        case voiceprints
        case write
    }

    /// Which of the naming files could not be read (#269), and why.
    public typealias SpeakerNamesFile = LoreFormat.SpeakerNamesFile
    public typealias SpeakerNamesProblem = LoreFormat.SpeakerNamesProblem

    /// Why a naming change was not saved (#269).
    public enum SpeakerNamingProblem: String, Codable, Sendable, CaseIterable {
        /// The lines or the speaker map on disk are not the ones the change was made on.
        case staleBasis
        /// A naming file cannot be read, so it is not written over.
        case unreadableFile
        case writeFailed
    }

    /// Why a summon left the screen (#149). Retired with the surface (#151) and
    /// kept for the same reason as the events that carry it: a persisted
    /// events.json must keep decoding. `.sweptGhost` was the reason nobody in
    /// this app chose — the notch library re-fronted a panel on a
    /// screen-parameter change and it rendered latched content, which is the
    /// class of fault that ended the surface.
    public enum SummonWithdrawal: String, Codable, Sendable, CaseIterable {
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
    public enum HintWithdrawal: String, Codable, Sendable, CaseIterable {
        case timedOut
        case closed
        case actionPerformed
        case conditionCleared
        case recordingEnded
        case displaced
    }

    /// What started an agent reply speaking (#256). `arrival` and `continued`
    /// are the two a reply starts by itself — the reply came in with nothing
    /// speaking, or the one before it finished — kept apart so "how often a
    /// reading that started by itself was stopped" can tell a fresh reply from
    /// the queue running on. `click` is the pointer on a reply, which is what
    /// plays and resumes since #263; `next`/`previous` a move. `key` is an
    /// explicit play on the keyboard: Fn+R (#259, and again since #278).
    public enum ReplyStartTrigger: String, Codable, Sendable, CaseIterable {
        case arrival
        case continued
        case click
        case key
        case next
        case previous
    }

    /// Why a speaking agent reply stopped short of its end (#256). `mute` holds
    /// reading the same way the microphone does, so it pauses a reply too.
    /// `click` is the pointer on the reply being read (#263); `key` is Fn+R
    /// (#259, and again since #278).
    public enum ReplyPauseReason: String, Codable, Sendable, CaseIterable {
        case click
        case key
        case escape
        case microphone
        case mute
    }

    /// Who put the player on screen or took it away (#263) — the key, the
    /// header's ×, or the Esc that follows a pause. Visibility only: a reply
    /// being read carries on either way. `key` is a tap of the talk key since
    /// #278; before it, Fn+R. `reading` is a reply beginning to be read over a
    /// player the owner had put away (#285): it shows while the reply speaks.
    public enum ReplyVisibility: String, Codable, Sendable, CaseIterable {
        case key
        case closeMark
        case escape
        case reading
    }

    public enum ReplyMove: String, Codable, Sendable, CaseIterable {
        case previous
        case next
    }

    /// Why a reply was not taken, and its words left to `say` (#257). The
    /// switch being off is the designed answer; `unreadableRequest` is a line
    /// on the command socket that decoded as no request at all — an oversize
    /// reply, or a truncated write.
    public enum ReplyDeclined: String, Codable, Sendable, CaseIterable {
        case switchOff
        case unreadableRequest
    }

    /// Where bringing in a note from the iPhone stopped (#309): one of its
    /// files in iCloud Drive could not be read or downloaded — the recording,
    /// the transcript, or another of the note's files — the copy could not be
    /// written into lore's own folder, or a Mac meeting already has its id.
    /// Which file, never its name.
    public enum PhoneNoteStage: String, Codable, Sendable, CaseIterable {
        case audio
        case transcript
        case noteFile
        case copy
        case idInUse
    }

    /// Where a reply's chat was when the user went to it (#258) — read live,
    /// never guessed: the host app running with the chat open, running with the
    /// chat closed, or not running.
    public enum ReplyChatState: String, Codable, Sendable, CaseIterable {
        case appRunningChatOpen
        case appRunningChatClosed
        case appNotRunning
    }

    /// Why the iPhone recorder's capture stopped (#306): the same closed set
    /// a note's gap carries, so the trace and the note cannot disagree.
    public typealias PhoneStopReason = LoreFormat.PhoneNoteGap.Reason

    /// Who brought the iPhone recorder's capture back (#306): the user's tap,
    /// or the system ending the interruption.
    public enum PhoneResumer: String, Codable, Sendable, CaseIterable {
        case user
        case system
    }

    /// Why the iPhone's Resume is blocked, as its reason line names it (#306):
    /// the app is in the background, another app holds the microphone, a call
    /// is on, the microphone permission is off, no input is available, or the
    /// input gives no audio.
    public enum PhoneResumeBlock: String, Codable, Sendable, CaseIterable {
        case background
        case microphoneBusy
        case call
        case noPermission
        case noInput
        case noAudio
        /// A cause a newer phone knows and this build does not.
        case unknown

        /// A cause this version does not know reads as `.unknown`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = PhoneResumeBlock(rawValue: raw) ?? .unknown
        }
    }

    /// How the iPhone's Resume reason line went away (#306): capture resumed,
    /// the recording was stopped, or the cause went away on its own.
    public enum PhoneResumeBlockClear: String, Codable, Sendable, CaseIterable {
        case resumed
        case stopped
        case causeGone
        /// A way a newer phone knows and this build does not.
        case unknown

        /// A way this version does not know reads as `.unknown`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = PhoneResumeBlockClear(rawValue: raw) ?? .unknown
        }
    }

    /// How joining a phone recording's segments into one file ended (#306):
    /// it worked, it failed, or the joined file's length did not match the
    /// segments' total.
    public enum PhoneSegmentMerge: String, Codable, Sendable, CaseIterable {
        case ok
        case failed
        case lengthMismatch
        /// An outcome a newer phone knows and this build does not.
        case unknown

        /// An outcome this version does not know reads as `.unknown`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = PhoneSegmentMerge(rawValue: raw) ?? .unknown
        }
    }

    /// Why the iPhone's Lock Screen card went away (#313 S3): the user
    /// dismissed it, iOS ended it at its 8 h limit, lore's setting switched it
    /// off, iOS's Live Activities switch is off, or the recording stopped.
    public enum PhoneCardGone: String, Codable, Sendable, CaseIterable {
        case dismissed
        case systemEnded
        case switchedOff
        case liveActivitiesOff
        case stopped
        /// A reason a newer phone knows and this build does not.
        case unknown

        /// A reason this version does not know reads as `.unknown`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = PhoneCardGone(rawValue: raw) ?? .unknown
        }
    }

    /// What the Watch asked the iPhone's recorder to do (#311).
    public enum PhoneWatchCommand: String, Codable, Sendable, CaseIterable {
        case start
        case pause
        case resume
        case stop
        /// A command a newer watch knows and this build does not.
        case unknown

        /// A command this version does not know reads as `.unknown`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = PhoneWatchCommand(rawValue: raw) ?? .unknown
        }
    }

    /// What became of a Watch command on the iPhone (#311): done, it needs
    /// lore in the foreground, the recorder refused it, or it was stale (the
    /// watch face showed a different recording than the phone's current one).
    public enum PhoneWatchOutcome: String, Codable, Sendable, CaseIterable {
        case done
        case needsForeground
        case refused
        case stale
        /// An outcome a newer phone knows and this build does not.
        case unknown

        /// An outcome this version does not know reads as `.unknown`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = PhoneWatchOutcome(rawValue: raw) ?? .unknown
        }
    }

    /// Why the iPhone could not make a note's title on the device (#306):
    /// the on-device model was unavailable, the generation threw, or it
    /// returned no title (`MeetingEnrichment` gave nil or an empty title).
    public enum PhoneTitleFailure: String, Codable, Sendable, CaseIterable {
        case modelUnavailable
        case generationFailed
        case empty
        /// A reason a newer phone knows and this build does not.
        case unknown

        /// A reason this version does not know reads as `.unknown`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = PhoneTitleFailure(rawValue: raw) ?? .unknown
        }
    }

    /// Why a phone note's speaker pass found no one to label (#308): the
    /// note has no text, or no voice was heard in its recording. An empty
    /// result, not a failure; the same note gives it again.
    public enum PhoneSpeakersAbsence: String, Codable, Sendable, CaseIterable {
        case noText
        case noVoice
        /// A reason a newer phone knows and this build does not.
        case unknown

        /// A reason this version does not know reads as `.unknown`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = PhoneSpeakersAbsence(rawValue: raw) ?? .unknown
        }
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

    /// "Restart lore" was chosen and the quit went through (#336): a shell
    /// outside the process waits for it to exit, then opens the same bundle.
    /// The restart came back when the next event is `appLaunched`;
    /// `waiterStarted` false means that shell could not be started.
    case appRelaunch(waiterStarted: Bool)

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
    /// The drag card docked by System Settings for one grant (#300).
    case grantCardShown(permission: Permission, dock: GrantCardDock)
    /// Another app came to the front, so the card faded out…
    case grantCardSteppedAside(permission: Permission)
    /// …and System Settings or lore is in front again.
    case grantCardReturned(permission: Permission)
    /// A fresh process read the grant while the card was up: the one thing
    /// that turns the card into "lore is allowed".
    case grantCardAllowed(permission: Permission)
    /// The card went without the grant being read.
    case grantCardGone(permission: Permission, reason: GrantCardExit)
    /// A fresh-process grant reading could not be had, so the tick read
    /// in-process. Recorded on the edge, not per tick.
    case grantCheckFailed(reason: GrantCheckFailure)

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
    /// When the hold window closed, the system's keyboard said the talk key
    /// was up before lore had read its release (#343). `confirmed`: it was —
    /// the release, by its own timestamp, came inside the window, and the
    /// press was a tap. Not confirmed: the key was held through the window
    /// after all (no release came, or it came later), and the press recorded.
    /// A key whose state the system misreads leaves a run of unconfirmed ones.
    case talkKeyReleasedInWindow(key: TalkKey, confirmed: Bool)
    /// "Fix permissions" removed lore's own entry for one grant (#338):
    /// `tccutil reset <service> com.lore.app`, run as the user. `exitStatus` is
    /// tccutil's; nil when it could not be started or did not finish.
    case permissionReset(permission: Permission, exitStatus: Int32?)
    /// The blocked condition moved to a later stage of its fix (#338).
    case permissionFixStage(stage: PermissionFixStage)
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
    /// The system tap's rate, measured from its capture stamps (#272): the
    /// first reading of every tap, then each change of the rate its audio is
    /// read at, at most one per ten seconds. `declared` is the tap's format,
    /// `device` the output device's nominal rate when the tap was made (nil
    /// when unreadable), `delivered` the measurement — nil when the tap gave
    /// no reading by the end of its hold, so its audio passes as declared. A
    /// delivered rate away from the declared one is the half-speed tap, and
    /// its audio is resampled back to `declared`.
    case systemAudioRate(declared: Int, device: Int?, delivered: Int?)
    /// Latched: at most one per recording, never one per audio buffer.
    case recordingSaved(outcome: Outcome, frames: Int)
    /// A meeting's merged recording in the notes folder (#290), once per
    /// meeting: written, given up, or never queued — its marker could not
    /// be written.
    case recordingExported(outcome: Outcome, frames: Int)
    /// A meeting's tracks were due to go and stayed (#330): no merged
    /// recording in the notes folder holds them, and saving was not turned
    /// off. Once per meeting: the kept marker beside the tracks dedupes it.
    case recordingTracksKept
    /// The meeting asked for audio and none will be captured: capture started
    /// with no session to own the tracks, so no recording was created
    /// (#177). Not a `recordingSaved(.failed)` — nothing was saved and nothing
    /// was attempted, and reusing a save outcome here would put a second one in
    /// the ring for a meeting that still records its own.
    case recordingUnowned
    /// A buffer reached the meeting recording without its capture time, so it
    /// could not be placed on the capture clock (#268). Latched: once per
    /// track per recording.
    case recordingBufferUnstamped(track: RecordingTrack)
    /// Audio did not make it through the 16 kHz conversion (#271). At most one
    /// per source and reason per 10 s, carrying the buffers and frames lost
    /// since that pair's previous event (a failing converter fails on every
    /// buffer).
    case resampleFailed(source: ResampleSource, reason: ResampleFailure, buffers: Int, frames: Int)

    // MARK: - Transcription

    /// `speechModel` names which speech model an ASR load was (#299); nil for
    /// every other kind, and in events written before it existed.
    case modelLoad(model: ModelKind, outcome: Outcome, seconds: Double, fromCache: Bool, speechModel: SpeechModel? = nil)
    case modelCacheCleared
    /// The next speech model, prepared in the background while the current one
    /// keeps transcribing (#299): one event for the download and compile, one
    /// per set of instances built at a quiet moment. Not a `modelLoad` on
    /// purpose: the health surface reads those, and a Mac whose dictation
    /// works has nothing to be told when the next model cannot download yet.
    case speechModelPrepared(model: SpeechModel, outcome: Outcome, seconds: Double)
    /// Every cache now serves Parakeet Ultra in place of v3, taken at a moment
    /// nothing was recording or transcribing (#299). `remembered` is false
    /// when the marker could not be written: the next launch starts on v3
    /// again and repeats the upgrade.
    case speechModelSwapped(remembered: Bool)
    /// The launch after the swap removed v3's folders before anything loaded
    /// (#299); `.failed` when one could not go. Recorded only when one was there.
    case speechModelRemoved(outcome: Outcome)
    /// Launch removed half-finished compiles of the speech model from lore's
    /// own Neural Engine cache (#294): `*.tmp.<pid>_*.bundle` folders whose
    /// process is gone. Recorded only when any went.
    case modelCacheOrphansRemoved(folders: Int)
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
    /// The speaker pass wrote a meeting's speaker map (#269): how many voices
    /// it found across both tracks, how many lines it placed, whether the
    /// owner's voiceprint was there to compare against.
    case speakerMapSaved(clusters: Int, records: Int, ownerKnown: Bool, ms: Int)
    /// The speaker pass stopped at `stage`; the meeting keeps its transcript
    /// and has no speaker map.
    case speakerMapFailed(stage: SpeakerStage, ms: Int)
    /// The speaker pass failed `attempts` times for one meeting; its tracks
    /// were deleted without a map, when a saved recording holds them (#330) —
    /// or, for a pass asked for with Who spoke?
    /// (#308), kept, so it can be asked for again.
    case speakerMapGaveUp(attempts: Int)
    /// Who spoke? asked for a meeting's speaker pass (#308), with a fresh
    /// count of attempts; any words saying an earlier one could not finish go.
    case speakerPassRequested
    /// The owner closed the words saying the last pass asked for could not
    /// finish (#308); they stay closed for that meeting until it is asked again.
    case speakerFailureDismissed
    /// With "Separate speakers" off (#308), a meeting's tracks were kept
    /// compressed for a later pass: `.ok`, or `.failed` with the recorded
    /// ones left in place.
    case speakerTracksKept(outcome: Outcome)
    /// A count kept beside a meeting's tracks (attempts, or whether they
    /// were asked for) could not be written; this launch still holds it.
    case stashCountNotSaved
    /// A second pass's transcript could not be written; the pass failed and
    /// kept its audio for the retry.
    case transcriptSaveFailed
    /// The owner's voiceprint was made from dictation speech: `.ok` stored,
    /// `.unknown` too little speech to store yet (used for this map only),
    /// `.failed` it could not be made (the map goes on without it).
    case ownerVoiceprint(outcome: Outcome, recordings: Int, speechSeconds: Int)
    /// A naming file could not be read: readers go without it, and nothing
    /// writes over it, so the names in it are kept.
    case speakerNamesUnreadable(file: SpeakerNamesFile, problem: SpeakerNamesProblem)
    /// A naming or merge from the review was not saved; the review reads the
    /// meeting from disk again.
    case speakerNamingNotSaved(reason: SpeakerNamingProblem)
    /// `lore transcribe` asked the app for a file's transcript (#254). Never the
    /// path, never the text: which file and what it said stay between the
    /// command and the person who ran it.
    case commandTranscribeReceived
    /// The transcript went back to the command, `ms` after the request arrived.
    /// `complete` is false when the file stopped decoding part-way.
    case commandTranscribeFinished(ms: Int, complete: Bool)
    /// No transcript went back; `reason` is the sentence the command printed,
    /// as its closed case.
    case commandTranscribeFailed(reason: TranscribeFailure, ms: Int)
    /// The command went away (Ctrl-C) and the work stopped with no one to answer.
    case commandTranscribeAbandoned(ms: Int)
    /// `lore transcribe --speakers` (#276) answered the plain transcript:
    /// `.models` the diarizer did not load, `.diarization` it failed while
    /// hearing the file, `.transcript` the transcript had no word timings to
    /// place.
    case commandSpeakersNotFound(stage: SpeakerStage)
    /// A speaker pass on the Mac fell back to its one second try and it
    /// worked (#328): `.models` the diarizer did not load the first time,
    /// `.diarization` it failed while hearing. Recorded once the second try
    /// has heard the file; a second try that fails is the pass's own stop
    /// (`speakerMapFailed`, `commandSpeakersNotFound`). In 3.8.26–3.8.29 it
    /// meant Community-1 failed twice and Nemotron-3 heard the file instead.
    case diarizerFellBack(stage: SpeakerStage)
    /// Per-session (or per-batch-pass) summary, never per suppressed utterance —
    /// an echoey meeting would otherwise evict the whole ring. Numbers only:
    /// never `you='…' them='…'`.
    case echoSuppressed(path: EchoPath, count: Int, meanJaccard: Double)

    // MARK: - Intelligence (OpenAI)

    case apiCall(endpoint: Endpoint, outcome: Outcome, httpStatus: Int?, ms: Int)
    /// The call came back but its answer was not used (#321). Whether it was
    /// asked for again reads off the `apiCall` that follows, as #103's retries
    /// do. Never the text itself — only why it was turned down.
    case apiOutputRejected(endpoint: Endpoint, reason: OutputRejection)

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
    /// A take whose audio was saved but never transcribed — a restart caught
    /// it (#294) — is being transcribed by itself after launch, into history
    /// only. `attempt` counts across launches and never passes three, so a
    /// take that takes the process down with it cannot loop.
    case strandedDictationAttempt(attempt: Int)
    /// …and how that attempt ended: `.ok` its words are in history, `.failed`
    /// the row now says why, as any dictation's would, `.unknown` nothing
    /// changed — the audio could not be read, or the attempt was stopped — and
    /// a later launch may try again while attempts remain.
    case strandedDictationSettled(outcome: Outcome)

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
    /// The owner confirmed deleting dictations (#243), so a row that is gone
    /// reads as deleted, never as lost: `deleted` went to the Trash, `kept`
    /// stayed in history whole because a file of theirs could not be moved,
    /// `incomplete` stayed without a file that went to the Trash and could not
    /// be put back. Counts and the gesture only, never which dictation or what
    /// it said.
    case dictationsDeleted(scope: DictationDeleteScope, deleted: Int, kept: Int, incomplete: Int)
    /// A delete's alert had no lore window to appear on (#243): the
    /// confirmation (`afterDelete` false, nothing was deleted) or the report of
    /// what stayed (true). Never silent, even when nothing could be shown.
    case dictationDeleteAlertUnshown(afterDelete: Bool)
    /// A dictation was marked for later (`marked`) or unmarked (#324), and
    /// from where. K in the bubble is traced once, when the mark lands with
    /// the entry; a K pressed twice marks nothing and leaves no event.
    case dictationMarked(source: MarkSource, marked: Bool)
    /// The app read a take an agent appended to a sidecar while it ran
    /// (#324): one event a line. Never which dictation, nor the agent's name.
    case markTakeSeen
    /// A `.takes` sidecar whose dictation is gone went to the Trash (#324): a
    /// take that raced a delete. Never which dictation.
    case orphanTakesTrashed
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
    /// A note from the iPhone came into Meetings (#309). `hasTranscript` is
    /// false for a note the phone sent with audio only; the repair queue
    /// transcribes it.
    case phoneNoteImported(hasTranscript: Bool)
    /// Bringing one in failed at `stage`; `attempt` counts this note's
    /// failures across launches.
    case phoneNoteImportFailed(stage: PhoneNoteStage, attempt: Int)
    /// …and its tries are spent: the report under the switch may now show.
    case phoneNoteImportGaveUp(attempts: Int)
    /// A read of the iPhone notes folder was refused by macOS: the line under
    /// the switch says so. Recorded on the change, not on every read.
    case phoneNotesAccessRefused
    /// The first read that succeeded after a refusal; the line withdraws.
    case phoneNotesAccessRestored
    /// A read of the folder failed for a reason that is not a refusal; no line
    /// is shown for it. Recorded on the change, not on every read.
    case phoneNotesFolderUnreadable
    /// A note's report was on screen for the first time (one per note, ever).
    case phoneNoteReportShown
    /// The report withdrew itself: the note came in after all, or left the
    /// folder.
    case phoneNoteReportCleared
    /// The owner closed a note's report; it stays closed for that note.
    case phoneNoteReportDismissed

    // MARK: - Storage

    /// Failure only — a successful history write is the unremarkable case, and
    /// recording one per dictation would crowd the ring. `reason` is nil only
    /// on records written before #265, which carried none.
    case historyWriteFailed(reason: HistoryWriteReason?)
    /// Entries a refused write had left only in memory reached disk (#265):
    /// the clear that pairs with `historyWriteFailed`, recorded once per pass
    /// that saved any (`no-false-positives.md` §5).
    case historySaveRecovered(entries: Int)
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
    /// events.json loaded with `count` records this build cannot decode — a case
    /// or value from a newer build — kept in the ring as written rather than
    /// failing the whole file (#314). Once per load, never at zero.
    case unreadRecordsKept(count: Int)
    /// Failure only. A *preempted* import (`.cancelled`, #43) is the normal
    /// "a recording started" path and is not recorded at all.
    case sessionImportFailed

    // MARK: - Agent replies (#236)
    //
    // The whole feature's event set, added with the queue (#256); the receiver,
    // the chat action and the keys only call these. No case carries the reply's
    // text, the chat's name, a folder or an app — only whether a reply said
    // where it came from.

    case agentReplyArrived(hasHostApp: Bool, hasPane: Bool, hasSession: Bool)
    /// A reply the app did not take, so the command spoke it through `say`
    /// (#257) — the one answer to "why did lore not read this one". An
    /// unreadable line is recorded here because this is the loss it hides:
    /// `lore transcribe` prints its own failure, while a reply nobody could
    /// read is spoken with nothing to say why.
    case agentReplyDeclined(reason: ReplyDeclined)
    case agentReplyReadingStarted(trigger: ReplyStartTrigger)
    case agentReplyReadingFinished
    case agentReplyReadingPaused(by: ReplyPauseReason)
    /// An Esc within 2 s after an Esc that paused a reply, which reached the app
    /// in front — so the first was probably meant for it too. Since #263 the
    /// press straight after a pause is the player's own hide, and that one is
    /// not this: it went to the player, which is the opposite evidence.
    case agentReplyEscapeRepeated
    /// A microphone came into use while the feature was on; reading holds.
    case agentReplyHeldByMicrophone
    /// Every microphone stopped; reading had not begun on `waiting` replies.
    case agentReplyMicrophoneFreed(waiting: Int)
    case agentReplyMoved(direction: ReplyMove)
    case agentReplyChatOpened(state: ReplyChatState, outcome: Outcome)
    case agentReplyMute(on: Bool)
    /// The capsule that says how many replies wait went up (#260) — `muted`
    /// tells the two reasons apart: mute is on, or a microphone is in use.
    case agentReplyWaitingShown(muted: Bool, waiting: Int)
    /// …and came down, because its condition stopped being true.
    case agentReplyWaitingWithdrawn
    /// The owner put the player on screen (#263), or a reply began to be read
    /// over it put away (#285). Visibility only — nothing about it starts or
    /// stops a reply.
    case agentReplyPlayerShown(by: ReplyVisibility)
    /// …and put it away again. A reply being read carries on unheard-of by this.
    case agentReplyPlayerHidden(by: ReplyVisibility)
    /// The owner dragged the player to another place (#267). Where he put it is
    /// deliberately not here: a coordinate on his screen is as much about him as
    /// a folder name, and nothing about this event needs it.
    case agentReplyPlayerMoved

    // MARK: - iPhone recorder (#306)
    //
    // Recorded by the iPhone app through this module, so every stop, resume
    // and alert of a recording is traced (`no-false-positives.md` §5).

    /// Capture stopped under a recording, for the reason its note's gap names.
    case phoneCaptureStopped(reason: PhoneStopReason)
    /// Capture came back after a stop.
    case phoneCaptureResumed(by: PhoneResumer)
    /// A resume was attempted and the system would not restart capture.
    case phoneResumeRefused
    /// The reason line about Resume went up, naming why it is blocked.
    case phoneResumeBlocked(cause: PhoneResumeBlock)
    /// The reason line came down after `afterMs`, and how.
    case phoneResumeBlockCleared(afterMs: Int, how: PhoneResumeBlockClear)
    /// The automatic Resume retries ran out after `tries` attempts.
    case phoneResumeGaveUp(cause: PhoneResumeBlock, tries: Int)
    /// The audio writer stopped `atSeconds` into the recording.
    case phoneWriterDied(atSeconds: Int)
    /// A new audio segment of the recording was opened, numbered from 0.
    case phoneSegmentOpened(index: Int)
    /// The recording's `parts` segments were joined into one file in `ms`.
    case phoneSegmentsMerged(parts: Int, ms: Int, outcome: PhoneSegmentMerge)
    /// The stop alert went up, and came down.
    case phoneStopAlertShown
    case phoneStopAlertCleared
    /// The reminder that a recording is still stopped was delivered.
    case phoneReminderFired
    /// iOS ended the background task before transcription finished; the note
    /// is queued again.
    case phoneTranscriptionOutOfTime
    /// The note's title could not be made on the device.
    case phoneTitleFailed(reason: PhoneTitleFailure)
    /// A note's speaker pass ended with no one to label and wrote no map
    /// (#308); its failures stay `speakerMapFailed`, its maps `speakerMapSaved`.
    case phoneSpeakersNotFound(reason: PhoneSpeakersAbsence, ms: Int)
    /// The owner confirmed deleting notes on the phone (#313 S14): one record
    /// per confirmation, `count` the notes it removed — 1 for a swipe, N from
    /// Edit. A count and nothing else: no note's id, title or text.
    case phoneNotesDeleted(count: Int)
    /// The recording screen's "hard to hear" hint went up after 30 s of sound
    /// with no words (#313 S13), and came down when words returned; `afterMs`
    /// is how long it was up. Its own pair, not `hintShown`/`hintWithdrawn`:
    /// those name a Mac dictation hint, and a phone one there would read as
    /// the Mac's in a trace.
    case farVoiceHintShown
    case farVoiceHintCleared(afterMs: Int)
    /// The Lock Screen card went up for a recording (#313 S3); `putBack` is
    /// true when lore asked again for a card that was dismissed or ended.
    case phoneCardShown(putBack: Bool)
    /// The Lock Screen card went away, and why.
    case phoneCardGone(reason: PhoneCardGone)
    /// The Watch sent the iPhone's recorder a command, and what became of it (#311).
    case phoneWatchCommand(command: PhoneWatchCommand, outcome: PhoneWatchOutcome)
    /// The Watch became reachable or unreachable (#311); traced once per change.
    case phoneWatchReachability(reachable: Bool)
}

// MARK: - Grouping

extension DiagEvent {
    var subsystem: DiagSubsystem {
        switch self {
        case .appLaunched, .appLaunchRefused, .appRelaunch, .healthConditionSustained, .healthConditionCleared,
             .healthSummonFired, .healthSummonWithdrawn, .healthSummonCleared,
             .onboardingStarted, .onboardingStepShown, .onboardingDictationLanded,
             .onboardingCompleted, .grantCardShown, .grantCardSteppedAside,
             .grantCardReturned, .grantCardAllowed, .grantCardGone, .grantCheckFailed:
            return .app

        case .permissionTransition, .tapCreate, .tapReinstall, .tapDisabledByOS,
             .tapDiedDuringRecording, .tapEventsStalled, .tapEventsResumed,
             .tapGaveUp, .secureInputChanged, .talkKeyReleasedInWindow, .pasteAttempt, .permissionReset, .permissionFixStage:
            return .input

        case .captureStart, .captureFailed, .captureStopped, .captureRetryScheduled,
             .captureGaveUp, .captureReconfigured, .inputDeviceSelected, .deviceSwitched,
             .noFramesRecovery, .micStalled, .micRecovered, .micFramesFlowing,
             .systemAudioCapture, .systemAudioGaveUp, .systemAudioRate, .recordingSaved,
             .recordingExported, .recordingTracksKept, .recordingUnowned, .recordingBufferUnstamped,
             .resampleFailed:
            return .audio

        case .modelLoad, .modelCacheCleared, .modelCacheOrphansRemoved, .transcribed, .echoSuppressed,
             .speechModelPrepared, .speechModelSwapped, .speechModelRemoved,
             .transcriptRepairQueued, .transcriptRepairSettled,
             .speakerMapSaved, .speakerMapFailed, .speakerMapGaveUp, .ownerVoiceprint, .transcriptSaveFailed,
             .speakerPassRequested, .speakerFailureDismissed, .speakerTracksKept, .stashCountNotSaved,
             .speakerNamesUnreadable, .speakerNamingNotSaved,
             .commandTranscribeReceived, .commandTranscribeFinished, .commandTranscribeFailed,
             .commandTranscribeAbandoned, .commandSpeakersNotFound, .diarizerFellBack:
            return .transcription

        case .apiCall, .apiOutputRejected:
            return .intelligence

        case .dictationRecorded, .dictationZeroFrames, .dictationPasted,
             .dictationUpgrade, .dictationDiscarded,
             .dictationPaused, .dictationResumed, .dictationLocked,
             .strandedDictationAttempt, .strandedDictationSettled,
             .hintShown, .hintWithdrawn, .dictationItemCollected,
             .dictationItemSwitched, .dictationItemsPasted, .dictationItemsPruned, .dictationsDeleted,
             .dictationDeleteAlertUnshown, .dictationMarked, .markTakeSeen, .orphanTakesTrashed,
             .dictationScreenshotChord, .dictationScreenshotRedirected,
             .clipboardProbeRead:
            return .dictation

        case .detectionLifecycle, .detectionDeviceListChanged, .detectionListenerFailed,
             .detectionSignal, .detectionAppScan, .detectionPrompt, .promptWindow,
             .notificationAuthorization, .notificationPosted,
             .sessionPaused, .sessionResumed, .sessionResumeFailed,
             .phoneNoteImported, .phoneNoteImportFailed, .phoneNoteImportGaveUp,
             .phoneNotesAccessRefused, .phoneNotesAccessRestored, .phoneNotesFolderUnreadable,
             .phoneNoteReportShown, .phoneNoteReportCleared, .phoneNoteReportDismissed:
            return .meetings

        case .historyWriteFailed, .historySaveRecovered, .historyMigrated, .notesFolderMoveStarted,
             .notesFolderMigrated, .notesFolderLeftoverCleared, .corruptFileAside,
             .unreadRecordsKept, .sessionImportFailed:
            return .storage

        case .agentReplyArrived, .agentReplyDeclined,
             .agentReplyReadingStarted, .agentReplyReadingFinished,
             .agentReplyReadingPaused, .agentReplyEscapeRepeated, .agentReplyHeldByMicrophone,
             .agentReplyMicrophoneFreed, .agentReplyMoved, .agentReplyChatOpened,
             .agentReplyMute, .agentReplyWaitingShown, .agentReplyWaitingWithdrawn,
             .agentReplyPlayerShown, .agentReplyPlayerHidden, .agentReplyPlayerMoved:
            return .agentReplies

        case .phoneCaptureStopped, .phoneCaptureResumed, .phoneResumeRefused,
             .phoneResumeBlocked, .phoneResumeBlockCleared, .phoneResumeGaveUp,
             .phoneWriterDied, .phoneSegmentOpened, .phoneSegmentsMerged,
             .phoneStopAlertShown, .phoneStopAlertCleared, .phoneReminderFired,
             .phoneTranscriptionOutOfTime, .phoneTitleFailed, .phoneSpeakersNotFound,
             .phoneNotesDeleted, .farVoiceHintShown, .farVoiceHintCleared,
             .phoneCardShown, .phoneCardGone, .phoneWatchCommand,
             .phoneWatchReachability:
            return .phone
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
        case .appRelaunch: return "appRelaunch"
        case .healthConditionSustained: return "healthConditionSustained"
        case .healthConditionCleared: return "healthConditionCleared"
        case .healthSummonFired: return "healthSummonFired"
        case .healthSummonWithdrawn: return "healthSummonWithdrawn"
        case .healthSummonCleared: return "healthSummonCleared"
        case .onboardingStarted: return "onboardingStarted"
        case .onboardingStepShown: return "onboardingStepShown"
        case .onboardingDictationLanded: return "onboardingDictationLanded"
        case .onboardingCompleted: return "onboardingCompleted"
        case .grantCardShown: return "grantCardShown"
        case .grantCardSteppedAside: return "grantCardSteppedAside"
        case .grantCardReturned: return "grantCardReturned"
        case .grantCardAllowed: return "grantCardAllowed"
        case .grantCardGone: return "grantCardGone"
        case .grantCheckFailed: return "grantCheckFailed"
        case .permissionTransition: return "permissionTransition"
        case .tapCreate: return "tapCreate"
        case .tapReinstall: return "tapReinstall"
        case .tapDisabledByOS: return "tapDisabledByOS"
        case .tapDiedDuringRecording: return "tapDiedDuringRecording"
        case .tapEventsStalled: return "tapEventsStalled"
        case .tapEventsResumed: return "tapEventsResumed"
        case .tapGaveUp: return "tapGaveUp"
        case .secureInputChanged: return "secureInputChanged"
        case .talkKeyReleasedInWindow: return "talkKeyReleasedInWindow"
        case .pasteAttempt: return "pasteAttempt"
        case .permissionReset: return "permissionReset"
        case .permissionFixStage: return "permissionFixStage"
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
        case .systemAudioRate: return "systemAudioRate"
        case .recordingSaved: return "recordingSaved"
        case .recordingExported: return "recordingExported"
        case .recordingTracksKept: return "recordingTracksKept"
        case .recordingUnowned: return "recordingUnowned"
        case .recordingBufferUnstamped: return "recordingBufferUnstamped"
        case .resampleFailed: return "resampleFailed"
        case .modelLoad: return "modelLoad"
        case .modelCacheCleared: return "modelCacheCleared"
        case .modelCacheOrphansRemoved: return "modelCacheOrphansRemoved"
        case .speechModelPrepared: return "speechModelPrepared"
        case .speechModelSwapped: return "speechModelSwapped"
        case .speechModelRemoved: return "speechModelRemoved"
        case .transcribed: return "transcribed"
        case .echoSuppressed: return "echoSuppressed"
        case .transcriptRepairQueued: return "transcriptRepairQueued"
        case .transcriptRepairSettled: return "transcriptRepairSettled"
        case .speakerMapSaved: return "speakerMapSaved"
        case .speakerMapFailed: return "speakerMapFailed"
        case .speakerMapGaveUp: return "speakerMapGaveUp"
        case .speakerPassRequested: return "speakerPassRequested"
        case .speakerFailureDismissed: return "speakerFailureDismissed"
        case .speakerTracksKept: return "speakerTracksKept"
        case .stashCountNotSaved: return "stashCountNotSaved"
        case .transcriptSaveFailed: return "transcriptSaveFailed"
        case .ownerVoiceprint: return "ownerVoiceprint"
        case .speakerNamesUnreadable: return "speakerNamesUnreadable"
        case .speakerNamingNotSaved: return "speakerNamingNotSaved"
        case .commandTranscribeReceived: return "commandTranscribeReceived"
        case .commandTranscribeFinished: return "commandTranscribeFinished"
        case .commandTranscribeFailed: return "commandTranscribeFailed"
        case .commandTranscribeAbandoned: return "commandTranscribeAbandoned"
        case .commandSpeakersNotFound: return "commandSpeakersNotFound"
        case .diarizerFellBack: return "diarizerFellBack"
        case .apiCall: return "apiCall"
        case .apiOutputRejected: return "apiOutputRejected"
        case .dictationRecorded: return "dictationRecorded"
        case .dictationZeroFrames: return "dictationZeroFrames"
        case .dictationPasted: return "dictationPasted"
        case .dictationUpgrade: return "dictationUpgrade"
        case .dictationDiscarded: return "dictationDiscarded"
        case .dictationPaused: return "dictationPaused"
        case .dictationResumed: return "dictationResumed"
        case .dictationLocked: return "dictationLocked"
        case .strandedDictationAttempt: return "strandedDictationAttempt"
        case .strandedDictationSettled: return "strandedDictationSettled"
        case .hintShown: return "hintShown"
        case .hintWithdrawn: return "hintWithdrawn"
        case .dictationItemCollected: return "dictationItemCollected"
        case .dictationItemSwitched: return "dictationItemSwitched"
        case .dictationItemsPasted: return "dictationItemsPasted"
        case .dictationItemsPruned: return "dictationItemsPruned"
        case .dictationsDeleted: return "dictationsDeleted"
        case .dictationDeleteAlertUnshown: return "dictationDeleteAlertUnshown"
        case .dictationMarked: return "dictationMarked"
        case .markTakeSeen: return "markTakeSeen"
        case .orphanTakesTrashed: return "orphanTakesTrashed"
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
        case .phoneNoteImported: return "phoneNoteImported"
        case .phoneNoteImportFailed: return "phoneNoteImportFailed"
        case .phoneNoteImportGaveUp: return "phoneNoteImportGaveUp"
        case .phoneNotesAccessRefused: return "phoneNotesAccessRefused"
        case .phoneNotesAccessRestored: return "phoneNotesAccessRestored"
        case .phoneNotesFolderUnreadable: return "phoneNotesFolderUnreadable"
        case .phoneNoteReportShown: return "phoneNoteReportShown"
        case .phoneNoteReportCleared: return "phoneNoteReportCleared"
        case .phoneNoteReportDismissed: return "phoneNoteReportDismissed"
        case .historyWriteFailed: return "historyWriteFailed"
        case .historySaveRecovered: return "historySaveRecovered"
        case .historyMigrated: return "historyMigrated"
        case .notesFolderMoveStarted: return "notesFolderMoveStarted"
        case .notesFolderMigrated: return "notesFolderMigrated"
        case .notesFolderLeftoverCleared: return "notesFolderLeftoverCleared"
        case .corruptFileAside: return "corruptFileAside"
        case .unreadRecordsKept: return "unreadRecordsKept"
        case .sessionImportFailed: return "sessionImportFailed"
        case .agentReplyArrived: return "agentReplyArrived"
        case .agentReplyDeclined: return "agentReplyDeclined"
        case .agentReplyReadingStarted: return "agentReplyReadingStarted"
        case .agentReplyReadingFinished: return "agentReplyReadingFinished"
        case .agentReplyReadingPaused: return "agentReplyReadingPaused"
        case .agentReplyEscapeRepeated: return "agentReplyEscapeRepeated"
        case .agentReplyHeldByMicrophone: return "agentReplyHeldByMicrophone"
        case .agentReplyMicrophoneFreed: return "agentReplyMicrophoneFreed"
        case .agentReplyMoved: return "agentReplyMoved"
        case .agentReplyChatOpened: return "agentReplyChatOpened"
        case .agentReplyMute: return "agentReplyMute"
        case .agentReplyWaitingShown: return "agentReplyWaitingShown"
        case .agentReplyWaitingWithdrawn: return "agentReplyWaitingWithdrawn"
        case .agentReplyPlayerShown: return "agentReplyPlayerShown"
        case .agentReplyPlayerHidden: return "agentReplyPlayerHidden"
        case .agentReplyPlayerMoved: return "agentReplyPlayerMoved"
        case .phoneCaptureStopped: return "phoneCaptureStopped"
        case .phoneCaptureResumed: return "phoneCaptureResumed"
        case .phoneResumeRefused: return "phoneResumeRefused"
        case .phoneResumeBlocked: return "phoneResumeBlocked"
        case .phoneResumeBlockCleared: return "phoneResumeBlockCleared"
        case .phoneResumeGaveUp: return "phoneResumeGaveUp"
        case .phoneWriterDied: return "phoneWriterDied"
        case .phoneSegmentOpened: return "phoneSegmentOpened"
        case .phoneSegmentsMerged: return "phoneSegmentsMerged"
        case .phoneStopAlertShown: return "phoneStopAlertShown"
        case .phoneStopAlertCleared: return "phoneStopAlertCleared"
        case .phoneReminderFired: return "phoneReminderFired"
        case .phoneTranscriptionOutOfTime: return "phoneTranscriptionOutOfTime"
        case .phoneTitleFailed: return "phoneTitleFailed"
        case .phoneSpeakersNotFound: return "phoneSpeakersNotFound"
        case .phoneNotesDeleted: return "phoneNotesDeleted"
        case .farVoiceHintShown: return "farVoiceHintShown"
        case .farVoiceHintCleared: return "farVoiceHintCleared"
        case .phoneCardShown: return "phoneCardShown"
        case .phoneCardGone: return "phoneCardGone"
        case .phoneWatchCommand: return "phoneWatchCommand"
        case .phoneWatchReachability: return "phoneWatchReachability"
        }
    }
}

// MARK: - Convenience constructors

extension DiagEvent.Outcome {
    public init(success: Bool) {
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
public struct DiagRecord: Codable, Sendable, Equatable {
    let at: Date
    public let event: DiagEvent
    /// Occurrences folded in; `nil` means the plain one.
    private(set) var count: Int?
    /// When the last of them happened; `nil` alongside `count`.
    private(set) var until: Date?

    var subsystem: DiagSubsystem { event.subsystem }

    var occurrences: Int { count ?? 1 }

    /// The most recent occurrence — what an age is measured from.
    public var lastAt: Date { until ?? at }

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
