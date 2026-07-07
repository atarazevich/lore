import XCTest
@testable import LoreKit

/// Polls `condition` on the main actor until it holds or `timeout` elapses.
/// Returns the final value of the condition.
@MainActor
@discardableResult
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

/// Coordinator + controller pair wired like the app, with a scripted engine
/// and isolated temp storage. Holds strong references so the coordinator's
/// weak controller stays alive for the test's duration.
@MainActor
struct MeetingHarness {
    let coordinator: AppCoordinator
    let controller: LiveSessionController
    let settings: AppSettings
    let sessionRepository: SessionRepository
    let root: URL

    /// Isolated temp root + suite defaults + settings — the storage dance
    /// shared by the harness and the launch-context builder.
    private static func makeStorage() -> (
        root: URL, notesDirectory: URL, defaults: UserDefaults, settings: AppSettings
    ) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LoreMeetingHarness", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesDirectory = root.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

        let suiteName = "com.lore.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(notesDirectory.path, forKey: "notesFolderPath")
        defaults.set(true, forKey: "hasAcknowledgedRecordingConsent")

        let storage = AppSettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: notesDirectory,
            runMigrations: false
        )
        return (root, notesDirectory, defaults, AppSettings(storage: storage))
    }

    static func make(scripted: [Utterance] = [], withEngine: Bool = true) -> MeetingHarness {
        let (root, notesDirectory, defaults, settings) = makeStorage()
        let transcriptStore = TranscriptStore()
        let sessionRepository = SessionRepository(rootDirectory: root)
        let coordinator = AppCoordinator(
            sessionRepository: sessionRepository,
            templateStore: TemplateStore(rootDirectory: root),
            transcriptStore: transcriptStore
        )
        if withEngine {
            coordinator.transcriptionEngine = TranscriptionEngine(
                transcriptStore: transcriptStore,
                settings: settings,
                mode: .scripted(scripted)
            )
        }

        let container = AppContainer(
            mode: .live,
            defaults: defaults,
            appSupportDirectory: root,
            notesDirectory: notesDirectory
        )
        let controller = LiveSessionController(coordinator: coordinator, container: container)
        coordinator.liveSessionController = controller

        return MeetingHarness(
            coordinator: coordinator,
            controller: controller,
            settings: settings,
            sessionRepository: sessionRepository,
            root: root
        )
    }

    /// Harness with a session already started and the engine running.
    static func makeStarted(scripted: [Utterance] = []) async -> MeetingHarness {
        let harness = make(scripted: scripted)
        harness.controller.startSession(settings: harness.settings)
        await waitUntil { harness.coordinator.transcriptionEngine?.isRunning == true }
        return harness
    }

    /// Launch context with isolated storage, an inert uiTest-mode container
    /// (never one call away from a real TranscriptionEngine/AudioBus start),
    /// and an updater that never starts — for app-layer bootstrap tests.
    static func makeLaunchContext() -> AppLaunchContext {
        let (root, notesDirectory, defaults, settings) = makeStorage()
        let coordinator = AppCoordinator(
            sessionRepository: SessionRepository(rootDirectory: root),
            templateStore: TemplateStore(rootDirectory: root),
            transcriptStore: TranscriptStore()
        )
        return AppLaunchContext(
            isFirstLaunch: false,
            uiTestScenario: .launchSmoke,
            runtimeMode: .uiTest(.launchSmoke),
            container: AppContainer(
                mode: .uiTest(.launchSmoke),
                defaults: defaults,
                appSupportDirectory: root,
                notesDirectory: notesDirectory
            ),
            settings: settings,
            coordinator: coordinator,
            updaterController: AppUpdaterController(startUpdater: false)
        )
    }
}
