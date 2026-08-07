import Foundation

enum UITestScenario: String {
    case launchSmoke
    case sessionSmoke
    case notesSmoke
}

enum AppRuntimeMode {
    case live
    case uiTest(UITestScenario)
}

struct AppServices {
    let transcriptionEngine: TranscriptionEngine
    let refinementEngine: TranscriptRefinementEngine
    let audioRecorder: AudioRecorder
    let batchEngine: BatchTranscriptionEngine
}

struct AppLaunchContext {
    let uiTestScenario: UITestScenario?
    let runtimeMode: AppRuntimeMode
    let container: AppContainer
    let settings: AppSettings
    let coordinator: AppCoordinator
    let updaterController: AppUpdaterController
    /// Which world this launch runs in (#150) — setup or configured.
    let boot: AppBoot
}
