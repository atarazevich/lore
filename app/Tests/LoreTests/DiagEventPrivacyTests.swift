import CoreAudio
import XCTest
@testable import LoreKit

/// The compile-time guarantee — "no `DiagEvent` case can carry user content" —
/// deserves a runtime witness (#82, design §4).
///
/// **How this cannot be bypassed.** An earlier version of this file compared two
/// hand-maintained lists against each other, so an author who added
/// `case foo(String)`, satisfied production's `caseName` switch, and never opened
/// this file would have shipped the leak with every test still green. The loop is
/// closed here by three links:
///
/// 1. `key(of:)` is an exhaustive `switch` over `DiagEvent`. A new case does not
///    compile until it is given a `CaseKey`.
/// 2. `CaseKey` is `CaseIterable`, so the *expected* set grows by itself the moment
///    that key is added — nothing is hand-maintained.
/// 3. `sample(for:)` is an exhaustive `switch` over `CaseKey` returning a real
///    `DiagEvent`. The new case cannot compile without a value existing, and that
///    value is what every assertion below runs over.
///
/// The assertions, strongest first:
///
/// - **Typed payloads** (`testNoAssociatedValueIsAFreeFormString`): reflect over each
///   sample and assert no associated value is *declared* as `String`/`Substring`/`URL`
///   (or an optional of one). This is the property "there is no field a transcript
///   fits into", stated as a test. It catches `.foo("ok")` — a leak whose *value*
///   happens to sit in the closed vocabulary.
/// - **Closed vocabulary**: every string value in the encoded JSON is the raw value of
///   one of the model's enums. Run over in-memory encodes *and* over the persisted
///   `events.json`, which is the artifact that actually uploads (#84).
/// - **Fixtures**: no substring of a synthetic transcript, device name, path or key.
final class DiagEventPrivacyTests: XCTestCase {

    // MARK: - Fixtures a report must never contain (`PrivacyFixtures`)

    private static let transcript = PrivacyFixtures.transcript
    private static let fixtures = PrivacyFixtures.all
    private static let fixtureTokens = PrivacyFixtures.tokens
    private static let stringValues = PrivacyFixtures.stringValues(in:)

    // MARK: - Link 1: exhaustive over DiagEvent (compile-time)

    /// One key per `DiagEvent` case. Adding a case breaks `key(of:)` below until a key
    /// is added here; `CaseIterable` then grows the expected set for free.
    private enum CaseKey: String, CaseIterable {
        case appLaunched, appLaunchRefused
        case healthConditionSustained, healthConditionCleared
        case healthSummonFired, healthSummonWithdrawn, healthSummonCleared
        case onboardingStarted, onboardingStepShown, onboardingDictationLanded
        case onboardingCompleted
        case permissionTransition, tapCreate, tapReinstall, tapDisabledByOS
        case tapDiedDuringRecording, tapEventsStalled, tapEventsResumed, tapGaveUp
        case secureInputChanged, pasteAttempt
        case captureStart, captureFailed, captureStopped, captureRetryScheduled
        case captureGaveUp, captureReconfigured, inputDeviceSelected, deviceSwitched
        case noFramesRecovery, micStalled, micRecovered, micFramesFlowing
        case systemAudioCapture
        case systemAudioGaveUp, recordingSaved, recordingUnowned
        case modelLoad, modelCacheCleared, transcribed, echoSuppressed
        case transcriptRepairQueued, transcriptRepairSettled
        case apiCall
        case dictationRecorded, dictationZeroFrames, dictationPasted
        case dictationUpgrade, dictationDiscarded
        case dictationItemCollected, dictationItemSwitched, dictationItemsPasted
        case dictationItemsPruned
        case dictationScreenshotChord, clipboardProbeRead
        case detectionLifecycle, detectionDeviceListChanged, detectionListenerFailed
        case detectionSignal, detectionAppScan, detectionPrompt
        case notificationAuthorization, notificationPosted
        case sessionPaused, sessionResumed, sessionResumeFailed
        case historyWriteFailed, historyMigrated, corruptFileAside, sessionImportFailed
        case notesFolderMoveStarted, notesFolderMigrated, notesFolderLeftoverCleared
    }

