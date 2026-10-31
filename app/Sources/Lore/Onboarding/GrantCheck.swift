import Foundation
import LoreCLIKit
import LoreCore

/// The two list-granted permissions read by a process that did not exist a
/// moment ago (#300). Onboarding's green check for Accessibility and Input
/// Monitoring comes from here and only from here: a fresh process holds no
/// per-process cache (`CGPreflightListenEventAccess` keeps its first answer for
/// the life of the process that asked), so what it prints is what TCC says now.
///
/// The child is lore's own executable started with `flag`, so it is the very
/// code identity the grant is keyed to. `main.swift` hands it here before the
/// app starts, so it reads, prints one JSON line and exits with no window, no
/// menu bar and no subsystem.
public enum GrantCheck {

    /// `Lore --check-grants` prints a `Reading` and exits 0.
    public static let flag = "--check-grants"

    /// The child's whole answer.
    struct Reading: Codable, Equatable, Sendable {
        var accessibility: Bool
        var inputMonitoring: Bool
    }

    /// Long enough for `AXIsProcessTrusted`'s worst observed stall; a child
    /// that takes longer is killed and the tick keeps its last reading.
    static let timeout: TimeInterval = 3

    /// Entry from `main.swift`: when the flag is on the command line, answer and
    /// exit before anything of the app exists.
    public static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard arguments.dropFirst().contains(flag) else { return }
        let reading = Reading(
            accessibility: PermissionReader.accessibilityGranted(),
            inputMonitoring: PermissionReader.inputMonitoringGranted()
        )
        if let data = try? JSONEncoder().encode(reading) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(0)
    }

    /// The executable that holds the grant: this process's own, but only when
    /// this process *is* lore. Under `xctest` the main bundle is the test
    /// runner, and starting it with an unknown flag would run the suite again.
    static var executable: URL? {
        guard Bundle.main.bundleIdentifier == "com.lore.app" else { return nil }
        return Bundle.main.executableURL
    }

    /// One fresh reading. Blocks for the child's lifetime — run it on the
    /// poll's own queue, never on main.
    static func readFresh(executable: URL? = executable) -> Result<Reading, GrantCheckFailure> {
        guard let executable else { return .failure(.unavailable) }
        guard let run = SystemCommandRunner.runBlocking(executable, [flag], timeout) else {
            return .failure(.noAnswer)
        }
        guard run.status == 0,
              let reading = try? JSONDecoder().decode(Reading.self, from: Data(run.output.utf8))
        else { return .failure(.unreadable) }
        return .success(reading)
    }
}
