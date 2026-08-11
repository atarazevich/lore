import XCTest
@testable import LoreKit

/// #166: the self-healing queue. Jobs are driven through a stub runner —
/// the engine's ASR passes are not under test here, the healing policy is:
/// sweep evidence, open-summons dedupe, preemption-without-charge, bounded
/// retries, and the settled per-session state the three pane faces derive
/// from.
@MainActor
final class TranscriptHealerTests: XCTestCase {

    // MARK: - Stub runner

    /// Records every job the healer dispatches; can block one run to model
    /// an in-flight engine pass.
    @MainActor
    private final class RunnerStub {
        var calls: [TranscriptHealer.Job] = []
        /// Results returned per call, in order; `.repaired` once exhausted.
        var results: [TranscriptHealer.RunResult] = []
        var blockNext = false
        var cancelCount = 0
        private var pending: CheckedContinuation<TranscriptHealer.RunResult, Never>?

        func run(_ job: TranscriptHealer.Job) async -> TranscriptHealer.RunResult {
            calls.append(job)
            if blockNext {
                blockNext = false
                return await withCheckedContinuation { pending = $0 }
            }
            return results.isEmpty ? .repaired : results.removeFirst()
        }

        func finishPending(_ result: TranscriptHealer.RunResult) {
            pending?.resume(returning: result)
            pending = nil
        }
    }

    private var rootDir: URL!
    private var repo: SessionRepository!
    private var stub: RunnerStub!
    private var repairedSessions: [String] = []
    private var liveID: String?

