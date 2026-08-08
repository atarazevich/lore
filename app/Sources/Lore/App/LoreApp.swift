import SwiftUI
import AppKit
import AVFoundation
import os
import Sparkle
import UniformTypeIdentifiers

private let appLog = Logger(subsystem: "com.lore.app", category: "LoreApp")

public struct LoreRootApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var settings: AppSettings
    @State var coordinator: AppCoordinator
    @State private var container: AppContainer
    @State var shell: ShellModel
    @State private var boot: AppBoot
    private let updaterController: AppUpdaterController
    private let defaults: UserDefaults

    /// One launch context per process, no matter how many times this struct
    /// is constructed. The executable wrapper used to do `LoreRootApp().body`,
    /// re-running init — and with it AppContainer.bootstrap() — on every scene
    /// evaluation. Each eval minted a parallel coordinator/audio bus/updater
    /// set: the window environment ended up holding an idle orphan coordinator
    /// while the first one recorded (split-brain — all UI surfaces read idle,
    /// deep links hit orphans). main.swift now delegates @main here, but
    /// SwiftUI does not contractually guarantee a single App.init: on a
    /// re-init, @State restores the kept values while a fresh bootstrap would
    /// mint live orphans (AudioBus, lifecycle tasks, Sparkle). The memo is the
    /// invariant that prevents orphan creation; @main delegation is the
    /// hygiene layer.
    static let sharedContext: AppLaunchContext = {
        #if DEBUG
        contextForced = true
        return makeContext()
        #else
        return AppContainer.bootstrap()
        #endif
    }()
    private static let sharedShell = ShellModel()

    #if DEBUG
    /// Test seam: set once, before the first `sharedContext` access, so tests
    /// can exercise the memo without a live bootstrap (Sparkle, real defaults).
    static var makeContext: () -> AppLaunchContext = { AppContainer.bootstrap() } {
        willSet {
            precondition(
                !contextForced,
                "makeContext must be replaced before sharedContext is first accessed"
            )
        }
    }
    private static var contextForced = false
    #endif

    public init() {
        let context = Self.sharedContext
        self._settings = State(initialValue: context.settings)
        self._coordinator = State(initialValue: context.coordinator)
        self._container = State(initialValue: context.container)
        self._boot = State(initialValue: context.boot)
        self.updaterController = context.updaterController
        self.defaults = context.container.defaults

        // ShellModel holds no coordinator reference; give it the one bit it
        // needs so review navigation is recording-scoped (#43). Wired here,
        // before any deep link or menu action can navigate. Re-wiring on a
        // repeat init is idempotent: same shell, same coordinator.
        let shellModel = Self.sharedShell
        let coordinator = context.coordinator
        shellModel.isRecordingActive = { coordinator.state != .idle }
        self._shell = State(initialValue: shellModel)
    }

    public var body: some Scene {
        Window(LoreTheme.wordmark, id: "main") {
            // The #150 gate at its sharpest point: before setup completes the
            // shell is not mounted, so no destination's `.task` runs — that is
            // what started meeting detection from a window nobody had opened.
            Group {
                if boot.phase == .running {
                    ShellView(settings: settings, updater: updaterController.updater)
                        .environment(container)
                        .environment(coordinator)
                        .environment(coordinator.dictationCoordinator)
                        .environment(shell)
                        .defaultAppStorage(defaults)
                } else {
                    // Never ordered in; sized so the swap does not resize the
                    // window at the moment setup completes.
                    Color.clear.frame(minWidth: 1000, minHeight: 640)
                }
            }
            .onAppear {
                wireDelegate()
                startSubsystemsIfRunning()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1240, height: 832)
        // A keyboard shortcut is not stopped by an unmounted window, so the gate
        // has to hold against it too: during `.setup` Cmd+Shift+L reached
        // `toggleMeeting` and opened a capture with no microphone grant (#150).
        // Each handler asks at invocation time, which no re-evaluation of this
        // builder can get wrong.
        .commands {
            // The macOS Settings scene is retired (SET-06): Cmd+, opens the
            // unified window at the Settings destination instead.
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") {
                    guard isRunning else { return }
                    shell.destination = .settings
                    showMainWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                // Sparkle is not started during setup, so this would target a
                // never-started updater.
                if case .live = container.mode, boot.phase == .running {
                    CheckForUpdatesView(updater: updaterController.updater)

                    Divider()
                }

                Button("Toggle Meeting") {
                    guard isRunning else { return }
                    appDelegate.toggleMeeting()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Past Meetings") {
                    guard isRunning else { return }
                    showPastMeetings()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("Import Meeting Recording...") {
                    guard isRunning else { return }
                    importMeetingRecording()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(coordinator.isRecording || isBatchEngineBusy)

                Button("Dictation") {
                    guard isRunning else { return }
                    shell.destination = .dictation
                    showMainWindow()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("GitHub Repository...") {
                    if let url = URL(string: "https://github.com/atarazevich/lore") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

extension LoreRootApp {
    static let mainWindowID = "main"

    /// The gate, as the menu commands ask it: nothing outside the onboarding
    /// window may act while setup is unfinished.
    private var isRunning: Bool { boot.phase == .running }

    /// Hand the delegate the objects and presenters only the scene graph can
    /// build. Runs in both phases — the onboarding window needs the same
    /// coordinator and container, and `openWindow` works only from here.
    private func wireDelegate() {
        appDelegate.coordinator = coordinator
        appDelegate.settings = settings
        appDelegate.container = container
        appDelegate.updaterController = updaterController
        // Real presenter (fronts the window, or re-creates it via openWindow) —
        // the delegate cannot build this closure itself because openWindow only
        // works from the installed scene graph. If applicationDidFinishLaunching
        // already wanted the window, wiring this presents it (didSet).
        appDelegate.onShowMainWindow = { [self] in showMainWindow() }
        appDelegate.onShowMeetings = { [self] in
            // As-is: live while recording, review otherwise.
            shell.showMeetings()
            showMainWindow()
        }
        // The amber bead's destination (#151) — same two lines as Meetings
        // above: name the surface on the shared model, front the window.
        appDelegate.onShowHealth = { [self] in
            shell.presentsHealthPanel = true
            showMainWindow()
        }
    }

    /// The one place every subsystem starts, exactly once, and only in the
    /// configured world (#150). The other call site is `completeSetup()`.
    private func startSubsystemsIfRunning() {
        boot.startSubsystemsOnce {
            appDelegate.startSubsystems()
        }
    }

    /// The unified main window, if AppKit has materialized it.
    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == mainWindowID }
    }

    /// Replaces the old Notes window: unified window, Meetings review side.
    private func showPastMeetings() {
        shell.showMeetingsReview()
        showMainWindow()
    }

    private var isBatchEngineBusy: Bool {
        switch coordinator.batchStatus {
        case .idle, .completed, .failed, .cancelled: return false
        default: return true
        }
    }

    private func importMeetingRecording() {
        let panel = NSOpenPanel()
        panel.title = "Import Meeting Recording"
        panel.allowedContentTypes = [
            .audio,
            .init(filenameExtension: "m4a")!,
            .init(filenameExtension: "mp3")!,
            .init(filenameExtension: "wav")!,
            .init(filenameExtension: "caf")!,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        guard let batchEngine = coordinator.batchEngine else { return }

        let repo = coordinator.sessionRepository

        let fm = FileManager.default
        let startDate: Date
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let creation = attrs[.creationDate] as? Date {
            startDate = creation
        } else {
            startDate = Date()
        }

        var estimatedEnd = startDate
        if let audioFile = try? AVAudioFile(forReading: fileURL) {
            let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            estimatedEnd = startDate.addingTimeInterval(duration)
        }

        let title = fileURL.deletingPathExtension().lastPathComponent

        Task {
            let sessionID = await repo.createImportedSession(
                config: .init(
                    title: title,
                    startedAt: startDate,
                    endedAt: estimatedEnd,
                    language: settings.transcriptionLocale,
                    engine: ParakeetBackend.engineName
                )
            )

            // Fresh marker + immediate list refresh + auto-select so the
            // imported meeting is on screen showing the Processing state
            // from the start (MREV-33, meetings-review.md acceptance).
            await repo.markSessionUnviewed(sessionID: sessionID)
            await coordinator.loadHistory()
            coordinator.queueSessionSelection(sessionID)
            showPastMeetings()

            await batchEngine.importFile(
                url: fileURL,
                sessionID: sessionID,
                sessionRepository: repo
            )

            // #43: import completion never deletes — failure/preemption keep the row with retry.
            let status = await batchEngine.status
            if case .failed(let message, _) = status {
                DiagStore.record(.sessionImportFailed)
                appLog.error("import did not complete for \(sessionID, privacy: .private): \(message, privacy: .private) — keeping session for retry")
            } else if case .cancelled = status {
                // Preemption by a recording start is the designed path (#43), not a
                // failure. Recording it as one would put a red line in every report
                // from a user who records back-to-back meetings.
                appLog.debug("import preempted (recording started) — keeping session for retry")
            }
            await coordinator.loadHistory()
        }
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = Self.mainWindow {
            appLog.debug("showMainWindow: found-window")
            window.makeKeyAndOrderFront(nil)
        } else {
            appLog.debug("showMainWindow: openWindow-fallback")
            openWindow(id: Self.mainWindowID)
            // openWindow(id:) no-ops when SwiftUI already considers the scene
            // open (NSWindow exists but was never ordered in — the launch
            // race, #65 B). Front whatever exists one runloop turn later.
            DispatchQueue.main.async {
                if let window = Self.mainWindow {
                    appLog.debug("showMainWindow: retry-present")
                    window.makeKeyAndOrderFront(nil)
                } else {
                    appLog.debug("showMainWindow: retry-none")
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windowObserver: Any?
    private var menuBarController: MenuBarController?
    private var isTerminating = false
    var coordinator: AppCoordinator? {
        didSet { flushPendingDeepLinkCommand() }
    }
    var settings: AppSettings?
    var container: AppContainer?
    var updaterController: AppUpdaterController?
    // Shared container's defaults from launch — applicationDidFinishLaunching
    // reads this before onAppear runs any handoff, so .standard would be wrong
    // in UI-test mode.
    var defaults: UserDefaults = LoreRootApp.sharedContext.container.defaults

    /// Navigate the shell to Meetings and front the window (menu bar action).
    var onShowMeetings: (() -> Void)?
    /// Fronts the window with the health panel up — the menu bar's route from
    /// the amber bead to the gauge (#151).
    var onShowHealth: (() -> Void)?

    /// The exclusive setup surface (#150) — nil once setup is complete.
    private var onboardingWindow: OnboardingWindowController?
    private var onboardingModel: OnboardingModel?

    /// The SwiftUI-layer presenter (fronts the main window, or re-creates it
    /// via openWindow), wired in onAppear. onAppear/didFinishLaunching order
    /// is not contractual: if launch wanted the window before the handoff
    /// ran, present as soon as the closure arrives.
    var onShowMainWindow: (() -> Void)? {
        didSet {
            guard shouldShowMainWindowOnWire, let onShowMainWindow else { return }
            shouldShowMainWindowOnWire = false
            // Defer one runloop turn: this didSet fires from onAppear, mid
            // scene-attachment — presenting synchronously there can find an
            // NSWindow that exists but cannot yet be ordered in (#65 B).
            DispatchQueue.main.async { onShowMainWindow() }
        }
    }
    private var shouldShowMainWindowOnWire = false

    /// Start the configured world — menu bar, dictation, health, updates, the
    /// global meeting hotkey — exactly once (#150), so no subsystem needs a
    /// first-run conditional of its own. Returns whether it actually started
    /// anything: that, not the attempt, is what the latch is burned on.
    @discardableResult
    func startSubsystems() -> Bool {
        // `completeSetup()` can arrive before the scene's onAppear handed these
        // over — during setup the main window was never presented — so resolve
        // from the launch context rather than returning empty-handed.
        let context = LoreRootApp.sharedContext
        if coordinator == nil { coordinator = context.coordinator }
        if settings == nil { settings = context.settings }
        if container == nil { container = context.container }
        if updaterController == nil { updaterController = context.updaterController }

        // UI-test runs drive the shell directly and must not get a menu bar, an
        // event tap or an updater — the one place that question is asked.
        guard let coordinator, let settings, let container, case .live = container.mode
        else { return false }

        container.ensureServicesInitialized(settings: settings, coordinator: coordinator)
        setupMenuBar(coordinator: coordinator, settings: settings)
        setupDictation(coordinator: coordinator, settings: settings)
        setupHealthMonitor(coordinator: coordinator, settings: settings)
        registerGlobalHotkey()
        updaterController?.start()
        return true
    }

    private func setupMenuBar(coordinator: AppCoordinator, settings: AppSettings) {
        guard menuBarController == nil else { return }

        let controller = MenuBarController(
            coordinator: coordinator,
            settings: settings,
            onCheckForUpdates: { [weak self] in
                self?.updaterController?.checkForUpdatesFromMenuBar()
            }
        )
        controller.onShowMainWindow = { [weak self] in self?.onShowMainWindow?() }
        controller.onShowMeetings = { [weak self] in self?.onShowMeetings?() }
        controller.onShowHealth = { [weak self] in self?.onShowHealth?() }
        controller.onQuitApp = { [weak self] in
            self?.handleQuit()
        }
        menuBarController = controller
    }

    private var isUITest: Bool {
        ProcessInfo.processInfo.environment["LORE_UI_TEST"] != nil
    }

    private var appNapActivity: NSObjectProtocol?
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    private var didSetupDictation = false
    private var didStartDictationPipeline = false

    /// The last second of events is exactly the interesting second when the user
    /// quits to escape a wedged state. `record()` coalesces disk writes at 1s, so
    /// without this the tail is lost. (A crash still loses it — nothing to do there.)
    func applicationWillTerminate(_ notification: Notification) {
        DiagStore.shared.flush()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First event of every run: the persisted ring is loaded here, so the
        // timeline shows where one launch ends and the next begins — which is
        // exactly the question "did they restart after granting the permission?".
        // CFBundleVersion is MAJOR.MINOR.<git commit count>; the last component
        // is the monotonic build that maps to an exact commit.
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        DiagStore.record(.appLaunched(
            build: Int(bundleVersion.split(separator: ".").last ?? "") ?? 0
        ))

        if !isUITest {
            NSApp.setActivationPolicy(.regular)
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Background hotkey monitoring and audio processing"
            )
        }

        // Screen-share visibility is owned by SettingsStore (same store the
        // Settings toggle writes) — one source of truth for the on/off/absent
        // decision instead of a parallel raw-defaults read here.
        LoreRootApp.sharedContext.settings.applyScreenShareVisibility()

        if !isUITest {
            // Set delegate on main window for close-to-background behavior
            LoreRootApp.mainWindow?.delegate = self

            if LoreRootApp.sharedContext.boot.phase == .setup {
                // The exclusive state (#150): the setup window is the only
                // surface, and even a login-item launch has to show it — a
                // background process with nothing configured can do nothing.
                presentOnboarding()
            } else if !isLoginItemLaunch {
                // LSUIElement launches the process as .accessory; flipping to
                // .regular above does not activate the app, so the main window
                // would sit unfocused on an inactive Space (launch looks
                // windowless). Present it explicitly — except for login-item
                // launches, which must stay quiet in the background.
                if let onShowMainWindow {
                    onShowMainWindow()
                } else {
                    // onAppear handoff hasn't run yet; present on wire.
                    shouldShowMainWindowOnWire = true
                }
            }
        }

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // SettingsStore is the canonical write path; an off-band
                // `defaults write` is not picked up until relaunch — intentional.
                LoreRootApp.sharedContext.settings.applyScreenShareVisibility()
            }
        }

        // Cmd+Shift+L and every other subsystem now start behind the boot gate
        // (`startSubsystems`), not here.
    }

    // MARK: - Setup state (#150)

    /// Build and show the onboarding window. Everything the flow needs is
    /// injected here; the flow itself reaches no subsystem directly.
    private func presentOnboarding() {
        guard onboardingWindow == nil else { return }
        let coordinator = LoreRootApp.sharedContext.coordinator
        let settings = LoreRootApp.sharedContext.settings

        let model = OnboardingModel()
        let window = OnboardingWindowController(defaults: defaults)

        model.startDictationForTryIt = { [weak self] in
            self?.startDictationPipeline(coordinator: coordinator, settings: settings)
        }
        // One seam onto the dictation subsystem, read from the flow's body as
        // well as its poll — that is how the waveform keeps observing the
        // coordinator's own level.
        model.readDictation = {
            OnboardingModel.DictationReading(
                tapAlive: coordinator.hotkeyManager.isEventTapAlive,
                state: coordinator.dictationCoordinator.state,
                audioLevel: coordinator.dictationCoordinator.audioLevel,
                lastPasted: coordinator.dictationCoordinator.lastTranscript
            )
        }
        model.onClosableChanged = { [weak window] in window?.setClosable($0) }
        model.onWantsFront = { [weak window] in window?.front() }
        model.onFinish = { [weak self] in self?.completeSetup() }
        // Closing before "Start using lore" leaves no surface at all, so it is a
        // quit; the next launch resumes the flow from the same reading.
        window.onAbandon = { NSApp.terminate(nil) }

        onboardingModel = model
        onboardingWindow = window
        window.present(model: model)
        model.start()
    }

    /// The single transition into the configured world.
    private func completeSetup() {
        LoreRootApp.sharedContext.settings.markSetupCompleted()
        onboardingWindow?.dismiss()
        onboardingWindow = nil
        onboardingModel = nil

        // Flipping the phase swaps ShellView into the scene. The boot is driven
        // from here because a scene whose content never appeared observes
        // nothing; the shared latch makes the scene's own later call a no-op.
        let boot = LoreRootApp.sharedContext.boot
        boot.markSetupComplete()
        boot.startSubsystemsOnce { [weak self] in self?.startSubsystems() ?? false }

        // Same on-wire handshake launch uses: if the scene never wired its
        // presenter, present as soon as it does.
        if let onShowMainWindow {
            onShowMainWindow()
        } else {
            shouldShowMainWindowOnWire = true
        }
    }

    // MARK: - Deep Links (lore:// scheme)

    /// Command parsed from a URL delivered before onAppear wired the
    /// coordinator (super-early launch); flushed when the coordinator lands.
    /// Single slot, last-wins — matching the downstream
    /// AppCoordinator.pendingExternalCommand slot it feeds.
    private var pendingDeepLinkCommand: ExternalCommand?

    /// SwiftUI's .onOpenURL stopped firing after the second Window scene was
    /// removed (#65 A) — scene URL routing is not deterministic. AppKit
    /// delivery is: works at launch and while running, window open or closed.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            appLog.debug("deep link: \(url.absoluteString, privacy: .private)")
            guard let command = LoreDeepLink.parse(url) else {
                appLog.error("unrecognized deep link URL, skipping")
                continue
            }
            if NSApp.activationPolicy() == .accessory {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            if case .openNotes = command {
                // The consumer (LiveSessionController) navigates the shell to
                // review but does not front the window; mirror the old
                // .onOpenURL's showMainWindow via the same on-wire handshake
                // as launch presentation.
                if let onShowMainWindow {
                    onShowMainWindow()
                } else {
                    shouldShowMainWindowOnWire = true
                }
            }
            if let coordinator {
                coordinator.queueExternalCommand(command)
            } else {
                pendingDeepLinkCommand = command
            }
        }
    }

    private func flushPendingDeepLinkCommand() {
        guard let coordinator, let command = pendingDeepLinkCommand else { return }
        pendingDeepLinkCommand = nil
        appLog.debug("flushing deep link queued before coordinator wire: \(String(describing: command), privacy: .private)")
        coordinator.queueExternalCommand(command)
    }

    /// True when this process was started as a login item: launchd delivers
    /// the kAEOpenApplication ('oapp') launch event with propData ('prdt')
    /// set to keyAELaunchedAsLogInItem ('lgit') — see AppKit NSApplication.h.
    private var isLoginItemLaunch: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication),
              let propData = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))
        else { return false }
        return propData.enumCodeValue == UInt32(keyAELaunchedAsLogInItem)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }

        if isTerminating {
            return .terminateNow
        }

        guard coordinator.isRecording else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Recording in Progress"
        alert.informativeText = "Stop recording and quit?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop & Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        isTerminating = true
        coordinator.handle(.userStopped, settings: settings)

        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if case .idle = coordinator.state { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.isTerminating = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        isUITest
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isUITest else { return true }

        let isMainWindow = sender === LoreRootApp.mainWindow

        if isMainWindow {
            sender.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            return false
        }
        return true
    }

    // MARK: - Dictation Setup

    /// The dictation pipeline itself: coordinator wiring, the CGEvent tap, the
    /// model warm-up. Split out of `setupDictation` for the Try-it step (#150),
    /// which needs hold-to-talk and nothing else — no indicator panel over the
    /// onboarding window, no Read Aloud chords, no health reporting.
    func startDictationPipeline(coordinator: AppCoordinator, settings: AppSettings) {
        guard !didStartDictationPipeline else { return }
        didStartDictationPipeline = true

        coordinator.dictationCoordinator.settings = settings
        coordinator.dictationCoordinator.audioBus = container?.audioBus
        coordinator.dictationCoordinator.backendCache = coordinator.sharedBackendCache
        coordinator.hotkeyManager.install(
            coordinator: coordinator.dictationCoordinator,
            settings: settings
        )

        // Preload models so the first use is instant. Detached; launch never
        // blocks. Two loads cover the common warm set: the shared cache (meeting
        // mic reuses it) and dictation's private backend (its own decoder state).
        // The meeting system-audio backend is left lazy on purpose — it's a
        // second decoder only a meeting recording needs, so preloading it would
        // hold a third model resident for users who only ever dictate.
        Task {
            try? await coordinator.sharedBackendCache.prepare()
        }
        Task {
            await coordinator.dictationCoordinator.prewarm()
        }
    }

    private func setupDictation(coordinator: AppCoordinator, settings: AppSettings) {
        guard !didSetupDictation else { return }
        didSetupDictation = true

        startDictationPipeline(coordinator: coordinator, settings: settings)

        coordinator.dictationIndicator.start(
            coordinator: coordinator.dictationCoordinator,
            hotkeyManager: coordinator.hotkeyManager
        )

        // Read Aloud (#105): Fn+R / Fn+Q chords, floating player panel, and
        // the dictation interplay (capture start pauses playback before the
        // mic opens; capture end may auto-resume — a cancelled tap always,
        // a real dictation only when the setting opts in).
        let readAloud = coordinator.readAloudController
        readAloud.settings = settings
        coordinator.hotkeyManager.readAloudController = readAloud
        coordinator.readAloudPanel.start(controller: readAloud)
        coordinator.dictationCoordinator.onCaptureStarted = { [weak readAloud] in
            readAloud?.pauseForDictation()
        }
        coordinator.dictationCoordinator.onCaptureEnded = { [weak readAloud] cancelled in
            readAloud?.dictationEnded(cancelled: cancelled)
        }
    }

    /// Build the health monitor (#83, reworked #140/#151): an on-open fact sheet
    /// plus the failure-driven amber state — no periodic verdict loop. It lives on
    /// the delegate, not a view, because actions fail with no window open (the
    /// "Fn dead" incident). The prober reads the hotkey tap's existing
    /// liveness (never installs a second tap) and the key presence; the three
    /// expensive Test-now actions reach the real mic / model cache / network.
    private func setupHealthMonitor(coordinator: AppCoordinator, settings: AppSettings) {
        guard coordinator.healthMonitor == nil else { return }

        let hotkeyManager = coordinator.hotkeyManager
        // The signing-identity migration (#135, rationale on
        // `SigningIdentityLedger`) rides on the prober; the monitor reads it
        // from there.
        // One defaults domain for the whole seam — the same one `AppSettings`
        // was built on, so the notes-migration marker (#148) is read from where
        // the migration wrote it, and the row and its clear cannot disagree.
        let defaults = container?.defaults ?? .standard
        let signingLedger = SigningIdentityLedger(defaults: defaults)
        let prober = HealthProber(
            readTapLiveness: { hotkeyManager.tapLiveness },
            hasOpenAIKey: { !settings.openaiApiKey.isEmpty },
            signingLedger: signingLedger,
            readNotesLeftover: { NotesFolderMigration.pendingLeftover(defaults: defaults) }
        )
        let monitor = HealthMonitor(prober: prober)
        monitor.verifyNotesLeftover = { NotesFolderMigration.verifyLeftover(defaults: defaults) }

        let audioBus = container?.audioBus
        monitor.runMicCaptureTest = {
            guard let audioBus else { return }
            let subscription = audioBus.subscribe(deviceID: nil)
            try? await Task.sleep(for: .seconds(2))
            audioBus.unsubscribe(subscription.id)
        }
        monitor.runModelWarmupTest = { [weak coordinator] in
            try? await coordinator?.sharedBackendCache.prepare()
        }
        monitor.runOpenAITest = {
            let key = settings.openaiApiKey
            guard !key.isEmpty else { return }
            _ = await KeyHealthCheck.probe(apiKey: key)
        }

        // Opening the panel is a fresh signal for a tap blocked on a permission
        // the user may have just granted (#149).
        monitor.refillTapRepairs = { [weak hotkeyManager] in
            hotkeyManager?.refillTapRepairBudget()
        }

        coordinator.healthMonitor = monitor

        // The failure door (#140): a health claim moves only when a user action
        // just failed, delivered by the event stream itself — no verdict loop.
        // The filter runs on the recording thread; only a match hops to main.
        // One filter, one hop, in the order the events were recorded (#149): a
        // failure and the recovery behind it must not race each other onto the
        // mark, which two independent Tasks would allow.
        DiagStore.shared.setObserver { [weak monitor] event in
            guard let signal = HealthMonitor.healthSignal(for: event) else { return }
            Task { @MainActor in monitor?.note(signal) }
        }

        // The #135 acknowledge rode the deleted 5 s cycle; now it rides its own
        // event — the first real key-down reaching the tap runs one refresh,
        // whose ack path closes a pending migration (#140).
        hotkeyManager.onFirstRealKeyDown = { [weak monitor] in monitor?.refresh() }

        // Self-clear (#144): a keystroke reaching the tap acknowledges the
        // ledger (`HealthMonitor.refresh`), and the migration's clock stops the
        // same moment — no polling, the ack site drives it. In the healthy case
        // that keystroke lands well inside the persistence window, so the mark
        // never says anything at all.
        signingLedger.onMigrationClosed = { [weak monitor] in
            monitor?.clearFailure(.identityMigration)
        }

        // Proactive notice (#135): the identity changed since the last launch in
        // a TCC-affecting way (different team, or ad-hoc involved — same-team
        // dev↔release flips share grants and stay silent, #140), so guide the
        // re-grant instead of waiting for the user to discover dead hotkeys.
        // Through the same failure clock as every other condition.
        //
        // Read live from `migrationPending`, with no cross-launch marker (#151).
        // #144's marker existed to stop an *interrupting popup* firing twice for
        // one cause; a quiet dot has no such cost, and suppressing it on relaunch
        // left the panel row warning beside a dark mark — the disagreement rule 2
        // forbids. The 60 s persistence gate is the only dedupe a standing,
        // non-interrupting report needs.
        if signingLedger.migrationPending {
            monitor.noteFailure(.identityMigration)
        } else {
            // Nothing pending: make the current identity the record, which is
            // what starts it on a first-ever launch.
            signingLedger.acknowledge()
        }
    }

    // MARK: - Global Hotkey (Cmd+Shift+L)

    private func registerGlobalHotkey() {
        let matchesHotkey: (NSEvent) -> Bool = { event in
            event.modifierFlags.contains([.command, .shift])
                && event.charactersIgnoringModifiers?.lowercased() == "l"
        }

        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard matchesHotkey(event) else { return }
            Task { @MainActor in self?.toggleMeeting() }
        }

        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard matchesHotkey(event) else { return event }
            Task { @MainActor in self?.toggleMeeting() }
            return nil
        }
    }

    func toggleMeeting() {
        // No consent branch: the app only runs once setup completed, and setup
        // completing *is* the acknowledgement (#150).
        guard let coordinator, let settings else { return }

        if coordinator.isRecording {
            coordinator.handle(.userStopped, settings: settings)
        } else {
            coordinator.handle(.userStarted(.manual()), settings: settings)
        }
    }

    // MARK: - Quit

    private func handleQuit() {
        NSApp.terminate(nil)
    }
}
