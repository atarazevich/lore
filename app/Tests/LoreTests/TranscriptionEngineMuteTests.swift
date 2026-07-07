@preconcurrency import AVFoundation
import XCTest
@testable import LoreKit

/// Engine-level mic mute (#66): the mute gate lives in TranscriptionEngine's mic sink,
/// not on the AudioBus (which has no mute surface — compile-level invariant). While
/// muted, the engine's mic stream carries full-duration silence (recorder + VAD see
/// zeros); the shared bus buffer is never zeroed in place, so other consumers
/// (dictation) keep their audio.
final class TranscriptionEngineMuteTests: XCTestCase {

    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    private func toneBuffer(frames: AVAudioFrameCount = 160, value: Float = 0.5) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { channel[i] = value }
        return buffer
    }

    private func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        let channel = buffer.floatChannelData![0]
        return (0..<Int(buffer.frameLength)).map { abs(channel[$0]) }.max() ?? 0
    }

    /// Feed the buffers through `mutedStream` with the mute flag preset, then collect
    /// everything that comes out.
    private func collectOutput(muted: Bool, buffers: [AVAudioPCMBuffer]) async -> [AVAudioPCMBuffer] {
        let flag = SyncBool()
        flag.value = muted
        let (input, feed) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let output = TranscriptionEngine.mutedStream(input, muted: flag)

        for buffer in buffers { feed.yield(buffer) }
        feed.finish()

        var received: [AVAudioPCMBuffer] = []
        for await buffer in output { received.append(buffer) }
        return received
    }

    func testMutedStreamReplacesFramesWithSilenceOfSameDuration() async {
        let received = await collectOutput(muted: true, buffers: [toneBuffer()])

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].frameLength, 160)
        XCTAssertEqual(received[0].format, format)
        XCTAssertEqual(peak(received[0]), 0)
    }

    func testUnmutedStreamPassesAudioThrough() async {
        let received = await collectOutput(muted: false, buffers: [toneBuffer()])

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(peak(received[0]), 0.5)
    }

    func testMuteTogglesMidStream() async {
        let muted = SyncBool()
        let (input, feed) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let output = TranscriptionEngine.mutedStream(input, muted: muted)
        var iterator = output.makeAsyncIterator()

        // Each toggle happens only after the previous frame came back out, so the
        // gate's read of the flag is deterministic.
        feed.yield(toneBuffer())
        let live = await iterator.next()
        XCTAssertEqual(live.map(peak), 0.5)

        muted.value = true
        feed.yield(toneBuffer())
        let mutedFrame = await iterator.next()
        XCTAssertEqual(mutedFrame?.frameLength, 160)
        XCTAssertEqual(mutedFrame.map(peak), 0)

        muted.value = false
        feed.yield(toneBuffer())
        let resumed = await iterator.next()
        XCTAssertEqual(resumed.map(peak), 0.5)

        feed.finish()
    }

    func testMutingDoesNotZeroTheSharedBusBuffer() async {
        // AudioBus fans the SAME buffer instance out to every consumer. The engine's
        // mute must yield a silent copy, never zero the shared buffer — otherwise a
        // second consumer (dictation) would lose its audio.
        let shared = toneBuffer()
        let received = await collectOutput(muted: true, buffers: [shared])

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(peak(received[0]), 0)
        XCTAssertEqual(peak(shared), 0.5)
    }

    @MainActor
    func testMuteCannotOutliveTheSession() {
        let harness = MeetingHarness.make()
        guard let engine = harness.coordinator.transcriptionEngine else {
            return XCTFail("harness has no engine")
        }
        engine.isMicMuted = true
        engine.stop()
        XCTAssertFalse(engine.isMicMuted)
    }
}
