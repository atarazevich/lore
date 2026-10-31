import ApplicationServices
import CoreGraphics
import Foundation
import LoreCLIKit
import LoreCore

/// What "Fix permissions" does to the machine (#338): remove lore's own
/// Accessibility and Input Monitoring entries, so the stale ones macOS kept
/// after a reinstall are gone, then ask for both again.
///
/// `tccutil reset <service> <bundle id>` touches only the named app's entry
/// and runs as the user, with no password and no prompt (verified on macOS
/// 27.2). It runs on the user's click and never otherwise. The runner is the
/// app's one seam onto other programs, so a test never reaches tccutil.
struct PermissionReset: Sendable {
    let runner: any CommandRunner

    static let tccutil = URL(fileURLWithPath: "/usr/bin/tccutil")
    static let timeout: TimeInterval = 10

    /// The two grants and tccutil's name for each, in order — the whole of
    /// what the reset may run, always against lore's own identifier.
    static let services: [(permission: DiagEvent.Permission, service: String)] = [
        (.accessibility, "Accessibility"),
        (.inputMonitoring, "ListenEvent"),
    ]

    /// Runs both, each traced with tccutil's exit status. A failed first reset
    /// does not skip the second: each entry is its own stale record.
    func run() async {
        for (permission, service) in Self.services {
            let result = await runner.run(
                Self.tccutil, arguments: ["reset", service, "com.lore.app"], timeout: Self.timeout
            )
            DiagStore.record(.permissionReset(permission: permission, exitStatus: result?.status))
        }
    }

    /// Ask macOS again for both grants, so its own prompt appears and lore has
    /// a fresh row in each list. Off the main thread: both calls can block.
    static func requestBoth() {
        DispatchQueue.global(qos: .userInitiated).async {
            // `kAXTrustedCheckOptionPrompt`'s value, spelled out: the global is
            // a mutable C var Swift 6 will not read off the main actor.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            _ = CGRequestListenEventAccess()
        }
    }
}
