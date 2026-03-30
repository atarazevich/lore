@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import os

private let micLog = Logger(subsystem: "com.lore", category: "MicCapture")

/// Captures microphone audio via AVAudioEngine and streams PCM buffers.
final class MicCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var hasTapInstalled = false
    private let _audioLevel = AudioLevel()
    private let _hasCapturedFrames = SyncBool()
    private let _error = SyncString()
    private let _streamContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(uncheckedState: nil)
    private let _muted = SyncBool()
    private let _lastFrameTime = SyncOptionalDate()

    var audioLevel: Float { _muted.value ? 0 : _audioLevel.value }
    var hasCapturedFrames: Bool { _hasCapturedFrames.value }
    var captureError: String? { _error.value }

    /// Returns true if the engine is running AND a frame was received within the last 5 seconds.
    var isEngineAlive: Bool {
        guard engine.isRunning else { return false }
        guard let lastFrame = _lastFrameTime.value else { return false }
        return Date().timeIntervalSince(lastFrame) < 5.0
    }

    /// When muted, buffers are not forwarded to the stream and audio level reads as 0.
    var isMuted: Bool {
        get { _muted.value }
        set { _muted.value = newValue }
    }

    /// Set a specific input device by its AudioDeviceID. Pass nil to use system default.
    func setInputDevice(_ deviceID: AudioDeviceID?) {
        guard let id = deviceID else { return }
        let audioUnit = engine.inputNode.audioUnit!
        var deviceID = id
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    func bufferStream(deviceID: AudioDeviceID? = nil, echoCancellation: Bool = false) -> AsyncStream<AVAudioPCMBuffer> {
        // Defensive cleanup of any prior state
        _streamContinuation.withLock { $0?.finish(); $0 = nil }
        if hasTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            hasTapInstalled = false
        }
        engine.stop()

        let level = _audioLevel
        let errorHolder = _error

        return AsyncStream { continuation in
            self._streamContinuation.withLock { $0 = continuation }
            errorHolder.value = nil
            self._hasCapturedFrames.value = false

            diagLog("[MIC-1] bufferStream called, deviceID=\(String(describing: deviceID))")

            // When the system default input is Bluetooth, temporarily swap it to the
            // target device BEFORE creating the engine. AVAudioEngine configures its
            // inputNode based on the system default at init; Bluetooth triggers HFP
            // negotiation which blocks for seconds.
            var restoredDefaultDevice: AudioDeviceID?
            let currentDefault = Self.defaultInputDeviceID() ?? 0
            if let id = deviceID, currentDefault > 0, Self.isBluetoothDevice(currentDefault) {
                if Self.setDefaultInputDevice(id) {
                    restoredDefaultDevice = currentDefault
                    diagLog("[MIC-1a] swapped system default from Bluetooth (\(currentDefault)) to device \(id)")
                }
            }
            defer {
                if let restore = restoredDefaultDevice {
                    _ = Self.setDefaultInputDevice(restore)
                    diagLog("[MIC-1a] restored system default to \(restore)")
                }
            }

            let engine = self.makeFreshEngine()
            diagLog("[MIC-1a] fresh engine created")

            let inputNode = engine.inputNode
            diagLog("[MIC-1b] input node ready")

            // Enable voice processing (AEC + noise suppression) if requested
            if echoCancellation {
                do {
                    try inputNode.setVoiceProcessingEnabled(true)
                    diagLog("[MIC-1c] voice processing (AEC) enabled")
                } catch {
                    diagLog("[MIC-1c] failed to enable voice processing: \(error.localizedDescription)")
                }
            }

            // Set input device before accessing inputNode format
            var resolvedDeviceID: AudioDeviceID?
            if let id = deviceID {
                guard let inAU = inputNode.audioUnit else {
                    let msg = "inputNode has no audio unit after prepare"
                    diagLog("[MIC-2-FAIL] \(msg)")
                    errorHolder.value = msg
                    continuation.finish()
                    return
                }
                var devID = id
                let inStatus = AudioUnitSetProperty(
                    inAU,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                diagLog("[MIC-2] setInputDevice status=\(inStatus) (0=ok)")
                resolvedDeviceID = id
            } else {
                diagLog("[MIC-2] no deviceID, using system default")
                resolvedDeviceID = Self.defaultInputDeviceID()
            }

            let format = inputNode.outputFormat(forBus: 0)

            // The inputNode format may lag behind a device switch (e.g. USB mic at 48 kHz
            // while the engine still reports 44.1 kHz). Query the hardware sample rate
            // directly and prefer it when it differs from the inputNode format.
            var sampleRate = format.sampleRate
            if let devID = resolvedDeviceID,
               let hwRate = Self.deviceNominalSampleRate(for: devID),
               hwRate > 0, hwRate != sampleRate {
                diagLog("[MIC-3] hardware sr=\(hwRate) differs from inputNode sr=\(sampleRate), using hardware rate")
                sampleRate = hwRate
            }

            diagLog("[MIC-3] inputNode format: sr=\(format.sampleRate) ch=\(format.channelCount) interleaved=\(format.isInterleaved) commonFormat=\(format.commonFormat.rawValue), effective sr=\(sampleRate)")

            guard sampleRate > 0 && format.channelCount > 0 else {
                let msg = "Invalid audio format: sr=\(sampleRate) ch=\(format.channelCount)"
                diagLog("[MIC-3-FAIL] \(msg)")
                errorHolder.value = msg
                continuation.finish()
                return
            }

            // Try multiple tap formats — some devices report formats that don't
            // round-trip through AVAudioFormat(standardFormat:). Fall back to the
            // native input format as a last resort.
            let tapFormat: AVAudioFormat
            if let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: format.channelCount) {
                tapFormat = f
            } else if sampleRate != format.sampleRate,
                      let f = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount) {
                diagLog("[MIC-4] hardware-rate format failed, using node rate \(format.sampleRate)")
                tapFormat = f
            } else {
                diagLog("[MIC-4] standard formats failed, using native input format")
                tapFormat = format
            }

            diagLog("[MIC-4] tapFormat: sr=\(tapFormat.sampleRate) ch=\(tapFormat.channelCount)")

            let muted = self._muted
            var tapCallCount = 0
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
                tapCallCount += 1
                self._hasCapturedFrames.value = true
                self._lastFrameTime.value = Date()
                let rms = Self.normalizedRMS(from: buffer)
                level.value = min(rms * 25, 1.0)

                if tapCallCount <= 5 || tapCallCount % 100 == 0 {
                    diagLog("[MIC-6] tap #\(tapCallCount): frames=\(buffer.frameLength) rms=\(rms) level=\(level.value)")
                }

                guard !muted.value else { return }
                continuation.yield(buffer)
            }
            self.hasTapInstalled = true

            diagLog("[MIC-5] tap installed, preparing engine...")

            continuation.onTermination = { _ in
                diagLog("[MIC-TERM] stream terminated")
                // Audio hardware teardown handled by stop() — not here,
                // so finishStream() can drain without premature engine shutdown.
            }

            do {
                diagLog("[MIC-7] engine prepared, starting...")
                try engine.start()
                diagLog("[MIC-8] engine started successfully, isRunning=\(engine.isRunning)")
            } catch {
                let msg = "Mic failed: \(error.localizedDescription)"
                print("[MIC-8-FAIL] \(msg)")
                errorHolder.value = msg
                self.hasTapInstalled = false
                continuation.finish()
            }
        }
    }

    /// Finish the async stream so consumers exit their for-await loop.
    /// Call this before stop() when you need a graceful drain.
    func finishStream() {
        _streamContinuation.withLock { $0?.finish(); $0 = nil }
    }

    func stop() {
        finishStream()
        if hasTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            hasTapInstalled = false
        }
        engine.stop()
        engine.reset()
        _audioLevel.value = 0
        _hasCapturedFrames.value = false
        _lastFrameTime.value = nil
    }

    private func makeFreshEngine() -> AVAudioEngine {
        if hasTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            hasTapInstalled = false
        }
        engine.stop()
        let freshEngine = AVAudioEngine()
        engine = freshEngine
        return freshEngine
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        // Float32 path — use vDSP for hardware-accelerated RMS
        if let channelData = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            if channelCount == 1 || buffer.format.isInterleaved {
                // Single channel or interleaved: compute RMS directly on contiguous samples
                let totalSamples = buffer.format.isInterleaved ? frameLength * channelCount : frameLength
                var rms: Float = 0
                vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(totalSamples))
                return rms
            } else {
                // Multi-channel non-interleaved: average RMS across all channels
                // to preserve the original semantics
                var totalRMS: Float = 0
                for ch in 0..<channelCount {
                    var chRMS: Float = 0
                    vDSP_rmsqv(channelData[ch], 1, &chRMS, vDSP_Length(frameLength))
                    totalRMS += chRMS * chRMS
                }
                return sqrt(totalRMS / Float(channelCount))
            }
        }

        // Int16 fallback — convert to float, then vDSP
        // Rare in practice (mic is typically Float32)
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

    // MARK: - List available input devices

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
            // Check if device has input channels
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

            // Get device name
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

    /// Convert a CoreAudio AudioDeviceID to its stable UID string.
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

    /// Query the nominal sample rate of a CoreAudio device directly from hardware.
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

    /// Get the transport type of an audio device (built-in, Bluetooth, USB, etc.)
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

    /// Check if a device uses any Bluetooth transport.
    static func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let transport = transportType(for: deviceID) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth ||
               transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Find the first built-in input device.
    static func builtInInputDevice() -> AudioDeviceID? {
        let devices = availableInputDevices()
        return devices.first { transportType(for: $0.id) == kAudioDeviceTransportTypeBuiltIn }?.id
    }

    /// Resolve the best input device — redirects Bluetooth to built-in if available.
    /// Returns the device ID to use and whether a redirect occurred.
    static func resolveBestInputDevice(requested: AudioDeviceID) -> (deviceID: AudioDeviceID, redirectedFromBluetooth: Bool) {
        let resolved = requested > 0 ? requested : (defaultInputDeviceID() ?? requested)
        guard resolved > 0, isBluetoothDevice(resolved) else {
            return (resolved, false)
        }
        if let builtIn = builtInInputDevice() {
            return (builtIn, true)
        }
        // No built-in mic (Mac Mini/Studio) — use Bluetooth anyway
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

    /// Temporarily set the system default input device. Returns true on success.
    @discardableResult
    static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &devID
        )
        return status == noErr
    }

}

/// Simple thread-safe float holder for audio level.
final class AudioLevel: @unchecked Sendable {
    private var _value: Float = 0
    private let lock = NSLock()

    var value: Float {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Simple thread-safe optional string holder.
final class SyncString: @unchecked Sendable {
    private var _value: String?
    private let lock = NSLock()

    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Simple thread-safe double holder.
final class SyncDouble: @unchecked Sendable {
    private var _value: Double = 0
    private let lock = NSLock()

    var value: Double {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    func add(_ delta: Double) {
        lock.withLock { _value += delta }
    }
}

/// Simple thread-safe bool holder.
final class SyncBool: @unchecked Sendable {
    private var _value = false
    private let lock = NSLock()

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Simple thread-safe optional Date holder.
final class SyncOptionalDate: @unchecked Sendable {
    private var _value: Date?
    private let lock = NSLock()

    var value: Date? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
