import Foundation

/// Whether this launch should defer to another process already answering to
/// the same bundle id (#193). Two `com.lore.app` processes each hold their
/// own Fn event tap, mic subscription and menu-bar mark, so a hold-to-talk
/// is heard twice.
///
/// A pure decision over process ids and launch dates, so the launch-time
/// check is testable without any AppKit/XCTest scaffolding —
/// `NSRunningApplication` is the only caller that has to touch real process
/// state.
enum SingleInstanceGuard {
    /// One process's identity for the decision below: a pid and the moment it
    /// started answering to the bundle id. `NSRunningApplication.launchDate`
    /// supplies the latter for every instance, including
    /// `NSRunningApplication.current`.
    struct Candidate: Equatable {
        let pid: Int32
        let launchDate: Date
    }

    /// The pid this launch must defer to — activate it and exit — or `nil` if
    /// `myPID` is the one that keeps running. `candidates` is every process
    /// currently answering to the bundle id, including this one.
    ///
    /// No lock file: the older process (by `launchDate`) wins. Two direct-exec
    /// launches landing in the same instant — the gap a snapshot with no
    /// tie-break leaves open, where each would see the other, each would
    /// defer, and zero processes would survive — break toward the lower pid
    /// instead, so every candidate computes this same winner independently.
    static func processToDeferTo(candidates: [Candidate], myPID: Int32) -> Candidate? {
        guard let winner = candidates.min(by: ranksBefore) else { return nil }
        return winner.pid == myPID ? nil : winner
    }

    private static func ranksBefore(_ a: Candidate, _ b: Candidate) -> Bool {
        (a.launchDate, a.pid) < (b.launchDate, b.pid)
    }
}
