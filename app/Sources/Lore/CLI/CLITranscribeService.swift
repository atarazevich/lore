import Darwin
import FluidAudio
import Foundation
import LoreCLIKit

/// `lore transcribe` inside the app (#254): a file in, its text out, and nothing
/// written anywhere — no meeting, no healer job, no history entry. It reads the
/// file with the app's own permissions, which is the reason it runs here and not
/// in the command.
///
/// One request at a time: `CLISocketServer` serializes them, and `inFlight`
/// relies on that.
@MainActor
final class CLITranscribeService {
    private let backendCache: SharedBackendCache
    /// A meeting's microphone leg transcribes through the same prepared model,
    /// so a request never starts beside one — recording, paused or finalizing.
    private let isMeetingLive: @MainActor () -> Bool
    private var vad: VadManager?

    /// Every request's way into the shared model. It outlives the request, so a
    /// call from one the command abandoned still counts until it leaves.
    private let gate = ModelGate()

    /// The request being answered, which a meeting start can take the model back from.
    private var current: Current?

    private struct Current {
        let work: Task<Void, Never>
        let door: ModelGate.Door
        /// Receives the request's own result, or nil from a meeting start. The
        /// first to arrive is the answer.
        let decide: AsyncStream<Result<Pass, any Error>?>.Continuation
    }

    /// The longest a meeting start waits for a request's call already inside
    /// the model. One call is one speech segment of at most 30 s, which Parakeet
    /// finishes in a fraction of a second.
    static let yieldBound: Duration = .seconds(2)

    init(backendCache: SharedBackendCache, isMeetingLive: @escaping @MainActor () -> Bool) {
        self.backendCache = backendCache
        self.isMeetingLive = isMeetingLive
    }

    /// The text of one file, and whether decoding reached its end.
    struct Pass: Sendable, Equatable {
        var texts: [String] = []
        var complete = true
    }

    /// One `lore transcribe` request. Nil when the command went away and
    /// cancelled the work: there is no one to answer. The wire's other request
    /// (`lore say`, #257) is routed to its own receiver, so this service never
    /// sees one.
    func respond(toFileAt path: String) async -> CLIResponse? {
        DiagStore.record(.commandTranscribeReceived)
        let startedAt = Date()
        let response = await transcribe(path: path)
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        switch response {
        case .transcript(_, let complete):
            DiagStore.record(.commandTranscribeFinished(ms: ms, complete: complete))
        case .failed(let reason, _):
            DiagStore.record(.commandTranscribeFailed(reason: reason, ms: ms))
        case nil:
            DiagStore.record(.commandTranscribeAbandoned(ms: ms))
        case .queued, .notAccepted:
            // `lore say`'s answers; a transcription never gives one.
            break
        }
        return response
    }

    /// Called by a meeting start before its microphone leg first touches the
    /// shared model. The request's answer becomes the meeting sentence unless it
    /// already had its own, it gets no further model call, and its work is
    /// cancelled and left to end by itself — an `open()` behind a consent prompt
    /// or a model load holds nothing here. The one wait is for a call already
    /// inside the model, this request's or an abandoned one's, bounded by
    /// `yieldBound`.
    func yieldToMeeting() async {
        if let current {
            // The answer is decided before the door closes: the work, turned
            // away at a closed door, would otherwise race in with a failure of
            // its own.
            current.decide.yield(nil)
            gate.close(current.door)
            current.work.cancel()
        }
        await gate.waitForCallInside(bound: Self.yieldBound)
    }

    private func transcribe(path: String) async -> CLIResponse? {
        // Checked and `current` set with no suspension between them, so a
        // meeting either is live here or finds the request to take back.
        guard !isMeetingLive() else { return .failed(.meetingInProgress) }
        let gate = self.gate
        let door = ModelGate.Door()
        let (decisions, decide) = AsyncStream<Result<Pass, any Error>?>.makeStream()
        let work = Task {
            do {
                decide.yield(.success(try await self.readAndTranscribe(path: path, door: door)))
            } catch {
                decide.yield(.failure(error))
            }
        }
        current = Current(work: work, door: door, decide: decide)
        defer { current = nil }

        let decision: Result<Pass, any Error>?? = await withTaskCancellationHandler {
            for await first in decisions { return Optional(first) }
            return nil
        } onCancel: {
            // The command went away. A call already inside the model stays
            // counted by the gate; no new one goes in.
            gate.close(door)
            work.cancel()
        }

        guard !Task.isCancelled, let decision else { return nil }
        switch decision {
        case nil:
            return .failed(.meetingInProgress)
        case .success(let pass)?:
            let text = Self.joined(pass.texts)
            guard !text.isEmpty else { return .failed(reason: .noSpeech, complete: pass.complete) }
            return .transcript(text: text, complete: pass.complete)
        case .failure(let error)?:
            return .failed(error as? TranscribeFailure ?? .transcriptionFailed)
        }
    }