    /// Exhaustive over `DiagEvent`. The compile-time forcing function in the test
    /// target — counterpart to `DiagEvent.caseName` in production.
    private static func key(of event: DiagEvent) -> CaseKey {
        switch event {
        case .appLaunched: return .appLaunched
        case .appLaunchRefused: return .appLaunchRefused
        case .healthConditionSustained: return .healthConditionSustained
        case .healthConditionCleared: return .healthConditionCleared
        case .healthSummonFired: return .healthSummonFired
        case .healthSummonWithdrawn: return .healthSummonWithdrawn
        case .healthSummonCleared: return .healthSummonCleared
        case .onboardingStarted: return .onboardingStarted
        case .onboardingStepShown: return .onboardingStepShown
        case .onboardingDictationLanded: return .onboardingDictationLanded
        case .onboardingCompleted: return .onboardingCompleted
        case .permissionTransition: return .permissionTransition
        case .tapCreate: return .tapCreate
        case .tapReinstall: return .tapReinstall
        case .tapDisabledByOS: return .tapDisabledByOS
        case .tapDiedDuringRecording: return .tapDiedDuringRecording
        case .tapEventsStalled: return .tapEventsStalled
        case .tapEventsResumed: return .tapEventsResumed
        case .tapGaveUp: return .tapGaveUp
        case .secureInputChanged: return .secureInputChanged
        case .pasteAttempt: return .pasteAttempt
        case .captureStart: return .captureStart
        case .captureFailed: return .captureFailed
        case .captureStopped: return .captureStopped
        case .captureRetryScheduled: return .captureRetryScheduled
        case .captureGaveUp: return .captureGaveUp
        case .captureReconfigured: return .captureReconfigured
        case .inputDeviceSelected: return .inputDeviceSelected
        case .deviceSwitched: return .deviceSwitched
        case .noFramesRecovery: return .noFramesRecovery
        case .micStalled: return .micStalled
        case .micRecovered: return .micRecovered
        case .micFramesFlowing: return .micFramesFlowing
        case .systemAudioCapture: return .systemAudioCapture
        case .systemAudioGaveUp: return .systemAudioGaveUp
        case .recordingSaved: return .recordingSaved
        case .recordingUnowned: return .recordingUnowned
        case .modelLoad: return .modelLoad
        case .modelCacheCleared: return .modelCacheCleared
        case .transcribed: return .transcribed
        case .echoSuppressed: return .echoSuppressed
        case .transcriptRepairQueued: return .transcriptRepairQueued
        case .transcriptRepairSettled: return .transcriptRepairSettled
        case .apiCall: return .apiCall
        case .dictationRecorded: return .dictationRecorded
        case .dictationZeroFrames: return .dictationZeroFrames
        case .dictationPasted: return .dictationPasted
        case .dictationUpgrade: return .dictationUpgrade
        case .dictationDiscarded: return .dictationDiscarded
        case .dictationItemCollected: return .dictationItemCollected
        case .dictationItemSwitched: return .dictationItemSwitched
        case .dictationItemsPasted: return .dictationItemsPasted
        case .dictationItemsPruned: return .dictationItemsPruned
        case .dictationScreenshotChord: return .dictationScreenshotChord
        case .clipboardProbeRead: return .clipboardProbeRead
        case .detectionLifecycle: return .detectionLifecycle
        case .detectionDeviceListChanged: return .detectionDeviceListChanged
        case .detectionListenerFailed: return .detectionListenerFailed
        case .detectionSignal: return .detectionSignal
        case .detectionAppScan: return .detectionAppScan
        case .detectionPrompt: return .detectionPrompt
        case .notificationAuthorization: return .notificationAuthorization
        case .notificationPosted: return .notificationPosted
        case .sessionPaused: return .sessionPaused
        case .sessionResumed: return .sessionResumed
        case .sessionResumeFailed: return .sessionResumeFailed
        case .historyWriteFailed: return .historyWriteFailed
        case .historyMigrated: return .historyMigrated
        case .notesFolderMoveStarted: return .notesFolderMoveStarted
        case .notesFolderMigrated: return .notesFolderMigrated
        case .notesFolderLeftoverCleared: return .notesFolderLeftoverCleared
        case .corruptFileAside: return .corruptFileAside
        case .sessionImportFailed: return .sessionImportFailed
        }
    }

    // MARK: - Link 3: exhaustive over CaseKey, returning a real event

