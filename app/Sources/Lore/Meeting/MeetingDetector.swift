import AppKit
import CoreAudio
import Foundation
import os

// Same category as MeetingDetectionController: one subsystem, one Console filter.
private let detectorLog = Logger(subsystem: "com.lore.app", category: "MeetingDetection")

// MARK: - Audio Signal Source Protocol

/// Abstraction for observing microphone activation status changes.
protocol AudioSignalSource: Sendable {
    /// Emits `true` when any physical input device becomes active, `false` when all go silent.
    var signals: AsyncStream<Bool> { get }

    /// Tear down any platform listeners and finish `signals`. Called from
    /// `MeetingDetector.stop()`. Default: no-op (mocks have nothing to remove).
    func shutdown()
}

extension AudioSignalSource {
    func shutdown() {}
}

// MARK: - CoreAudio HAL Signal Source

/// Monitors kAudioDevicePropertyDeviceIsRunningSomewhere on all physical input devices.
/// Does NOT capture audio -- only reads activation status.
final class CoreAudioSignalSource: AudioSignalSource, @unchecked Sendable {
    /// Queue choice (#64): this source keeps its own serial queue instead of routing
    /// through AudioBus's shared HAL queue — the documented exception to the one-queue
    /// rule: everything here is read-only status listening on *other* devices'
    /// IsRunningSomewhere flags, never start/stop of our own IO contexts, so it
    /// cannot form the #64 start-vs-IO-thread mutex cycle.
    ///
    /// Lifetime (#78): the source lives for one detection enable/disable cycle, not
    /// the app's lifetime. Primary teardown is `shutdown()`, called from
    /// `MeetingDetector.stop()`: it removes all listeners on listenerQueue (the block
    /// retains self, so removal completes before the object can free). Deinit's
    /// removal is only a fallback for instances that were never shut down; in the
    /// normal toggle path deinit has no listeners left to remove, so the #64
    /// invariant — no HAL call ever runs on, or sync-blocks, the main thread —
    /// holds regardless of which thread drops the last reference. In-flight
    /// notifications are NOT drained by AudioObjectRemovePropertyListener
    /// (pre-existing): a callback past takeUnretainedValue can race a
    /// last-reference release for the duration of one callback.
    private let listenerQueue = DispatchQueue(label: "com.lore.mic-listener")
    private var deviceIDs: [AudioDeviceID] = []
    private var continuation: AsyncStream<Bool>.Continuation?
    private var lastEmittedValue: Bool = false
    /// Set on listenerQueue by shutdown(); read by deinit, which can only run
    /// after the shutdown block completes (the block retains self).
    private var didShutdown = false

    let signals: AsyncStream<Bool>

    init() {
        var stream: AsyncStream<Bool>!
        var capturedContinuation: AsyncStream<Bool>.Continuation!

        stream = AsyncStream<Bool> { continuation in
            capturedContinuation = continuation
        }

        self.signals = stream

        self.continuation = capturedContinuation

        // Install listeners asynchronously: enumeration + AddPropertyListener are HAL
        // IPC and must never block the constructing (main) thread (#64 — a wedged HAL
        // at launch would freeze the app before this fix). The block retains self, so
        // setup always completes before deinit can run; deviceIDs/lastEmittedValue are
        // touched only on listenerQueue afterwards (checkAndEmit hops here too), and
        // callbacks cannot fire before their listener is installed on this same queue.
        listenerQueue.async {
            self.deviceIDs = Self.physicalInputDeviceIDs()

            for deviceID in self.deviceIDs {
                self.addRunningListener(to: deviceID)
            }

            // Watch the system device list (#75): a Bluetooth profile switch
            // (A2DP -> HFP when a meeting app grabs the AirPods mic) tears down
            // and re-creates the device under a new AudioDeviceID — a static
            // listener set installed at init goes deaf to it.
            self.addDeviceListListener()

            let described = self.deviceIDs
                .map { "\(Self.deviceName($0)) (\($0))" }
                .joined(separator: ", ")
            detectorLog.debug("signal source installed, monitoring \(self.deviceIDs.count, privacy: .public) input device(s): \(described, privacy: .private)")
        }
    }

