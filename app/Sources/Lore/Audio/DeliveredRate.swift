@preconcurrency import AVFoundation
import os

private let rateLog = Logger(subsystem: "com.lore.app", category: "DeliveredRate")

/// The rate a capture really delivers, measured from its capture stamps (#272).
///
/// The system tap can deliver fewer frames per second than it declares — a
/// Bluetooth headset in call mode ran a tap declared 48 kHz at 24 kHz. Each
/// IOProc buffer is one cycle of the device's sample clock, so a pair of
/// buffers is contiguous exactly when that clock advanced by the first one's
/// frames; a lost buffer advances it by at least twice as much and is never
/// read. Over contiguous pairs the rate is frames over host seconds, summed so
/// stamp jitter cancels. Stamps without a valid host and sample time (taken at
/// dispatch) are not read at all.
///
/// Assumed, not yet seen on hardware: the aggregate device's sample clock runs
/// at the rate the tap delivers, so a buffer's frames equal the clock's
/// advance. Were the clock to stay at 48 kHz while each cycle carried half the
/// frames, every pair would look like a lost buffer: nothing is read, nothing
/// is corrected, and the tap's trace says its rate was never read.
struct DeliveredRateMeter {
    /// Contiguous capture needed before a reading is given.
    static let settleSpan: TimeInterval = 0.5
    /// Pairs remembered — a few seconds of capture.
    static let window = 256
    /// The newest pairs, about half a second at the tap's usual 512-frame
    /// buffers. When their median leaves the window's, the rate changed
    /// mid-stream — a headset moving to call mode without an output-device
    /// change — and the older pairs are dropped, so the new rate is read
    /// within about half a second instead of once it fills half the window.
    static let recent = 48
    /// How far the sample clock may stray from the previous buffer's frames
    /// and the pair still be contiguous.
    static let contiguity = 0.1
    /// How far a contiguous pair's rate may sit from the median and still be
    /// read — a host stamp gone wrong, or the old rate across a change.
    static let outlier = 0.25

    private var pairs: [(frames: Double, seconds: Double)] = []
    private var last: (host: TimeInterval, sample: Double, frames: Double)?

    /// Reads one buffer. False when it did not follow the previous one on the
    /// sample clock — a lost buffer, an outage; true when it did, or when
    /// there is no clock to tell by.
    @discardableResult
    mutating func add(frames: AVAudioFrameCount, stamp: CapturedBuffer.Stamp) -> Bool {
        guard let sample = stamp.sampleTime else {
            last = nil
            return true
        }
        defer { last = (stamp.hostSeconds, sample, Double(frames)) }
        guard let last else { return true }
        guard stamp.hostSeconds > last.host,
              abs(sample - last.sample - last.frames) <= Self.contiguity * last.frames
        else { return false }
        pairs.append((last.frames, stamp.hostSeconds - last.host))
        if pairs.count > Self.window { pairs.removeFirst(pairs.count - Self.window) }
        if pairs.count > Self.recent,
           let now = Self.median(pairs.suffix(Self.recent)), let all = Self.median(pairs[...]),
           abs(now / all - 1) > Self.outlier {
            pairs.removeFirst(pairs.count - Self.recent)
        }
        return true
    }

    /// Frames per second over the contiguous pairs, once they span
    /// `settleSpan`; nil before.
    var rate: Double? {
        guard let median = Self.median(pairs[...]) else { return nil }
        var frames = 0.0
        var seconds = 0.0
        for pair in pairs where abs(pair.frames / pair.seconds / median - 1) <= Self.outlier {
            frames += pair.frames
            seconds += pair.seconds
        }
        return seconds >= Self.settleSpan ? frames / seconds : nil
    }

    private static func median(_ pairs: ArraySlice<(frames: Double, seconds: Double)>) -> Double? {
        guard !pairs.isEmpty else { return nil }
        let rates = pairs.map { $0.frames / $0.seconds }.sorted()
        return rates[rates.count / 2]
    }
}

