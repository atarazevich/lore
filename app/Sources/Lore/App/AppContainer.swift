import Foundation
import Observation

@MainActor
@Observable
final class AppContainer {
    static let notesSmokeSessionID = "session_ui_test_notes"

    let mode: AppRuntimeMode
    let defaults: UserDefaults
    let appSupportDirectory: URL
    let notesDirectory: URL

    /// Persistent shared audio bus — one CoreAudio HAL IOProc for all consumers (D-029).
    let audioBus = AudioBus()

    /// Detection controller for the meeting auto-detect lifecycle.
    /// Created when detection is enabled; nil otherwise.
    private(set) var detectionController: MeetingDetectionController?

    private var didSeedInitialData = false
    private var didInitializeServices = false

    init(
        mode: AppRuntimeMode,
        defaults: UserDefaults,
        appSupportDirectory: URL,
        notesDirectory: URL
    ) {
        self.mode = mode
        self.defaults = defaults
        self.appSupportDirectory = appSupportDirectory
        self.notesDirectory = notesDirectory
        // The Copying switches are read live by surfaces that hold no settings
        // object — the clipboard door, the paste's text, the event tap (#198).
        // Point them at this run's store so a UI test's suite, not the user's
        // defaults, is what they see.
        RichInputSettings.use(defaults)
    }