    /// Primary teardown (#78): remove ALL listeners (system-object + per-device)
    /// on listenerQueue and finish the signals stream. The block strongly retains
    /// self, so removal completes before the object can free, and no HAL call
    /// runs on the caller's thread.
    func shutdown() {
        listenerQueue.async {
            guard !self.didShutdown else { return }
            self.didShutdown = true
            self.removeDeviceListListener()
            for deviceID in self.deviceIDs {
                self.removeRunningListener(from: deviceID)
            }
            self.deviceIDs = []
            self.continuation?.finish()
        }
    }

    deinit {
        // Fallback for instances that were never shut down (see the lifetime
        // note above): after shutdown() the guard makes this a pure Swift
        // no-op, so deinit performs no HAL IPC in the normal toggle path.
        // What IS guaranteed for the fallback: init's block retains self until
        // setup completes, and refresh/shutdown blocks retain self while
        // running, so deviceIDs is never mid-mutation when deinit reads it.
        if !didShutdown {
            removeDeviceListListener()
            for deviceID in deviceIDs {
                removeRunningListener(from: deviceID)
            }
        }
        continuation?.finish()
    }

    // MARK: - Listener Callbacks

    private static let listenerCallback: AudioObjectPropertyListenerProc = {
        _, _, _, clientData in
        guard let clientData else { return kAudioHardwareNoError }
        let source = Unmanaged<CoreAudioSignalSource>.fromOpaque(clientData).takeUnretainedValue()
        source.checkAndEmit()
        return kAudioHardwareNoError
    }

    private static let deviceListCallback: AudioObjectPropertyListenerProc = {
        _, _, _, clientData in
        guard let clientData else { return kAudioHardwareNoError }
        let source = Unmanaged<CoreAudioSignalSource>.fromOpaque(clientData).takeUnretainedValue()
        source.refreshDeviceList()
        return kAudioHardwareNoError
    }

    // MARK: - Device List Maintenance (#75)

    private func refreshDeviceList() {
        listenerQueue.async { [weak self] in
            guard let self else { return }
            // A callback dispatched before shutdown() can land behind the
            // shutdown block on this serial queue; without the guard it would
            // re-add listeners (deviceIDs is empty) on a dead instance (#78).
            guard !self.didShutdown else { return }
            let latest = Self.physicalInputDeviceIDs()
            let added = Set(latest).subtracting(self.deviceIDs)
            let removed = Set(self.deviceIDs).subtracting(latest)
            guard !added.isEmpty || !removed.isEmpty else { return }

            for deviceID in removed {
                self.removeRunningListener(from: deviceID)
            }
            for deviceID in added {
                self.addRunningListener(to: deviceID)
            }
            self.deviceIDs = latest

            let addedDesc = added.map { "\(Self.deviceName($0)) (\($0))" }.joined(separator: ", ")
            let removedDesc = removed.map(String.init).joined(separator: ", ")
            DiagStore.record(.detectionDeviceListChanged(
                added: added.count,
                removed: removed.count,
                monitored: latest.count
            ))
            detectorLog.debug("device list changed: added [\(addedDesc, privacy: .private)], removed IDs [\(removedDesc, privacy: .public)]")

            // A newly appeared device may already be running (AirPods re-created
            // in HFP mode with the mic already hot) — re-evaluate immediately.
            self.checkAndEmit()
        }
    }

    private func addRunningListener(to deviceID: AudioDeviceID) {
        var address = Self.runningSomewhereAddress
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(deviceID, &address, Self.listenerCallback, selfPtr)
        if status != kAudioHardwareNoError {
            // A silently failed add on a newly appeared device reproduces the
            // exact deafness #75 fixes — make it visible.
            DiagStore.record(.detectionListenerFailed(osStatus: status))
            detectorLog.error("add listener failed for device \(deviceID, privacy: .public), OSStatus \(status, privacy: .public)")
        }
    }

