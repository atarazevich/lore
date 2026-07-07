@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import os

private let busLog = Logger(subsystem: "com.lore", category: "AudioBus")

/// Persistent shared audio bus that captures microphone input via a CoreAudio HAL IOProc.
/// Consumers subscribe/unsubscribe to receive PCM buffers without touching the HAL.
/// Capture starts on first subscribe and stops when the last consumer unsubscribes, so
/// coreaudiod releases the device and the system mic indicator clears between recordings
/// (#30). The next subscribe cold-starts capture with a fresh device resolution.
///
/// The public API is preserved across the AVAudioEngine → HAL IOProc rewrite (see D-029).
final class AudioBus: @unchecked Sendable {
    typealias ConsumerID = UUID

    // MARK: - HAL State (halQueue only)

    /// All HAL calls (Start/Stop/Create/Destroy IOProc/tap/aggregate, property queries
    /// and listener install/remove) in the whole process serialize on this ONE queue.
    /// (Sole documented exception: CoreAudioSignalSource's read-only status listeners —
    /// see the queue-choice note there.) HAL calls are synchronous IPC to coreaudiod and
    /// can block for seconds after wake-from-sleep or while an IO context is wedged —
    /// never call them from main or any other queue. Private on purpose: external code
    /// enters only through `performHALOperation` / `onHALQueue`, which are async-only —
    /// a `sync` waiter would recreate the #64 deadlock from a different door.
    private static let sharedHALQueue = DispatchQueue(label: "com.lore.audio-bus.hal", qos: .userInitiated)

    /// Instance alias for the shared HAL queue.
    private let halQueue = AudioBus.sharedHALQueue

    /// IOProc callback delivery queue. MUST stay distinct from halQueue: CoreAudio's IO
    /// thread sync-dispatches the IOProc block onto this queue while holding the HAL IO
    /// context mutex. If HAL calls ran here (or the IOProc were delivered on halQueue),
    /// `AudioDeviceStart` on halQueue waiting for that mutex and the IO thread waiting
    /// for halQueue would deadlock — the exact triangle captured in #64. This queue does
    /// no HAL calls and never blocks.
    private let ioQueue = DispatchQueue(label: "com.lore.audio-bus.io", qos: .userInteractive)

    /// Property listener callbacks are delivered here and bounce onto halQueue.
    private let listenerQueue = DispatchQueue(label: "com.lore.audio-bus.listener", qos: .userInitiated)

