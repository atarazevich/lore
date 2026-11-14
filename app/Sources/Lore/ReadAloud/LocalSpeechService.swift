import Foundation
import LoreCLIKit
import LoreCore

/// The two local voices agent replies are read in (#351), chosen by ear on
/// 2026-11-01: Silero `xenia` for Russian, `en_116` for English.
enum SileroVoice: String, Codable, Equatable, Sendable {
    case xenia
    case en116 = "en_116"

    /// The language the voice reads, as the service names it.
    var language: String {
        switch self {
        case .xenia: "ru"
        case .en116: "en"
        }
    }

    /// The voice for a language; nil for a language no local voice reads.
    init?(_ language: ReadAloudController.TextLanguage) {
        switch language {
        case .russian: self = .xenia
        case .english: self = .en116
        case .other: return nil
        }
    }
}

/// One sentence the service wrote: the WAV and how long it plays.
struct LocalSpeechClip: Equatable, Sendable {
    let url: URL
    let seconds: Double
}

/// The speech service as the speaker sees it: installed or not, and one
/// sentence in, one WAV out. A seam, so the speaker is tested with a fake.
protocol LocalSpeechSynthesizing: Sendable {
    /// Whether this Mac has the service: its Python, its script and both models.
    var isInstalled: Bool { get }
    /// Throws `startFailed` for a service that is installed and did not come
    /// up, `requestFailed` for one that took the request and gave nothing
    /// usable back — crashed, killed, a text its model refused, or a WAV
    /// outside its own folder.
    func synthesize(_ text: String, voice: SileroVoice) async throws(DiagEvent.LocalVoiceFallback) -> LocalSpeechClip
}

/// Where the installed service lives (`tools/speech-service/install.sh`).
/// The internal disk on purpose: it works without the SSD.
struct LocalSpeechPaths: Sendable {
    let directory: URL

    static let standard = LocalSpeechPaths(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lore/SpeechService", isDirectory: true)
    )

    var python: URL { directory.appendingPathComponent("venv/bin/python") }
    var script: URL { directory.appendingPathComponent("speech_service.py") }
    var socket: URL { directory.appendingPathComponent("speech.sock") }
    /// Where the service writes its WAVs.
    var out: URL { directory.appendingPathComponent("out", isDirectory: true) }
    var models: [URL] {
        ["v5_6_ru.pt", "v3_en.pt"].map { directory.appendingPathComponent("models/\($0)") }
    }

    var isInstalled: Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: python.path)
            && ([script] + models).allSatisfy { files.fileExists(atPath: $0.path) }
    }

    /// The WAV an answer names, only when it is a file directly in `out`:
    /// anything else is never played and never deleted.
    func clip(at path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let folder = out.standardizedFileURL.resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == folder.path,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }
}

/// What goes over the service's socket: one JSON line each way.
struct LocalSpeechRequest: Codable, Equatable, Sendable {
    let text: String
    let language: String
    let voice: String
}

struct LocalSpeechAnswer: Codable, Equatable, Sendable {
    let wav: String?
    let seconds: Double?
    let error: String?
}

/// The live service: started on demand with `Process`, never twice — a
/// socket that answers is a service already running — and left to quit by
/// itself after ten idle minutes.
actor LocalSpeechService: LocalSpeechSynthesizing {
    nonisolated let paths: LocalSpeechPaths
    private let recordEvent: @Sendable (DiagEvent) -> Void
    /// How long a cold start may take: Python, torch and the first model.
    private let startTimeout: TimeInterval
    /// One sentence; the first one after a start also loads its model.
    private let requestTimeout: Int
    /// The copy this app started, held so it is reaped when it quits.
    private var process: Process?
    /// When that copy was started, until its socket first answers.
    private var launchedAt: Date?

    init(
        paths: LocalSpeechPaths = .standard,
        recordEvent: @escaping @Sendable (DiagEvent) -> Void = { DiagStore.record($0) },
        startTimeout: TimeInterval = 20,
        requestTimeout: Int = 30
    ) {
        self.paths = paths
        self.recordEvent = recordEvent
        self.startTimeout = startTimeout
        self.requestTimeout = requestTimeout
    }

    nonisolated var isInstalled: Bool { paths.isInstalled }

    func synthesize(_ text: String, voice: SileroVoice) async throws(DiagEvent.LocalVoiceFallback) -> LocalSpeechClip {
        try await ensureRunning()
        let request = LocalSpeechRequest(text: text, language: voice.language, voice: voice.rawValue)
        let socket = paths.socket.path
        let timeout = requestTimeout
        let answer = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.exchange(request, socket: socket, timeout: timeout))
            }
        }
        guard let answer, let wav = answer.wav, let seconds = answer.seconds,
              let url = paths.clip(at: wav)
        else { throw .requestFailed }
        return LocalSpeechClip(url: url, seconds: seconds)
    }

    /// Alive is a socket that accepts. Not alive: start one and wait for its
    /// socket — the service binds it before loading any model.
    private func ensureRunning() async throws(DiagEvent.LocalVoiceFallback) {
        if Self.answers(paths.socket.path) { return }
        // A request arriving while this actor waits for the copy it started
        // (the wait suspends, so a second one can come in) waits for that copy
        // rather than starting another.
        let process: Process
        if let running = self.process, running.isRunning, launchedAt != nil {
            process = running
        } else {
            process = Process()
            process.executableURL = paths.python
            process.arguments = ["-I", paths.script.path, "--dir", paths.directory.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { throw .startFailed }
            self.process = process
            launchedAt = Date()
        }
        let started = launchedAt ?? Date()
        while Date().timeIntervalSince(started) < startTimeout {
            if Self.answers(paths.socket.path) {
                if let launched = launchedAt {
                    launchedAt = nil
                    recordEvent(.agentReplySpeechServiceStarted(ms: Int(Date().timeIntervalSince(launched) * 1000)))
                }
                return
            }
            // A copy that found another one answering exits at once; one that
            // crashed exits too. Either way, one last look and then it failed.
            if !process.isRunning {
                launchedAt = nil
                if Self.answers(paths.socket.path) { return }
                throw .startFailed
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        launchedAt = nil
        process.terminate()
        throw .startFailed
    }

    private static func answers(_ path: String) -> Bool {
        guard let fd = CLISocket.connect(to: path) else { return false }
        close(fd)
        return true
    }

    /// One request and its answer, blocking; nil when the service closed,
    /// timed out or said something unreadable.
    private static func exchange(_ request: LocalSpeechRequest, socket: String, timeout: Int) -> LocalSpeechAnswer? {
        guard let fd = CLISocket.connect(to: socket) else { return nil }
        defer { close(fd) }
        CLISocket.setTimeouts(fd, seconds: timeout)
        guard let line = try? CLIWire.encode(request),
              CLISocket.writeAll(fd, line),
              let reply = CLISocket.readLine(fd, limit: CLIWire.maxRequestBytes)
        else { return nil }
        return try? CLIWire.decode(LocalSpeechAnswer.self, from: reply)
    }
}
