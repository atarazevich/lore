import Foundation
import Observation
import os

private let healLog = Logger(subsystem: "com.lore.app", category: "TranscriptHealer")

/// The transcript self-healing engine (#166). The meeting pane only ever
/// shows the transcript, "Preparing the transcript…" backed by a live job,
/// or the single no-transcript sentence — so every dispatch into
/// `BatchTranscriptionEngine` goes through this class's one serialized queue,
/// and the app repairs transcripts itself instead of presenting failures:
///
/// - **End of meeting** (#109): the whole-audio pass jumps the queue.
/// - **Launch sweep**: an orphaned per-track stash is an interrupted job —
///   it resumes; a stash beside a final transcript is a completed job whose
///   cleanup was killed — the stash is cleaned. No stored "processing" claim
///   survives without a live job behind it.
/// - **Open summons a job**: opening a meeting with no readable transcript
///   while audio exists starts a fresh attempt — the Preparing face is live
///   by construction, only ever seen with work running behind it.
/// - **Quiet bounded retries**: a failed pass retries a few times per
///   launch, on the app's own schedule; failures never surface as states.
/// - **Preemption is not failure**: a recording start suspends the queue and
///   re-queues the running job without charging its retry budget; the job
///   runs after the meeting ends.
///
/// Speaker-collapse policy (#129, resolved by policy — never ask): repairs
/// prefer the per-track stash (keeps You/Them via timing anchors); the
/// merged-file pass runs only when the stash is gone. On a damaged or absent
/// transcript there is no separation left to preserve, and a transcript with
/// one speaker label beats no transcript.
@MainActor
@Observable
final class TranscriptHealer {

    /// One queued unit of work. `importURL` is set only for a user-picked
    /// audio import; every other job resolves its own source from the
    /// session's stash / audio copy / notes-folder export at run time. The
    /// import's timestamp anchor is not carried here — the runner reads the
    /// session's stored start, which the import flow set from the same date.
    struct Job: Equatable, Sendable {
        let sessionID: String
        var importURL: URL? = nil
    }

    /// What one run of a job produced. Reported by the injected runner so
    /// tests can drive the queue without touching the ASR model.
    enum RunResult: Equatable, Sendable {
        /// A readable transcript is on disk after the pass.
        case repaired
        /// The pass completed but the session still has no text to show
        /// (no speech in the audio). Nothing left to try.
        case empty
        /// Nothing to run from — no stash, no merged audio.
        case noSource
        case failed
        /// The run was cancelled (a recording start preempted it).
        case cancelled
    }

    /// Runs one job to completion. Production wires this to
    /// `BatchTranscriptionEngine` (`engineRunner`); tests inject stubs.
    typealias JobRunner = @MainActor (Job) async -> RunResult

    // MARK: - Published state

    /// Sessions with pending work: being assessed, queued, running, or
    /// waiting on a scheduled retry. The pane's Preparing face and the row's
    /// "preparing…" slot derive from this — durable per-session knowledge,
    /// never the engine's transient status alone.
    private(set) var activeSessionIDs: Set<String> = []

    /// Sessions assessed this launch as having nothing to show and nothing
    /// to make it from. In-memory only — rows use it to suppress a count the
    /// index promises but the transcript cannot honor (ui-language rule 8),
    /// and re-opens re-assess silently instead of flashing Preparing.
    private var unavailableSessionIDs: Set<String> = []

    /// Bumped after a job replaces a transcript; `lastRepairedSessionID`
    /// names it. The review UI reloads on this, not on engine status —
    /// which is reset between queued jobs and can be missed.
    private(set) var repairGeneration = 0
    private(set) var lastRepairedSessionID: String?

    // MARK: - Internals

