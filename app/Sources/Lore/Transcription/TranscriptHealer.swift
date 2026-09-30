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
/// - **The merged recording is a job too** (#290): a meeting is listed the
///   moment it ends, and its m4a export runs here, one job at a time, after
///   its transcript job and before the speaker pass that removes its tracks.
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
        /// A transcript job, the merged recording's export (#290), or the
        /// speaker pass that follows a saved transcript (#269) — queued in
        /// this order, so a meeting's export reads its tracks after its
        /// transcript job and before the speaker pass removes them.
        enum Kind: Hashable, Comparable, Sendable {
            case transcript
            case export
            case speakers
        }

        let sessionID: String
        var importURL: URL? = nil
        var kind: Kind = .transcript

        /// What a job is the same job as: one session, one kind.
        var key: Key { Key(sessionID: sessionID, kind: kind) }

        struct Key: Hashable {
            let sessionID: String
            let kind: Kind
        }
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

    /// Bumped when a meeting's speaker pass settles for good — its map
    /// written, or given up (#269). Its Markdown mirror has been rewritten by
    /// then; the review reloads the open meeting's speakers on every bump, so
    /// settles that land together miss nothing.
    private(set) var speakersGeneration = 0

    /// Bumped when a meeting's merged recording lands in the notes folder
    /// (#290) — after the meeting was listed and perhaps opened. The review
    /// looks for the open meeting's recording again on every bump.
    private(set) var exportGeneration = 0

    // MARK: - Internals

    private var queue: [Job] = []
    /// The running job plus its dispatch token: the same Job value can be
    /// dispatched twice (suspend re-queues it), so completions are matched
    /// by token, never by value — a stale run can neither settle nor
    /// duplicate its successor.
    private var current: (job: Job, token: Int, task: Task<Void, Never>)?
    private var nextDispatchToken = 0
    private var suspended = false
    /// Per-session, per-launch retry budgets. Cleared on success and on a
    /// fresh user signal (opening the meeting).
    private var budgets: [String: RetryBudget] = [:]
    private var retryTasks: [Job.Key: Task<Void, Never>] = [:]

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
    /// A speaker pass settled, its mirror rewritten (#269): the summary
    /// follows the lines the map gives.
    private let onSpeakersSettled: @MainActor (String) async -> Void
    private let runJob: JobRunner
    private let cancelRun: @MainActor () async -> Void
    /// The speaker pass (#269), run by meeting after its transcript job. Nil
    /// runs none, and a finished transcript's tracks are cleaned as before.
    typealias SpeakerRunner = @Sendable (String) async -> SpeakerFinder.Outcome
    private let runSpeakers: SpeakerRunner?
    /// Speaker passes, and exports (#290), per meeting across launches — their
    /// own bound, not the transcript jobs'. One that crashes the app is not
    /// tried at every launch.
    static let attemptLimit = 3
    /// A model did not download this launch: no speaker pass runs until the next.
    private var speakersOffline = false
    /// The merged recording's export (#290): the closed tracks, placed by
    /// their meta, into an m4a. Replaceable so tests can hold one.
    typealias ExportRunner = @Sendable (_ tracks: URL, _ meta: BatchMeta, _ file: URL) async
        -> MeetingRecording.ExportResult
    private let runExport: ExportRunner
    /// The running export's meeting and its attempts before it (#290): a
    /// normal quit puts that count back (`willTerminate`), so only a failure
    /// or a crash spends an attempt.
    private let exportCharge = OSAllocatedUnfairLock<(sessionID: String, attempts: Int)?>(initialState: nil)
    /// The last speaker pass or export, cancelled or not (`inBackground`).
    private var lastBackgroundTask: Task<Void, Never>?
    /// The partial recordings a killed export left are removed once (`sweep`).
    private var sweptPartials = false
    private let retryLimit: Int
    private let retryDelay: Duration

    init(
        repository: SessionRepository,
        liveSessionID: @escaping @MainActor () -> String?,
        onRepaired: @escaping @MainActor (String) async -> Void,
        onSpeakersSettled: @escaping @MainActor (String) async -> Void = { _ in },
        onGaveUp: @escaping @MainActor (String) async -> Void = { _ in },
        runJob: @escaping JobRunner,
        cancelRun: @escaping @MainActor () async -> Void,
        retryLimit: Int = 3,
        retryDelay: Duration = .seconds(30),
        runSpeakers: SpeakerRunner? = nil,
        runExport: @escaping ExportRunner = { MeetingRecording.exportMerged(tracksIn: $0, meta: $1, to: $2) }
    ) {
        self.runSpeakers = runSpeakers
        self.runExport = runExport
        self.repository = repository
        self.liveSessionID = liveSessionID
        self.onRepaired = onRepaired
        self.onGaveUp = onGaveUp
        self.onSpeakersSettled = onSpeakersSettled
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

    /// A speaker pass is running for this meeting, or next in line for it —
    /// queued or waiting to retry (#269) — the review's "finding who
    /// spoke…". Not while the meeting's export is still to run (#290), which
    /// looks for no one; nor while the models are offline: then no pass runs
    /// this launch, and saying one does would be a false claim.
    func isFindingSpeakers(_ sessionID: String) -> Bool {
        let speakers = Job.Key(sessionID: sessionID, kind: .speakers)
        if current?.job.key == speakers { return true }
        guard !speakersOffline, !isPending(Job.Key(sessionID: sessionID, kind: .export)) else { return false }
        return isPending(speakers)
    }

    /// The job is running, queued, or waiting to retry.
    private func isPending(_ key: Job.Key) -> Bool {
        current?.job.key == key || queue.contains { $0.key == key } || retryTasks[key] != nil
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

    /// The meeting's merged recording, when "Save audio recording" asked for
    /// it (#290): queued behind its transcript job, ahead of its speaker pass.
    func enqueueExport(sessionID: String) {
        enqueue(Job(sessionID: sessionID, kind: .export))
    }

    /// User-picked audio import. Retries of a failed import re-resolve from
    /// the session's own audio copy instead of the original URL, which may
    /// be gone by then.
    func enqueueImport(sessionID: String, url: URL) {
        enqueue(Job(sessionID: sessionID, importURL: url), reason: .importRequested)
    }

    /// Open summons a job: called when a meeting is opened and its loaded
    /// transcript is empty (`opened`), and again whenever the open pane
    /// settles empty. Only the open is a fresh signal — the retry budget
    /// starts over once per open, so the app makes a fresh attempt while
    /// audio exists; a re-evaluation with the budget spent does nothing, so
    /// an open meeting whose passes keep failing gets the budget and no more.
    /// Never double-dispatches against a job already queued or running for
    /// the session.
    ///
    /// The live session is excluded by the guard below, and only by it: since
    /// #177 a recording meeting has a stash from its first buffer and no final
    /// transcript, which is exactly the shape this dispatches on.
    func ensure(sessionID: String, opened: Bool = false) {
        guard sessionID != liveSessionID() else { return }
        // An open is a fresh signal: the budget starts over even while a
        // retry cycle is already pending — the attempts that follow this
        // open get the full allowance.
        if opened {
            budgets[sessionID] = nil
        } else if budgets[sessionID]?.allowsAttempt == false {
            return
        }
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
        // What a killed export left beside the recordings (#290) — on the
        // first sweep only. The sweep runs again whenever the meetings view
        // mounts, when an export of this launch may be filling its partial;
        // the first runs before any meeting of this launch has ended.
        if !sweptPartials {
            sweptPartials = true
            await repository.removePartialExports()
        }
        var exports: [String] = []
        for session in await repository.listSessions() {
            guard session.id != liveSessionID() else { continue }

            // A merged recording a quit cut short (#290) is written again,
            // queued after every transcript job below, as at a meeting's end.
            // Its tracks stay for it: the removal a pass asked for meanwhile
            // is the export's to do, and nothing else reads them then.
            if let pending = await repository.pendingExport(sessionID: session.id) {
                exports.append(session.id)
                if pending.removeTracks { continue }
            }

            let stash = await repository.batchAudioURLs(sessionID: session.id)
            if stash.mic != nil || stash.sys != nil {
                if session.hasFinalTranscript,
                   await !repository.finalTranscript(sessionID: session.id).isEmpty {
                    // The transcript pass completed. What is left is the
                    // speaker pass's (#269), which deletes the tracks itself
                    // — or, without one, a cleanup the kill interrupted. A
                    // final transcript that reads as nothing needs the
                    // transcript job instead, below.
                    if runSpeakers != nil {
                        enqueue(Job(sessionID: session.id, kind: .speakers))
                    } else {
                        await repository.cleanupBatchAudio(sessionID: session.id)
                    }
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
        for sessionID in exports { enqueueExport(sessionID: sessionID) }
    }

    // MARK: - Recording preemption

    /// A recording is starting: stop dispatching, cancel the running job,
    /// and put it back first in its line — uncharged. The model belongs to
    /// live capture now. A speaker pass or an export is cancelled without
    /// waiting: a model load in flight finishes in the background and is
    /// thrown away, an export stops at its next chunk.
    func suspend() async {
        suspended = true
        if let running = current {
            current = nil
            if running.job.kind != .transcript { running.task.cancel() }
            insert(running.job, first: true)
        }
        await cancelRun()
    }

    /// The recording is over: dispatch continues.
    func resume() {
        suspended = false
        dispatchIfIdle()
    }

    // MARK: - Termination

    /// A normal quit — ⌘Q, Stop & Quit, an update's relaunch — is not a
    /// failed export (#290): the running export's count goes back, so it is
    /// not charged for the quit. Synchronous, because the process ends when
    /// the app delegate returns; a crash never gets here, and counts.
    func willTerminate() {
        let repository = repository
        exportCharge.withLock { charge in
            guard let charge else { return }
            repository.setExportAttempts(charge.attempts, sessionID: charge.sessionID)
        }
    }

    // MARK: - Queue mechanics

    /// Queue a job once. A transcript job shows as work on its meeting; the
    /// export and the speaker pass never do — the meeting reads without them.
    private func enqueue(_ job: Job, reason: DiagEvent.RepairReason? = nil, front: Bool = false) {
        guard job.kind != .speakers || runSpeakers != nil,
              current?.job.key != job.key,
              !queue.contains(where: { $0.key == job.key })
        else { return }
        if job.kind == .transcript {
            activeSessionIDs.insert(job.sessionID)
            unavailableSessionIDs.remove(job.sessionID)
        }
        insert(job, first: front)
        if let reason { DiagStore.record(.transcriptRepairQueued(reason: reason)) }
        dispatchIfIdle()
    }

    /// Kinds in their order — transcript jobs, exports, speaker passes;
    /// `first` puts a job at the head of its own kind.
    private func insert(_ job: Job, first: Bool) {
        let index = queue.firstIndex { first ? $0.kind >= job.kind : $0.kind > job.kind }
        queue.insert(job, at: index ?? queue.endIndex)
    }

    private func dispatchIfIdle() {
        guard !suspended else { return }
        if let running = current {
            // A transcript job outranks a running speaker pass or export:
            // cancelled without waiting, back first among its kind, uncharged.
            // It starts over later — an export over its own partial file.
            guard running.job.kind != .transcript, queue.first?.kind == .transcript else { return }
            current = nil
            running.task.cancel()
            insert(running.job, first: true)
        }
        guard !queue.isEmpty else { return }
        // Speaker passes sort last, so none of the rest can run either.
        if speakersOffline, queue.first?.kind == .speakers { return }
        let job = queue.removeFirst()
        nextDispatchToken += 1
        let token = nextDispatchToken
        let task: Task<Void, Never>
        switch job.kind {
        case .transcript:
            task = Task { [weak self] in
                guard let self else { return }
                // Suspended between dispatch and here (a recording start): the
                // job was already re-queued by suspend(); run nothing.
                guard !self.suspended, self.current?.token == token else { return }
                let result = await self.runJob(job)
                self.settle(job: job, token: token, result: .transcript(result))
            }
        case .speakers:
            task = inBackground(job, token: token) { [repository, runSpeakers] in
                guard let runSpeakers else { return nil }
                let attempt = await Self.speakerAttempt(
                    sessionID: job.sessionID, repository: repository, limit: Self.attemptLimit, run: runSpeakers)
                return .speakers(attempt.outcome, attempt.budget)
            }
        case .export:
            task = inBackground(job, token: token) { [repository, runExport, exportCharge] in
                let attempt = await Self.exportAttempt(
                    sessionID: job.sessionID, repository: repository, limit: Self.attemptLimit, run: runExport,
                    charge: exportCharge)
                return .export(attempt.outcome, attempt.budget)
            }
        }
        current = (job, token, task)
    }

    /// A speaker pass or an export, off the main actor. Each waits for the
    /// last of either, cancelled or not, so no two overlap — each holds a
    /// meeting's tracks in memory — and a cancelled one's bookkeeping lands
    /// first.
    private func inBackground(
        _ job: Job, token: Int, _ work: @escaping @Sendable () async -> Settlement?
    ) -> Task<Void, Never> {
        let previous = lastBackgroundTask
        let task = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            guard let result = await work() else { return }
            await self?.settle(job: job, token: token, result: result)
        }
        lastBackgroundTask = task
        return task
    }

    /// What a job's run came to.
    private enum Settlement: Sendable {
        case transcript(RunResult)
        /// The pass's outcome and its attempts so far, seeded from disk.
        case speakers(SpeakerFinder.Outcome, RetryBudget)
        /// The export's outcome and its attempts so far, seeded from disk.
        case export(ExportOutcome, RetryBudget)
    }

    /// How one export attempt ended (#290).
    enum ExportOutcome: Equatable, Sendable {
        case exported(MeetingRecording.ExportResult)
        /// The marker carries no timing for the tracks: none is tried.
        case noTiming
        /// No export is pending: the meeting was deleted meanwhile.
        case gone
    }

    private func settle(job: Job, token: Int, result: Settlement) {
        // A written export is done whatever cancelled it after (#290): its
        // recording is in the notes folder, so it is reported and shown even
        // when a yield or a recording start already put the job back — which
        // then finds nothing pending.
        if case .export(.exported(.written(let frames)), _) = result {
            DiagStore.record(.recordingExported(outcome: .ok, frames: frames))
            exportGeneration += 1
        }
        // A stale token means this run was preempted — suspend() or a
        // transcript job already re-queued it; the completion is the cancelled run's.
        guard current?.token == token else { return }
        current = nil

        switch result {
        case .transcript(.repaired):
            activeSessionIDs.remove(job.sessionID)
            unavailableSessionIDs.remove(job.sessionID)
            budgets[job.sessionID] = nil
            lastRepairedSessionID = job.sessionID
            repairGeneration += 1
            DiagStore.record(.transcriptRepairSettled(outcome: .repaired))
            Task(priority: .utility) { [onRepaired, sessionID = job.sessionID] in
                await onRepaired(sessionID)
            }
            // Tracks left behind are the speaker pass's (#269).
            enqueue(Job(sessionID: job.sessionID, kind: .speakers))

        case .transcript(.empty):
            // The pass ran to completion and verified there is nothing to
            // show — the runner persisted the no-speech verdict, so no
            // launch or open re-transcribes this silence.
            activeSessionIDs.remove(job.sessionID)
            unavailableSessionIDs.insert(job.sessionID)
            DiagStore.record(.transcriptRepairSettled(outcome: .unavailable))

        case .transcript(.noSource):
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

        case .transcript(.failed):
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

        case .transcript(.cancelled):
            // Cancelled without suspend() bookkeeping — treat like a
            // preemption and requeue quietly.
            insert(job, first: true)

        // A yield makes the token stale, so a cancelled speaker pass that
        // reaches here was not yielded: a failure, retried after a delay.
        case .speakers(.failed, let budget), .speakers(.cancelled, let budget):
            if budget.allowsAttempt {
                scheduleRetry(job)
            } else {
                // The attempts are spent, across launches: the tracks go
                // without a map.
                DiagStore.record(.speakerMapGaveUp(attempts: budget.failures))
                Task(priority: .utility) { [repository, sessionID = job.sessionID] in
                    await repository.cleanupBatchAudio(sessionID: sessionID)
                }
                speakersSettled(job.sessionID)
            }

        case .speakers(.offline, _):
            speakersOffline = true

        case .speakers(.finished, _):
            // The tracks went with it.
            speakersSettled(job.sessionID)

        case .speakers(.deferred, _):
            // The tracks stay for the transcript's repair.
            break

        // A failure with attempts left, retried after a delay. (A yield or a
        // recording start leaves a stale token, and never reaches here.)
        case .export(.exported(.failed), let budget) where budget.allowsAttempt:
            scheduleRetry(job)

        // No audio, no timing, or the attempts spent, across launches: the
        // marker goes, and the tracks with it when nothing else reads them —
        // traced, unless the meeting was deleted meanwhile.
        case .export(.exported(.failed), _), .export(.exported(.noAudio), _), .export(.noTiming, _):
            Task(priority: .utility) { [repository, sessionID = job.sessionID] in
                if (try? await repository.finishExport(sessionID: sessionID, writtenTo: nil)) == true {
                    DiagStore.record(.recordingExported(outcome: .failed, frames: 0))
                }
            }

        // Written: reported above, whatever the token. Gone: deleted while it
        // waited or ran — nothing to write, nothing to say.
        case .export(.exported(.written), _), .export(.gone, _):
            break
        }

        dispatchIfIdle()
    }

    /// The mirror is rewritten with the names the map gives, then the review
    /// is told and the summary follows.
    private func speakersSettled(_ sessionID: String) {
        Task { [weak self, repository] in
            await repository.mirrorNotesArtifacts(sessionID: sessionID)
            guard let self else { return }
            self.speakersGeneration += 1
            await self.onSpeakersSettled(sessionID)
        }
    }

    /// Quiet self-retry: a transcript job's session stays active (work is
    /// still pending — this task is the job behind the Preparing face), and
    /// the next attempt re-resolves its source rather than replaying a stale
    /// import URL.
    private func scheduleRetry(_ job: Job) {
        let key = job.key
        retryTasks[key]?.cancel()
        retryTasks[key] = Task { [weak self, retryDelay] in
            try? await Task.sleep(for: retryDelay)
            guard let self, !Task.isCancelled else { return }
            self.retryTasks[key] = nil
            // enqueue() dedupes against the queue and the running slot, both
            // of which this job left when its run failed — the retry passes;
            // a transcript job's session merely re-enters activeSessionIDs it
            // never left.
            self.enqueue(
                Job(sessionID: key.sessionID, kind: key.kind),
                reason: key.kind == .transcript ? .retry : nil
            )
        }
    }

    // MARK: - Speakers

    /// One speaker pass on a meeting's tracks (#269). Attempts are counted on
    /// disk before the run, so a pass that crashed the app counts; the
    /// returned budget carries them to `settle`, the one place that gives up.
    /// Only a run that finished and was not cancelled deletes the tracks — a
    /// cancelled one may have been yielded to a job about to read them.
    nonisolated private static func speakerAttempt(
        sessionID: String, repository: SessionRepository, limit: Int, run: SpeakerRunner
    ) async -> (outcome: SpeakerFinder.Outcome, budget: RetryBudget) {
        let started = await repository.speakerAttempts(sessionID: sessionID)
        var budget = RetryBudget(limit: limit, failures: started)
        guard !Task.isCancelled else { return (.cancelled, budget) }
        let stash = await repository.batchAudioURLs(sessionID: sessionID)
        guard stash.mic != nil || stash.sys != nil else { return (.finished, budget) }
        guard budget.allowsAttempt else { return (.failed, budget) }
        await repository.setSpeakerAttempts(started + 1, sessionID: sessionID)
        var outcome = await run(sessionID)
        // Only a yield cancels this task; a cancellation from inside the
        // models without one is a failure like any other.
        if Task.isCancelled {
            outcome = .cancelled
        } else if outcome == .cancelled {
            outcome = .failed
        }
        switch outcome {
        case .finished:
            await repository.cleanupBatchAudio(sessionID: sessionID)
        case .cancelled, .deferred, .offline:
            await repository.setSpeakerAttempts(started, sessionID: sessionID)
        case .failed:
            budget.noteFailure()
        }
        return (outcome, budget)
    }

    /// One export of a meeting's merged recording (#290). Like a speaker
    /// pass, it is counted on disk before it runs, so one a crash cut short
    /// counts, and its attempts go to `settle`, the one place that gives up;
    /// `charge` holds the count from before it, which a normal quit puts back
    /// (`willTerminate`). It fills a partial file beside the m4a, renamed over
    /// the m4a only once complete. A cancelled run — a yield or a recording
    /// start — is not charged; a written one is finished whatever cancels it
    /// after.
    nonisolated private static func exportAttempt(
        sessionID: String, repository: SessionRepository, limit: Int, run: ExportRunner,
        charge: OSAllocatedUnfairLock<(sessionID: String, attempts: Int)?>
    ) async -> (outcome: ExportOutcome, budget: RetryBudget) {
        let started = repository.exportAttempts(sessionID: sessionID)
        var budget = RetryBudget(limit: limit, failures: started)
        let plan = await repository.planExport(sessionID: sessionID)
        switch plan {
        case .gone: return (.gone, budget)
        case .noTiming: return (.noTiming, budget)
        case .ready, .notesFolderUnset: break
        }
        guard !Task.isCancelled, budget.allowsAttempt else { return (.exported(.failed), budget) }
        charge.withLock {
            $0 = (sessionID, started)
            repository.setExportAttempts(started + 1, sessionID: sessionID)
        }
        defer { charge.withLock { $0 = nil } }
        guard case .ready(let tracks, let meta, let file) = plan else {
            // Cannot run yet, and spent like a failure: retried, then given up
            // and traced — never tried silently at every launch.
            healLog.error("no notes folder to save a meeting's recording into")
            budget.noteFailure()
            return (.exported(.failed), budget)
        }
        var result = await run(tracks, meta, file)
        if case .written = result {
            do {
                let pending = try await repository.finishExport(sessionID: sessionID, writtenTo: file)
                return (pending ? .exported(result) : .gone, budget)
            } catch {
                healLog.error("export not moved into the notes folder: \(error.localizedDescription, privacy: .private)")
                result = .failed
            }
        }
        try? FileManager.default.removeItem(at: file)
        if Task.isCancelled {
            repository.setExportAttempts(started, sessionID: sessionID)
        } else if result == .failed {
            budget.noteFailure()
        }
        return (.exported(result), budget)
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
