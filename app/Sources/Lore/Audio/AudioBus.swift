@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import os

private let busLog = Logger(subsystem: "com.lore", category: "AudioBus")

/// Persistent shared audio bus that captures microphone input via a CoreAudio HAL IOProc.
/// Consumers subscribe/unsubscribe to receive PCM buffers without touching the HAL.
/// Capture starts on first subscribe and stays running for the lifetime of the process.
///
/// The public API is preserved across the AVAudioEngine → HAL IOProc rewrite (see D-029).
final class AudioBus: @unchecked Sendable {
    typealias ConsumerID = UUID

    // MARK: - HAL State (halQueue only)

    /// All HAL calls (Start/Stop/Create/Destroy IOProc, property listener install/remove) run on this
    /// serial queue. The IOProc callback block is also dispatched here (by AudioToolbox).
    /// HAL calls are synchronous IPC to coreaudiod and can block for seconds after wake-from-sleep
    /// — never call them from main or any other queue.
    private let halQueue = DispatchQueue(label: "com.lore.audio-bus.hal", qos: .userInitiated)

    /// Property listener callbacks are delivered here and bounce onto halQueue.
    private let listenerQueue = DispatchQueue(label: "com.lore.audio-bus.listener", qos: .userInitiated)

    private var ioProcID: AudioDeviceIOProcID?
    private var currentDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var currentFormat: AVAudioFormat?

    /// Re-entry guard for reconfigureLocked(). halQueue is serial so this is just belt-and-braces
    /// against a reconfigure triggering another reconfigure synchronously inside the same call.
    private var isReconfiguring = false

