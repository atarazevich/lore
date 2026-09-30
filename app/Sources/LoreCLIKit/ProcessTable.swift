import Foundation

/// The two facts about another process `lore say` and the app read (#288):
/// when it started — so a pid given to a new process is not taken for a dead
/// chat's — and the environment it was started with. A protocol so both are
/// tested on processes written by hand.
public protocol ProcessTable: Sendable {
    /// Nil when no process has this pid.
    func started(_ pid: Int32) -> Date?
    /// Nil when the process is gone or not this user's.
    func environment(of pid: Int32) -> [String: String]?
}

/// The live table: `sysctl`, no process started and no file read.
public struct SystemProcessTable: ProcessTable {

    public init() {}

    public func started(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard pid > 0, sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride
        else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    public func environment(of pid: Int32) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard pid > 0, sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        return Self.environment(procargs: Array(bytes.prefix(size)))
    }

    /// `KERN_PROCARGS2`'s layout: the argument count, the executable's path
    /// padded with zeros to a multiple of eight bytes, the arguments, then the
    /// environment, every string ended by a zero. The padding is counted, not
    /// skipped, so an empty first argument keeps its place (checked 2026-09-28
    /// on every process of this user, and on children started with empty
    /// arguments). The environment ends at the first empty string; the first
    /// value of a key wins, as `getenv` reads it.
    public static func environment(procargs bytes: [UInt8]) -> [String: String]? {
        guard bytes.count > 4, let pathEnd = bytes[4...].firstIndex(of: 0) else { return nil }
        let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        let start = 4 + (pathEnd - 4 + 8) / 8 * 8
        guard count >= 0, start <= bytes.count else { return nil }
        let strings = bytes[start...].split(separator: 0, omittingEmptySubsequences: false)
        guard strings.count >= count else { return nil }
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(count).prefix(while: { !$0.isEmpty }) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            let key = String(text[..<equals])
            if environment[key] == nil { environment[key] = String(text[text.index(after: equals)...]) }
        }
        return environment
    }
}
