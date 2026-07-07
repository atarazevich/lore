import AppKit
import Foundation
import Observation

/// One-shot events emitted by the detection controller for consumption by the coordinator.
enum DetectionEvent: Sendable {
    case accepted(MeetingMetadata)
    case notAMeeting(bundleID: String)
    case dismissed
    case timeout
    case meetingAppExited
    case silenceTimeout
    case systemSleep
}

/// Owns the meeting detection lifecycle: mic monitoring, notification prompting,
/// silence timeout, and sleep observation. Exposes an `AsyncStream<DetectionEvent>`
/// consumed exactly once by the coordinator.
@Observable
@MainActor
final class MeetingDetectionController {
    // MARK: - Observable State (for UI)

    @ObservationIgnored nonisolated(unsafe) private var _isEnabled = false
    private(set) var isEnabled: Bool {
        get { access(keyPath: \.isEnabled); return _isEnabled }
        set { withMutation(keyPath: \.isEnabled) { _isEnabled = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _detectedApp: MeetingApp?
    private(set) var detectedApp: MeetingApp? {
        get { access(keyPath: \.detectedApp); return _detectedApp }
        set { withMutation(keyPath: \.detectedApp) { _detectedApp = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isMonitoringSilence = false
    private(set) var isMonitoringSilence: Bool {
        get { access(keyPath: \.isMonitoringSilence); return _isMonitoringSilence }
        set { withMutation(keyPath: \.isMonitoringSilence) { _isMonitoringSilence = newValue } }
    }

    // MARK: - Event Stream

    /// One-shot event stream. Events are consumed exactly once, never replayed.
    let events: AsyncStream<DetectionEvent>
    private let eventContinuation: AsyncStream<DetectionEvent>.Continuation

    // MARK: - Internal State

    /// The meeting detector actor (mic listener + process scanner).
    private(set) var meetingDetector: MeetingDetector?

    #if DEBUG
    /// Test seam: setup() can't run under swift test (NotificationService's
    /// UNUserNotificationCenter requires a real app bundle), so tests inject
    /// a detector with a mock signal source directly.
    func injectDetectorForTesting(_ detector: MeetingDetector) {
        meetingDetector = detector
    }
    #endif

    /// Notification service for prompting the user. Kept as a secondary
    /// surface: posting fails silently on dev-signed builds (no provisioning
    /// profile → authorization denied); removal is deferred (#79).
    private(set) var notificationService: NotificationService?

    /// Notch-anchored prompt — the primary detection surface (#79).
    private(set) var notchPromptPresenter: NotchPromptPresenter?

    /// The long-running task that listens for detection events.
    private var detectionTask: Task<Void, Never>?

    /// Task monitoring silence timeout during detected sessions.
    private var silenceCheckTask: Task<Void, Never>?

    /// Task polling for meeting app process exit during recording.
    private var appExitMonitorTask: Task<Void, Never>?

    /// Observer token for system sleep notifications.
    private var sleepObserver: Any?

    /// Timestamp of the last utterance, used for silence timeout.
    private var lastUtteranceAt: Date?

    /// Sessions the user dismissed via "Not a Meeting" (by detected app bundle ID).
    /// Cleared on app restart. Prevents re-prompting for the same app within a session.
    private(set) var dismissedEvents: Set<String> = []

    /// Retained reference to the active settings for detection callbacks.
    private(set) var activeSettings: AppSettings?

    /// Closure to check if a session is currently active — meeting recording
    /// or Lore's own dictation (#77). Used to suppress detection prompts.
    var isSessionActive: () -> Bool = { false }

    // MARK: - Init

    init() {
        let (stream, continuation) = AsyncStream<DetectionEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.eventContinuation = continuation
    }

    /// Yield an event into the stream. Visible for testing.
    func yield(_ event: DetectionEvent) {
        eventContinuation.yield(event)
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: - Setup / Teardown

    /// Initialize and start the meeting detection system.
    func setup(settings: AppSettings) {
        guard meetingDetector == nil else { return }
        activeSettings = settings
        isEnabled = true

        let detector = MeetingDetector(
            customBundleIDs: settings.customMeetingAppBundleIDs
        )
        meetingDetector = detector

        let service = NotificationService()
        notificationService = service

        // Wire notification callbacks to yield events
        service.onAccept = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleDetectionAccepted()
            }
        }

        service.onNotAMeeting = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleDetectionNotAMeeting()
            }
        }

        service.onDismiss = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleDetectionDismissed()
            }
        }

        service.onIgnoreApp = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleIgnoreApp()
            }
        }

