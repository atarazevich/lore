import Darwin
import Foundation

/// The few BSD-socket calls both ends of the wire make. Blocking file
/// descriptors throughout: each side does one write and one read per exchange.
public enum CLISocket {
    /// Runs `body` with `path` as a Unix socket address; nil when the path is
    /// longer than `sun_path` holds.
    public static func withAddress<R>(
        _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R
    ) -> R? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            bytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// A connected socket, or nil when nothing is listening at `path`.
    public static func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard withAddress(path, { Darwin.connect(fd, $0, $1) }) == 0 else {
            close(fd)
            return nil
        }
        ignoreSigPipe(fd)
        return fd
    }

    /// Bounds both halves of one exchange: a peer that stops reading or never
    /// finishes its line costs this much waiting and no more.
    public static func setTimeouts(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
    }

    /// A peer that goes away mid-write must cost an `EPIPE`, not the process.
    public static func ignoreSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Everything until the peer closes its side.
    public static func readToEnd(_ fd: Int32) -> Data {
        var data = Data()
        _ = readChunks(fd) { data.append($0); return false }
        return data
    }

    /// Everything up to and including the first newline; nil when the peer
    /// closes first, the read fails, or more than `limit` bytes arrive.
    public static func readLine(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        let found = readChunks(fd) { chunk in
            data.append(chunk)
            return data.contains(UInt8(ascii: "\n")) || data.count > limit
        }
        return found && data.count <= limit ? data : nil
    }

    /// Reads until `isDone` says so (true) or the stream ends (false).
    private static func readChunks(_ fd: Int32, _ isDone: (Data) -> Bool) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            if isDone(Data(buffer[..<count])) { return true }
        }
    }
}