    private func removeRunningListener(from deviceID: AudioDeviceID) {
        var address = Self.runningSomewhereAddress
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(deviceID, &address, Self.listenerCallback, selfPtr)
    }

    private func addDeviceListListener() {
        var address = Self.deviceListAddress
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.deviceListCallback,
            selfPtr
        )
    }

    private func removeDeviceListListener() {
        var address = Self.deviceListAddress
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.deviceListCallback,
            selfPtr
        )
    }

    private static var runningSomewhereAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var deviceListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func checkAndEmit() {
        listenerQueue.async { [weak self] in
            guard let self else { return }
            // Same post-shutdown straggler as refreshDeviceList: don't log a
            // spurious "mic signal -> inactive" from a dead instance (#78).
            guard !self.didShutdown else { return }
            let anyRunning = self.deviceIDs.contains { Self.isDeviceRunning($0) }
            if anyRunning != self.lastEmittedValue {
                self.lastEmittedValue = anyRunning
                DiagStore.record(.detectionSignal(active: anyRunning))
                self.continuation?.yield(anyRunning)
            }
        }
    }

    // MARK: - Helpers

    private static func physicalInputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == kAudioHardwareNoError else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == kAudioHardwareNoError else { return [] }

        // Filter to devices that have input streams
        return deviceIDs.filter { deviceID in
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize)
            return status == kAudioHardwareNoError && inputSize > 0
        }
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == kAudioHardwareNoError, let name else { return "?" }
        return name.takeRetainedValue() as String
    }

    private static func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return status == kAudioHardwareNoError && isRunning != 0
    }
}

// MARK: - Meeting Detector Actor