    /// Whether a stream-format listener is currently installed on `currentDeviceID`.
    private var formatListenerDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)

    /// Retry tracking for a failed start. Bounded at 3 attempts before giving up loudly.
    private var startRetryAttempt = 0
    private static let maxStartRetries = 3
    private var pendingRetryItem: DispatchWorkItem?

    /// Consumer continuations. The IOProc callback reads a snapshot under the unfair lock.
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

    /// Returns true if capture is running AND a frame was received within the last 5 seconds.
    var isEngineAlive: Bool {
        guard _running.value else { return false }
        guard let lastFrame = _lastFrameTime.value else { return false }
        return Date().timeIntervalSince(lastFrame) < 5.0
    }

    // MARK: - Health Timer

    private var healthTimer: DispatchSourceTimer?

    // MARK: - Init

    init() {}

    deinit {
        healthTimer?.cancel()
        pendingRetryItem?.cancel()
        // We cannot safely dispatch to halQueue from deinit (queue may outlive us); trust the
        // process exiting for the final teardown. IOProc/device handles are released by the OS.
    }

    // MARK: - Public API

    /// Subscribe to the audio bus. Returns a consumer ID and an AsyncStream of PCM buffers.
    /// If capture isn't running yet, starts it on the HAL queue.
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

        // Start capture or switch device — decision happens on halQueue to avoid TOCTOU.
        let requestedDevice = deviceID
        halQueue.async { [weak self] in
            guard let self else { return }
            if !self._running.value {
                self.startCaptureLocked(deviceID: requestedDevice)
            } else if let requestedDevice, requestedDevice > 0, requestedDevice != self.currentDeviceID {
                self.performSwitchDeviceLocked(requestedDevice)
            }
        }

        diagLog("[AUDIO-BUS] subscribe id=\(id.uuidString.prefix(8)), consumers=\(consumerCount)")
        return (id: id, stream: stream)
    }

    /// Unsubscribe from the audio bus. Capture keeps running for remaining consumers.
    /// TODO: consider stopping the IOProc when consumers become empty to free the device.
    /// Matches prior engine-stays-running behavior for now.
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

    /// Switch capture to a different input device. Consumer streams stay alive.
    /// Passing nil (or 0) resolves the current system default once and pins to it.
    func switchDevice(_ deviceID: AudioDeviceID?) {
        halQueue.async { [weak self] in
            self?.performSwitchDeviceLocked(deviceID)
        }
    }

    private var consumerCount: Int {
        consumers.withLock { $0.count }
    }

    // MARK: - Capture Lifecycle (halQueue only)

    /// Start capture on the given device (nil = resolve system default once, then pin). Called on halQueue.
    private func startCaptureLocked(deviceID: AudioDeviceID?) {
        dispatchPrecondition(condition: .onQueue(halQueue))

        // Clean up any prior IOProc and listeners.
        teardownCaptureLocked()

        // Resolve device.
        let resolved: AudioDeviceID
        if let id = deviceID, id > 0 {
            resolved = id
        } else {
            guard let def = Self.defaultInputDeviceID(), def > 0 else {
                let msg = "No default input device"
                diagLog("[AUDIO-BUS] FAIL: \(msg)")
                _error.value = msg
                scheduleStartRetryLocked(deviceID: deviceID)
                return
            }
            resolved = def
            diagLog("[AUDIO-BUS] resolved system default device once — pinned for this capture")
        }

        currentDeviceID = resolved
        diagLog("[AUDIO-BUS] start on device=\(resolved)")

        // Query stream format (input scope) and build AVAudioFormat.
        guard let format = resolveStreamFormatLocked(for: resolved) else {
            let msg = "Invalid audio format for device \(resolved)"
            diagLog("[AUDIO-BUS] FAIL: \(msg)")
            _error.value = msg
            scheduleStartRetryLocked(deviceID: deviceID)
            return
        }
        currentFormat = format

        diagLog("[AUDIO-BUS] format: sr=\(format.sampleRate) ch=\(format.channelCount) interleaved=\(format.isInterleaved)")

        // Create IOProc. The block is invoked by AudioToolbox on halQueue.
        var newIOProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &newIOProcID,
            resolved,
            halQueue
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handleInputData(inInputData)
        }
        guard status == noErr, let newIOProcID else {
            let msg = "AudioDeviceCreateIOProcIDWithBlock failed (OSStatus \(status))"
            diagLog("[AUDIO-BUS] FAIL: \(msg)")
            _error.value = msg
            scheduleStartRetryLocked(deviceID: deviceID)
            return
        }
        ioProcID = newIOProcID

        // Install the format listener before starting the device so we don't miss transitions.
        // No default-device listener: the device is pinned for the whole capture (#39) —
        // mid-capture system-default changes must not switch the device.
        installFormatListenerLocked(for: resolved)

        // Start the device.
        let startStatus = AudioDeviceStart(resolved, newIOProcID)
        guard startStatus == noErr else {
            let msg = "AudioDeviceStart failed (OSStatus \(startStatus))"
            diagLog("[AUDIO-BUS] FAIL: \(msg)")
            _error.value = msg
            // Clean up the IOProc we just created before retrying.
            _ = AudioDeviceDestroyIOProcID(resolved, newIOProcID)
            ioProcID = nil
            removeFormatListenerLocked()
            scheduleStartRetryLocked(deviceID: deviceID)
            return
        }

        // Success.
        _running.value = true
        _error.value = nil
        startRetryAttempt = 0
        diagLog("[AUDIO-BUS] capture started on device=\(resolved)")
    }

    /// Stop + destroy current IOProc and detach listeners. Called on halQueue.
    /// Does NOT clear device state or format — caller is responsible for what happens next.
    private func stopCaptureLocked() {
        dispatchPrecondition(condition: .onQueue(halQueue))

        if let procID = ioProcID, currentDeviceID != AudioDeviceID(kAudioObjectUnknown) {
            _ = AudioDeviceStop(currentDeviceID, procID)
            _ = AudioDeviceDestroyIOProcID(currentDeviceID, procID)
        }
        ioProcID = nil
        removeFormatListenerLocked()
    }

    /// Full teardown for restart — stops capture, removes listeners, resets observable state.
    private func teardownCaptureLocked() {
        dispatchPrecondition(condition: .onQueue(halQueue))

        stopCaptureLocked()

        _running.value = false
        _audioLevel.value = 0
        _hasCapturedFrames.value = false
        _hasSignal.value = false
        _lastFrameTime.value = nil
    }

    /// Reconfigure capture in response to a route / format change.
    /// Settles 300ms for hardware transitions before rebuilding the IOProc.
    private func reconfigureLocked() {
        dispatchPrecondition(condition: .onQueue(halQueue))

        guard !isReconfiguring else {
            diagLog("[AUDIO-BUS] reconfigure already in progress, skipping")
            return
        }
        isReconfiguring = true
        defer { isReconfiguring = false }

        diagLog("[AUDIO-BUS] reconfigure begin (device=\(currentDeviceID))")

        // 1-4. Stop + destroy old IOProc, remove format listener.
        stopCaptureLocked()

        // 5. Settle 300ms for hardware to quiesce after a route change.
        //    This is documented as critical for Bluetooth A2DP <-> SCO transitions.
        usleep(300_000)

        // 6-8. Rebuild IOProc on the same device and restart. Never re-resolve —
        //      the device chosen at capture start stays pinned (#39).
        startCaptureLocked(deviceID: currentDeviceID)

        diagLog("[AUDIO-BUS] reconfigure end (running=\(_running.value))")
    }

    private func performSwitchDeviceLocked(_ deviceID: AudioDeviceID?) {
        dispatchPrecondition(condition: .onQueue(halQueue))

        diagLog("[AUDIO-BUS] switching device to \(String(describing: deviceID))")

        // Intentional device change — reset retry state.
        startRetryAttempt = 0
        pendingRetryItem?.cancel()
        pendingRetryItem = nil

        teardownCaptureLocked()
        startCaptureLocked(deviceID: deviceID)

        diagLog("[AUDIO-BUS] device switch complete (running=\(_running.value))")
    }

    /// Bounded retry with backoff: 1s, 2s, 3s. After maxStartRetries, give up loudly.
    private func scheduleStartRetryLocked(deviceID: AudioDeviceID?) {
        dispatchPrecondition(condition: .onQueue(halQueue))

        pendingRetryItem?.cancel()
        pendingRetryItem = nil

        guard startRetryAttempt < Self.maxStartRetries else {
            let msg = "Audio capture failed after \(Self.maxStartRetries) attempts"
            diagLog("[AUDIO-BUS] \(msg) — giving up")
            _error.value = msg
            return
        }

        startRetryAttempt += 1
        let delay = Double(startRetryAttempt) // 1s, 2s, 3s
        diagLog("[AUDIO-BUS] retry start in \(delay)s (attempt \(startRetryAttempt)/\(Self.maxStartRetries))")

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.startCaptureLocked(deviceID: deviceID)
        }
        pendingRetryItem = item
        halQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Format Resolution

    /// Query `kAudioDevicePropertyStreamFormat` in input scope. Build an AVAudioFormat.
    /// Falls back to `standardFormatWithSampleRate:channels:` using the nominal sample rate.
    private func resolveStreamFormatLocked(for deviceID: AudioDeviceID) -> AVAudioFormat? {
        dispatchPrecondition(condition: .onQueue(halQueue))

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)
        if status == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 {
            if let f = AVAudioFormat(streamDescription: &asbd) {
                return f
            }
            // ASBD didn't map to a supported AVAudioFormat — fall through to standard format.
            diagLog("[AUDIO-BUS] AVAudioFormat(streamDescription:) failed, using standard format")
        } else {
            diagLog("[AUDIO-BUS] kAudioDevicePropertyStreamFormat query failed (OSStatus \(status))")
        }

        let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate
                : (Self.deviceNominalSampleRate(for: deviceID) ?? 0)
        let channels = asbd.mChannelsPerFrame > 0 ? UInt32(asbd.mChannelsPerFrame) : 1
        guard rate > 0, channels > 0 else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))
    }

    // MARK: - Property Listeners

    /// Listener block for `kAudioDevicePropertyStreamFormat` on the current device.
    /// Fires on listenerQueue, hops onto halQueue for reconfigure. halQueue is serial, so
    /// queued reconfigures run in order; the 300ms settle inside reconfigureLocked() is the
    /// real route-change shock absorber.
    private lazy var formatListenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        diagLog("[AUDIO-BUS] stream format changed")
        self.halQueue.async { [weak self] in
            self?.reconfigureLocked()
        }
    }

    private func installFormatListenerLocked(for deviceID: AudioDeviceID) {
        dispatchPrecondition(condition: .onQueue(halQueue))
        removeFormatListenerLocked()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            listenerQueue,
            formatListenerBlock
        )
        if status == noErr {
            formatListenerDeviceID = deviceID
        } else {
            diagLog("[AUDIO-BUS] install format listener failed (OSStatus \(status))")
        }
    }

    private func removeFormatListenerLocked() {
        dispatchPrecondition(condition: .onQueue(halQueue))
        guard formatListenerDeviceID != AudioDeviceID(kAudioObjectUnknown) else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(
            formatListenerDeviceID,
            &address,
            listenerQueue,
            formatListenerBlock
        )
        formatListenerDeviceID = AudioDeviceID(kAudioObjectUnknown)
    }

    // MARK: - IOProc Callback

    /// Invoked by AudioToolbox on halQueue. Builds an AVAudioPCMBuffer, updates observable
    /// state, and fans out to consumers.
    private func handleInputData(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let format = currentFormat else { return }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let streamDescription = format.streamDescription
        let bytesPerFrame = Int(streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, let firstBuffer = sourceBuffers.first else { return }

        let frameCount = AVAudioFrameCount(Int(firstBuffer.mDataByteSize) / bytesPerFrame)
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        pcmBuffer.frameLength = frameCount

        let destBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        guard destBuffers.count == sourceBuffers.count else { return }

        for index in 0..<sourceBuffers.count {
            let src = sourceBuffers[index]
            let copySize = min(
                Int(src.mDataByteSize),
                Int(destBuffers[index].mDataByteSize)
            )
            guard copySize > 0,
                  let sourceData = src.mData,
                  let destinationData = destBuffers[index].mData
            else {
                continue
            }
            memcpy(destinationData, sourceData, copySize)
            destBuffers[index].mDataByteSize = UInt32(copySize)
        }

        let rms = Self.normalizedRMS(from: pcmBuffer)

        _lastFrameTime.value = Date()
        _hasCapturedFrames.value = true
        _hasSignal.value = rms > 1e-6
        _audioLevel.value = min(rms * 25, 1.0)

        // Fan-out to consumers. Snapshot under the unfair lock so we don't hold it during yield().
        if !_muted.value {
            let snapshot = consumers.withLock { Array($0.values) }
            for continuation in snapshot {
                continuation.yield(pcmBuffer)
            }
        }
    }

    // MARK: - Health Monitoring

    private func startHealthMonitor() {
        healthTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: halQueue)
        timer.schedule(deadline: .now() + 10, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.checkHealthLocked()
        }
        timer.resume()
        healthTimer = timer
    }

    private func checkHealthLocked() {
        dispatchPrecondition(condition: .onQueue(halQueue))

        guard _running.value else { return }

        // If we've received frames and the last one is older than 5s, reconfigure.
        if let lastFrame = _lastFrameTime.value, Date().timeIntervalSince(lastFrame) > 5.0 {
            diagLog("[AUDIO-BUS-HEALTH] silent for >5s, reconfiguring")
            reconfigureLocked()
            return
        }

        // Otherwise — we're either producing frames or still warming up. Do nothing.
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

    /// Transports allowed for recording: built-in and wired. Anything else (Bluetooth,
    /// Continuity/iPhone, AirPlay, virtual) is wireless or unreliable and gets redirected.
    /// Allowlist, not Bluetooth-blocklist, so Continuity devices cannot slip through (#39).
    private static let allowedTransports: Set<UInt32> = [
        kAudioDeviceTransportTypeBuiltIn,
        kAudioDeviceTransportTypeUSB,
        kAudioDeviceTransportTypeThunderbolt,
        kAudioDeviceTransportTypeFireWire,
        kAudioDeviceTransportTypePCI,
    ]

    /// Canonical UID of the real built-in microphone. Continuity phantoms have been observed
    /// reporting the built-in transport type, so transport alone is not trustworthy (#39).
    private static let builtInMicrophoneUID = "BuiltInMicrophoneDevice"

    /// Pick the input device for a recording. Called once at recording start; the result is
    /// pinned for the whole recording (#39). Enumerates devices fresh on every call — never
    /// trusts a cached AudioDeviceID (IDs are not stable across sessions).
    ///
    /// Rule: if the requested device (or, failing that, the system default) is built-in or
    /// wired, use it. Otherwise use the built-in mic; if none exists (Mac mini), the first
    /// wired input; else keep the candidate. Returns nil when no input devices are present.
    static func resolveBestInputDevice(requested: AudioDeviceID) -> (deviceID: AudioDeviceID, redirectedToBuiltIn: Bool)? {
        let available = availableInputDevices()
        guard !available.isEmpty else {
            diagLog("[AUDIO-BUS] select input: no input devices available")
            return nil
        }

        func isAllowed(_ id: AudioDeviceID) -> Bool {
            guard let transport = transportType(for: id) else { return false }
            guard allowedTransports.contains(transport) else { return false }
            // BuiltIn transport is not enough — Continuity phantoms report it too (#39).
            // Require the canonical built-in mic UID; anything else falls through to
            // builtInInputDevice(in:), which picks the real built-in mic.
            if transport == kAudioDeviceTransportTypeBuiltIn {
                return deviceUID(for: id) == builtInMicrophoneUID
            }
            return true
        }
        func name(_ id: AudioDeviceID) -> String {
            available.first(where: { $0.id == id })?.name ?? "unknown"
        }

        // Candidate: explicit selection if it still exists, else the current system default.
        var candidate: AudioDeviceID = 0
        if requested > 0, available.contains(where: { $0.id == requested }) {
            candidate = requested
        } else if let def = defaultInputDeviceID(), available.contains(where: { $0.id == def }) {
            candidate = def
        }

        if candidate > 0, isAllowed(candidate) {
            diagLog("[AUDIO-BUS] selected input device=\(candidate) (\(name(candidate)))")
            return (candidate, false)
        }

        // Candidate is wireless (or unresolvable) — redirect per the allowlist.
        if let builtIn = builtInInputDevice(in: available) {
            // Report the redirect (drives the "wireless mic compresses audio" UI hint) only
            // when the candidate's transport was readable and actually disallowed — not when
            // the transport was unreadable or the device merely failed the built-in UID check.
            let candidateTransport = candidate > 0 ? transportType(for: candidate) : nil
            let redirectedFromWireless = candidateTransport.map { !allowedTransports.contains($0) } ?? false
            diagLog("[AUDIO-BUS] wireless/unavailable input (\(candidate > 0 ? name(candidate) : "none")), selected built-in device=\(builtIn) (\(name(builtIn)))")
            return (builtIn, redirectedFromWireless)
        }
        if let wired = available.first(where: { isAllowed($0.id) }) {
            diagLog("[AUDIO-BUS] no built-in mic, selected wired device=\(wired.id) (\(wired.name))")
            return (wired.id, false)
        }
        guard candidate > 0 else {
            diagLog("[AUDIO-BUS] select input: no usable input device")
            return nil
        }
        diagLog("[AUDIO-BUS] no built-in or wired mic, keeping device=\(candidate) (\(name(candidate)))")
        return (candidate, false)
    }

    /// The real built-in microphone, disambiguated by UID: Continuity iPhone mics have been
    /// observed reporting the built-in transport type with session-unstable device IDs, so
    /// transport alone is not trustworthy (#39 — phantom device 146/114 vs real built-in 102).
    private static func builtInInputDevice(in available: [(id: AudioDeviceID, name: String)]) -> AudioDeviceID? {
        let candidates = available.filter {
            transportType(for: $0.id) == kAudioDeviceTransportTypeBuiltIn
        }
        if let canonical = candidates.first(where: { deviceUID(for: $0.id) == builtInMicrophoneUID }) {
            return canonical.id
        }
        return candidates.first?.id
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
