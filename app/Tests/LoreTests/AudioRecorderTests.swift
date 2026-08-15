import AVFoundation
import XCTest
@testable import LoreKit

final class AudioRecorderTests: XCTestCase {

    private var root: URL!
    /// The notes folder the merged m4a export lands in.
    private var outputDir: URL!
    /// A meeting's own `audio/` directory — where the two tracks are written
    /// from the first buffer (#177).
    private var trackDir: URL!
    /// The meeting `trackDir` belongs to. Every recorder operation names it,
    /// so one armed for another meeting is left alone.
    private let sessionID = "session_1"

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LoreRecorderTests")
            .appendingPathComponent(UUID().uuidString)
        outputDir = root.appendingPathComponent("Notes")
        trackDir = audioDirectory(of: sessionID)
        for dir in [outputDir!, trackDir!] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Helpers

    /// A meeting's own `audio/` directory, as the repository lays it out.
    private func audioDirectory(of sessionID: String) -> URL {
        root.appendingPathComponent("sessions/\(sessionID)/audio")
    }

    /// A recorder armed for the test meeting.
    private func makeRecorder() -> AudioRecorder {
        let recorder = AudioRecorder(outputDirectory: outputDir)
        recorder.startSession(id: sessionID, trackDirectory: trackDir)
        return recorder
    }

    private var micTrack: URL { BatchAudioStash.micURL(in: trackDir) }
    private var sysTrack: URL { BatchAudioStash.sysURL(in: trackDir) }