    static func bootstrap() -> AppLaunchContext {
        // Decode the persisted event ring here, on main, before AudioBus or the
        // hotkey tap exist. Otherwise the first `DiagStore.record()` — which can
        // come from halQueue or a CoreAudio listener queue — would be the thread
        // that pays for the file read.
        DiagStore.prepare()

        let environment = ProcessInfo.processInfo.environment
        let mode = runtimeMode(from: environment)

        switch mode {
        case .live:
            let appSupportDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("Lore", isDirectory: true)
            let container = AppContainer(
                mode: .live,
                defaults: .standard,
                appSupportDirectory: appSupportDirectory,
                // #148: the app's own domain, same location `SettingsStorage.live`
                // defaults to. Seed value only — `LiveSessionController` re-points
                // the recorder at `notesFolderPath` once settings are observed.
                notesDirectory: NotesFolder.notes(in: appSupportDirectory)
            )
            let settings = AppSettings()
            let coordinator = AppCoordinator()
            let updaterController = AppUpdaterController()
            return AppLaunchContext(
                uiTestScenario: nil,
                runtimeMode: .live,
                container: container,
                settings: settings,
                coordinator: coordinator,
                updaterController: updaterController,
                // The #150 gate. Nothing here has started a subsystem yet —
                // `AppUpdaterController.init` no longer starts Sparkle, and the
                // audio bus is inert until something subscribes.
                boot: AppBoot(needsSetup: !settings.didCompleteSetup)
            )

        case .uiTest(let scenario):
            let runID = environment["LORE_UI_TEST_RUN_ID"] ?? UUID().uuidString
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("LoreUITests", isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
            let appSupportDirectory = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
            let notesDirectory = root.appendingPathComponent("Notes", isDirectory: true)
            try? FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

            let suiteName = "com.lore.uitests.\(runID)"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            // #150: one preset instead of the two retired flags — a UI test
            // starts in the configured world, never in the setup state.
            defaults.set(true, forKey: SetupState.completedKey)
            defaults.set(false, forKey: "meetingAutoDetectEnabled")
            defaults.set(false, forKey: "hasShownAutoDetectExplanation")
            defaults.set(false, forKey: "hideFromScreenShare")
            defaults.set(true, forKey: "showLiveTranscript")
            defaults.set(false, forKey: "saveAudioRecording")
            defaults.set(false, forKey: "enableTranscriptRefinement")
            defaults.set(notesDirectory.path, forKey: NotesFolderMigration.notesPathKey)

            let storage = AppSettingsStorage(
                defaults: defaults,
                secretStore: .ephemeral,
                defaultNotesDirectory: notesDirectory,
                legacyNotesDirectories: [],
                runMigrations: false
            )
            let settings = AppSettings(storage: storage)
            let coordinator = AppCoordinator(
                sessionRepository: SessionRepository(rootDirectory: appSupportDirectory),
                templateStore: TemplateStore(rootDirectory: appSupportDirectory),
                transcriptStore: TranscriptStore()
            )
            let container = AppContainer(
                mode: .uiTest(scenario),
                defaults: defaults,
                appSupportDirectory: appSupportDirectory,
                notesDirectory: notesDirectory
            )
            let updaterController = AppUpdaterController()
            return AppLaunchContext(
                uiTestScenario: scenario,
                runtimeMode: .uiTest(scenario),
                container: container,
                settings: settings,
                coordinator: coordinator,
                updaterController: updaterController,
                boot: AppBoot(needsSetup: false)
            )
        }
    }

    func makeServices(settings: AppSettings, coordinator: AppCoordinator) -> AppServices {
        let transcriptionEngine: TranscriptionEngine
        switch mode {
        case .live:
            transcriptionEngine = TranscriptionEngine(
                transcriptStore: coordinator.transcriptStore,
                settings: settings,
                sharedBackendCache: coordinator.sharedBackendCache,
                audioBus: audioBus
            )
        case .uiTest:
            transcriptionEngine = TranscriptionEngine(
                transcriptStore: coordinator.transcriptStore,
                settings: settings,
                sharedBackendCache: coordinator.sharedBackendCache,
                mode: .scripted(Self.scriptedUtterances)
            )
        }

        return AppServices(
            transcriptionEngine: transcriptionEngine,
            refinementEngine: TranscriptRefinementEngine(
                settings: settings,
                transcriptStore: coordinator.transcriptStore
            ),
            audioRecorder: AudioRecorder(outputDirectory: notesDirectory),
            batchEngine: BatchTranscriptionEngine()
        )
    }

    func ensureServicesInitialized(settings: AppSettings, coordinator: AppCoordinator) {
        guard !didInitializeServices else { return }
        didInitializeServices = true

        let services = makeServices(settings: settings, coordinator: coordinator)
        coordinator.transcriptionEngine = services.transcriptionEngine
        coordinator.refinementEngine = services.refinementEngine
        coordinator.audioRecorder = services.audioRecorder
        coordinator.batchEngine = services.batchEngine

        // Everything below is live mode only: UI-test sessions must stay
        // byte-stable, scripted runs must not call the on-device model, and
        // a healer sweep or open in a UI test must never load the real ASR
        // model.
        guard case .live = mode else { return }

        // Meeting auto-enrichment (#107).
        coordinator.enrichmentEngine = MeetingEnrichmentEngine(
            repository: coordinator.sessionRepository,
            onEnriched: { [weak coordinator] in
                await coordinator?.loadHistory()
            }
        )

        // Transcript self-healing (#166): the one queue every batch/import/
        // repair dispatch goes through. `onRepaired` is the single
        // completion path — a transcript replaced by the sweep or a retry
        // resets the enrichment marker and re-enriches exactly like the
        // end-of-meeting pass (#107/#109).
        let batchEngine = services.batchEngine
        coordinator.transcriptHealer = TranscriptHealer(
            repository: coordinator.sessionRepository,
            liveSessionID: { [weak coordinator] in
                coordinator?.liveSessionController?.activeSessionID
            },
            onRepaired: { [weak coordinator] sessionID in
                guard let coordinator else { return }
                await coordinator.sessionRepository.updateSessionSummary(sessionID: sessionID, summary: nil)
                await coordinator.loadHistory()
                if let engine = coordinator.enrichmentEngine {
                    await engine.enrichIfNeeded(sessionID: sessionID)
                }
            },
            onGaveUp: { [weak coordinator] sessionID in
                // A failed repair leaves the live transcript in place —
                // enrich it now (#107) rather than waiting a launch. No
                // summary reset: nothing was replaced.
                await coordinator?.enrichmentEngine?.enrichIfNeeded(sessionID: sessionID)
            },
            runJob: TranscriptHealer.engineRunner(
                engine: batchEngine,
                repository: coordinator.sessionRepository,
                notesDirectory: { URL(fileURLWithPath: settings.notesFolderPath) }
            ),
            cancelRun: { await batchEngine.cancel() }
        )
    }

    /// Create and start the detection controller, wire the coordinator event loop.
    func enableDetection(settings: AppSettings, coordinator: AppCoordinator) {
        guard detectionController == nil else { return }
        let controller = MeetingDetectionController()
        controller.isSessionActive = { [weak coordinator] in
            guard let coordinator else { return false }
            // Meeting recording or Lore's own dictation (#77): dictation capture
            // flips DeviceIsRunningSomewhere and a >5s dictation would otherwise
            // prompt "Meeting detected" mid-dictation. Suppression is at prompt
            // time only — the detector keeps running, so a real meeting still
            // prompts after dictation ends.
            //
            // Any non-idle phase, not just `.recording` (#153): during a pause
            // the mic really is free, so the detector would happily announce
            // "Meeting detected" for the meeting already open behind it — and
            // accepting that prompt is a start the chokepoint then rejects.
            return coordinator.state != .idle
                || coordinator.dictationCoordinator.state == .recording
        }
        detectionController = controller
        controller.setup(settings: settings)
        coordinator.activeSettings = settings
        coordinator.startDetectionEventLoop(controller)
    }

    /// Tear down the detection controller and stop the coordinator event loop.
    func disableDetection(coordinator: AppCoordinator) {
        coordinator.stopDetectionEventLoop()
        coordinator.activeSettings = nil
        detectionController?.teardown()
        detectionController = nil
    }

    func seedIfNeeded(coordinator: AppCoordinator) async {
        guard !didSeedInitialData else { return }
        didSeedInitialData = true

        guard case .uiTest(let scenario) = mode, scenario == .notesSmoke else {
            return
        }

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let transcript = [
            SessionRecord(
                speaker: .you,
                text: "Thanks for taking the time today. I wanted to walk through the pilot scope.",
                timestamp: startedAt
            ),
            SessionRecord(
                speaker: .them,
                text: "That makes sense. The main thing we care about is faster onboarding for new reps.",
                timestamp: startedAt.addingTimeInterval(30)
            ),
            SessionRecord(
                speaker: .you,
                text: "Great. We can start with one team, define baseline metrics, and report back in two weeks.",
                timestamp: startedAt.addingTimeInterval(60)
            ),
        ]

        await coordinator.sessionRepository.seedSession(
            id: Self.notesSmokeSessionID,
            records: transcript,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            templateSnapshot: coordinator.templateStore.snapshot(
                of: coordinator.templateStore.template(for: TemplateStore.genericID)
                    ?? TemplateStore.builtInTemplates.first!
            ),
            title: "UI Test Discovery Call"
        )
        await coordinator.loadHistory()
    }

    private static func runtimeMode(from environment: [String: String]) -> AppRuntimeMode {
        guard environment["LORE_UI_TEST"] == "1" else {
            return .live
        }

        let scenario = UITestScenario(rawValue: environment["LORE_UI_SCENARIO"] ?? "")
            ?? .launchSmoke
        return .uiTest(scenario)
    }

    private static let scriptedUtterances: [Utterance] = [
        Utterance(
            text: "Thanks for joining. I want to show how the rollout plan works for new customers.",
            speaker: .you,
            timestamp: Date(timeIntervalSince1970: 1_700_000_100)
        ),
        Utterance(
            text: "Sounds good. I mostly care about getting the first team live quickly and measuring adoption.",
            speaker: .them,
            timestamp: Date(timeIntervalSince1970: 1_700_000_130)
        ),
    ]

}