/// Observes microphone activation and correlates with running meeting apps
/// to determine whether the user is in a meeting.
actor MeetingDetector {
    private let audioSource: any AudioSignalSource
    private let knownApps: [MeetingAppEntry]
    private let customBundleIDs: [String]
    private let selfBundleID: String
    private let knownBundleIDs: Set<String>

    /// Set to true once the debounce expires and we have confirmed detection.
    private(set) var isActive = false

    /// The meeting app that was detected, if any.
    private(set) var detectedApp: MeetingApp?

    /// Emits detection events (true = meeting detected, false = meeting ended).
    let events: AsyncStream<MeetingDetectionEvent>
    private let eventContinuation: AsyncStream<MeetingDetectionEvent>.Continuation

    private var monitorTask: Task<Void, Never>?
    private var micActiveAt: Date?

    /// Debounce duration: mic must stay active for this long before we confirm.
    private let debounceSeconds: TimeInterval = 5.0

    enum MeetingDetectionEvent: Sendable {
        case detected(MeetingApp?)
        case ended
    }

    init(
        audioSource: (any AudioSignalSource)? = nil,
        customBundleIDs: [String] = []
    ) {
        self.audioSource = audioSource ?? CoreAudioSignalSource()
        self.customBundleIDs = customBundleIDs
        self.selfBundleID = Bundle.main.bundleIdentifier ?? "com.lore.app"

        // Known meeting apps (embedded to avoid Bundle.module issues in
        // manually-constructed .app bundles)
        self.knownApps = Self.defaultMeetingApps
        self.knownBundleIDs = Set(Self.defaultMeetingApps.map(\.bundleID) + customBundleIDs)
            .subtracting([selfBundleID])

        var capturedContinuation: AsyncStream<MeetingDetectionEvent>.Continuation!
        self.events = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.eventContinuation = capturedContinuation
    }

    deinit {
        monitorTask?.cancel()
        eventContinuation.finish()
    }

    // MARK: - Lifecycle

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            for await micIsActive in self.audioSource.signals {
                guard !Task.isCancelled else { break }
                await self.handleMicSignal(micIsActive)
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        // Remove the source's HAL listeners now, on its own queue (#78) —
        // not in a deinit racing whichever thread drops the last reference.
        audioSource.shutdown()
        if isActive {
            isActive = false
            detectedApp = nil
            eventContinuation.yield(.ended)
        }
        micActiveAt = nil
        // Finish the events stream so consumers that do NOT exit via task
        // cancellation terminate deterministically (the controller's
        // detectionTask is cancelled before stop() runs; this covers any
        // other listener, e.g. in tests). A stopped detector is never
        // restarted: the controller builds a fresh one per setup() (#78).
        eventContinuation.finish()
    }

    // MARK: - Query

    /// Query the current state: is a meeting app running with active mic?
    func queryCurrentState() async -> (micActive: Bool, meetingApp: MeetingApp?) {
        let app = await scanForMeetingApp()
        let micActive = micActiveAt != nil
        return (micActive, app)
    }

    // MARK: - Signal Handling

    private func handleMicSignal(_ micIsActive: Bool) async {
        if micIsActive {
            if micActiveAt == nil {
                micActiveAt = Date()
                detectorLog.debug("mic active, debouncing \(self.debounceSeconds, privacy: .public)s")
            }

            // Wait for debounce period
            let activeSince = micActiveAt!
            try? await Task.sleep(for: .seconds(debounceSeconds))
            guard !Task.isCancelled else { return }

            // Verify mic is still considered active (debounce passed)
            guard micActiveAt == activeSince else { return }

            // Scan for meeting app
            let app = await scanForMeetingApp()
            DiagStore.record(.detectionAppScan(found: app != nil))
            detectorLog.debug("debounce confirmed, app scan: \(app.map { "\($0.name) (\($0.bundleID))" } ?? "no meeting app found", privacy: .private)")

            if !isActive {
                isActive = true
                detectedApp = app
                eventContinuation.yield(.detected(app))
            }
        } else {
            micActiveAt = nil
            if isActive {
                isActive = false
                detectedApp = nil
                detectorLog.debug("mic inactive, detection ended")
                eventContinuation.yield(.ended)
            }
        }
    }

    // MARK: - Process Scanning

    private func scanForMeetingApp() async -> MeetingApp? {
        let runningApps = await MainActor.run {
            NSWorkspace.shared.runningApplications
        }

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            if knownBundleIDs.contains(bundleID) {
                let name = app.localizedName
                    ?? knownApps.first(where: { $0.bundleID == bundleID })?.displayName
                    ?? bundleID
                return MeetingApp(bundleID: bundleID, name: name)
            }
        }
        return nil
    }

    // MARK: - Default Meeting Apps

    static var bundledMeetingApps: [MeetingAppEntry] {
        defaultMeetingApps
    }

    private static let defaultMeetingApps: [MeetingAppEntry] = [
        MeetingAppEntry(bundleID: "us.zoom.xos", displayName: "Zoom"),
        MeetingAppEntry(bundleID: "com.microsoft.teams", displayName: "Microsoft Teams (classic)"),
        MeetingAppEntry(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams"),
        MeetingAppEntry(bundleID: "com.apple.FaceTime", displayName: "FaceTime"),
        MeetingAppEntry(bundleID: "com.cisco.webexmeetingsapp", displayName: "Webex"),
        MeetingAppEntry(bundleID: "app.tuple.app", displayName: "Tuple"),
        MeetingAppEntry(bundleID: "co.around.Around", displayName: "Around"),
        MeetingAppEntry(bundleID: "com.slack.Slack", displayName: "Slack"),
        MeetingAppEntry(bundleID: "com.hnc.Discord", displayName: "Discord"),
        MeetingAppEntry(bundleID: "net.whatsapp.WhatsApp", displayName: "WhatsApp"),
        MeetingAppEntry(bundleID: "com.google.Chrome.app.kjgfgldnnfobanmcafgkdilakhehfkbm", displayName: "Google Meet (PWA)"),
    ]
}
