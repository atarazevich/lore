import Darwin
import Foundation
import LoreCLIKit
import os

private let serverLog = Logger(subsystem: "com.lore.app", category: "CLI")

/// The app's end of the `lore` command's wire (#254): a Unix socket at
/// `CLIWire.socketPath`, readable and writable by this user alone, one exchange
/// per connection. Connections are answered one at a time, in arrival order —
/// a second `lore transcribe` waits for the first instead of sharing the model
/// with it.
final class CLISocketServer: Sendable {
    private let acceptSource: any DispatchSourceRead

    /// Nil when the socket cannot be opened; the app runs on without the command.
    /// `respond` answers nil when its work was cancelled because the command
    /// went away, and then nothing is written.
    init?(
        path: String = CLIWire.socketPath,
        recordEvent: @escaping @Sendable (DiagEvent) -> Void = { DiagStore.record($0) },
        respond: @escaping @Sendable (CLIRequest) async -> CLIResponse?
    ) {
        guard let fd = Self.listen(at: path) else { return nil }
        let (connections, continuation) = AsyncStream<Int32>.makeStream()
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: DispatchQueue(label: "com.lore.app.cli-accept")
        )
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            continuation.yield(client)
        }
        source.resume()
        Task.detached {
            for await client in connections {
                await Self.serve(client, recordEvent: recordEvent, respond: respond)
            }
        }
        acceptSource = source
    }

    /// Binds and listens at `path`, replacing a socket an earlier run left
    /// behind (a crash leaves one). Anything else at the path is not ours to
    /// remove, so the server does not start.
    private static func listen(at path: String) -> Int32? {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK else {
                serverLog.error("cli socket path is taken by something else; command unavailable")
                return nil
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        // The mode is set between bind and listen: until listen() nothing can
        // connect, so there is no moment the socket is open to other users.
        // SOMAXCONN, so a shell loop that starts every file at once is queued
        // rather than refused.
        guard CLISocket.withAddress(path, { bind(fd, $0, $1) }) == 0,
              chmod(path, 0o600) == 0,
              Darwin.listen(fd, SOMAXCONN) == 0 else {
            serverLog.error("cli socket failed to listen: errno \(errno, privacy: .public)")
            close(fd)
            return nil
        }
        // Non-blocking so a connection that vanishes between the readiness
        // event and accept() cannot stall the accept queue.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    private static func serve(
        _ fd: Int32,
        recordEvent: @escaping @Sendable (DiagEvent) -> Void,
        respond: @escaping @Sendable (CLIRequest) async -> CLIResponse?
    ) async {
        // An accepted socket inherits the listener's O_NONBLOCK on Darwin.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        CLISocket.ignoreSigPipe(fd)
        // A peer that connects and never finishes its line, or stops reading
        // the answer, cannot hold the queue for longer than this. The
        // transcription in between has no limit.
        CLISocket.setTimeouts(fd, seconds: 10)

        guard let line = CLISocket.readLine(fd, limit: CLIWire.maxRequestBytes),
              let request = try? CLIWire.decode(CLIRequest.self, from: line) else {
            serverLog.error("cli request unreadable; connection closed")
            // Traced as a declined reply (#257): a reply lost here is spoken by
            // `say` with nothing to say why, while `lore transcribe` prints its
            // own failure.
            recordEvent(.agentReplyDeclined(reason: .unreadableRequest))
            close(fd)
            return
        }

        let work = Task { await respond(request) }

        // The command sends nothing after its line, so the socket turning
        // readable again means it closed — Ctrl-C, or its terminal went away —
        // and the work stops instead of holding the queue.
        let (watchEnded, endWatch) = AsyncStream<Void>.makeStream()
        let watch = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        watch.setEventHandler { [watch] in
            work.cancel()
            watch.cancel()
        }
        watch.setCancelHandler { endWatch.finish() }
        watch.resume()

        let response = await work.value
        watch.cancel()
        // The descriptor is closed only once the source has let go of it.
        for await _ in watchEnded {}

        if let response {
            if (try? CLIWire.encode(response)).map({ CLISocket.writeAll(fd, $0) }) != true {
                serverLog.error("cli answer not delivered")
            }
        }
        close(fd)
    }
}
