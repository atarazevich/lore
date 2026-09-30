@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Dispatch
import Foundation
import os

/// Captures system output audio via a Core Audio process tap.
final class SystemAudioCapture: @unchecked Sendable {
    private let _aggregateDeviceID = OSAllocatedUnfairLock<AudioObjectID>(
        uncheckedState: AudioObjectID(kAudioObjectUnknown)
    )
    private let _tapID = OSAllocatedUnfairLock<AudioObjectID>(
        uncheckedState: AudioObjectID(kAudioObjectUnknown)
    )
    private let _ioProcID = OSAllocatedUnfairLock<AudioDeviceIOProcID?>(uncheckedState: nil)
    /// The open stream: its consumer and, once a tap delivers into it, that
    /// tap's rate correction (#272). One lock over both, so every path that
    /// ends the stream ends both.
    private struct OpenStream: Sendable {
        let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
        var deliveredRate: DeliveredRate?
    }
    private let _stream = OSAllocatedUnfairLock<OpenStream?>(uncheckedState: nil)
    private let callbackQueue = DispatchQueue(
        label: "com.lore.system-audio",
        qos: .userInteractive
    )

    /// One attempt per fresh signal (#149). The tap is the step a missing Screen &
    /// System Audio Recording grant kills, and the output-device listener re-drives
    /// a start on every device flap — unbounded, with no user in it. A failed start
    /// is therefore reported once and not retried until the user starts another
    /// meeting (`resetFailureBudget`) or a start succeeds.
    static let maxStartAttempts = 1

    /// The budget plus the signal it belongs to. One lock over both, so a meeting
    /// starting mid-flight cannot have its fresh budget spent by an older start's
    /// failure landing after the await.
    private struct Attempts {
        var budget = RetryBudget(limit: maxStartAttempts)
        var generation = 0
    }
    private let _attempts = OSAllocatedUnfairLock<Attempts>(uncheckedState: Attempts())

    /// The HAL half of a start, injectable so the give-up bound can be exercised
    /// without revoking a TCC grant (a test cannot). `nil` — production — creates
    /// the real process tap.
    private let startOverride: (@Sendable (AudioDeviceID?) async throws -> Void)?

    init(startOverride: (@Sendable (AudioDeviceID?) async throws -> Void)? = nil) {
        self.startOverride = startOverride
    }

    struct CaptureStreams {
        let systemAudio: AsyncStream<AVAudioPCMBuffer>
    }

    /// A fresh user signal — the user started a meeting — refills the budget.
    /// Never called from a timer or the device-change listener: those are exactly
    /// the unattended re-drives the budget exists to bound.
    func resetFailureBudget() {
        _attempts.withLock {
            $0.budget.reset()
            $0.generation += 1
        }
    }

    func bufferStream(outputDeviceID: AudioDeviceID? = nil) async throws -> CaptureStreams {
        // Claim the attempt and the generation it belongs to in one step.
        let generation = _attempts.withLock { attempts -> Int? in
            attempts.budget.allowsAttempt ? attempts.generation : nil
        }
        guard let generation else {
            throw CaptureError.givenUp(attempts: Self.maxStartAttempts)
        }

        await stop()

        let sysStream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self._stream.withLock { $0 = OpenStream(continuation: continuation) }
        }

        do {
            if let startOverride {
                try await startOverride(outputDeviceID)
            } else {
                // All tap/aggregate/IOProc control calls are HAL IPC — they serialize on
                // the process-wide HAL queue with AudioBus's own start/stop (#64), entered
                // through the async door (never sync). IOProc delivery stays on callbackQueue.
                try await AudioBus.onHALQueue { [self] in
                    try startCaptureOnHALQueue(outputDeviceID: outputDeviceID)
                }
            }
        } catch {
            // Every in-HAL guard already finishes the stream; this covers the
            // injected seam so a caller's `for await` never hangs on a dead start.
            abandonStream()
            // A failure from a superseded generation spends nothing.
            let exhausted = _attempts.withLock { attempts -> Bool in
                guard attempts.generation == generation else { return false }
                return attempts.budget.noteFailure()
            }
            if exhausted {
                DiagStore.record(.systemAudioGaveUp(attempts: Self.maxStartAttempts))
            }
            throw error
        }