    private var ioProcID: AudioDeviceIOProcID?
    private var currentDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)

    /// Current capture format. Written on halQueue at capture start, read on ioQueue by
    /// the IOProc callback — hence lock-protected rather than halQueue-confined.
    private let _currentFormat = OSAllocatedUnfairLock<AVAudioFormat?>(uncheckedState: nil)

    /// Re-entry guard for reconfigureLocked(). halQueue is serial so this is just belt-and-braces
    /// against a reconfigure triggering another reconfigure synchronously inside the same call.
    private var isReconfiguring = false

    /// Whether a stream-format listener is currently installed on `currentDeviceID`.
    private var formatListenerDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)

    /// Retry tracking for a failed start. Bounded at 3 attempts before giving up loudly.
    private var startRetryAttempt = 0
    private static let maxStartRetries = 3
    private var pendingRetryItem: DispatchWorkItem?

    /// When the current capture started (halQueue only). Drives the no-frames-ever
    /// recovery: a live IOProc delivers buffers even for digital silence, so zero
    /// callbacks after start means the IOProc is wedged (#64 precursor).
    private var captureStartDate: Date?
    private var noFrameRecoveryAttempts = 0
    private static let maxNoFrameRecoveries = 2

    /// Consumer continuations. The IOProc callback reads a snapshot under the unfair lock.
    /// OSAllocatedUnfairLock is real-time safe on Darwin (no priority inversion).
    private let consumers = OSAllocatedUnfairLock<[UUID: AsyncStream<AVAudioPCMBuffer>.Continuation]>(
        uncheckedState: [:]
    )

    // MARK: - Observable State (thread-safe)

    private let _audioLevel = AudioLevel()
    private let _running = SyncBool()
    private let _lastFrameTime = SyncOptionalDate()
    private let _hasCapturedFrames = SyncBool()
    private let _hasSignal = SyncBool()
    private let _error = SyncString()

    var audioLevel: Float { _audioLevel.value }
    var isRunning: Bool { _running.value }
    var captureError: String? { _error.value }
    var hasCapturedFrames: Bool { _hasCapturedFrames.value }
    var hasSignal: Bool { _hasSignal.value }

    // The bus deliberately has NO mute surface (#66): a bus-level mute silenced every
    // consumer at once (dictation died during a muted meeting) and survived past the
    // meeting with no UI to clear it. Muting is a consumer concern — see
    // TranscriptionEngine.isMicMuted.

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

        // Start capture or join the running one — decision happens on halQueue to avoid TOCTOU.
        let requestedDevice = deviceID
        halQueue.async { [weak self] in
            guard let self else { return }
            switch Self.subscribeDecision(captureRunning: self._running.value) {
            case .startCapture:
                self.noFrameRecoveryAttempts = 0
                self.startCaptureLocked(deviceID: requestedDevice)
            case .joinPinnedDevice:
                diagLog("[AUDIO-BUS] joining pinned device \(self.currentDeviceID) (requested \(requestedDevice.map(String.init) ?? "nil"))")
            }
        }

        diagLog("[AUDIO-BUS] subscribe id=\(id.uuidString.prefix(8)), consumers=\(consumerCount)")
        return (id: id, stream: stream)
    }

    /// Unsubscribe from the audio bus. Capture keeps running for remaining consumers;
    /// when the last consumer leaves, capture is torn down on the HAL queue so the
    /// device is freed and the system mic indicator clears (#30).
    func unsubscribe(_ id: ConsumerID) {
        let (continuation, isEmpty) = consumers.withLock { state -> (AsyncStream<AVAudioPCMBuffer>.Continuation?, Bool) in
            let c = state.removeValue(forKey: id)
            return (c, state.isEmpty)
        }
        continuation?.finish()
        if isEmpty {
            // subscribe/unsubscribe don't serialize registration against each other —
            // both callers (DictationCoordinator, TranscriptionEngine) are @MainActor;
            // don't race them from concurrent threads.
            healthTimer?.cancel()
            healthTimer = nil
            halQueue.async { [weak self] in
                guard let self else { return }
                // Re-check on the HAL queue: a subscribe may have been queued behind this
                // teardown (rapid Fn press-release). Its consumer is registered before its
                // halQueue block runs, so a non-empty set here means capture must stay up —
                // and that subscribe's own block will then correctly join the running capture.
                let stillEmpty = self.consumers.withLock { $0.isEmpty }
                guard stillEmpty else {
                    diagLog("[AUDIO-BUS] idle stop skipped — new consumer arrived")
                    return
                }
                self.stopIdleCaptureLocked()
            }
        }
        diagLog("[AUDIO-BUS] unsubscribe id=\(id.uuidString.prefix(8)), consumers=\(consumerCount)")
    }

    /// What `subscribe` does with capture, as a pure decision (#66). While capture is
    /// running, a new subscriber ALWAYS joins the currently pinned device — the requested
    /// device has no say while running (it isn't even a parameter), so a second consumer
    /// (e.g. dictation during a meeting) can never switch the meeting's pinned device
    /// mid-recording (D-030). Device switching is exclusively the explicit
    /// `switchDevice` path (Settings).
    enum SubscribeDecision: Equatable {
        case startCapture
        case joinPinnedDevice
    }

    static func subscribeDecision(captureRunning: Bool) -> SubscribeDecision {
        captureRunning ? .joinPinnedDevice : .startCapture
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
        _currentFormat.withLock { $0 = format }

        diagLog("[AUDIO-BUS] format: sr=\(format.sampleRate) ch=\(format.channelCount) interleaved=\(format.isInterleaved)")

        // Create IOProc. The block is invoked by CoreAudio's IO thread as a *synchronous*
        // dispatch onto ioQueue — never onto halQueue (see ioQueue docs, #64).
        var newIOProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &newIOProcID,
            resolved,
            ioQueue
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
        captureStartDate = Date()
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

    /// Last consumer left — free the device so the orange mic indicator clears (#30).
    /// Called on halQueue after the empty-consumers re-check; cancels pending start
    /// retries and resets the watchdog state; next subscribe cold-starts (D-030 unchanged).
    private func stopIdleCaptureLocked() {
        dispatchPrecondition(condition: .onQueue(halQueue))

        diagLog("[AUDIO-BUS] last consumer left — stopping capture (device=\(currentDeviceID))")

        pendingRetryItem?.cancel()
        pendingRetryItem = nil
        startRetryAttempt = 0
        noFrameRecoveryAttempts = 0
        captureStartDate = nil

        teardownCaptureLocked()

        currentDeviceID = AudioDeviceID(kAudioObjectUnknown)
        _currentFormat.withLock { $0 = nil }
        // Deliberately drop any persistent capture error (#30): idle stop means a fresh
        // cold start next time, so a genuinely dead mic resurfaces via the 5s dictation /
        // 10s no-frames watchdogs on the next recording instead of instantly.
        _error.value = nil
    }

    /// Reconfigure capture in response to a route / format change.
    /// Settles 300ms for hardware transitions before rebuilding the IOProc.
    private func reconfigureLocked() {
        dispatchPrecondition(condition: .onQueue(halQueue))

        // An idle teardown (#30) may have stopped capture while this reconfigure was
        // queued (stale format-listener event hopping listenerQueue → halQueue). A
        // stopped bus must stay stopped — never resurrect capture with no consumers.
        // Safe for live reconfigures: _running stays true throughout reconfigure
        // (stopCaptureLocked doesn't clear it; only teardown paths do).
        guard _running.value else {
            diagLog("[AUDIO-BUS] reconfigure skipped — capture not running")
            return
        }

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
        noFrameRecoveryAttempts = 0
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

    /// Invoked by CoreAudio (sync-dispatched from the HAL IO thread) on ioQueue. Builds an
    /// AVAudioPCMBuffer, updates observable state, and fans out to consumers.
    /// Makes NO HAL calls and never blocks — see ioQueue docs (#64).
    private func handleInputData(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let format = _currentFormat.withLock({ $0 }) else { return }

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
        let snapshot = consumers.withLock { Array($0.values) }
        for continuation in snapshot {
            continuation.yield(pcmBuffer)
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
        if let lastFrame = _lastFrameTime.value {
            if Date().timeIntervalSince(lastFrame) > 5.0 {
                diagLog("[AUDIO-BUS-HEALTH] silent for >5s, reconfiguring")
                reconfigureLocked()
            }
            return
        }

        // No frame ever delivered on this capture. A live IOProc yields buffers even for
        // digital silence, so zero callbacks after 10s means the IOProc is wedged in
        // coreaudiod (#64 precursor: micSamples=0 while system audio flowed). Rebuild it
        // through the serialized path, bounded; then surface the failure loudly.
        guard let started = captureStartDate, Date().timeIntervalSince(started) > 10 else { return }
        if noFrameRecoveryAttempts < Self.maxNoFrameRecoveries {
            noFrameRecoveryAttempts += 1
            diagLog("[AUDIO-BUS-HEALTH] no frames since capture start, rebuilding IOProc (attempt \(noFrameRecoveryAttempts)/\(Self.maxNoFrameRecoveries))")
            reconfigureLocked()
        } else if _error.value == nil {
            _error.value = "Microphone is not delivering audio"
            diagLog("[AUDIO-BUS-HEALTH] no frames after \(Self.maxNoFrameRecoveries) rebuilds — giving up")
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

    // MARK: - Async Device API (public — hops to the shared HAL queue)

    /// Everything below `Locked` runs HAL property IPC and therefore must execute on
    /// `sharedHALQueue` (#64). Callers get async wrappers that hop via a continuation —
    /// never a `sync` wait, which would recreate the deadlock from a different door.

    static func availableInputDevices() async -> [(id: AudioDeviceID, name: String)] {
        await onHALQueue { availableInputDevicesLocked() }
    }

    /// Async wrapper for the allowlist selection (D-030 semantics unchanged: one fresh
    /// enumeration per call, result pinned by the caller for the whole recording).
    static func resolveBestInputDevice(requested: AudioDeviceID) async -> (deviceID: AudioDeviceID, redirectedToBuiltIn: Bool)? {
        await onHALQueue { resolveBestInputDeviceLocked(requested: requested) }
    }

    /// Human-readable name of the input device that would be selected for a recording,
    /// for error messaging. Enumeration needs no microphone permission, so this is safe
    /// to call on a denied/failure path. Returns nil if no input device resolves.
    static func resolvedInputDeviceName(requested: AudioDeviceID) async -> String? {
        await onHALQueue {
            guard let selection = resolveBestInputDeviceLocked(requested: requested) else { return nil }
            return availableInputDevicesLocked().first(where: { $0.id == selection.deviceID })?.name
        }
    }

    /// Fire-and-forget HAL operation on the shared HAL queue, for HAL calls that live
    /// outside AudioBus (system-object listener registration in TranscriptionEngine).
    /// This and `onHALQueue` are the only doors to the HAL queue — both async-only;
    /// never add (or take) a `sync` path onto it (#64: a sync waiter from a context
    /// that holds or waits on HAL state recreates the deadlock).
    static func performHALOperation(_ body: @escaping @Sendable () -> Void) {
        sharedHALQueue.async(execute: body)
    }

    /// Value-returning HAL operation on the shared HAL queue (continuation hop, never
    /// `sync` — see `performHALOperation`). For HAL callers that need a result
    /// (SystemAudioCapture teardown, device resolution).
    static func onHALQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            sharedHALQueue.async { continuation.resume(returning: body()) }
        }
    }

    /// Throwing variant of `onHALQueue` for HAL setup paths that fail with errors
    /// (SystemAudioCapture tap/aggregate/IOProc creation).
    static func onHALQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sharedHALQueue.async { continuation.resume(with: Result(catching: body)) }
        }
    }

    // MARK: - Static Device Utilities (sharedHALQueue only)

    private static func availableInputDevicesLocked() -> [(id: AudioDeviceID, name: String)] {
        dispatchPrecondition(condition: .onQueue(sharedHALQueue))
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

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        dispatchPrecondition(condition: .onQueue(sharedHALQueue))
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

    private static func deviceNominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        dispatchPrecondition(condition: .onQueue(sharedHALQueue))
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

    private static func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        dispatchPrecondition(condition: .onQueue(sharedHALQueue))
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

    /// Canonical UID of the real built-in microphone. Continuity iPhone phantoms have been
    /// observed reporting the built-in transport type with session-unstable device IDs
    /// (#39 — phantom device 146/114 vs real built-in 102), so transport alone is never
    /// trusted: anything claiming built-in transport must match this UID to count as the
    /// real built-in mic, with the first built-in-transport device only as a last resort.
    private static let builtInMicrophoneUID = "BuiltInMicrophoneDevice"

    /// Snapshot of one input device's HAL properties, probed on sharedHALQueue so the
    /// pure selection logic below never touches the HAL (and is unit-testable, #64).
    struct InputDeviceProbe: Sendable {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32?
        let uid: String?
    }

    /// Pick the input device for a recording. Called once at recording start; the result is
    /// pinned for the whole recording (#39). Enumerates devices fresh on every call — never
    /// trusts a cached AudioDeviceID (IDs are not stable across sessions).
    private static func resolveBestInputDeviceLocked(requested: AudioDeviceID) -> (deviceID: AudioDeviceID, redirectedToBuiltIn: Bool)? {
        dispatchPrecondition(condition: .onQueue(sharedHALQueue))
        let probes = availableInputDevicesLocked().map {
            InputDeviceProbe(id: $0.id, name: $0.name, transport: transportType(for: $0.id), uid: deviceUID(for: $0.id))
        }
        return selectInputDevice(from: probes, requested: requested, systemDefault: defaultInputDeviceID())
    }

    /// Pure allowlist selection over pre-probed devices — no HAL calls, any thread.
    ///
    /// Rule: if the requested device (or, failing that, the system default) is built-in or
    /// wired, use it. Otherwise use the built-in mic; if none exists (Mac mini), the first
    /// wired input; else keep the candidate. Returns nil when no input devices are present.
    static func selectInputDevice(
        from devices: [InputDeviceProbe],
        requested: AudioDeviceID,
        systemDefault: AudioDeviceID?
    ) -> (deviceID: AudioDeviceID, redirectedToBuiltIn: Bool)? {
        guard !devices.isEmpty else {
            diagLog("[AUDIO-BUS] select input: no input devices available")
            return nil
        }

        func probe(_ id: AudioDeviceID) -> InputDeviceProbe? {
            devices.first(where: { $0.id == id })
        }
        func isAllowed(_ device: InputDeviceProbe) -> Bool {
            guard let transport = device.transport else { return false }
            guard allowedTransports.contains(transport) else { return false }
            // BuiltIn transport requires the canonical UID (see builtInMicrophoneUID, #39);
            // anything else falls through to the built-in fallback below.
            if transport == kAudioDeviceTransportTypeBuiltIn {
                return device.uid == builtInMicrophoneUID
            }
            return true
        }
        func name(_ id: AudioDeviceID) -> String {
            probe(id)?.name ?? "unknown"
        }

        // Candidate: explicit selection if it still exists, else the current system default.
        var candidate: AudioDeviceID = 0
        if requested > 0, probe(requested) != nil {
            candidate = requested
        } else if let def = systemDefault, probe(def) != nil {
            candidate = def
        }

        if candidate > 0, let candidateProbe = probe(candidate), isAllowed(candidateProbe) {
            diagLog("[AUDIO-BUS] selected input device=\(candidate) (\(name(candidate)))")
            return (candidate, false)
        }

        // Candidate is wireless (or unresolvable) — redirect per the allowlist. The real
        // built-in mic is disambiguated by UID (see builtInMicrophoneUID, #39).
        let builtInCandidates = devices.filter { $0.transport == kAudioDeviceTransportTypeBuiltIn }
        let builtIn = builtInCandidates.first(where: { $0.uid == builtInMicrophoneUID }) ?? builtInCandidates.first
        if let builtIn {
            // Report the redirect (drives the "wireless mic compresses audio" UI hint) only
            // when the candidate's transport was readable and actually disallowed — not when
            // the transport was unreadable or the device merely failed the built-in UID check.
            let candidateTransport = candidate > 0 ? probe(candidate)?.transport : nil
            let redirectedFromWireless = candidateTransport.map { !allowedTransports.contains($0) } ?? false
            diagLog("[AUDIO-BUS] wireless/unavailable input (\(candidate > 0 ? name(candidate) : "none")), selected built-in device=\(builtIn.id) (\(builtIn.name))")
            return (builtIn.id, redirectedFromWireless)
        }
        if let wired = devices.first(where: { isAllowed($0) }) {
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

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        dispatchPrecondition(condition: .onQueue(sharedHALQueue))
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