    private func m4aFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: outputDir, includingPropertiesForKeys: nil
        )) ?? []
        return files.filter { $0.pathExtension == "m4a" }
    }

    /// The stash as the batch pass reads it — the persisted anchors, not the
    /// recorder's memory of them.
    private func persistedMeta() -> BatchMeta? {
        BatchAudioStash.readMeta(in: trackDir)
    }

    /// Write system audio buffers simulating a rate mismatch:
    /// buffers are tagged at `declaredRate` but delivered at real-time intervals
    /// corresponding to `effectiveRate`.
    private func writeSysBuffers(
        recorder: AudioRecorder,
        declaredRate: Double,
        effectiveRate: Double,
        durationSeconds: Double
    ) {
        let bufferSize: AVAudioFrameCount = 480
        let totalFrames = Int(effectiveRate * durationSeconds)
        let bufferCount = totalFrames / Int(bufferSize)

        // Time between buffers based on effective rate
        let intervalPerBuffer = Double(bufferSize) / effectiveRate

        let startTime = Date()
        for i in 0..<bufferCount {
            let buffer = makeSineBuffer(
                sampleRate: declaredRate,
                frameCount: bufferSize,
                frequency: 440
            )
            // Simulate wall-clock timing by adjusting sysStartDate/sysEndDate
            // We write all buffers synchronously but the recorder tracks Date() calls
            recorder.writeSysBuffer(buffer)

            // For the first few and last buffers, we can't control Date() precisely,
            // but the test verifies the merge output duration is approximately correct.
            _ = intervalPerBuffer * Double(i)
        }
        let elapsed = Date().timeIntervalSince(startTime)
        // Sanity: buffer writes should be fast (< 2s for any reasonable test)
        XCTAssertLessThan(elapsed, 5.0)
    }

    // MARK: - Tests

    func testMergeProducesOutputFile() async {
        let recorder = makeRecorder()

        // Write 2 seconds of mic audio at 24kHz
        let micBuffer = makeSineBuffer(sampleRate: 24000, frameCount: 48000)
        recorder.writeMicBuffer(micBuffer)

        // Write 2 seconds of system audio at 48kHz
        let sysBuffer = makeSineBuffer(sampleRate: 48000, frameCount: 96000)
        recorder.writeSysBuffer(sysBuffer)

        await recorder.exportMerged(for: sessionID)

        XCTAssertEqual(m4aFiles().count, 1, "Expected one m4a output file")
    }

    /// The tracks are the meeting's from the first buffer (#177): they land in
    /// the session's own audio/ directory, not in a temp directory, and the
    /// timing anchors are on disk beside them while the recording is still
    /// running — the two things a rebuild after a kill needs.
    @MainActor
    func testTracksAndAnchorsLandInTheMeetingDuringRecording() async {
        let recorder = makeRecorder()

        recorder.writeMicBuffer(makeSineBuffer(sampleRate: 48000, frameCount: 4800))
        recorder.writeSysBuffer(makeSineBuffer(sampleRate: 48000, frameCount: 4800))

        XCTAssertTrue(FileManager.default.fileExists(atPath: micTrack.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sysTrack.path))

        // The anchor write is dispatched off the audio thread; it is the only
        // thing here that is not synchronous.
        await waitUntil { self.persistedMeta()?.sysStartDate != nil }
        let meta = persistedMeta()
        XCTAssertNotNil(meta?.micStartDate, "the mic start anchor must be on disk mid-recording")
        XCTAssertNotNil(meta?.sysStartDate, "the sys start anchor must be on disk mid-recording")
        XCTAssertEqual(meta?.micAnchors.first?.frame, 0)
    }

    /// Closing the tracks writes the last anchor snapshot once more. Anchors
    /// persist themselves as they appear, but that write can only log its
    /// failures — without this retry a meeting whose one anchor write failed
    /// would keep its tracks and permanently lack the timing beside them, and
    /// the rebuild would stamp the recovered transcript at the moment of the
    /// rebuild instead of the moment it was spoken.
    @MainActor
    func testClosingTheTracksWritesTheTimingAgain() async {
        let recorder = makeRecorder()
        recorder.writeMicBuffer(makeSineBuffer(sampleRate: 48_000, frameCount: 4_800))
        await waitUntil { self.persistedMeta() != nil }

        // Stands in for the anchor write that failed: the meeting has its
        // track, and no timing beside it.
        try? FileManager.default.removeItem(at: BatchAudioStash.metaURL(in: trackDir))
        XCTAssertNil(persistedMeta())

        await recorder.finishTracks(for: sessionID)
        XCTAssertNotNil(
            persistedMeta()?.micStartDate,
            "the close must persist the timing the failed write lost"
        )
    }

    /// The assumption recovery rests on: a track file that was never closed is
    /// still readable at its true length. While writing, CoreAudio leaves the
    /// CAF data chunk sized −1 ("to end of file"), so a reader measures the
    /// bytes that landed rather than trusting a header the kill never patched.
    /// A canary: if this ever stops holding, every meeting killed mid-recording
    /// loses its audio again.
    ///
    /// Two seconds, not a fraction of one: the whole fix rests on this platform
    /// property, and a margin under a second would be passed by a writer that
    /// simply buffers a second before flushing.
    func testTrackKilledMidWriteIsStillReadable() throws {
        let recorder = makeRecorder()
        let frames = AVAudioFrameCount(48_000) // 1s at 48kHz
        for _ in 0..<2 {
            recorder.writeMicBuffer(makeSineBuffer(sampleRate: 48_000, frameCount: frames))
        }

        // The kill: read the bytes on disk with the recorder still holding the
        // file open — no close, no header patch.
        let file = try AVAudioFile(forReading: micTrack)
        XCTAssertEqual(file.length, Int64(frames) * 2, "the killed track must read back whole")
        XCTAssertGreaterThan(file.processingFormat.sampleRate, 0)
    }

    /// A finalize dropped by its timeout resumes long after a later meeting
    /// armed the recorder for itself. Every operation names its meeting, so the
    /// stale one merges nothing and — the part that would be silent — closes
    /// nothing: the running recording keeps writing.
    func testStaleFinalizeLeavesTheRunningMeetingAlone() async throws {
        let recorder = makeRecorder()

        // The later meeting takes the recorder.
        let secondDir = audioDirectory(of: "session_2")
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        recorder.startSession(id: "session_2", trackDirectory: secondDir)

        let frames = AVAudioFrameCount(4_800)
        recorder.writeMicBuffer(makeSineBuffer(sampleRate: 48_000, frameCount: frames))

        // The earlier meeting's finalize, arriving now.
        await recorder.exportMerged(for: sessionID)
        await recorder.finishTracks(for: sessionID)

        recorder.writeMicBuffer(makeSineBuffer(sampleRate: 48_000, frameCount: frames))
        await recorder.finishTracks(for: "session_2")

        let mic = try AVAudioFile(forReading: BatchAudioStash.micURL(in: secondDir))
        XCTAssertEqual(
            mic.length, Int64(frames) * 2,
            "a stale finalize must not close the running meeting's track"
        )
        XCTAssertEqual(m4aFiles().count, 0, "and must not export another meeting's audio")
    }

    /// The known re-entry path (`confirmDownloadAndStart` continuing a paused
    /// session, #153) must not restart the recorder over its own files: the
    /// destination is fixed per meeting now, so a second arm would truncate
    /// everything recorded so far.
    func testRearmingTheSameMeetingKeepsTheRecording() async throws {
        let recorder = makeRecorder()
        let frames = AVAudioFrameCount(4_800)
        recorder.writeMicBuffer(makeSineBuffer(sampleRate: 48_000, frameCount: frames))

        recorder.startSession(id: sessionID, trackDirectory: trackDir)
        recorder.writeMicBuffer(makeSineBuffer(sampleRate: 48_000, frameCount: frames))

        await recorder.finishTracks(for: sessionID)
        let mic = try AVAudioFile(forReading: micTrack)
        XCTAssertEqual(mic.length, Int64(frames) * 2, "the re-arm must not truncate the track")
    }

    func testMergeWithRateMismatchProducesCorrectDuration() async {
        // Simulate the real bug: system audio IO proc delivers at half the declared rate.
        // 480 frames tagged as 48kHz, but arriving at the rate of 24kHz
        // (i.e., half as many buffers per second as expected).
        let recorder = makeRecorder()

        let durationSeconds = 4.0

        // Write mic audio at 24kHz for the full duration
        let micFrames = AVAudioFrameCount(24000 * durationSeconds)
        let micBuffer = makeSineBuffer(sampleRate: 24000, frameCount: micFrames)
        recorder.writeMicBuffer(micBuffer)

        // Write system audio: same number of frames as mic (simulating the bug),
        // but tagged as 48kHz. The wall-clock tracking in writeSysBuffer will
        // compute the effective rate and correct during merge.
        //
        // At 24kHz effective for 4 seconds = 96,000 frames.
        // These are tagged as 48kHz, so without correction they'd be 2 seconds.
        let sysFramesPerBuffer: AVAudioFrameCount = 480
        let totalSysFrames = Int(24000 * durationSeconds) // same count as mic
        let numSysBuffers = totalSysFrames / Int(sysFramesPerBuffer)

        for _ in 0..<numSysBuffers {
            let buffer = makeSineBuffer(
                sampleRate: 48000, // declared rate (what the tap reports)
                frameCount: sysFramesPerBuffer
            )
            recorder.writeSysBuffer(buffer)
        }

        await recorder.exportMerged(for: sessionID)

        // Check the output file duration
        let outputs = m4aFiles()
        XCTAssertEqual(outputs.count, 1)

        guard let outputURL = outputs.first else { return }
        let outputFile = try? AVAudioFile(forReading: outputURL)
        guard let outputFile else {
            XCTFail("Could not read output file")
            return
        }

        let outputDuration = Double(outputFile.length) / outputFile.processingFormat.sampleRate

        // Without the fix, output would be ~2s (sys audio at declared 48kHz).
        // With the fix, sys audio is resampled from effective rate, so output ≈ 4s.
        // Allow 0.5s tolerance for AAC encoding padding.
        XCTAssertGreaterThan(outputDuration, durationSeconds - 0.5,
            "Output duration \(outputDuration)s is too short — rate correction may not be working")
        XCTAssertLessThan(outputDuration, durationSeconds + 1.0,
            "Output duration \(outputDuration)s is unexpectedly long")
    }

    func testMergeWithMatchingRatesDoesNotResample() async {
        // When declared and effective rates match, no resampling override should happen.
        let recorder = makeRecorder()

        let durationSeconds = 2.0

        // Mic at 48kHz
        let micFrames = AVAudioFrameCount(48000 * durationSeconds)
        let micBuffer = makeSineBuffer(sampleRate: 48000, frameCount: micFrames)
        recorder.writeMicBuffer(micBuffer)

        // System at 48kHz, matching rate (no mismatch)
        let sysFrames = AVAudioFrameCount(48000 * durationSeconds)
        let sysBuffer = makeSineBuffer(sampleRate: 48000, frameCount: sysFrames)
        recorder.writeSysBuffer(sysBuffer)

        await recorder.exportMerged(for: sessionID)

        let outputs = m4aFiles()
        XCTAssertEqual(outputs.count, 1)

        guard let outputURL = outputs.first,
              let outputFile = try? AVAudioFile(forReading: outputURL) else {
            XCTFail("Could not read output file")
            return
        }

        let outputDuration = Double(outputFile.length) / outputFile.processingFormat.sampleRate
        // Should be approximately 2 seconds
        XCTAssertGreaterThan(outputDuration, durationSeconds - 0.5)
        XCTAssertLessThan(outputDuration, durationSeconds + 0.5)
    }

    func testSysEffectiveRateTracking() async {
        // Verify that writeSysBuffer tracks timing anchors correctly.
        let recorder = makeRecorder()

        let buffer = makeSineBuffer(sampleRate: 48000, frameCount: 480)

        // Write several buffers
        for _ in 0..<100 {
            recorder.writeSysBuffer(buffer)
        }

        await recorder.finishTracks(for: sessionID)
        let anchors = persistedMeta()
        XCTAssertNotNil(anchors?.sysStartDate, "sysStartDate should be set after writes")
        XCTAssertEqual(anchors?.sysAnchors.count, 1, "Should have exactly one start anchor")
        XCTAssertEqual(anchors?.sysAnchors.first?.frame, 0, "Start anchor should be at frame 0")
    }

    // MARK: - recordingSaved is latched, once per recording (#82)

    /// Occurrences, not slots (#149): the latch these tests guard is about how
    /// many times the event happened, and repeats fold into one record.
    private func recordingSavedCount() -> Int {
        DiagStore.shared.recent(DiagStore.capacity)
            .filter { $0.event.caseName == "recordingSaved" }
            .occurrences
    }

    /// Block the meeting's track paths so `AVAudioFile(forWriting:)` throws,
    /// driving the per-buffer failure branch. A directory where a file is
    /// expected is enough to make AVAudioFile throw.
    private func blockTrackPaths() {
        for url in [micTrack, sysTrack] {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// The real R1 regression: the failure site sits inside
    /// `if micFile == nil { … } catch { record; return }`, which the buffer path
    /// re-enters on EVERY audio callback. Unlatched, 40 buffers = 40 events, and a
    /// real recording delivers them at buffer rate — evicting the whole 2000-event
    /// ring within seconds.
    func testPerBufferFileCreationFailureRecordsExactlyOneEvent() {
        blockTrackPaths()

        let recorder = makeRecorder()
        let before = recordingSavedCount()

        let buffer = makeSineBuffer(sampleRate: 48_000, frameCount: 512)
        for _ in 0..<40 {
            recorder.writeMicBuffer(buffer)
        }

        let delta = recordingSavedCount() - before
        XCTAssertEqual(delta, 1, "40 failing buffers must record exactly one recordingSaved, got \(delta)")
    }

    /// The failure sites live inside `if micFile == nil { … } catch { record; return }`,
    /// which the buffer path re-enters on every audio callback. Unlatched, one dead
    /// output file would evict all 2000 prior events within seconds. An export
    /// of an empty session drives the same latched helper end to end.
    func testRecordingSavedIsEmittedAtMostOncePerSession() async {
        let recorder = AudioRecorder(outputDirectory: outputDir)
        let before = recordingSavedCount()

        recorder.startSession(id: sessionID, trackDirectory: trackDir)
        await recorder.exportMerged(for: sessionID)
        let afterFirst = recordingSavedCount()
        XCTAssertEqual(afterFirst - before, 1, "an empty session records exactly one outcome")

        // Second finalize on the finished session must add nothing.
        await recorder.finishTracks(for: sessionID)
        await recorder.exportMerged(for: sessionID)
        XCTAssertEqual(recordingSavedCount(), afterFirst, "a finished session records no further outcome")
    }

    /// `startSession` re-arms the latch, so the next recording gets its own event.
    func testLatchResetsPerSession() async {
        let recorder = AudioRecorder(outputDirectory: outputDir)
        let before = recordingSavedCount()

        recorder.startSession(id: sessionID, trackDirectory: trackDir)
        await recorder.exportMerged(for: sessionID)
        await recorder.finishTracks(for: sessionID)
        recorder.startSession(id: "session_2", trackDirectory: audioDirectory(of: "session_2"))
        await recorder.exportMerged(for: "session_2")

        XCTAssertEqual(recordingSavedCount() - before, 2, "two sessions, two outcomes")
    }

    // MARK: - Capture-gap anchors (#128)

    /// A dead tap writes no frames while wall time keeps moving: 10s of wall
    /// time against 1s of audio is a gap; normal jitter around real-time
    /// delivery is not.
    func testIsCaptureGapDetectsOutage() {
        XCTAssertTrue(AudioRecorder.isCaptureGap(
            frameDelta: 48_000, sampleRate: 48_000, wallDelta: 10.0
        ), "10s wall for 1s of audio is an outage")
        XCTAssertFalse(AudioRecorder.isCaptureGap(
            frameDelta: 48_000, sampleRate: 48_000, wallDelta: 1.5
        ), "sub-threshold jitter is not an outage")
        XCTAssertFalse(AudioRecorder.isCaptureGap(
            frameDelta: 480, sampleRate: 0, wallDelta: 10.0
        ), "degenerate sample rate never triggers")
        XCTAssertTrue(AudioRecorder.isCaptureGap(
            frameDelta: 0, sampleRate: 48_000, wallDelta: 3.0
        ), "no frames written while wall time passed is an outage — the resume-after-failed-writes shape")
    }

    /// Failure exits must leave gap tracking untouched: with the output path
    /// blocked no write ever succeeds, so no start date, no end tracking, and
    /// no anchors. The old code advanced end-frame/date tracking before the
    /// failure exits, skewing the frame delta and (under persistent failure)
    /// spamming anchors on every buffer.
    func testFailingWritesLeaveAnchorTrackingUntouched() async {
        blockTrackPaths()

        let recorder = makeRecorder()

        let buffer = makeSineBuffer(sampleRate: 48_000, frameCount: 512)
        for _ in 0..<40 {
            recorder.writeMicBuffer(buffer)
            recorder.writeSysBuffer(buffer)
        }

        // A track's first successful write is also its first anchor, so an
        // empty pair is "no start date, no gap anchors, nothing tracked".
        XCTAssertTrue(recorder.micAnchors.isEmpty, "failed writes must not append anchors")
        XCTAssertTrue(recorder.sysAnchors.isEmpty, "failed writes must not append anchors")

        await recorder.finishTracks(for: sessionID)
        XCTAssertNil(persistedMeta(), "and nothing of them may reach disk")
    }

    // MARK: - Pause fill (#153)

    /// Close the recorder's handles and read the finished tracks back from the
    /// meeting they were recorded into.
    ///
    /// A track that never received a buffer opened no file, which is the shape
    /// of every pause test that drives one leg only. Every production consumer
    /// checks existence before opening (`AudioRecorder.mergeAndEncode`,
    /// `SessionRepository.batchAudioURLs`); this reader does the same, so a
    /// silent track reads back as `nil` rather than as an open failure.
    private func sealAndRead(
        _ recorder: AudioRecorder
    ) async throws -> (mic: AVAudioFile?, sys: AVAudioFile?) {
        await recorder.finishTracks(for: sessionID)
        func read(_ url: URL) throws -> AVAudioFile? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try AVAudioFile(forReading: url)
        }
        return (mic: try read(micTrack), sys: try read(sysTrack))
    }

    /// The invariant the whole pause design rests on: after a resume, each
    /// track's frame count has advanced by its own wall-clock gap. It is what
    /// keeps `testMergeWithMatchingRatesDoesNotResample` above true for a paused
    /// meeting — see `docs/features/meeting-pause-resume.md` for why an unfilled
    /// gap silently stretches the system track.
    ///
    /// Second assertion, same run: the fill also has to make the pause
    /// invisible to capture-gap detection (#128). Frame delta now matches wall
    /// delta, so no resume-anchor is appended — a real outage still gets one.
    func testPauseIsFilledWithSilenceAndAppendsNoGapAnchor() async throws {
        let recorder = makeRecorder()

        let rate: Double = 48_000
        let frames = AVAudioFrameCount(4_800) // 0.1s
        recorder.writeMicBuffer(makeSineBuffer(sampleRate: rate, frameCount: frames))
        recorder.writeSysBuffer(makeSineBuffer(sampleRate: rate, frameCount: frames))

        // Longer than `captureGapThreshold` (2s), so an unfilled gap would be
        // detected as an outage and the anchor assertion would discriminate.
        let pause: TimeInterval = 2.2
        try await Task.sleep(for: .seconds(pause))
        recorder.noteResumedFromPause()

        recorder.writeMicBuffer(makeSineBuffer(sampleRate: rate, frameCount: frames))
        recorder.writeSysBuffer(makeSineBuffer(sampleRate: rate, frameCount: frames))

        let files = try await sealAndRead(recorder)
        let anchors = persistedMeta()
        XCTAssertEqual(
            anchors?.micAnchors.count, 1,
            "filled silence keeps frame delta in step with wall time — no gap anchor is due"
        )
        XCTAssertEqual(anchors?.sysAnchors.count, 1)

        for file in [files.mic, files.sys].compactMap({ $0 }) {
            let expected = Double(frames) * 2 + pause * file.processingFormat.sampleRate
            XCTAssertEqual(
                Double(file.length), expected,
                accuracy: file.processingFormat.sampleRate * 0.35,
                "the track must carry \(pause)s of silence for the pause"
            )
        }
    }

    /// Each track fills to its *own* first buffer back, not to a shared clock:
    /// the mic and the system tap come back at different instants, and neither
    /// may inherit the other's bring-up latency.
    func testEachTrackFillsItsOwnGap() async throws {
        let recorder = makeRecorder()

        let rate: Double = 48_000
        let frames = AVAudioFrameCount(4_800)
        recorder.writeMicBuffer(makeSineBuffer(sampleRate: rate, frameCount: frames))
        recorder.writeSysBuffer(makeSineBuffer(sampleRate: rate, frameCount: frames))

        try await Task.sleep(for: .milliseconds(400))
        recorder.noteResumedFromPause()

        // The mic is back now; the system tap takes another 600ms.
        recorder.writeMicBuffer(makeSineBuffer(sampleRate: rate, frameCount: frames))
        try await Task.sleep(for: .milliseconds(600))
        recorder.writeSysBuffer(makeSineBuffer(sampleRate: rate, frameCount: frames))

        let files = try await sealAndRead(recorder)
        guard let mic = files.mic, let sys = files.sys else {
            XCTFail("both tracks must exist")
            return
        }
        XCTAssertEqual(Double(mic.length), Double(frames) * 2 + 0.4 * rate,
                       accuracy: rate * 0.2, "mic fills its own ~0.4s gap")
        XCTAssertEqual(Double(sys.length), Double(frames) * 2 + 1.0 * rate,
                       accuracy: rate * 0.2, "system tap fills its own ~1.0s gap")
        XCTAssertGreaterThan(sys.length, mic.length,
                             "the later-returning track fills the longer gap")
    }

    /// Two pauses with no audio in between need no accounting: the gap is
    /// always measured from the last write that carried real audio, so the
    /// second fill covers the whole span.
    func testSecondPauseBeforeAnyAudioStillFillsTheWholeGap() async throws {
        let recorder = makeRecorder()

        let rate: Double = 48_000
        let frames = AVAudioFrameCount(4_800)
        recorder.writeMicBuffer(makeSineBuffer(sampleRate: rate, frameCount: frames))

        try await Task.sleep(for: .milliseconds(300))
        recorder.noteResumedFromPause()  // resume 1 — no buffer arrives
        try await Task.sleep(for: .milliseconds(300))
        recorder.noteResumedFromPause()  // resume 2
        recorder.writeMicBuffer(makeSineBuffer(sampleRate: rate, frameCount: frames))

        let files = try await sealAndRead(recorder)
        guard let mic = files.mic else {
            XCTFail("mic file missing")
            return
        }
        XCTAssertEqual(Double(mic.length), Double(frames) * 2 + 0.6 * rate,
                       accuracy: rate * 0.2,
                       "the fill spans both pauses, not just the last one")
    }

    /// A track whose first buffer arrives only after the pause has no earlier
    /// audio to stay aligned with — its own start date is the truth. Leading
    /// silence there would push the whole track late by the pause.
    func testPauseBeforeATrackHasAudioAddsNoLeadingSilence() async throws {
        let recorder = makeRecorder()

        recorder.noteResumedFromPause()

        let frames = AVAudioFrameCount(4_800)
        recorder.writeMicBuffer(makeSineBuffer(sampleRate: 48_000, frameCount: frames))

        let files = try await sealAndRead(recorder)
        XCTAssertEqual(files.mic?.length, Int64(frames),
                       "no silence may precede a track's first audio")
    }

    /// Continuous back-to-back writes must keep exactly one anchor per track —
    /// the first-write one. The gap path stays dormant without an outage.
    func testContinuousWritesAddNoExtraAnchors() async {
        let recorder = makeRecorder()

        let buffer = makeSineBuffer(sampleRate: 48_000, frameCount: 4800)
        for _ in 0..<20 {
            recorder.writeMicBuffer(buffer)
            recorder.writeSysBuffer(buffer)
        }

        await recorder.finishTracks(for: sessionID)
        let anchors = persistedMeta()
        XCTAssertEqual(anchors?.micAnchors.count, 1)
        XCTAssertEqual(anchors?.sysAnchors.count, 1)
    }

}