        _attempts.withLock { $0.budget.reset() }
        return CaptureStreams(systemAudio: sysStream)
    }

    /// Runs on AudioBus's shared HAL queue only (via the `onHALQueue` door).
    private func startCaptureOnHALQueue(outputDeviceID: AudioDeviceID?) throws {
        let outputDeviceID = try (outputDeviceID ?? Self.defaultOutputDeviceID())
        let outputUID = try Self.deviceUID(for: outputDeviceID)
        let tapUUID = UUID()

        let tapDescription = CATapDescription()
        tapDescription.name = "Lore System Audio"
        tapDescription.uuid = tapUUID
        tapDescription.processes = Self.currentProcessObjectID().map { [$0] } ?? []
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        tapDescription.isMixdown = true
        tapDescription.isMono = true
        tapDescription.isExclusive = true
        tapDescription.deviceUID = outputUID
        tapDescription.stream = 0

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else {
            abandonStream()
            throw CaptureError.tapCreationFailed(status)
        }

        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lore System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        )
        guard status == noErr else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            abandonStream()
            throw CaptureError.aggregateDeviceCreationFailed(status)
        }

        let streamDescription = try Self.tapStreamDescription(for: tapID)
        var mutableStreamDescription = streamDescription
        guard let format = AVAudioFormat(streamDescription: &mutableStreamDescription) else {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            abandonStream()
            throw CaptureError.invalidTapFormat
        }

        // The tap's declared format is not always what it delivers (#272).
        // Each tap measures afresh, and its IOProc holds this stream's own
        // continuation, so a block still queued when the stream finishes
        // delivers into it rather than being dropped or reaching the next one.
        let deliveredRate = DeliveredRate(
            declared: format, deviceRate: AudioBus.deviceNominalSampleRate(for: outputDeviceID)
        )
        let continuation = _stream.withLock { stream in
            stream?.deliveredRate = deliveredRate
            return stream?.continuation
        }

        var ioProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDeviceID,
            callbackQueue
        ) { _, inInputData, inInputTime, _, _ in
            guard let continuation,
                  let buffer = CapturedBuffer.copy(of: inInputData, format: format, stamp: .init(inputTime: inInputTime))
            else { return }
            for corrected in deliveredRate.process(buffer) {
                continuation.yield(corrected)
            }
        }
        guard status == noErr, let ioProcID else {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            abandonStream()
            throw CaptureError.ioProcCreationFailed(status)
        }

        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else {
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            abandonStream()
            throw CaptureError.startFailed(status)
        }

        // Copy to lets: withLock closures are @Sendable and cannot capture the vars.
        let activeTapID = tapID
        let activeAggregateDeviceID = aggregateDeviceID
        let activeIOProcID = ioProcID

        _tapID.withLock { $0 = activeTapID }
        _aggregateDeviceID.withLock { $0 = activeAggregateDeviceID }
        _ioProcID.withLock { $0 = activeIOProcID }
    }

    /// Finish the async stream so consumers exit their for-await loop.
    /// Call this before stop() when you need a graceful drain.
    /// The end is queued on the callback queue: IOProc blocks already queued
    /// there deliver first, then the buffers the rate correction still holds,
    /// then the stream finishes. Blocks after it yield into a finished
    /// stream, which drops them.
    func finishStream() {
        guard let stream = _stream.withLock({ state in
            defer { state = nil }
            return state
        }) else { return }
        callbackQueue.async {
            stream.deliveredRate?.flush().forEach { stream.continuation.yield($0) }
            stream.continuation.finish()
        }
    }

    /// A start that failed: the stream ends at once, with nothing to deliver.
    private func abandonStream() {
        _stream.withLock { $0?.continuation.finish(); $0 = nil }
    }

    func stop() async {
        finishStream()

        let aggregateDeviceID = _aggregateDeviceID.withLock { state -> AudioObjectID in
            let current = state
            state = AudioObjectID(kAudioObjectUnknown)
            return current
        }
        let ioProcID = _ioProcID.withLock { state -> AudioDeviceIOProcID? in
            let current = state
            state = nil
            return current
        }
        let tapID = _tapID.withLock { state -> AudioObjectID in
            let current = state
            state = AudioObjectID(kAudioObjectUnknown)
            return current
        }

        guard aggregateDeviceID != AudioObjectID(kAudioObjectUnknown)
                || tapID != AudioObjectID(kAudioObjectUnknown) else { return }

        // Teardown is HAL IPC — same single serialization point as setup (#64).
        await AudioBus.onHALQueue {
            if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
                if let ioProcID {
                    _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
                    _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                }
                _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            }
            if tapID != AudioObjectID(kAudioObjectUnknown) {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
        }
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    private static func currentProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var address = propertyAddress(selector: kAudioHardwarePropertyTranslatePIDToProcessObject)
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = withUnsafePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &dataSize,
                &processObjectID
            )
        }

        guard status == noErr, processObjectID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return processObjectID
    }

    /// HAL property read — called only from startCaptureOnHALQueue (shared HAL queue).
    private static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = propertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw CaptureError.noOutputDevice
        }
        return deviceID
    }

    private static func deviceUID(for deviceID: AudioDeviceID) throws -> String {
        var address = propertyAddress(selector: kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &uid
        )

        guard status == noErr, let uid else {
            throw CaptureError.outputDeviceUIDUnavailable(status)
        }
        return uid.takeRetainedValue() as String
    }

    private static func tapStreamDescription(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = propertyAddress(selector: kAudioTapPropertyFormat)
        var streamDescription = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(
            tapID,
            &address,
            0,
            nil,
            &dataSize,
            &streamDescription
        )

        guard status == noErr else {
            throw CaptureError.tapFormatUnavailable(status)
        }
        return streamDescription
    }

    enum CaptureError: LocalizedError {
        case noOutputDevice
        case outputDeviceUIDUnavailable(OSStatus)
        case tapCreationFailed(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case tapFormatUnavailable(OSStatus)
        case invalidTapFormat
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)
        /// The retry budget is spent (#149) — no HAL call was made, and the last
        /// real failure is still the standing report.
        case givenUp(attempts: Int)

        var errorDescription: String? {
            switch self {
            case .givenUp:
                return "System audio capture failed and stopped retrying. Enable \(LoreTheme.wordmark) in System Settings > Privacy & Security > Screen & System Audio Recording, then start the meeting again."
            case .noOutputDevice:
                return "No audio output device is currently available."
            case .outputDeviceUIDUnavailable(let status):
                return "Unable to inspect the system output device (OSStatus \(status))."
            case .tapCreationFailed(let status):
                return "System audio capture could not start. Enable \(LoreTheme.wordmark) in System Settings > Privacy & Security > Screen & System Audio Recording (OSStatus \(status))."
            case .aggregateDeviceCreationFailed(let status):
                return "Unable to create the Core Audio aggregate device (OSStatus \(status))."
            case .tapFormatUnavailable(let status):
                return "Unable to inspect the system audio tap format (OSStatus \(status))."
            case .invalidTapFormat:
                return "System audio capture produced an unsupported audio format."
            case .ioProcCreationFailed(let status):
                return "Unable to create the system audio IO callback (OSStatus \(status))."
            case .startFailed(let status):
                return "Unable to start system audio capture (OSStatus \(status))."
            }
        }

        /// The HAL status behind this failure, for `DiagEvent.systemAudioCapture` (#82).
        /// `nil` where the failure carries no OSStatus of its own.
        var osStatus: OSStatus? {
            switch self {
            case .noOutputDevice, .invalidTapFormat, .givenUp:
                return nil
            case .outputDeviceUIDUnavailable(let status),
                 .tapCreationFailed(let status),
                 .aggregateDeviceCreationFailed(let status),
                 .tapFormatUnavailable(let status),
                 .ioProcCreationFailed(let status),
                 .startFailed(let status):
                return status
            }
        }
    }
}