/// The system tap's stream, made true to its declared format (#272): when the
/// measured rate differs from the declared one, each buffer is read at the
/// measured rate and resampled to the declared one. Every consumer — the
/// meeting's track, the live transcriber, and so the batch pass and the export
/// that read the track — gets one truthful stream, and none can disagree.
///
/// A tap that delivers what it declares passes through untouched: the same
/// buffer objects, in the same order. The first buffers are held until the
/// rate is measured (about half a second), then released with their capture
/// stamps, so the start is corrected too and nothing is placed differently.
///
/// One per tap: a re-created tap starts a fresh measurement. Confined to the
/// capture's serial callback queue — every call, the final flush included,
/// runs there.
final class DeliveredRate: @unchecked Sendable {
    /// Correction starts when the reading is further than this ratio from the
    /// declared rate. Device clock drift is parts per million, and the
    /// recording eases out up to 0.5 % (`MeetingRecording.correction`); a real
    /// mismatch is tens of percent.
    static let enter = 0.005
    /// Correction ends only when the reading comes this close again, so a
    /// reading near `enter` cannot switch it on and off.
    static let exit = 0.002
    /// A rate in use is replaced when a new reading differs by more than this
    /// ratio; what is left is eased out by the recording.
    static let retune = 0.002
    /// The longest the first buffers are held without a reading; then they
    /// pass as declared.
    static let longestHold: TimeInterval = 2
    /// At most one `systemAudioRate` per tap in this long; a change inside it
    /// is traced when it ends, or when the stream does.
    static let traceInterval: TimeInterval = 10

    let declared: AVAudioFormat
    /// The output device's nominal rate when the tap was made, for the trace
    /// only: whether the headset's own rate predicts the mismatch.
    private let deviceRate: Double?
    private var meter = DeliveredRateMeter()
    /// Buffers waiting for the first reading, each with whether it followed
    /// the one before.
    private var held: [(buffer: CapturedBuffer, followed: Bool)] = []
    private var settled = false
    /// The rate buffers are read at when it is not the declared one.
    private(set) var inUse: Double?
    private var converter: AVAudioConverter?
    /// The end of the converter's last output, where a drained tail is
    /// placed. The tail itself is about a millisecond older — the filter's
    /// latency — which the recording's placement tolerance absorbs.
    private var nextOutput: CapturedBuffer.Stamp?
    private var lastHost: TimeInterval = 0
    private var tracePending = true
    private var lastTrace: TimeInterval?

    init(declared: AVAudioFormat, deviceRate: Double? = nil) {
        self.declared = declared
        self.deviceRate = deviceRate
    }

    /// One captured buffer in; the buffers to pass on out, in `declared`.
    func process(_ buffer: CapturedBuffer) -> [CapturedBuffer] {
        let followed = meter.add(frames: buffer.frameLength, stamp: buffer.stamp)
        lastHost = buffer.stamp.hostSeconds
        if settled {
            return adopt() + convert(buffer, followed: followed)
        }
        held.append((buffer, followed))
        let span = buffer.stamp.hostSeconds - held[0].buffer.stamp.hostSeconds
        guard meter.rate != nil || span >= Self.longestHold else { return [] }
        return release()
    }

    /// The stream is ending: what is held, then what the converter still
    /// holds; a change not yet traced is traced now.
    func flush() -> [CapturedBuffer] {
        let out = release() + drain()
        if tracePending, let rate = meter.rate { trace(rate) }
        return out
    }

    /// Releases what is held. A tap with no reading by now is traced as
    /// never read, so that stays apart from a tap true to its format; a
    /// reading that comes later is traced in its turn.
    private func release() -> [CapturedBuffer] {
        let first = !settled
        settled = true
        let out = adopt() + held.flatMap { convert($0.buffer, followed: $0.followed) }
        held = []
        if first, meter.rate == nil {
            trace(nil)
            lastTrace = lastHost
            tracePending = true
        }
        return out
    }

