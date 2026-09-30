@preconcurrency import AVFoundation
import CoreAudio

/// A captured buffer stamped with the instant its first frame was captured
/// (#268). The recorder places audio by when it was heard, not by when a
/// consumer task got round to writing it — so a scheduler stall, a burst of
/// backlog or a wall-clock jump never reads as a gap.
///
/// A subclass rather than a new stream element, so every consumer of the
/// mic bus and the system tap keeps its `AVAudioPCMBuffer` stream unchanged.
final class CapturedBuffer: AVAudioPCMBuffer, @unchecked Sendable {
    struct Stamp: Sendable, Equatable {
        /// Capture instant on the continuous host clock, in seconds.
        /// Continuous (`mach_continuous_time`) rather than absolute: time
        /// asleep counts, so audio after a wake lands after the sleep, as it
        /// does on the wall clock the transcripts use.
        let hostSeconds: TimeInterval
        /// The same instant on the wall clock — what dates a track's frame 0.
        let capturedAt: Date
        /// The device's sample clock at the first frame, only when the HAL
        /// gave both it and a valid host time — the pair a delivered rate is
        /// measured from (#272). Nil for a stamp taken at dispatch or not
        /// read from a device.
        let sampleTime: Double?

        init(hostSeconds: TimeInterval, capturedAt: Date, sampleTime: Double? = nil) {
            self.hostSeconds = hostSeconds
            self.capturedAt = capturedAt
            self.sampleTime = sampleTime
        }
    }

    let stamp: Stamp

    init?(pcmFormat: AVAudioFormat, frameCapacity: AVAudioFrameCount, stamp: Stamp) {
        self.stamp = stamp
        super.init(pcmFormat: pcmFormat, frameCapacity: frameCapacity)
    }

    /// The one copy out of an `AudioBufferList` — an IOProc's input, or a
    /// buffer the recorder reshapes. Skips the first `dropping` frames and
    /// puts `holding` copies of the first kept frame in front, so the same
    /// loop serves a plain copy, a trim and a hold. `mBytesPerFrame` is the
    /// stride per buffer in the list either way: one buffer per channel when
    /// non-interleaved, one for all when interleaved. Nil when no frame is
    /// left or allocation fails.
    static func copy(
        of list: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat,
        dropping: AVAudioFrameCount = 0,
        holding: AVAudioFrameCount = 0,
        stamp: Stamp
    ) -> CapturedBuffer? {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let stride = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard stride > 0, let first = source.first else { return nil }
        let available = Int(first.mDataByteSize) / stride
        guard available > Int(dropping) else { return nil }
        let kept = available - Int(dropping)
        let frames = AVAudioFrameCount(kept) + holding
        guard let buffer = CapturedBuffer(pcmFormat: format, frameCapacity: frames, stamp: stamp) else {
            return nil
        }
        buffer.frameLength = frames

        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard destination.count == source.count else { return nil }
        for index in 0..<source.count {
            let bytes = min(Int(source[index].mDataByteSize) / stride - Int(dropping), kept) * stride
            guard bytes > 0, let from = source[index].mData, let to = destination[index].mData else { continue }
            let start = from + Int(dropping) * stride
            for frame in 0..<Int(holding) {
                memcpy(to + frame * stride, start, stride)
            }
            memcpy(to + Int(holding) * stride, start, bytes)
            destination[index].mDataByteSize = UInt32(Int(holding) * stride + bytes)
        }
        return buffer
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Host-clock ticks in seconds.
    static func seconds(_ ticks: Int64) -> TimeInterval {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}

extension CapturedBuffer.Stamp {
    /// From an IOProc's input time. The HAL reports it on the absolute
    /// host clock; its age against `mach_absolute_time` moves it onto the
    /// continuous clock and the wall clock alike. Without a valid host
    /// time it is stamped now, and carries no sample time.
    init(inputTime: UnsafePointer<AudioTimeStamp>) {
        let absolute = mach_absolute_time()
        let continuous = mach_continuous_time()
        let time = inputTime.pointee
        let hostValid = time.mFlags.contains(.hostTimeValid)
        let host = hostValid ? time.mHostTime : absolute
        let age = CapturedBuffer.seconds(Int64(bitPattern: absolute &- host))
        self.init(
            hostSeconds: CapturedBuffer.seconds(Int64(bitPattern: continuous)) - age,
            capturedAt: Date().addingTimeInterval(-age),
            sampleTime: hostValid && time.mFlags.contains(.sampleTimeValid) ? time.mSampleTime : nil
        )
    }
}