    /// Worst-case value for every case. "Worst case" means the value a caller would
    /// most plausibly want to smuggle text into — the longest transcript, the named
    /// device, the failing endpoint. Because no case accepts a `String`, the worst
    /// case is still only numbers, booleans and closed enums. That is the point.
    private static func sample(for key: CaseKey) -> DiagEvent {
        switch key {
        case .appLaunched: return .appLaunched(build: .max)
        case .appLaunchRefused: return .appLaunchRefused(build: .max)
        case .healthConditionSustained: return .healthConditionSustained(trigger: .captureFailed)
        case .healthConditionCleared: return .healthConditionCleared(trigger: .identityMigration)
        case .healthSummonFired: return .healthSummonFired(trigger: .pasteFailed)
        case .healthSummonWithdrawn:
            return .healthSummonWithdrawn(trigger: .systemAudioFailed, reason: .sweptGhost)
        case .healthSummonCleared: return .healthSummonCleared
        case .onboardingStarted: return .onboardingStarted
        case .onboardingStepShown: return .onboardingStepShown(step: .permissions)
        case .onboardingDictationLanded: return .onboardingDictationLanded
        case .onboardingCompleted: return .onboardingCompleted

        case .permissionTransition:
            return .permissionTransition(permission: .accessibility, granted: false)
        case .tapCreate: return .tapCreate(outcome: .failed, osStatus: .min)
        case .tapReinstall: return .tapReinstall(outcome: .failed)
        case .tapDisabledByOS: return .tapDisabledByOS
        case .tapDiedDuringRecording: return .tapDiedDuringRecording
        case .tapEventsStalled: return .tapEventsStalled(seconds: .max)
        case .tapEventsResumed: return .tapEventsResumed
        case .tapGaveUp: return .tapGaveUp(attempts: .max)
        case .secureInputChanged: return .secureInputChanged(active: true, holderPID: .max)
        case .pasteAttempt:
            return .pasteAttempt(kind: .undoAndPaste, eventsCreated: false, accessibilityTrusted: false)

        case .captureStart: return .captureStart(deviceKind: .wireless, ms: .max)
        case .captureFailed: return .captureFailed(stage: .createIOProc, osStatus: .min)
        case .captureStopped: return .captureStopped(reason: .reconfigure)
        case .captureRetryScheduled: return .captureRetryScheduled(attempt: 3, maxAttempts: 3)
        case .captureGaveUp: return .captureGaveUp(attempts: .max)
        case .captureReconfigured: return .captureReconfigured(reason: .silentTooLong, running: false)
        case .inputDeviceSelected: return .inputDeviceSelected(kind: .virtual, redirectedToBuiltIn: true)
        case .deviceSwitched: return .deviceSwitched(kind: .wired)
        case .noFramesRecovery: return .noFramesRecovery(attempt: 2, maxAttempts: 2)
        case .micStalled: return .micStalled(seconds: .max)
        case .micRecovered: return .micRecovered
        case .micFramesFlowing: return .micFramesFlowing
        case .systemAudioCapture: return .systemAudioCapture(outcome: .failed, osStatus: .min)
        case .systemAudioGaveUp: return .systemAudioGaveUp(attempts: .max)
        case .recordingSaved: return .recordingSaved(outcome: .ok, frames: .max)
        case .recordingUnowned: return .recordingUnowned

        case .modelLoad:
            return .modelLoad(
                model: .vad, outcome: .unknown,
                seconds: .greatestFiniteMagnitude, fromCache: false
            )
        case .modelCacheCleared: return .modelCacheCleared
        case .transcribed:
            return .transcribed(
                chunks: .max, failedChunks: .max, samples: .max,
                characters: transcript.count, ms: .max
            )
        case .echoSuppressed:
            return .echoSuppressed(path: .retroactive, count: .max, meanJaccard: 1.0)
        case .transcriptRepairQueued:
            return .transcriptRepairQueued(reason: .openedMeeting)
        case .transcriptRepairSettled:
            return .transcriptRepairSettled(outcome: .failed)

        case .apiCall:
            return .apiCall(endpoint: .keyHealth, outcome: .unknown, httpStatus: 503, ms: .max)

        case .dictationRecorded: return .dictationRecorded(samples: .max, durationMs: .max)
        case .dictationZeroFrames: return .dictationZeroFrames
        case .dictationPasted: return .dictationPasted(characters: transcript.count, cleaned: true)
        case .dictationUpgrade: return .dictationUpgrade(endpoint: .translate, outcome: .failed)
        case .dictationDiscarded: return .dictationDiscarded(state: .processing)
        case .dictationItemCollected:
            return .dictationItemCollected(kind: .image, bytes: .max)
        case .dictationItemSwitched:
            return .dictationItemSwitched(kind: .text, included: false)
        case .dictationItemsPasted: return .dictationItemsPasted(items: .max, included: .max)
        case .dictationItemsPruned:
            return .dictationItemsPruned(deleted: .max, bytesFreed: .max)
        case .dictationScreenshotChord: return .dictationScreenshotChord(eventsCreated: false)
        case .clipboardProbeRead: return .clipboardProbeRead(read: .data, result: .max)

        case .detectionLifecycle: return .detectionLifecycle(running: true)
        case .detectionDeviceListChanged:
            return .detectionDeviceListChanged(added: .max, removed: .max, monitored: .max)
        case .detectionListenerFailed: return .detectionListenerFailed(osStatus: .min)
        case .detectionSignal: return .detectionSignal(active: true)
        case .detectionAppScan: return .detectionAppScan(found: true)
        case .detectionPrompt: return .detectionPrompt(disposition: .suppressedSessionActive)
        case .notificationAuthorization: return .notificationAuthorization(outcome: .failed)
        case .notificationPosted: return .notificationPosted(outcome: .ok)
        case .sessionPaused: return .sessionPaused
        case .sessionResumed: return .sessionResumed
        case .sessionResumeFailed: return .sessionResumeFailed

        case .historyWriteFailed: return .historyWriteFailed
        case .historyMigrated: return .historyMigrated(entries: .max, written: 0)
        case .notesFolderMoveStarted: return .notesFolderMoveStarted(entries: .max)
        case .notesFolderMigrated:
            return .notesFolderMigrated(
                disposition: .customPathRespected, moved: .max, leftBehind: .max,
                unverified: .max, evicted: .max
            )
        case .notesFolderLeftoverCleared: return .notesFolderLeftoverCleared
        case .corruptFileAside: return .corruptFileAside(artifact: .chatJSON)
        case .sessionImportFailed: return .sessionImportFailed
        }
    }

