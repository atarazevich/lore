import Foundation

/// What `lore say` and the app read about other processes (#288): when one
/// started — so a pid given to a new process is not taken for a dead chat's —
/// and the environment it was started with; and, to find Claude Code's agents
/// view (#293), which processes this user runs, their arguments and the folder
/// each works in. A protocol so all of it is tested on processes written by
/// hand.
public protocol ProcessTable: Sendable {
    /// Nil when no process has this pid.
    func started(_ pid: Int32) -> Date?
    /// Nil when the process is gone or not this user's.
    func environment(of pid: Int32) -> [String: String]?
    /// Every process of this user.
    func pids() -> [Int32]
    /// Nil when the process is gone or not this user's.
    func arguments(of pid: Int32) -> [String]?
    /// The folder the process works in; nil when it is gone or not this user's.
    func workingFolder(of pid: Int32) -> String?
}

/// The live table: `sysctl` and libproc, no process started and no file
/// read.
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
        procargs(pid).flatMap(Self.environment(procargs:))
    }

    public func pids() -> [Int32] {
        let uid = UInt32(getuid())
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [Int32](repeating: 0, count: Int(needed) / MemoryLayout<Int32>.size + 32)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<Int32>.size).filter { $0 > 0 }
    }

    public func arguments(of pid: Int32) -> [String]? {
        procargs(pid).flatMap(Self.arguments(procargs:))
    }

    public func workingFolder(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    private func procargs(_ pid: Int32) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard pid > 0, sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        return Array(bytes.prefix(size))
    }

    /// `KERN_PROCARGS2`'s layout: the argument count, the executable's path
    /// padded with zeros to a multiple of eight bytes, the arguments, then the
    /// environment, every string ended by a zero. The padding is counted, not
    /// skipped, so an empty first argument keeps its place (checked 2026-09-28
    /// on every process of this user, and on children started with empty
    /// arguments). The environment ends at the first empty string; the first
    /// value of a key wins, as `getenv` reads it.
    public static func environment(procargs bytes: [UInt8]) -> [String: String]? {
        guard let (count, strings) = strings(procargs: bytes) else { return nil }
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(count).prefix(while: { !$0.isEmpty }) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            let key = String(text[..<equals])
            if environment[key] == nil { environment[key] = String(text[text.index(after: equals)...]) }
        }
        return environment
    }

    /// The arguments of the same layout, the first one included.
    public static func arguments(procargs bytes: [UInt8]) -> [String]? {
        guard let (count, strings) = strings(procargs: bytes) else { return nil }
        return strings.prefix(count).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The argument count, and every string after the executable's path.
    private static func strings(procargs bytes: [UInt8]) -> (Int, [ArraySlice<UInt8>])? {
        guard bytes.count > 4, let pathEnd = bytes[4...].firstIndex(of: 0) else { return nil }
        let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        let start = 4 + (pathEnd - 4 + 8) / 8 * 8
        guard count >= 0, start <= bytes.count else { return nil }
        let strings = bytes[start...].split(separator: 0, omittingEmptySubsequences: false)
        guard strings.count >= count else { return nil }
        return (count, strings)
    }
}