    /// Off the main actor from the first file-system call on: opening a file
    /// that another app's data protection covers can wait on a system consent
    /// prompt, and decoding a long file is real work.
    @concurrent
    nonisolated private func readAndTranscribe(path: String, door: ModelGate.Door) async throws -> Pass {
        if let failure = Self.unreadableReason(path: path) { throw failure }
        // Before the models: a file that is not audio should not wait on a load.
        guard let reader = await AssetChunkReader(url: URL(fileURLWithPath: path)) else {
            throw TranscribeFailure.notAudio
        }
        let (shared, vad) = try await models()
        let backend = gate.guarding(shared, through: door)
        return try await Self.pass {
            try await AudioFileSpeech(backend: backend, vad: vad).read(nextChunk: reader.nextChunk)
        }
    }

    /// The model the launch already prepared (or the load in progress), and the
    /// voice detector, loaded by the first request and kept. A cancelled
    /// request's reason is never read, so cancellation needs no case of its own.
    private func models() async throws(TranscribeFailure) -> (any TranscriptionBackend, VadManager) {
        do {
            let backend = try await backendCache.prepare()
            try Task.checkCancellation()
            if let vad { return (backend, vad) }
            let loaded = try await SileroVAD.load()
            vad = loaded
            return (backend, loaded)
        } catch {
            throw .modelLoadFailed
        }
    }

    /// The file read to its end, or to where decoding failed. A decoding
    /// failure after something decoded keeps what was transcribed; before
    /// anything decoded it means the file is not audio.
    nonisolated static func pass(_ read: () async throws -> AudioFileSpeech.Reading) async throws -> Pass {
        let reading: AudioFileSpeech.Reading
        do {
            reading = try await read()
        } catch {
            throw TranscribeFailure.transcriptionFailed
        }
        if reading.decodeError != nil && reading.blocks == 0 { throw TranscribeFailure.notAudio }
        return Pass(texts: reading.utterances.map(\.text), complete: reading.decodeError == nil)
    }

    /// Why the app cannot read `path`, asked of the file system as the app — a
    /// file behind Full Disk Access answers `EPERM` here and nowhere earlier.
    nonisolated static func unreadableReason(path: String) -> TranscribeFailure? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .fileNotFound
            case EACCES, EPERM: return .notPermitted
            default: return .couldNotOpen
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .notAudio }
        return nil
    }

    /// One paragraph: a pause can fall mid-sentence, so a line per utterance
    /// would break sentences the speaker did not.
    nonisolated static func joined(_ utterances: [String]) -> String {
        utterances
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// `lore transcribe`'s way into the shared model (#254). One gate for every
/// request, and one call inside at a time: a call counts until it leaves the
/// model, even when the request that made it was abandoned, so the next request
/// and a meeting start both wait for it. Each request goes in through its own
/// door, which a meeting start or the command leaving closes.
final class ModelGate: @unchecked Sendable {
    /// One request's entrance. Its state is guarded by the gate's lock.
    final class Door: @unchecked Sendable {
        fileprivate var closed = false
    }

    private let lock = NSLock()
    private var callInside = false

    /// `backend`, with every `transcribe` call going in through `door`.
    func guarding(_ backend: any TranscriptionBackend, through door: Door) -> any TranscriptionBackend {
        Gated(backend: backend, gate: self, door: door)
    }

    /// No call goes in through `door` from here on. Under the same lock as
    /// entering, so a call either got in before this — and a wait after it
    /// sees that call — or is turned away.
    func close(_ door: Door) {
        lock.withLock { door.closed = true }
    }

    /// Returns once no call is inside the model, or after `bound`.
    func waitForCallInside(bound: Duration) async {
        let deadline = ContinuousClock.now + bound
        while lock.withLock({ callInside }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    fileprivate func enter(through door: Door) async throws {
        while true {
            let admitted = try lock.withLock {
                guard !door.closed else { throw CancellationError() }
                guard !callInside else { return false }
                callInside = true
                return true
            }
            if admitted { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    fileprivate func leave() {
        lock.withLock { callInside = false }
    }

    private struct Gated: TranscriptionBackend {
        let backend: any TranscriptionBackend
        let gate: ModelGate
        let door: Door

        func checkStatus() -> BackendStatus { backend.checkStatus() }

        /// The shared cache prepared the model; a gated view never loads one.
        func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {}

        func transcribe(_ samples: [Float], previousContext: String?) async throws -> String {
            try await gate.enter(through: door)
            defer { gate.leave() }
            return try await backend.transcribe(samples, previousContext: previousContext)
        }
    }
}