    /// Every case, exactly once, derived — never hand-maintained.
    private static var allSamples: [DiagEvent] { CaseKey.allCases.map(sample(for:)) }

    /// Every raw value any enum in the model can legally contribute to the JSON.
    private static let closedVocabulary: Set<String> = {
        var allowed = Set<String>()
        allowed.formUnion(DiagEvent.Outcome.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.DeviceKind.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.Permission.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.Endpoint.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.ModelKind.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.CaptureStage.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.CaptureStopReason.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.ReconfigureReason.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.EchoPath.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.PasteKind.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.PromptDisposition.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.Artifact.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.HealthTrigger.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.NotesMigration.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.SummonWithdrawal.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.OnboardingStep.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.RepairReason.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.RepairOutcome.allCases.map(\.rawValue))
        allowed.formUnion(DiagEvent.ClipboardRead.allCases.map(\.rawValue))
        allowed.formUnion(DictationItemKind.allCases.map(\.rawValue))
        allowed.formUnion(DictationState.allCases.map(\.rawValue))
        return allowed
    }()

    // MARK: - Link 2: the coverage loop closes

    func testEveryDiagEventCaseHasASample() {
        let covered = Set(Self.allSamples.map(Self.key(of:)))
        XCTAssertEqual(
            Set(CaseKey.allCases).symmetricDifference(covered), [],
            "every DiagEvent case needs a worst-case sample in sample(for:)"
        )
    }

    func testSampleForKeyReturnsThatCase() {
        for key in CaseKey.allCases {
            XCTAssertEqual(
                Self.key(of: Self.sample(for: key)), key,
                "sample(for: .\(key.rawValue)) returned a different case"
            )
        }
    }

    func testCaseKeyMatchesProductionCaseName() {
        for key in CaseKey.allCases {
            XCTAssertEqual(Self.sample(for: key).caseName, key.rawValue)
        }
    }

    // MARK: - The guarantee, strongest form

    /// The property itself: no associated value is *declared* as text. Checks the
    /// declared type, not the rendered value — `.foo("ok")` leaks even though "ok"
    /// happens to be in the closed vocabulary. Enums whose `rawValue` is a `String`
    /// are fine: their declared type is the enum, and their value set is closed.
    func testNoAssociatedValueIsAFreeFormString() {
        for event in Self.allSamples {
            let offenders = Self.freeFormTextPayloads(in: event)
            XCTAssertTrue(
                offenders.isEmpty,
                """
                \(event.caseName) declares a free-form text payload: \(offenders). \
                DiagEvent payloads must be numbers, booleans or closed enums — \
                text belongs in os.Logger with privacy: .private (design §5).
                """
            )
        }
    }

    /// Types a transcript, a device name, a file path or an API key fits into.
    private static let forbiddenPayloadTypes: [Any.Type] = [
        String.self, String?.self,
        Substring.self, Substring?.self,
        URL.self, URL?.self,
        Character.self, Character?.self,
    ]

