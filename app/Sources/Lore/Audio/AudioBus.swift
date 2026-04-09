@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import ObjCExceptionCatcher
import os

private let busLog = Logger(subsystem: "com.lore", category: "AudioBus")

/// Persistent shared audio bus that owns a single AVAudioEngine.
/// Consumers subscribe/unsubscribe to receive PCM buffers without touching the engine.
/// The engine starts on first subscribe and stays running for the lifetime of the process.
final class AudioBus: @unchecked Sendable {
    typealias ConsumerID = UUID

    // MARK: - Engine State

    private var engine: AVAudioEngine?
    private var hasTapInstalled = false

    /// All engine operations happen on this serial queue — never main thread.
    private let engineQueue = DispatchQueue(label: "com.lore.audio-bus", qos: .userInitiated)

    /// Consumer continuations. The tap callback reads a snapshot under the unfair lock.
    /// OSAllocatedUnfairLock is real-time safe on Darwin (no priority inversion).
    private let consumers = OSAllocatedUnfairLock<[UUID: AsyncStream<AVAudioPCMBuffer>.Continuation]>(
        uncheckedState: [:]
    )

    // MARK: - Observable State (thread-safe)

    private let _audioLevel = AudioLevel()
    private let _muted = SyncBool()
    private let _running = SyncBool()
    private let _lastFrameTime = SyncOptionalDate()
    private let _hasCapturedFrames = SyncBool()
    private let _hasSignal = SyncBool()
    private let _error = SyncString()

    var audioLevel: Float { _muted.value ? 0 : _audioLevel.value }
    var isRunning: Bool { _running.value }
    var captureError: String? { _error.value }
    var hasCapturedFrames: Bool { _hasCapturedFrames.value }
    var hasSignal: Bool { _hasSignal.value }

    var isMuted: Bool {
        get { _muted.value }
        set { _muted.value = newValue }
    }

    /// Returns true if the engine is running AND a frame was received within the last 5 seconds.
    var isEngineAlive: Bool {
        guard _running.value else { return false }
        guard let lastFrame = _lastFrameTime.value else { return false }
        return Date().timeIntervalSince(lastFrame) < 5.0
    }

    // MARK: - Config Change Observer

    private var configChangeObserver: NSObjectProtocol?
    private var healthTimer: DispatchSourceTimer?
    private var currentDeviceID: AudioDeviceID?
    private var usesSystemDefault = true

    // MARK: - Init

    init() {}

    deinit {
        healthTimer?.cancel()
        removeConfigChangeObserver()
    }

    // MARK: - Public API

    /// Subscribe to the audio bus. Returns a consumer ID and an AsyncStream of PCM buffers.
    /// If no engine is running, starts one on the engine queue.
    func subscribe(deviceID: AudioDeviceID?) -> (id: ConsumerID, stream: AsyncStream<AVAudioPCMBuffer>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .unbounded
        )

        let isFirstConsumer = consumers.withLock { state -> Bool in
            let wasEmpty = state.isEmpty
            state[id] = continuation
            return wasEmpty
        }

        if isFirstConsumer {
            startHealthMonitor()
        }

        // Start engine or switch device — decision happens on engineQueue to avoid TOCTOU
        let requestedDevice = deviceID
        engineQueue.async { [weak self] in
            guard let self else { return }
            if !self._running.value {
                self.startEngine(deviceID: requestedDevice)
            } else if let requestedDevice, requestedDevice > 0, requestedDevice != self.currentDeviceID {
                self.performSwitchDevice(requestedDevice)
            }
        }

