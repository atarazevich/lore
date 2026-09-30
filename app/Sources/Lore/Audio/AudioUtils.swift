@preconcurrency import AVFoundation
import os

enum AudioUtils {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    private static let log = Logger(subsystem: "com.lore.app", category: "AudioUtils")

    /// A zeroed buffer of `frames` in `format`. Two callers with one rule: the
    /// mic mute gate substitutes silence of the same shape as the buffer it
    /// drops (#66), carrying that buffer's capture stamp so the recorder still
    /// places it (#268), and the recorder fills a gap with it (#153).
    /// Returns nil only on allocation failure — the callers treat that as
    /// "drop the frame" rather than passing audio through.
    static func silentBuffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        stamp: CapturedBuffer.Stamp? = nil
    ) -> AVAudioPCMBuffer? {
        guard frames > 0 else { return nil }
        let allocated: AVAudioPCMBuffer? = if let stamp {
            CapturedBuffer(pcmFormat: format, frameCapacity: frames, stamp: stamp)
        } else {
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        }
        guard let buffer = allocated else { return nil }
        buffer.frameLength = frames
        // Every channel of every buffer in the list: `mDataByteSize` tracks
        // `frameLength`, so this zeroes exactly what will be read.
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
        return buffer
    }

    /// One capture buffer → 16 kHz mono Float32, for a stream of buffers that
    /// share `converter` across calls so the resampler's filter state carries
    /// from one buffer to the next. The one conversion for live capture:
    /// dictation and the meeting's streaming ASR both come through here.
    /// `source` only names the stream in a failure event.
    ///
    /// The output has room for the whole buffer plus what the converter still
    /// holds; sized to exactly `frames × ratio`, the converter could fill it
    /// from its history alone and never take the buffer (#271).
    ///
    /// Channels are mixed by the converter itself (`downmix`), which reads any
    /// layout — planar or interleaved, Float32 or integer.
    static func extractSamples(
        _ buffer: AVAudioPCMBuffer,
        converter: inout AVAudioConverter?,
        source: DiagEvent.ResampleSource
    ) -> [Float]? {
        let format = buffer.format
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        // Already 16 kHz mono Float32: nothing to convert.
        if format.commonFormat == .pcmFormatFloat32 && format.sampleRate == 16000 && format.channelCount == 1 {
            guard let channelData = buffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

        if converter == nil || converter?.inputFormat != format {
            converter = makeConverter(from: format)
        }
        guard let conv = converter else {
            reportResampleFailure(.converterUnavailable, source: source, frames: frameLength)
            return nil
        }

        let capacity = convertedCapacity(
            frames: buffer.frameLength, from: format.sampleRate, to: targetFormat.sampleRate
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        if let failure = convert(buffer, with: conv, into: output) {
            // Keep what came out; a converter that failed is not reused.
            if failure == .converterError { converter = nil }
            reportResampleFailure(failure, source: source, frames: frameLength)
        }

        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// Room for a whole buffer converted between the two rates plus what the
    /// converter still holds (#271): sized to exactly `frames × ratio`, the
    /// converter could fill it from its history alone and never take the
    /// buffer. The held history is a filter's length, far under 64 frames.
    static func convertedCapacity(frames: AVAudioFrameCount, from: Double, to: Double) -> AVAudioFrameCount {
        AVAudioFrameCount((Double(frames) * to / from).rounded(.up)) + 64
    }

    /// One buffer of a stream through that stream's converter into `output`
    /// (sized by `convertedCapacity`), offered once so the converter's state
    /// carries to the next buffer (#271). Nil when it went through; otherwise
    /// why audio was lost — what did come out stays in `output`.
    static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        into output: AVAudioPCMBuffer
    ) -> DiagEvent.ResampleFailure? {
        var error: NSError?
        nonisolated(unsafe) var consumed = false
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            log.error("Resample error: \(error.localizedDescription)")
            return .converterError
        } else if !consumed {
            // Unreachable with `convertedCapacity`; a tripwire, not a path.
            log.error("Resample: converter did not take a \(buffer.frameLength, privacy: .public)-frame buffer")
            return .bufferNotTaken
        }
        return nil
    }

    /// Ends `converter`'s stream and puts what it still holds into `output`.
    /// Called again, it gives what is left; an empty `output` means nothing
    /// is. The converter needs `reset()` before it takes input again. False
    /// when the converter failed.
    static func drain(_ converter: AVAudioConverter, into output: AVAudioPCMBuffer) -> Bool {
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        return error == nil
    }

    /// A converter to `targetFormat` that mixes every input channel into the
    /// mono output (the default would take only the first).
    static func makeConverter(from format: AVAudioFormat) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: format, to: targetFormat)
        converter?.downmix = true
        return converter
    }

    private static let failureLimiter = ResampleFailureLimiter()

    static func reportResampleFailure(
        _ reason: DiagEvent.ResampleFailure,
        source: DiagEvent.ResampleSource,
        frames: Int
    ) {
        if let event = failureLimiter.report(reason, source: source, frames: frames, now: Date()) {
            DiagStore.record(event)
        }
    }
}

/// Failures not yet reported, per stream and reason, with when that pair last
/// left an event. A converter that fails fails on every buffer — about 47 a
/// second — so each pair yields at most one event per 10 s, carrying
/// everything lost since the previous one; one stream's failures never hide
/// another's. Thread-safe: the live streams report from their own tasks.
final class ResampleFailureLimiter: Sendable {
    private struct Key: Hashable {
        let source: DiagEvent.ResampleSource
        let reason: DiagEvent.ResampleFailure
    }
    private struct Pending {
        var lastRecorded: Date?
        var buffers = 0
        var frames = 0
    }
    private let pending = OSAllocatedUnfairLock<[Key: Pending]>(initialState: [:])

    /// Counts one lost buffer; returns the event to record when this pair is due.
    func report(
        _ reason: DiagEvent.ResampleFailure,
        source: DiagEvent.ResampleSource,
        frames: Int,
        now: Date
    ) -> DiagEvent? {
        pending.withLock { all in
            let key = Key(source: source, reason: reason)
            var entry = all[key] ?? Pending()
            entry.buffers += 1
            entry.frames += frames
            if let last = entry.lastRecorded, now.timeIntervalSince(last) < 10 {
                all[key] = entry
                return nil
            }
            all[key] = Pending(lastRecorded: now)
            return .resampleFailed(source: source, reason: reason, buffers: entry.buffers, frames: entry.frames)
        }
    }
}