    /// Takes the current reading; returns the old converter's tail when the
    /// rate in use changes.
    private func adopt() -> [CapturedBuffer] {
        guard let measured = meter.rate else { return [] }
        let off = abs(measured / declared.sampleRate - 1)
        let target: Double? = switch inUse {
        case nil: off > Self.enter ? measured : nil
        case let current?: off < Self.exit ? nil : abs(measured / current - 1) > Self.retune ? measured : current
        }
        var out: [CapturedBuffer] = []
        if target != inUse {
            out = drain()
            inUse = target
            converter = target.flatMap(makeConverter)
            tracePending = true
        }
        if tracePending, lastTrace.map({ lastHost - $0 >= Self.traceInterval }) ?? true {
            trace(measured)
            lastTrace = lastHost
        }
        return out
    }

    /// `measured` nil: the tap's rate was never read.
    private func trace(_ measured: Double?) {
        tracePending = false
        let declaredHz = Int(declared.sampleRate.rounded())
        let deliveredHz = measured.map { Int($0.rounded()) }
        let deviceHz = deviceRate.map { Int($0.rounded()) }
        rateLog.info("system audio delivers \(deliveredHz ?? 0, privacy: .public) Hz, declared \(declaredHz, privacy: .public), output device \(deviceHz ?? 0, privacy: .public)")
        DiagStore.record(.systemAudioRate(declared: declaredHz, device: deviceHz, delivered: deliveredHz))
    }

    /// `declared` with the sample rate changed: how the tap's frames really read.
    private func makeConverter(_ rate: Double) -> AVAudioConverter? {
        var description = declared.streamDescription.pointee
        description.mSampleRate = rate
        return AVAudioFormat(streamDescription: &description).flatMap { AVAudioConverter(from: $0, to: declared) }
    }

    /// The buffer read at the rate in use, resampled to `declared`; itself
    /// when the tap is true to its format. After a buffer that did not follow
    /// the one before, the converter's history is released first, so none of
    /// it lands after the gap. A buffer the conversion cannot take passes
    /// through as it came, and the loss is traced.
    private func convert(_ buffer: CapturedBuffer, followed: Bool) -> [CapturedBuffer] {
        guard let rate = inUse else { return [buffer] }
        let out = followed ? [] : drain()
        var failure = DiagEvent.ResampleFailure.converterUnavailable
        if let converter,
           let input = CapturedBuffer.copy(of: buffer.audioBufferList, format: converter.inputFormat, stamp: buffer.stamp),
           let output = CapturedBuffer(
               pcmFormat: declared,
               frameCapacity: AudioUtils.convertedCapacity(frames: buffer.frameLength, from: rate, to: declared.sampleRate),
               stamp: buffer.stamp
           ) {
            if let error = AudioUtils.convert(input, with: converter, into: output) {
                failure = error
            } else {
                let seconds = Double(output.frameLength) / declared.sampleRate
                nextOutput = .init(
                    hostSeconds: buffer.stamp.hostSeconds + seconds,
                    capturedAt: buffer.stamp.capturedAt.addingTimeInterval(seconds)
                )
                return out + (output.frameLength > 0 ? [output] : [])
            }
        }
        AudioUtils.reportResampleFailure(failure, source: .systemTapRate, frames: Int(buffer.frameLength))
        converter = makeConverter(rate)
        nextOutput = nil
        return out + [buffer]
    }

    /// What the converter still holds, placed right after its last output;
    /// the converter starts clean afterwards.
    private func drain() -> [CapturedBuffer] {
        guard let converter else { return [] }
        defer {
            converter.reset()
            nextOutput = nil
        }
        guard let nextOutput,
              let output = CapturedBuffer(pcmFormat: declared, frameCapacity: 1024, stamp: nextOutput)
        else { return [] }
        return AudioUtils.drain(converter, into: output) && output.frameLength > 0 ? [output] : []
    }
}