        diagLog("[AUDIO-BUS] subscribe id=\(id.uuidString.prefix(8)), consumers=\(consumerCount)")
        return (id: id, stream: stream)
    }

    /// Unsubscribe from the audio bus. Engine stays running.
    func unsubscribe(_ id: ConsumerID) {
        let (continuation, isEmpty) = consumers.withLock { state -> (AsyncStream<AVAudioPCMBuffer>.Continuation?, Bool) in
            let c = state.removeValue(forKey: id)
            return (c, state.isEmpty)
        }
        continuation?.finish()
        if isEmpty {
            healthTimer?.cancel()
            healthTimer = nil
        }
        diagLog("[AUDIO-BUS] unsubscribe id=\(id.uuidString.prefix(8)), consumers=\(consumerCount)")
    }

    /// Switch the engine to a different input device. Consumer streams stay alive.
    func switchDevice(_ deviceID: AudioDeviceID?) {
        engineQueue.async { [weak self] in
            self?.performSwitchDevice(deviceID)
        }
    }

    private var consumerCount: Int {
        consumers.withLock { $0.count }
    }

    // MARK: - Engine Lifecycle (engineQueue only)

    private func startEngine(deviceID: AudioDeviceID?) {
        dispatchPrecondition(condition: .onQueue(engineQueue))

        // Clean up any prior engine
        teardownEngine()

        let newEngine = AVAudioEngine()
        self.engine = newEngine

        diagLog("[AUDIO-BUS] engine created")

        let inputNode = newEngine.inputNode
        diagLog("[AUDIO-BUS] input node ready")

        // Set input device
        if let id = deviceID, id > 0 {
            if let audioUnit = inputNode.audioUnit {
                var devID = id
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                diagLog("[AUDIO-BUS] setInputDevice status=\(status) (0=ok)")
            }
            currentDeviceID = id
            usesSystemDefault = false
        } else {
            currentDeviceID = Self.defaultInputDeviceID()
            usesSystemDefault = true
            diagLog("[AUDIO-BUS] using system default device")
        }

        guard let tapFormat = resolveFormat(for: inputNode) else {
            let msg = "Invalid audio format"
            diagLog("[AUDIO-BUS] FAIL: \(msg)")
            _error.value = msg
            return
        }

        guard installTap(on: inputNode, format: tapFormat) else {
            let msg = "Failed to install audio tap"
            diagLog("[AUDIO-BUS] FAIL: \(msg)")
            _error.value = msg
            return
        }
        // Register observer before start() so no config change can be lost during startup.
        installConfigChangeObserver(for: newEngine)

        diagLog("[AUDIO-BUS] tap installed, starting engine...")

        do {
            try newEngine.start()
            _running.value = true
            _error.value = nil
            configChangeRestartFailures = 0
            lastEngineStartTime = .now()
            diagLog("[AUDIO-BUS] engine started, isRunning=\(newEngine.isRunning)")
        } catch {
            let msg = "Audio engine failed: \(error.localizedDescription)"
            diagLog("[AUDIO-BUS] FAIL: \(msg)")
            _error.value = msg
            _running.value = false
            hasTapInstalled = false
        }
    }

    private func performSwitchDevice(_ deviceID: AudioDeviceID?) {
        dispatchPrecondition(condition: .onQueue(engineQueue))

        diagLog("[AUDIO-BUS] switching device to \(String(describing: deviceID))")

        // Tear down old engine, start new one. Consumer continuations stay alive.
        // Reset failure counter — device switch is intentional, not a config-change cascade.
        configChangeRestartFailures = 0
        configChangeScheduled = false
        teardownEngine()
        startEngine(deviceID: deviceID)

        diagLog("[AUDIO-BUS] device switch complete")
    }

    private func resolveFormat(for inputNode: AVAudioInputNode) -> AVAudioFormat? {
        let format = inputNode.outputFormat(forBus: 0)

        var sampleRate = format.sampleRate
        if let devID = currentDeviceID,
           let hwRate = Self.deviceNominalSampleRate(for: devID),
           hwRate > 0, hwRate != sampleRate {
            diagLog("[AUDIO-BUS] hardware sr=\(hwRate) differs from inputNode sr=\(sampleRate), using hardware rate")
            sampleRate = hwRate
        }

        diagLog("[AUDIO-BUS] format: sr=\(format.sampleRate) ch=\(format.channelCount), effective sr=\(sampleRate)")

        guard sampleRate > 0 && format.channelCount > 0 else { return nil }

        if let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: format.channelCount) {
            return f
        } else if sampleRate != format.sampleRate,
                  let f = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount) {
            diagLog("[AUDIO-BUS] hardware-rate format failed, using node rate \(format.sampleRate)")
            return f
        } else {
            diagLog("[AUDIO-BUS] standard formats failed, using native input format")
            return format
        }
    }

    /// Returns true if the tap was installed successfully.
    @discardableResult
    private func installTap(on inputNode: AVAudioInputNode, format: AVAudioFormat) -> Bool {
        // Defensive: remove any existing tap before installing. No-op when no tap exists.
        inputNode.removeTap(onBus: 0)

        let level = _audioLevel
        let muted = _muted
        let hasCaptured = _hasCapturedFrames
        let hasSignal = _hasSignal
        let lastFrame = _lastFrameTime
        let consumersRef = consumers
        var tapCallCount = 0

        // AVAudioNode.installTap throws an ObjC NSException (not a Swift error) when the
        // node is in a transient state — e.g., during Bluetooth device transitions.
        // Swift cannot catch NSException, so we use an ObjC @try/@catch wrapper.
        var exceptionMessage: NSString?
        let ok = LRECatchException({
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                tapCallCount += 1
                hasCaptured.value = true
                lastFrame.value = Date()

                let rms = Self.normalizedRMS(from: buffer)
                level.value = min(rms * 25, 1.0)
                hasSignal.value = rms > 1e-6

                if tapCallCount <= 5 || tapCallCount % 100 == 0 {
                    diagLog("[AUDIO-BUS] tap #\(tapCallCount): frames=\(buffer.frameLength) rms=\(rms)")
                }

                guard !muted.value else { return }

                let snapshot = consumersRef.withLock { Array($0.values) }
                for continuation in snapshot {
                    continuation.yield(buffer)
                }
            }
        }, &exceptionMessage)

        if ok {
            hasTapInstalled = true
            return true
        } else {
            diagLog("[AUDIO-BUS] installTap threw ObjC exception: \(exceptionMessage ?? "unknown")")
            hasTapInstalled = false
            return false
        }
    }

    private func teardownEngine() {
        dispatchPrecondition(condition: .onQueue(engineQueue))

        removeConfigChangeObserver()
        if hasTapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
            hasTapInstalled = false
        }
        engine?.stop()
        engine?.reset()
        engine = nil
        _running.value = false
        _audioLevel.value = 0
        _hasCapturedFrames.value = false
        _hasSignal.value = false
        _lastFrameTime.value = nil
    }

    // MARK: - Health Monitoring

    private func startHealthMonitor() {
        healthTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now() + 10, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.checkHealth()
        }
        timer.resume()
        healthTimer = timer
    }

    private func checkHealth() {
        dispatchPrecondition(condition: .onQueue(engineQueue))

        guard _running.value else { return }

        // If engine reports running but no frames in 5 seconds, restart
        guard let engine, engine.isRunning else {
            diagLog("[AUDIO-BUS-HEALTH] engine not running, restarting")
            configChangeRestartFailures = 0
            let device = currentDeviceID
            teardownEngine()
            startEngine(deviceID: device)
            return
        }

        if let lastFrame = _lastFrameTime.value, Date().timeIntervalSince(lastFrame) > 5.0 {
            diagLog("[AUDIO-BUS-HEALTH] silent for >5s, restarting engine")
            configChangeRestartFailures = 0
            let device = currentDeviceID
            teardownEngine()
            startEngine(deviceID: device)
        } else if _lastFrameTime.value == nil && _hasCapturedFrames.value == false {
            // Engine started but never produced frames — give it time on first check
            return
        }
    }

    // MARK: - Config Change Observer

    /// Consecutive restart failures since last successful engine start.
    private var configChangeRestartFailures = 0
    private static let maxConfigChangeRestarts = 3
    /// Debounce: when set, a restart is already scheduled on engineQueue.
    private var configChangeScheduled = false
    /// Timestamp of last successful engine start — config changes within the cooldown are startup transients.
    private var lastEngineStartTime: DispatchTime = DispatchTime(uptimeNanoseconds: 0)

    private func installConfigChangeObserver(for engine: AVAudioEngine) {
        removeConfigChangeObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.engineQueue.async {
                guard self.engine != nil else { return }
                guard !self.configChangeScheduled else {
                    diagLog("[AUDIO-BUS] config change coalesced (restart already pending)")
                    return
                }
                self.configChangeScheduled = true
                // Debounce: wait 300ms for cascading notifications to settle
                self.engineQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.handleConfigChange()
                }
            }
        }
    }

    private func handleConfigChange() {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        configChangeScheduled = false

        // Suppress startup transients: engine.start() and tap installation fire spurious
        // config change notifications. If the engine just started and is running, ignore.
        // Real device failures within the cooldown window are caught by the health monitor.
        let nsSinceStart = DispatchTime.now().uptimeNanoseconds - lastEngineStartTime.uptimeNanoseconds
        if nsSinceStart < 1_500_000_000, _running.value {
            diagLog("[AUDIO-BUS] config change \(nsSinceStart / 1_000_000)ms after start, ignoring (startup transient)")
            return
        }

        guard configChangeRestartFailures < Self.maxConfigChangeRestarts else {
            let msg = "Audio engine failed after \(Self.maxConfigChangeRestarts) restart attempts"
            diagLog("[AUDIO-BUS] \(msg) — giving up")
            teardownEngine()
            _error.value = msg
            return
        }

        guard engine != nil else {
            diagLog("[AUDIO-BUS] config change but engine is nil, ignoring")
            return
        }

        diagLog("[AUDIO-BUS] AVAudioEngineConfigurationChange, restarting (attempt \(configChangeRestartFailures + 1))")

        // Full teardown + fresh engine. The previous approach (engine.reset() + reinstall tap)
        // crashed because the input node can be in a transient state during Bluetooth transitions,
        // causing installTap(onBus:) to throw an unrecoverable ObjC NSException.
        // The debounce mechanism (configChangeScheduled + 300ms delay) prevents cascading.
        let device = usesSystemDefault ? nil : currentDeviceID
        teardownEngine()
        startEngine(deviceID: device)

        if _running.value {
            configChangeRestartFailures = 0
        } else {
            configChangeRestartFailures += 1
            if configChangeRestartFailures >= Self.maxConfigChangeRestarts {
                let msg = "Audio engine failed after \(Self.maxConfigChangeRestarts) restart attempts"
                diagLog("[AUDIO-BUS] \(msg)")
                _error.value = msg
            }
        }
    }

    private func removeConfigChangeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    // MARK: - RMS Calculation

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            if channelCount == 1 || buffer.format.isInterleaved {
                let totalSamples = buffer.format.isInterleaved ? frameLength * channelCount : frameLength
                var rms: Float = 0
                vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(totalSamples))
                return rms
            } else {
                var totalRMS: Float = 0
                for ch in 0..<channelCount {
                    var chRMS: Float = 0
                    vDSP_rmsqv(channelData[ch], 1, &chRMS, vDSP_Length(frameLength))
                    totalRMS += chRMS * chRMS
                }
                return sqrt(totalRMS / Float(channelCount))
            }
        }

        if let channelData = buffer.int16ChannelData {
            var floats = [Float](repeating: 0, count: frameLength)
            vDSP_vflt16(channelData[0], 1, &floats, 1, vDSP_Length(frameLength))
            var scale: Float = 1 / Float(Int16.max)
            vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(frameLength))
            var rms: Float = 0
            vDSP_rmsqv(floats, 1, &rms, vDSP_Length(frameLength))
            return rms
        }

        if let channelData = buffer.int32ChannelData {
            let scale: Float = 1 / Float(Int32.max)
            var floats = [Float](repeating: 0, count: frameLength)
            for i in 0..<frameLength { floats[i] = Float(channelData[0][i]) * scale }
            var rms: Float = 0
            vDSP_rmsqv(floats, 1, &rms, vDSP_Length(frameLength))
            return rms
        }

        return 0
    }

    // MARK: - Static Device Utilities

    static func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [(id: AudioDeviceID, name: String)] = []

        for deviceID in deviceIDs {
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var bufferListSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &bufferListSize)
            guard status == noErr, bufferListSize > 0 else { continue }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            status = AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &bufferListSize, bufferListPtr)
            guard status == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
            guard status == noErr, let name else { continue }

            result.append((id: deviceID, name: name.takeRetainedValue() as String))
        }

        return result
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    static func deviceNominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return status == noErr ? sampleRate : nil
    }

    static func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        return status == noErr ? transportType : nil
    }

    static func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let transport = transportType(for: deviceID) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth ||
               transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func builtInInputDevice() -> AudioDeviceID? {
        let devices = availableInputDevices()
        return devices.first { transportType(for: $0.id) == kAudioDeviceTransportTypeBuiltIn }?.id
    }

    static func resolveBestInputDevice(requested: AudioDeviceID) -> (deviceID: AudioDeviceID, redirectedFromBluetooth: Bool) {
        let resolved = requested > 0 ? requested : (defaultInputDeviceID() ?? requested)
        guard resolved > 0, isBluetoothDevice(resolved) else {
            return (resolved, false)
        }
        if let builtIn = builtInInputDevice() {
            return (builtIn, true)
        }
        return (resolved, false)
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }
}