    private var queue: [Job] = []
    /// The running job plus its dispatch token: the same Job value can be
    /// dispatched twice (suspend re-queues it), so completions are matched
    /// by token, never by value — a stale run can neither settle nor
    /// duplicate its successor.
    private var current: (job: Job, token: Int)?
    private var nextDispatchToken = 0
    private var suspended = false
    /// Per-session, per-launch retry budgets. Cleared on success and on a
    /// fresh user signal (opening the meeting).
    private var budgets: [String: RetryBudget] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]

    private let repository: SessionRepository
    private let liveSessionID: @MainActor () -> String?
    /// Post-repair side effects: summary reset (#109), history reload,
    /// enrichment (#107). One shared path, so a repair completed by the
    /// sweep or a retry enriches exactly like one completed by the
    /// end-of-meeting pass.
    private let onRepaired: @MainActor (String) async -> Void
    /// The retry budget is spent and the transcript was not replaced. The
    /// meeting keeps whatever text it has — which is still worth enriching
    /// now (#107) instead of waiting for the next launch sweep, preserving
    /// the old failed-batch behavior.
    private let onGaveUp: @MainActor (String) async -> Void
    private let runJob: JobRunner
    private let cancelRun: @MainActor () async -> Void
    private let retryLimit: Int
    private let retryDelay: Duration

    init(
        repository: SessionRepository,
        liveSessionID: @escaping @MainActor () -> String?,
        onRepaired: @escaping @MainActor (String) async -> Void,
        onGaveUp: @escaping @MainActor (String) async -> Void = { _ in },
        runJob: @escaping JobRunner,
        cancelRun: @escaping @MainActor () async -> Void,
        retryLimit: Int = 3,
        retryDelay: Duration = .seconds(30)
    ) {
        self.repository = repository
        self.liveSessionID = liveSessionID
        self.onRepaired = onRepaired
        self.onGaveUp = onGaveUp
        self.runJob = runJob
        self.cancelRun = cancelRun
        self.retryLimit = retryLimit
        self.retryDelay = retryDelay
    }

    // MARK: - Queries

    /// Work is pending or running for this session — the Preparing face.
    func isBusy(_ sessionID: String) -> Bool {
        activeSessionIDs.contains(sessionID)
    }

    /// Assessed this launch: nothing to show, nothing to make it from.
    func isUnavailable(_ sessionID: String) -> Bool {
        unavailableSessionIDs.contains(sessionID)
    }

    // MARK: - Entry points

    /// End-of-meeting whole-audio pass (#109): jumps the queue — this is the
    /// meeting the user is most likely to open next.
    func enqueueMeetingBatch(sessionID: String) {
        budgets[sessionID] = nil
        enqueue(Job(sessionID: sessionID), reason: .meetingEnded, front: true)
    }

    /// User-picked audio import. Retries of a failed import re-resolve from
    /// the session's own audio copy instead of the original URL, which may
    /// be gone by then.
    func enqueueImport(sessionID: String, url: URL) {
        enqueue(Job(sessionID: sessionID, importURL: url), reason: .importRequested)
    }

    /// Open summons a job: called when a meeting is opened and its loaded
    /// transcript is empty. A user open is a fresh signal — the retry budget
    /// starts over, so the app always makes a fresh attempt while audio
    /// exists. Never fires for the live session (it has no stash and no
    /// final transcript by construction), and never double-dispatches
    /// against a job already queued or running for the session.
    func ensure(sessionID: String) {
        guard sessionID != liveSessionID() else { return }
        // A user open is a fresh signal: the budget starts over even while a
        // retry cycle is already pending — the attempts that follow this
        // open get the full allowance, so a spent budget can never leave the
        // pane claiming "no audio" over audio that exists.
        budgets[sessionID] = nil
        guard !activeSessionIDs.contains(sessionID) else { return }
        // A session already assessed unavailable re-checks silently — the
        // sentence stays on screen instead of flashing Preparing on every
        // reopen. First-time assessments show Preparing, honestly: this
        // assessment task is the work behind the face.
        let wasUnavailable = unavailableSessionIDs.contains(sessionID)
        if !wasUnavailable { activeSessionIDs.insert(sessionID) }
        Task { [weak self] in
            guard let self else { return }
            let source = await self.repository.rebuildAudioSource(sessionID: sessionID)
            // A persisted no-speech verdict means a completed pass already
            // proved this audio yields nothing — running it again every
            // open would be ceremony, not repair.
            let noSpeech = await self.repository.sessionNoSpeech(sessionID: sessionID)
            guard self.activeSessionIDs.contains(sessionID) || wasUnavailable else { return }
            if source == nil || noSpeech {
                self.activeSessionIDs.remove(sessionID)
                self.unavailableSessionIDs.insert(sessionID)
                // Trace the first verdict only — reopening a settled meeting
                // re-checks silently and must not spam the ring.
                if !wasUnavailable {
                    DiagStore.record(.transcriptRepairSettled(outcome: .unavailable))
                }
            } else {
                self.enqueue(Job(sessionID: sessionID), reason: .openedMeeting)
            }
        }
    }

    // MARK: - Launch sweep

    /// One pass over every session at launch. Cheap evidence only — file
    /// presence and sizes; the full parse happens at open, where the load is
    /// already paid for.
    ///
    /// This replaces the old init-time `cleanupOrphanedBatchAudio`, which
    /// keyed on directory mtime and deleted recoverable stashes before
    /// anything could resume them. Here the stash is read as what it is:
    /// evidence of a promised whole-audio pass.
    func sweep() async {
        for session in await repository.listSessions() {
            guard session.id != liveSessionID() else { continue }

            let stash = await repository.batchAudioURLs(sessionID: session.id)
            if stash.mic != nil || stash.sys != nil {
                if session.hasFinalTranscript {
                    // The pass completed; the kill landed between the final
                    // write and the cleanup. Real evidence of "done".
                    await repository.cleanupBatchAudio(sessionID: session.id)
                } else {
                    enqueue(Job(sessionID: session.id), reason: .launchSweep)
                }
                continue
            }

            // No stash: a session with transcript bytes is healthy enough to
            // leave alone, and a persisted no-speech verdict means a
            // completed pass already proved the audio yields nothing — no
            // re-transcribing silence every launch. An empty one with
            // findable audio (killed import, damaged files) gets a job;
            // without audio it simply shows the sentence when opened.
            guard session.noSpeech != true else { continue }
            guard await !repository.hasTranscriptText(sessionID: session.id) else { continue }
            if await repository.rebuildAudioSource(sessionID: session.id) != nil {
                enqueue(Job(sessionID: session.id), reason: .launchSweep)
            }
        }
    }

    // MARK: - Recording preemption

    /// A recording is starting: stop dispatching, cancel the running pass,
    /// and put its job back at the head of the queue — uncharged. The model
    /// belongs to live capture now.
    func suspend() async {
        suspended = true
        if let (job, _) = current {
            current = nil
            queue.insert(job, at: 0)
        }
        await cancelRun()
    }

    /// The recording is over: dispatch continues.
    func resume() {
        suspended = false
        dispatchIfIdle()
    }

    // MARK: - Queue mechanics

    private func enqueue(_ job: Job, reason: DiagEvent.RepairReason, front: Bool = false) {
        guard current?.job.sessionID != job.sessionID,
              !queue.contains(where: { $0.sessionID == job.sessionID })
        else { return }
        activeSessionIDs.insert(job.sessionID)
        unavailableSessionIDs.remove(job.sessionID)
        if front {
            queue.insert(job, at: 0)
        } else {
            queue.append(job)
        }
        DiagStore.record(.transcriptRepairQueued(reason: reason))
        dispatchIfIdle()
    }

    private func dispatchIfIdle() {
        guard !suspended, current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        nextDispatchToken += 1
        let token = nextDispatchToken
        current = (job, token)
        Task { [weak self] in
            guard let self else { return }
            // Suspended between dispatch and here (a recording start): the
            // job was already re-queued by suspend(); run nothing.
            guard !self.suspended, self.current?.token == token else { return }
            let result = await self.runJob(job)
            self.settle(job: job, token: token, result: result)
        }
    }

    private func settle(job: Job, token: Int, result: RunResult) {
        // A stale token means this run was preempted — suspend() already
        // re-queued the job; the completion belongs to the cancelled run.
        guard current?.token == token else { return }
        current = nil

        switch result {
        case .repaired:
            activeSessionIDs.remove(job.sessionID)
            unavailableSessionIDs.remove(job.sessionID)
            budgets[job.sessionID] = nil
            lastRepairedSessionID = job.sessionID
            repairGeneration += 1
            DiagStore.record(.transcriptRepairSettled(outcome: .repaired))
            Task(priority: .utility) { [onRepaired, sessionID = job.sessionID] in
                await onRepaired(sessionID)
            }

        case .empty:
            // The pass ran to completion and verified there is nothing to
            // show — the runner persisted the no-speech verdict, so no
            // launch or open re-transcribes this silence.
            activeSessionIDs.remove(job.sessionID)
            unavailableSessionIDs.insert(job.sessionID)
            DiagStore.record(.transcriptRepairSettled(outcome: .unavailable))

        case .noSource:
            // Nothing to run from. "Unavailable" only when there is also
            // nothing to show — with live text present the meeting is
            // face 1 and keeps its count (rule 8 cuts both ways).
            activeSessionIDs.remove(job.sessionID)
            Task { [weak self, sessionID = job.sessionID] in
                guard let self,
                      await self.repository.loadTranscript(sessionID: sessionID).isEmpty
                else { return }
                self.unavailableSessionIDs.insert(sessionID)
                DiagStore.record(.transcriptRepairSettled(outcome: .unavailable))
            }

        case .failed:
            var budget = budgets[job.sessionID] ?? RetryBudget(limit: retryLimit)
            budget.noteFailure()
            budgets[job.sessionID] = budget
            DiagStore.record(.transcriptRepairSettled(outcome: .failed))
            if budget.allowsAttempt {
                scheduleRetry(job)
            } else {
                // Budget spent for this launch. The session shows whatever
                // it has — its live text, or (while it stays open) the
                // standing open re-summons a fresh cycle, so the sentence
                // can never claim "no audio" over audio that exists.
                activeSessionIDs.remove(job.sessionID)
                healLog.error("repair budget exhausted for \(job.sessionID, privacy: .private)")
                Task(priority: .utility) { [onGaveUp, sessionID = job.sessionID] in
                    await onGaveUp(sessionID)
                }
            }

        case .cancelled:
            // Cancelled without suspend() bookkeeping — treat like a
            // preemption and requeue quietly.
            queue.insert(job, at: 0)
        }

        dispatchIfIdle()
    }

    /// Quiet self-retry: the session stays active (work is still pending —
    /// this task is the job behind the Preparing face), and the next attempt
    /// re-resolves its source rather than replaying a stale import URL.
    private func scheduleRetry(_ job: Job) {
        let sessionID = job.sessionID
        retryTasks[sessionID]?.cancel()
        retryTasks[sessionID] = Task { [weak self, retryDelay] in
            try? await Task.sleep(for: retryDelay)
            guard let self, !Task.isCancelled else { return }
            self.retryTasks[sessionID] = nil
            // enqueue() dedupes against the queue and the running slot, both
            // of which this session left when its run failed — the retry
            // passes; the session merely re-enters activeSessionIDs it never
            // left.
            self.enqueue(Job(sessionID: sessionID), reason: .retry)
        }
    }

    // MARK: - Production runner

    /// The real job runner: resolves the audio source, drives
    /// `BatchTranscriptionEngine`, and reads the outcome off disk — a
    /// transcript that can be loaded is the only success that counts.
    static func engineRunner(
        engine: BatchTranscriptionEngine,
        repository: SessionRepository,
        notesDirectory: @escaping @MainActor () -> URL
    ) -> JobRunner {
        { job in
            if let url = job.importURL {
                // Anchor at the session's stored start — the import flow
                // created the session from the same file date it would have
                // passed here.
                let startedAt = await repository.sessionStartDate(sessionID: job.sessionID)
                await engine.importFile(
                    url: url,
                    sessionID: job.sessionID,
                    sessionRepository: repository,
                    startDate: startedAt
                )
            } else {
                guard let source = await repository.rebuildAudioSource(sessionID: job.sessionID) else {
                    return .noSource
                }
                switch source {
                case .tracks:
                    await engine.process(
                        sessionID: job.sessionID,
                        sessionRepository: repository,
                        notesDirectory: notesDirectory()
                    )
                case .file(let audioURL):
                    // Anchor at the session's real start — the merged export
                    // is written at meeting END, so its file date would
                    // shift every timestamp (#109).
                    let startedAt = await repository.sessionStartDate(sessionID: job.sessionID)
                    await engine.importFile(
                        url: audioURL,
                        sessionID: job.sessionID,
                        sessionRepository: repository,
                        startDate: startedAt
                    )
                }
            }

            let status = await engine.status
            // The healer owns the outcome from here; no stale terminal claim
            // may outlive the job (no-false-positives: live, not latched).
            await engine.acknowledgeCompletion()

            switch status {
            case .completed:
                if await !repository.loadTranscript(sessionID: job.sessionID).isEmpty {
                    return .repaired
                }
                // A completed pass with nothing to show is a verdict, not a
                // failure — persist it so no later launch or open burns an
                // ASR pass re-proving the same silence (#166).
                await repository.markSessionNoSpeech(sessionID: job.sessionID)
                return .empty
            case .cancelled, .idle:
                return .cancelled
            case .failed:
                return .failed
            case .loading, .transcribing:
                return .failed
            }
        }
    }
}