    override func setUp() async throws {
        rootDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LoreHealerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        repo = SessionRepository(rootDirectory: rootDir)
        stub = RunnerStub()
        repairedSessions = []
        liveID = nil
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootDir)
        rootDir = nil
        repo = nil
        stub = nil
    }

    private func makeHealer(retryLimit: Int = 3) -> TranscriptHealer {
        TranscriptHealer(
            repository: repo,
            liveSessionID: { [weak self] in self?.liveID },
            onRepaired: { [weak self] id in self?.repairedSessions.append(id) },
            runJob: { [stub] job in await stub!.run(job) },
            cancelRun: { [stub] in stub!.cancelCount += 1 },
            retryLimit: retryLimit,
            retryDelay: .milliseconds(1)
        )
    }

    private func seed(_ id: String, records: [SessionRecord]) async {
        await repo.seedSession(id: id, records: records, startedAt: Date())
    }

    /// Drops a dummy file into the session's audio/ directory. "mic.caf"
    /// models the per-track batch stash; "imported.m4a" a merged audio copy.
    private func writeSessionAudio(_ id: String, filename: String) {
        let audioDir = rootDir
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try? Data(filename.utf8).write(to: audioDir.appendingPathComponent(filename))
    }

    private func writeStash(_ id: String) { writeSessionAudio(id, filename: "mic.caf") }
    private func writeMergedAudio(_ id: String) { writeSessionAudio(id, filename: "imported.m4a") }

    private var record: SessionRecord {
        SessionRecord(speaker: .you, text: "Hello", timestamp: Date())
    }

    // MARK: - Launch sweep

    /// An orphaned stash (kill mid-batch) is an interrupted job — the sweep
    /// resumes it, and its completion runs the shared repaired path.
    func testSweepResumesOrphanedStashJob() async {
        await seed("session_orphan", records: [record])
        writeStash("session_orphan")
        let healer = makeHealer()

        await healer.sweep()
        await waitUntil { !healer.isBusy("session_orphan") && !self.repairedSessions.isEmpty }

        XCTAssertEqual(stub.calls.map(\.sessionID), ["session_orphan"])
        XCTAssertEqual(repairedSessions, ["session_orphan"])
        XCTAssertEqual(healer.repairGeneration, 1)
        XCTAssertEqual(healer.lastRepairedSessionID, "session_orphan")
    }

    /// A stash beside a final transcript is a pass that completed but was
    /// killed before cleanup — evidence-keyed cleanup, no re-run.
    func testSweepCleansStashWhenPassAlreadyCompleted() async {
        await seed("session_done", records: [record])
        await repo.saveFinalTranscript(sessionID: "session_done", records: [record])
        writeStash("session_done")
        let healer = makeHealer()

        await healer.sweep()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(stub.calls.isEmpty, "A completed pass must not re-run")
        let stash = await repo.batchAudioURLs(sessionID: "session_done")
        XCTAssertNil(stash.mic)
        XCTAssertNil(stash.sys)
    }

    /// An empty session with findable merged audio (a killed import) gets a
    /// repair job; an empty session with no audio is left alone — it shows
    /// the sentence when opened, nothing runs for it.
    func testSweepQueuesEmptySessionWithAudioOnly() async {
        await seed("session_killed_import", records: [])
        writeMergedAudio("session_killed_import")
        await seed("session_nothing", records: [])
        let healer = makeHealer()

        await healer.sweep()
        await waitUntil { !healer.isBusy("session_killed_import") }

        XCTAssertEqual(stub.calls.map(\.sessionID), ["session_killed_import"])
    }

    /// Healthy sessions — transcript bytes, no stash — cost the sweep
    /// nothing and never enter the queue.
    func testSweepLeavesHealthySessionsAlone() async {
        await seed("session_fine", records: [record])
        let healer = makeHealer()

        await healer.sweep()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(stub.calls.isEmpty)
    }

    /// The live session is excluded: it has a stash-less, still-open state
    /// the sweep has no business reading.
    func testSweepSkipsLiveSession() async {
        await seed("session_live", records: [record])
        writeStash("session_live")
        liveID = "session_live"
        let healer = makeHealer()

        await healer.sweep()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(stub.calls.isEmpty)
        let stash = await repo.batchAudioURLs(sessionID: "session_live")
        XCTAssertNotNil(stash.mic, "The live session's stash must survive the sweep")
    }

    // MARK: - Open summons a job

    /// Opening an empty meeting with no audio settles it as unavailable —
    /// face 3 — without ever dispatching a run.
    func testEnsureMarksUnavailableWhenNoAudio() async {
        await seed("session_bare", records: [])
        let healer = makeHealer()

        healer.ensure(sessionID: "session_bare")
        await waitUntil { healer.isUnavailable("session_bare") }

        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertFalse(healer.isBusy("session_bare"))
    }

    /// Risk 5: an open must not double-dispatch against a job already queued
    /// or running for the session (the just-kicked end-of-meeting batch).
    func testEnsureDedupesAgainstRunningJob() async {
        await seed("session_busy", records: [record])
        writeStash("session_busy")
        let healer = makeHealer()

        stub.blockNext = true
        healer.enqueueMeetingBatch(sessionID: "session_busy")
        await waitUntil { self.stub.calls.count == 1 }

        healer.ensure(sessionID: "session_busy")
        try? await Task.sleep(for: .milliseconds(50))

        stub.finishPending(.repaired)
        await waitUntil { !healer.isBusy("session_busy") }

        XCTAssertEqual(stub.calls.count, 1, "The open must not dispatch a second run")
    }

    /// The live session never gets an open-summoned job.
    func testEnsureSkipsLiveSession() async {
        await seed("session_live2", records: [])
        writeMergedAudio("session_live2")
        liveID = "session_live2"
        let healer = makeHealer()

        healer.ensure(sessionID: "session_live2")
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertFalse(healer.isBusy("session_live2"))
    }

    // MARK: - Preemption (risk 6)

    /// A recording start suspends the queue and re-queues the running job
    /// WITHOUT charging its retry budget; it runs again after resume.
    func testSuspendRequeuesRunningJobWithoutFailureCharge() async {
        await seed("session_preempted", records: [record])
        writeStash("session_preempted")
        let healer = makeHealer(retryLimit: 1)

        stub.blockNext = true
        healer.enqueueMeetingBatch(sessionID: "session_preempted")
        await waitUntil { self.stub.calls.count == 1 }

        await healer.suspend()
        XCTAssertEqual(stub.cancelCount, 1)
        stub.finishPending(.cancelled)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(stub.calls.count, 1, "Nothing runs while suspended")
        XCTAssertTrue(healer.isBusy("session_preempted"), "The preempted job stays pending")

        healer.resume()
        await waitUntil { !healer.isBusy("session_preempted") }

        // With retryLimit 1, a charged preemption would have exhausted the
        // budget — the second, successful run proves it was not charged.
        XCTAssertEqual(stub.calls.count, 2)
        XCTAssertEqual(healer.repairGeneration, 1)
    }

    // MARK: - Bounded retries

    /// Failures retry quietly, exactly `retryLimit` runs per launch, then
    /// the session leaves the active set — no state surfaces, and the next
    /// open or launch starts a fresh cycle.
    func testFailedRunsRetryBoundedTimes() async {
        await seed("session_cursed", records: [record])
        writeStash("session_cursed")
        let healer = makeHealer(retryLimit: 3)

        stub.results = [.failed, .failed, .failed, .failed, .failed]
        healer.enqueueMeetingBatch(sessionID: "session_cursed")
        await waitUntil { !healer.isBusy("session_cursed") }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(stub.calls.count, 3, "Exactly retryLimit runs, then quiet")
        XCTAssertEqual(healer.repairGeneration, 0)
        XCTAssertTrue(repairedSessions.isEmpty)
    }

    /// A pass that completes with nothing to show (no speech) settles the
    /// session as unavailable — nothing left to try, no retry burn.
    func testEmptyResultSettlesUnavailable() async {
        await seed("session_silent", records: [])
        writeMergedAudio("session_silent")
        let healer = makeHealer()

        stub.results = [.empty]
        healer.ensure(sessionID: "session_silent")
        await waitUntil { healer.isUnavailable("session_silent") }

        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertFalse(healer.isBusy("session_silent"))
    }

    /// C2: a no-source verdict for a session that still has live text must
    /// not mark it unavailable — the meeting is face 1 with its count; the
    /// sentence and the empty row slot belong only to meetings with nothing
    /// to show.
    func testNoSourceWithLiveTextDoesNotMarkUnavailable() async {
        await seed("session_texty", records: [record])
        let healer = makeHealer()

        stub.results = [.noSource]
        healer.enqueueMeetingBatch(sessionID: "session_texty")
        await waitUntil { !healer.isBusy("session_texty") }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(healer.isUnavailable("session_texty"))
    }

    /// C1/C7: a user open is a fresh signal past a spent budget — ensure()
    /// resets it and queues a fresh attempt, so face 3 is unreachable while
    /// audio exists and the meeting is open.
    func testEnsureResetsSpentBudgetAndRetries() async {
        await seed("session_reopened", records: [])
        writeStash("session_reopened")
        let healer = makeHealer(retryLimit: 1)

        stub.results = [.failed]
        healer.enqueueMeetingBatch(sessionID: "session_reopened")
        await waitUntil { !healer.isBusy("session_reopened") }
        XCTAssertEqual(stub.calls.count, 1, "Budget of 1 spent")

        healer.ensure(sessionID: "session_reopened")
        await waitUntil { !healer.isBusy("session_reopened") && healer.repairGeneration == 1 }

        XCTAssertEqual(stub.calls.count, 2, "The open must start a fresh cycle")
        XCTAssertFalse(healer.isUnavailable("session_reopened"))
    }

    /// C9: the persisted no-speech verdict — a completed pass proved the
    /// audio yields nothing — stops both the sweep and the open-summons from
    /// re-transcribing the same silence.
    func testPersistedNoSpeechVerdictSkipsSweepAndEnsure() async {
        await seed("session_proved_silent", records: [])
        writeMergedAudio("session_proved_silent")
        await repo.markSessionNoSpeech(sessionID: "session_proved_silent")
        let healer = makeHealer()

        await healer.sweep()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(stub.calls.isEmpty, "The sweep must not re-run a proved-silent pass")

        healer.ensure(sessionID: "session_proved_silent")
        await waitUntil { healer.isUnavailable("session_proved_silent") }
        XCTAssertTrue(stub.calls.isEmpty, "An open settles unavailable without a run")
    }
}
