import XCTest
@testable import LoreKit

@MainActor
final class MeetingDetectionControllerTests: XCTestCase {

    /// Isolated settings (ephemeral suite + secret store) — never `.live()`.
    private func makeSettings() -> AppSettings {
        let suiteName = "MeetingDetectionControllerTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return AppSettings(storage: AppSettingsStorage(
            defaults: suite,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(suiteName),
            legacyNotesDirectories: [],
            runMigrations: false
        ))
    }

    // MARK: - Event Stream: accepted metadata flows through

    func testAcceptedEventFlowsMetadata() async throws {
        let controller = MeetingDetectionController()

        let metadata = MeetingMetadata(
            detectionContext: DetectionContext(
                signal: .appLaunched(MeetingApp(bundleID: "us.zoom.xos", name: "Zoom")),
                detectedAt: Date(),
                meetingApp: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
                calendarEvent: nil
            ),
            calendarEvent: nil,
            title: "Zoom",
            startedAt: Date(),
            endedAt: nil
        )

        var receivedEvent: DetectionEvent?

        let consumeTask = Task { @MainActor in
            for await event in controller.events {
                receivedEvent = event
                break
            }
        }

        // Yield after consumer is listening
        try await Task.sleep(for: .milliseconds(50))
        controller.yield(.accepted(metadata))

        // Wait for consumer to process
        try await Task.sleep(for: .milliseconds(50))

        if case .accepted(let received) = receivedEvent {
            XCTAssertEqual(received.title, "Zoom")
            XCTAssertEqual(received.detectionContext?.meetingApp?.bundleID, "us.zoom.xos")
        } else {
            XCTFail("Expected .accepted event, got \(String(describing: receivedEvent))")
        }

        consumeTask.cancel()
    }

    // MARK: - Events consumed exactly once (one-shot)

    func testEventsConsumedExactlyOnce() async throws {
        let controller = MeetingDetectionController()

        var firstConsumerEvents: [DetectionEvent] = []
        var secondConsumerEvents: [DetectionEvent] = []

        // First consumer starts and gets the event
        let firstConsumer = Task { @MainActor in
            for await event in controller.events {
                firstConsumerEvents.append(event)
                if firstConsumerEvents.count >= 1 { break }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        controller.yield(.dismissed)
        try await Task.sleep(for: .milliseconds(50))

        // After first consumer finishes, the event is consumed
        XCTAssertEqual(firstConsumerEvents.count, 1)
        if case .dismissed = firstConsumerEvents.first {
            // correct
        } else {
            XCTFail("Expected .dismissed")
        }

        firstConsumer.cancel()
        // Second consumer won't see the already-consumed event
        XCTAssertTrue(secondConsumerEvents.isEmpty)
    }

    // MARK: - Multiple rapid events all delivered (unbounded)

    func testMultipleRapidEventsDelivered() async throws {
        let controller = MeetingDetectionController()
        var receivedEvents: [DetectionEvent] = []

        let consumeTask = Task { @MainActor in
            for await event in controller.events {
                receivedEvents.append(event)
                if receivedEvents.count >= 4 { break }
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        // Yield 4 events rapidly
        controller.yield(.dismissed)
        controller.yield(.timeout)
        controller.yield(.meetingAppExited)
        controller.yield(.notAMeeting(bundleID: "com.test.app"))

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(receivedEvents.count, 4)
        consumeTask.cancel()
    }

    // MARK: - DismissedEvents Tracking

    func testDismissedEventsInitiallyEmpty() async {
        let controller = MeetingDetectionController()
        XCTAssertTrue(controller.dismissedEvents.isEmpty)
    }

    // MARK: - noteUtterance lifecycle

    func testNoteUtteranceUpdatesState() async throws {
        let controller = MeetingDetectionController()

        XCTAssertFalse(controller.isMonitoringSilence)

        controller.startSilenceMonitoring()
        XCTAssertTrue(controller.isMonitoringSilence)

        // noteUtterance should work without error
        controller.noteUtterance()

        controller.stopSilenceMonitoring()
        XCTAssertFalse(controller.isMonitoringSilence)
    }

    // MARK: - Observable State

    func testInitialState() async {
        let controller = MeetingDetectionController()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.detectedApp)
        XCTAssertFalse(controller.isMonitoringSilence)
        XCTAssertNil(controller.activeSettings)
        XCTAssertNil(controller.meetingDetector)
    }

    // MARK: - Teardown Clears State

    func testTeardownClearsState() async {
        let controller = MeetingDetectionController()
        controller.teardown()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.detectedApp)
        XCTAssertFalse(controller.isMonitoringSilence)
    }

    // MARK: - Silence Monitoring Lifecycle

    func testSilenceMonitoringStartStop() async {
        let controller = MeetingDetectionController()

        controller.startSilenceMonitoring()
        XCTAssertTrue(controller.isMonitoringSilence)

        controller.stopSilenceMonitoring()
        XCTAssertFalse(controller.isMonitoringSilence)

        // Double stop is safe
        controller.stopSilenceMonitoring()
        XCTAssertFalse(controller.isMonitoringSilence)
    }

    // MARK: - Stream construction does not block

    func testStreamUsesUnboundedBuffering() async {
        let controller = MeetingDetectionController()
        _ = controller.events
        // Reaching this point means the stream didn't block on init
    }

    // MARK: - Session-Active Suppression (#77)

    // These tests pin the isSessionActive guard in handleMeetingDetected; the
    // AppContainer closure wiring (meeting state != .idle — which since #153
    // includes a paused meeting, whose free mic would otherwise draw a prompt
    // for the meeting already open — or dictationCoordinator.state ==
    // .recording) is verified by inspection.

    func testMeetingDetectedSuppressedWhileSessionActive() async {
        let controller = MeetingDetectionController()
        controller.isSessionActive = { true }

        let prompted = controller.handleMeetingDetected(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom")
        )

        XCTAssertFalse(
            prompted,
            "No notch prompt while a session (meeting recording or dictation) is active"
        )
    }

    func testMeetingDetectedPromptsWhenNoSessionActive() async {
        let controller = MeetingDetectionController()
        controller.isSessionActive = { false }

        // notchPromptPresenter is nil without setup(), so no window is shown —
        // the return value covers reaching the prompt path.
        let prompted = controller.handleMeetingDetected(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom")
        )

        XCTAssertTrue(prompted, "Prompt path should be reached when no session is active")
    }

    // MARK: - Enable/Disable/Enable Cycle (#78)

    /// One detection stop/start cycle must not leave a ghost detector:
    /// teardown must stop the OLD MeetingDetector so its monitor loop exits
    /// and the detector — in production, with it the CoreAudioSignalSource
    /// and its HAL listeners — is released (#78).
    func testTeardownStopsAndReleasesOldDetector() async throws {
        let controller = MeetingDetectionController()
        let source = MockAudioSignalSource()

        // Inject a started detector (setup() starts a real CoreAudio mic
        // listener, unavailable under swift test). Its monitor task now parks
        // on the mock signal stream, holding the detector strongly.
        var detector: MeetingDetector? = MeetingDetector(audioSource: source)
        await detector?.start()
        controller.injectDetectorForTesting(detector!)
        weak var oldDetector = detector
        detector = nil

        controller.teardown()
        XCTAssertNil(controller.meetingDetector, "teardown must clear the detector reference")

        // Once stop() runs, nothing holds the detector and it deallocates.
        let released = await waitUntil { oldDetector == nil }
        XCTAssertTrue(released, "old detector must deallocate after teardown")
    }

    // MARK: - Signal-Only Ignore (#101)

    /// Field report WQ55J3PP: a mic-using app outside the known list. The
    /// detection is attributed to the frontmost app, Ignore persists its
    /// bundle ID — even after a mic flap nulls the detector's live copy —
    /// and the next detection with the same attribution is suppressed.
    func testIgnoreOnSignalOnlyDetectionPersistsAndSuppresses() async throws {
        let controller = MeetingDetectionController()
        let settings = makeSettings()
        let source = MockAudioSignalSource()
        let geforce = MeetingApp(bundleID: "com.nvidia.gfnpc", name: "GeForce NOW")
        let detector = MeetingDetector(audioSource: source, frontmostApp: { geforce })
        await detector.start()
        controller.injectDetectorForTesting(detector, settings: settings)

        // Signal-only detection: mic active, no known meeting app running.
        source.emit(true)
        try await Task.sleep(for: .seconds(5.5))
        let attributed = await detector.detectedApp
        XCTAssertEqual(attributed, geforce, "signal-only detection must be attributed to frontmost")

        // The prompt goes up naming GeForce NOW...
        XCTAssertTrue(controller.handleMeetingDetected(app: attributed))

        // ...then the mic flaps, nulling the detector's live copy. Ignore
        // must still act on what the prompt named, not the detector's now.
        source.emit(false)
        let actorCleared = await pollUntilNil { await detector.detectedApp }
        XCTAssertTrue(actorCleared, "flap must clear the detector's copy for this test to bite")

        controller.handleIgnoreApp()
        XCTAssertTrue(
            settings.ignoredAppBundleIDs.contains(geforce.bundleID),
            "Ignore must persist the bundle ID the prompt named, flap or no flap"
        )

        let prompted = controller.handleMeetingDetected(app: geforce)
        XCTAssertFalse(prompted, "next detection with the same attribution must be suppressed")

        await detector.stop()
        source.finish()
    }

    /// #102: Accept raced by a mic flap. The prompt named an app; the flap
    /// nulls the detector's live copy before the click. Accept must still
    /// start the session attributed to the named app — .appLaunched signal,
    /// meetingApp, title — not an unattributed .audioActivity session (which
    /// would also lose app-exit auto-stop).
    func testAcceptAfterFlapAttributesSessionToNamedApp() async throws {
        let controller = MeetingDetectionController()
        let source = MockAudioSignalSource()
        let geforce = MeetingApp(bundleID: "com.nvidia.gfnpc", name: "GeForce NOW")
        let detector = MeetingDetector(audioSource: source, frontmostApp: { geforce })
        await detector.start()
        controller.injectDetectorForTesting(detector)

        var receivedEvent: DetectionEvent?
        let consumeTask = Task { @MainActor in
            for await event in controller.events {
                receivedEvent = event
                break
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        // Signal-only detection; the prompt goes up naming the attributed app.
        source.emit(true)
        try await Task.sleep(for: .seconds(5.5))
        let attributed = await detector.detectedApp
        XCTAssertEqual(attributed, geforce, "signal-only detection must be attributed to frontmost")
        XCTAssertTrue(controller.handleMeetingDetected(app: attributed))

        // The mic flaps, nulling the detector's live copy before the click.
        source.emit(false)
        let actorCleared = await pollUntilNil { await detector.detectedApp }
        XCTAssertTrue(actorCleared, "flap must clear the detector's copy for this test to bite")

        controller.handleDetectionAccepted()
        try await Task.sleep(for: .milliseconds(100))

        guard case .accepted(let metadata) = receivedEvent else {
            XCTFail("Expected .accepted, got \(String(describing: receivedEvent))")
            consumeTask.cancel()
            await detector.stop()
            source.finish()
            return
        }
        XCTAssertEqual(metadata.detectionContext?.meetingApp, geforce,
                       "Accept must attribute the session to the app the prompt named")
        XCTAssertEqual(metadata.title, geforce.name)
        if case .appLaunched(let app) = metadata.detectionContext?.signal {
            XCTAssertEqual(app, geforce)
        } else {
            XCTFail("signal must be .appLaunched — .audioActivity means an unattributed session")
        }

        consumeTask.cancel()
        await detector.stop()
        source.finish()
    }

    /// Polls an actor-isolated optional until it goes nil (waitUntil takes a
    /// synchronous closure, so it can't await the detector).
    private func pollUntilNil(_ read: () async -> MeetingApp?) async -> Bool {
        for _ in 0..<40 {
            if await read() == nil { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await read() == nil
    }

    /// Ignore on an unattributed detection (frontmost was Lore or nil):
    /// nothing is persisted, so no `appIgnoredPermanently` diagnostic may be
    /// recorded — the pre-#101 stream claimed the button worked while the
    /// list stayed untouched. The shown prompt itself records
    /// `.shownUnattributed` so the stream can tell the two apart.
    func testIgnoreOnUnattributedDetectionRecordsNoDiagnostic() {
        let controller = MeetingDetectionController()

        func ignoredDiagCount() -> Int {
            DiagStore.shared.recent(DiagStore.capacity).filter {
                $0.event == .detectionPrompt(disposition: .appIgnoredPermanently)
            }.count
        }
        let before = ignoredDiagCount()

        controller.handleMeetingDetected(app: nil)
        XCTAssertEqual(
            DiagStore.shared.recent(1).first?.event,
            .detectionPrompt(disposition: .shownUnattributed)
        )

        controller.handleIgnoreApp()
        XCTAssertEqual(ignoredDiagCount(), before, "no persist happened, so no diagnostic may claim it did")
    }

    // MARK: - App Exit Monitoring

    func testAppExitMonitorYieldsEventWhenAppNotRunning() async throws {
        let controller = MeetingDetectionController()
        var receivedEvent: DetectionEvent?

        let consumeTask = Task { @MainActor in
            for await event in controller.events {
                receivedEvent = event
                break
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        // Use a bundle ID that is definitely not running
        controller.startAppExitMonitoring(bundleID: "com.test.fake-app-not-running")

        // The monitor polls every 5 seconds; wait for it to fire
        try await Task.sleep(for: .seconds(6))

        if case .meetingAppExited = receivedEvent {
            // correct — the monitor detected the app is not running
        } else {
            XCTFail("Expected .meetingAppExited, got \(String(describing: receivedEvent))")
        }

        consumeTask.cancel()
    }

    func testStopAppExitMonitoringPreventsEvent() async throws {
        let controller = MeetingDetectionController()
        var receivedEvent: DetectionEvent?

        let consumeTask = Task { @MainActor in
            for await event in controller.events {
                receivedEvent = event
                break
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        // Start monitoring then immediately stop
        controller.startAppExitMonitoring(bundleID: "com.test.fake-app-not-running")
        controller.stopAppExitMonitoring()

        // Wait past the poll interval
        try await Task.sleep(for: .seconds(6))

        // No event should have been yielded since we stopped monitoring
        XCTAssertNil(receivedEvent)

        consumeTask.cancel()
    }
}
