import CoreServices
import Foundation

/// File-level changes inside one folder, from FSEvents, on the main queue
/// (#324: the history row shows an agent's take without a relaunch). FSEvents
/// rather than a dispatch source on the folder: a take appended to a sidecar
/// that already exists changes the file, not the folder, and a folder source
/// never hears of it.
///
/// `onChange` gets the changed files, or nil when FSEvents lost track and the
/// whole folder has to be read again.
@MainActor
final class FolderEvents {
    private final class Handler {
        let onChange: @MainActor (Set<URL>?) -> Void
        init(_ onChange: @escaping @MainActor (Set<URL>?) -> Void) { self.onChange = onChange }
    }

    /// How long FSEvents gathers changes before it calls.
    private static let latency: TimeInterval = 0.1

    private let handler: Handler
    private var stream: FSEventStreamRef?

    init?(folder: URL, onChange: @escaping @MainActor (Set<URL>?) -> Void) {
        handler = Handler(onChange)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let names = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let lost = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            )
            let rescan = (0..<count).contains { flags[$0] & lost != 0 }
            let changed = rescan ? nil : Set(names.map { URL(fileURLWithPath: $0) })
            // The stream is scheduled on the main queue.
            MainActor.assumeIsolated { handler.onChange(changed) }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    /// Stop hearing changes. The handler is never called after this returns.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    isolated deinit {
        stop()
    }
}