        service.onTimeout = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleDetectionTimeout()
            }
        }

        // Notch prompt: same callbacks, same handlers as the notification
        // surface (no onDismiss — the notch has no user-driven dismiss
        // affordance). Whichever surface resolves first wins — the handlers
        // withdraw both.
        let presenter = NotchPromptPresenter()
        notchPromptPresenter = presenter
        presenter.onAccept = { [weak self] in self?.handleDetectionAccepted() }
        presenter.onNotAMeeting = { [weak self] in self?.handleDetectionNotAMeeting() }
        presenter.onIgnoreApp = { [weak self] in self?.handleIgnoreApp() }
        presenter.onTimeout = { [weak self] in self?.handleDetectionTimeout() }

        // Start listening for detection events from the MeetingDetector
        detectionTask = Task { [weak self] in
            await detector.start()

            for await event in detector.events {
                guard !Task.isCancelled else { break }
                guard let self else { break }

                switch event {
                case .detected(let app):
                    await self.handleMeetingDetected(app: app)
                case .ended:
                    self.handleMeetingEnded()
                }
            }
        }

        installSleepObserver()

        diagLog("[DETECT] detection system started")
    }

    /// Tear down the meeting detection system.
    func teardown() {
        detectionTask?.cancel()
        detectionTask = nil

        silenceCheckTask?.cancel()
        silenceCheckTask = nil
        isMonitoringSilence = false

        appExitMonitorTask?.cancel()
        appExitMonitorTask = nil

        // Capture before nil-ing: the Task body runs after the synchronous
        // assignment below, so reading `self.meetingDetector` inside it would
        // find nil and stop() would never run — each enable/disable cycle
        // would leak a live detector with its HAL listeners installed (#78).
        if let detector = meetingDetector {
            meetingDetector = nil
            Task {
                await detector.stop()
                diagLog("[DETECT] detector stopped, listeners released")
            }
        }

        notificationService?.cancelPending()
        notificationService = nil

        notchPromptPresenter?.cancelPending()
        notchPromptPresenter = nil

        if let observer = sleepObserver {
            NotificationCenter.default.removeObserver(observer)
            sleepObserver = nil
        }

        dismissedEvents.removeAll()
        activeSettings = nil
        isEnabled = false
        detectedApp = nil
        lastUtteranceAt = nil

        diagLog("[DETECT] detection system stopped")
    }

    // MARK: - Sleep Observer

    private func installSleepObserver() {
        sleepObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                diagLog("[DETECT] system sleep, yielding event")
                // Withdraw any pending prompt: without this, the notch
                // window survives sleep and its ContinuousClock timeout
                // fires immediately on wake for a meeting that is long dead.
                self.withdrawPrompts()
                self.eventContinuation.yield(.systemSleep)
            }
        }
    }

    // MARK: - Silence Monitoring

    /// Start monitoring for silence timeout during an auto-detected session.
    func startSilenceMonitoring() {
        lastUtteranceAt = Date()
        silenceCheckTask?.cancel()
        isMonitoringSilence = true

        silenceCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                guard let self else { break }

                let timeoutMinutes = self.activeSettings?.silenceTimeoutMinutes ?? 15
                if let lastUtterance = self.lastUtteranceAt {
                    let elapsed = Date().timeIntervalSince(lastUtterance)
                    if elapsed >= Double(timeoutMinutes) * 60.0 {
                        diagLog("[DETECT] silence timeout (\(timeoutMinutes)m), stopping")
                        self.eventContinuation.yield(.silenceTimeout)
                        break
                    }
                }
            }
        }
    }

    /// Stop silence monitoring (e.g. when session ends).
    func stopSilenceMonitoring() {
        silenceCheckTask?.cancel()
        silenceCheckTask = nil
        lastUtteranceAt = nil
        isMonitoringSilence = false
    }

    /// Called when a new utterance arrives, resets the silence timer.
    func noteUtterance() {
        lastUtteranceAt = Date()
    }

    // MARK: - Meeting App Process Monitor

    /// Start polling for meeting app process exit during recording.
    /// When the meeting app that triggered detection is no longer running,
    /// yield `.meetingAppExited` so the coordinator can auto-stop.
    func startAppExitMonitoring(bundleID: String) {
        appExitMonitorTask?.cancel()

        appExitMonitorTask = Task { [weak self] in
            // Poll every 5 seconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                guard let self else { break }

                let isRunning = NSWorkspace.shared.runningApplications.contains {
                    $0.bundleIdentifier == bundleID
                }

                if !isRunning {
                    diagLog("[DETECT] meeting app exited (\(bundleID)), yielding event")
                    self.eventContinuation.yield(.meetingAppExited)
                    break
                }
            }
        }
    }

    /// Stop monitoring for meeting app process exit.
    func stopAppExitMonitoring() {
        appExitMonitorTask?.cancel()
        appExitMonitorTask = nil
    }

    // MARK: - Evaluate Immediate

    /// Check current state immediately (e.g. on app launch) to see if a meeting is already active.
    func evaluateImmediate() async {
        guard !isSessionActive() else { return }
        guard let detector = meetingDetector else { return }

        let (micActive, app) = await detector.queryCurrentState()
        if micActive, app != nil {
            await handleMeetingDetected(app: app)
        }
    }

    // MARK: - Detection Event Handlers

    /// Returns true when the prompt path was reached (notification post attempted),
    /// false when suppressed. Visible for testing.
    @discardableResult
    func handleMeetingDetected(app: MeetingApp?) async -> Bool {
        detectedApp = app

        // Don't prompt if already recording (meeting session or dictation, #77)
        guard !isSessionActive() else {
            diagLog("[DETECT] prompt suppressed — session active")
            return false
        }

        // Don't re-prompt for dismissed apps
        if let bundleID = app?.bundleID, dismissedEvents.contains(bundleID) {
            diagLog("[DETECT] prompt suppressed — dismissed earlier this session")
            return false
        }

        // Don't prompt for permanently ignored apps
        if let bundleID = app?.bundleID,
           activeSettings?.ignoredAppBundleIDs.contains(bundleID) == true {
            diagLog("[DETECT] prompt suppressed — app permanently ignored")
            return false
        }

        diagLog("[DETECT] prompting")
        // Primary surface: notch prompt (#79). The notification attempt stays
        // as a secondary surface — it fails silently on dev-signed builds.
        notchPromptPresenter?.present(appName: app?.name)
        _ = await notificationService?.postMeetingDetected(appName: app?.name)
        return true
    }

    /// Withdraw both prompt surfaces. Called when either surface resolves
    /// (accept / not-a-meeting / ignore / dismiss / timeout) so the other
    /// doesn't linger and fire a stale 60s timeout, and when the detected
    /// meeting ends.
    private func withdrawPrompts() {
        notificationService?.cancelPending()
        notchPromptPresenter?.cancelPending()
    }

    private func handleMeetingEnded() {
        detectedApp = nil
        // Withdraw any stale prompt: the meeting it offers to transcribe is
        // gone. Also closes the #77 race where dictation ends between the
        // detector's debounce-expiry yield and MainActor delivery — the prompt
        // would fire for a dictation that just ended and never be withdrawn.
        withdrawPrompts()
        eventContinuation.yield(.meetingAppExited)
    }

    private func handleDetectionAccepted() {
        diagLog("[DETECT] user accepted, starting session")
        withdrawPrompts()
        Task {
            let app = await meetingDetector?.detectedApp
            let context = DetectionContext(
                signal: app.map { .appLaunched($0) } ?? .audioActivity,
                detectedAt: Date(),
                meetingApp: app,
                calendarEvent: nil
            )
            let metadata = MeetingMetadata(
                detectionContext: context,
                calendarEvent: nil,
                title: app?.name,
                startedAt: Date(),
                endedAt: nil
            )
            self.eventContinuation.yield(.accepted(metadata))
        }
    }

    private func handleDetectionNotAMeeting() {
        diagLog("[DETECT] user action: not a meeting")
        withdrawPrompts()
        Task {
            if let app = await meetingDetector?.detectedApp {
                dismissedEvents.insert(app.bundleID)
                eventContinuation.yield(.notAMeeting(bundleID: app.bundleID))
            }
        }
    }

    private func handleIgnoreApp() {
        diagLog("[DETECT] user action: ignore this app permanently")
        withdrawPrompts()
        Task {
            if let app = await meetingDetector?.detectedApp, let settings = activeSettings {
                var ignored = settings.ignoredAppBundleIDs
                if !ignored.contains(app.bundleID) {
                    ignored.append(app.bundleID)
                    settings.ignoredAppBundleIDs = ignored
                }
                dismissedEvents.insert(app.bundleID)
            }
        }
    }

    private func handleDetectionDismissed() {
        diagLog("[DETECT] user action: dismissed notification")
        withdrawPrompts()
        eventContinuation.yield(.dismissed)
    }

    private func handleDetectionTimeout() {
        diagLog("[DETECT] notification timed out (60s, no user action)")
        withdrawPrompts()
        eventContinuation.yield(.timeout)
    }
}
