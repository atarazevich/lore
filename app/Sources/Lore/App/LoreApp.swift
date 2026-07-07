import SwiftUI
import AppKit
import AVFoundation
import Sparkle
import UniformTypeIdentifiers
import UserNotifications

public struct LoreRootApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var settings: AppSettings
    @State var coordinator: AppCoordinator
    @State private var container: AppContainer
    @State var shell: ShellModel
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
        Window(XMOTheme.wordmark, id: "main") {
            ShellView(settings: settings, updater: updaterController.updater)
                .environment(container)
                .environment(coordinator)
                .environment(coordinator.dictationCoordinator)
                .environment(shell)
                .defaultAppStorage(defaults)
                .onAppear {
                    appDelegate.coordinator = coordinator
                    appDelegate.settings = settings
                    appDelegate.container = container
                    // Real presenter (fronts the window, or re-creates it via
                    // openWindow) — the delegate cannot build this closure
                    // itself because openWindow only works from the installed
                    // scene graph. If applicationDidFinishLaunching already
                    // wanted the window, wiring this presents it (didSet).
                    appDelegate.onShowMainWindow = { [self] in showMainWindow() }
                    if case .live = container.mode {
                        appDelegate.setupMenuBarIfNeeded(
                            coordinator: coordinator,
                            settings: settings,
                            showMainWindow: { [self] in showMainWindow() },
                            showMeetings: { [self] in
                                // As-is: live while recording, review otherwise.
                                shell.showMeetings()
                                showMainWindow()
                            },
                            checkForUpdates: { updaterController.checkForUpdatesFromMenuBar() }
                        )
                        appDelegate.setupDictationIfNeeded(
                            coordinator: coordinator,
                            settings: settings
                        )
                    }
                    // Screen-share visibility is applied by the delegate at
                    // didFinishLaunching (and re-applied on didBecomeKey), so
                    // no per-appearance pass is needed here.
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1240, height: 832)
        .commands {
            // The macOS Settings scene is retired (SET-06): Cmd+, opens the
            // unified window at the Settings destination instead.
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") {
                    shell.destination = .settings
                    showMainWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                if case .live = container.mode {
                    CheckForUpdatesView(updater: updaterController.updater)

                    Divider()
                }

                Button("Toggle Meeting") {
                    appDelegate.toggleMeeting()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Past Meetings") {
                    showPastMeetings()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("Import Meeting Recording...") {
                    importMeetingRecording()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(coordinator.isRecording || isBatchEngineBusy)

                Button("Dictation") {
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
                diagLog("[IMPORT] did not complete for \(sessionID): \(message) — keeping session for retry")
            } else if case .cancelled = status {
                diagLog("[IMPORT] preempted (recording started) — keeping session \(sessionID) for retry")
            }
            await coordinator.loadHistory()
        }
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = Self.mainWindow {
            diagLog("[WINDOW] showMainWindow: found-window")
            window.makeKeyAndOrderFront(nil)
        } else {
            diagLog("[WINDOW] showMainWindow: openWindow-fallback")
            openWindow(id: Self.mainWindowID)
            // openWindow(id:) no-ops when SwiftUI already considers the scene
            // open (NSWindow exists but was never ordered in — the launch
            // race, #65 B). Front whatever exists one runloop turn later.
            DispatchQueue.main.async {
                if let window = Self.mainWindow {
                    diagLog("[WINDOW] showMainWindow: retry-present")
                    window.makeKeyAndOrderFront(nil)
                } else {
                    diagLog("[WINDOW] showMainWindow: retry-none")
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
    // Shared container's defaults from launch — applicationDidFinishLaunching
    // reads this before onAppear runs any handoff, so .standard would be wrong
    // in UI-test mode.
    var defaults: UserDefaults = LoreRootApp.sharedContext.container.defaults

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

    func setupMenuBarIfNeeded(
        coordinator: AppCoordinator,
        settings: AppSettings,
        showMainWindow: @escaping () -> Void,
        showMeetings: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void
    ) {
        guard menuBarController == nil else { return }

        container?.ensureServicesInitialized(settings: settings, coordinator: coordinator)

        let controller = MenuBarController(
            coordinator: coordinator,
            settings: settings,
            onCheckForUpdates: checkForUpdates
        )
        controller.onShowMainWindow = showMainWindow
        controller.onShowMeetings = showMeetings
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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

            // LSUIElement launches the process as .accessory; flipping to
            // .regular above does not activate the app, so the main window
            // would sit unfocused on an inactive Space (launch looks
            // windowless). Present it explicitly — except for login-item
            // launches, which must stay quiet in the background.
            if !isLoginItemLaunch {
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

        registerGlobalHotkey()
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
            diagLog("[DEEPLINK] \(url.absoluteString)")
            guard let command = LoreDeepLink.parse(url) else {
                diagLog("[DEEPLINK] unrecognized URL, skipping")
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
        diagLog("[DEEPLINK] flushing deep link queued before coordinator wire: \(command)")
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
            showBackgroundModeHintIfNeeded()
            return false
        }
        return true
    }

    // MARK: - One-Shot Background Notification

    private func showBackgroundModeHintIfNeeded() {
        guard !defaults.bool(forKey: "hasShownBackgroundModeHint") else { return }
        guard settings?.meetingAutoDetectEnabled == true else { return }

        defaults.set(true, forKey: "hasShownBackgroundModeHint")

        Task {
            let center = UNUserNotificationCenter.current()
            let granted = try? await center.requestAuthorization(options: [.alert])
            guard granted == true else { return }

            let content = UNMutableNotificationContent()
            content.title = "\(XMOTheme.wordmark) is still running"
            content.body = "Meeting detection is active. Click the menu bar icon to access controls."

            let request = UNNotificationRequest(
                identifier: "background-mode-hint",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    // MARK: - Dictation Setup

    func setupDictationIfNeeded(coordinator: AppCoordinator, settings: AppSettings) {
        guard !didSetupDictation else { return }
        didSetupDictation = true

        coordinator.dictationCoordinator.settings = settings
        coordinator.dictationCoordinator.audioBus = container?.audioBus
        coordinator.dictationCoordinator.backendCache = coordinator.sharedBackendCache
        coordinator.hotkeyManager.install(
            coordinator: coordinator.dictationCoordinator,
            settings: settings
        )
        coordinator.dictationIndicator.start(
            coordinator: coordinator.dictationCoordinator,
            hotkeyManager: coordinator.hotkeyManager
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
        guard let coordinator, let settings else { return }
        guard settings.hasAcknowledgedRecordingConsent else { return }

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