    /// Walk a value's associated values (an enum boxes them in a tuple, hence the
    /// recursion) and report any whose declared type is textual.
    private static func freeFormTextPayloads(in value: Any) -> [String] {
        let valueType = type(of: value)
        if forbiddenPayloadTypes.contains(where: { $0 == valueType }) {
            return ["\(valueType)"]
        }
        return Mirror(reflecting: value).children.flatMap { freeFormTextPayloads(in: $0.value) }
    }

    // MARK: - Defense in depth: closed vocabulary + fixtures

    func testEveryStringValueInEncodedEventIsFromTheClosedVocabulary() throws {
        for event in Self.allSamples {
            let data = try JSONEncoder().encode(event)
            let object = try JSONSerialization.jsonObject(with: data)
            for string in Self.stringValues(object) {
                XCTAssertTrue(
                    Self.closedVocabulary.contains(string),
                    "\(event.caseName) encoded the free-form string '\(string)'"
                )
            }
        }
    }

    /// The artifact that actually uploads (#84) — not only the in-memory encode.
    func testPersistedEventsJSONCarriesOnlyClosedVocabularyAndNoFixture() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DiagPrivacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DiagStore(directory: directory)
        for event in Self.allSamples { store.record(event) }
        store.flush()

        let data = try Data(contentsOf: directory.appendingPathComponent("events.json"))
        let raw = String(decoding: data, as: UTF8.self)

        for token in Self.fixtureTokens {
            XCTAssertFalse(raw.localizedCaseInsensitiveContains(token), "events.json leaked '\(token)'")
        }

        // Every string value on disk is a closed-vocabulary raw value. The `at`
        // timestamps are ISO8601 and are excluded by reading only `event`.
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(records.count, Self.allSamples.count)
        for record in records {
            let event = try XCTUnwrap(record["event"])
            for string in Self.stringValues(event) {
                XCTAssertTrue(
                    Self.closedVocabulary.contains(string),
                    "persisted events.json carries the free-form string '\(string)'"
                )
            }
        }
    }

    func testNoEncodedEventContainsAnyFixtureSubstring() throws {
        for event in Self.allSamples {
            let json = try Self.encodedJSON(event)
            for fixture in Self.fixtures {
                XCTAssertFalse(json.contains(fixture), "\(event.caseName) leaked a fixture: \(json)")
            }
            for token in Self.fixtureTokens {
                XCTAssertFalse(
                    json.localizedCaseInsensitiveContains(token),
                    "\(event.caseName) leaked token '\(token)': \(json)"
                )
            }
        }
    }

    /// The device that reveals a name in the old log ("Sam's AirPods Pro")
    /// must collapse to a transport class and nothing more.
    func testDeviceKindCarriesNoName() throws {
        let event = DiagEvent.captureStart(
            deviceKind: DiagEvent.DeviceKind(transport: kAudioDeviceTransportTypeBluetooth),
            ms: 12
        )
        let json = try Self.encodedJSON(event)
        XCTAssertTrue(json.contains("wireless"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("AirPods"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("Sam"))
    }

    /// The classifier must agree with the recording allowlist it now sits beside (#39):
    /// a Continuity iPhone is never `.wired`, cable or no cable.
    func testDeviceKindAgreesWithRecordingAllowlist() {
        XCTAssertEqual(DiagEvent.DeviceKind(transport: kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(DiagEvent.DeviceKind(transport: kAudioDeviceTransportTypeUSB), .wired)
        XCTAssertEqual(DiagEvent.DeviceKind(transport: kAudioDeviceTransportTypeThunderbolt), .wired)
        XCTAssertEqual(DiagEvent.DeviceKind(transport: kAudioDeviceTransportTypeBluetooth), .wireless)
        XCTAssertEqual(DiagEvent.DeviceKind(transport: kAudioDeviceTransportTypeAirPlay), .wireless)
        XCTAssertEqual(
            DiagEvent.DeviceKind(transport: kAudioDeviceTransportTypeContinuityCaptureWired), .wireless,
            "Continuity over a cable is still a phantom device (#39), never .wired"
        )
        XCTAssertEqual(
            DiagEvent.DeviceKind(transport: kAudioDeviceTransportTypeContinuityCaptureWireless), .wireless
        )
        // Not on the allowlist: HDMI, aggregate and unknown transports are `.virtual`.
        XCTAssertEqual(DiagEvent.DeviceKind(transport: kAudioDeviceTransportTypeHDMI), .virtual)
        XCTAssertEqual(DiagEvent.DeviceKind(transport: kAudioDeviceTransportTypeAggregate), .virtual)
        XCTAssertEqual(DiagEvent.DeviceKind(transport: nil), .virtual)
    }

    // MARK: - Helpers

    private static func encodedJSON(_ event: DiagEvent) throws -> String {
        String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    }
}
