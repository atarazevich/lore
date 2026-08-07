import Observation

/// Which world this process runs in (#150). One gate, evaluated once at launch:
/// in `.setup` the onboarding window is the only thing that exists, and no
/// subsystem carries a first-run conditional of its own. Flow and rationale:
/// `docs/features/onboarding.md`.
@MainActor
@Observable
final class AppBoot {
    enum Phase: Equatable {
        case setup
        case running
    }

    private(set) var phase: Phase

    @ObservationIgnored private var didStartSubsystems = false

    init(needsSetup: Bool) {
        self.phase = needsSetup ? .setup : .running
    }

    /// Setup finished. The scene swaps `ShellView` in on the next evaluation;
    /// the caller then starts the subsystems.
    func markSetupComplete() {
        phase = .running
    }

    /// Run `start` exactly once, and only in the configured world — the scene's
    /// `onAppear` and the end of setup both call in, whichever lands first wins.
    /// The latch is burned only when `start` reports it actually ran: a caller
    /// whose dependencies were not wired yet must not leave the machine with no
    /// menu bar, no health monitor and no updater until the next launch.
    func startSubsystemsOnce(_ start: () -> Bool) {
        guard phase == .running, !didStartSubsystems else { return }
        didStartSubsystems = start()
    }
}
