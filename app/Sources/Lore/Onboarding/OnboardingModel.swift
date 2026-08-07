import AppKit
import Foundation
import Observation

/// The state behind the first-run flow (#150). Nothing here is a stored verdict:
/// every green is a live reading, and the reading itself moves the flow. Design
/// authority `docs/design/prototypes/lore-onboarding.pen`, notes
/// `docs/features/onboarding.md`.
@MainActor
@Observable
final class OnboardingModel {

    enum Step: String, CaseIterable, Equatable {
        case welcome
        case permissions
        case fnKey
        case tryIt
        case ready

        /// The footer's four dots, in board order. Ready owns the last one even
        /// though it shows no row: the dots are progress toward it.
        static let dotted: [Step] = [.permissions, .fnKey, .tryIt, .ready]

        /// Identity by raw value — `DiagEvent.OnboardingStep` spells all five
        /// the same way, pinned by `OnboardingStateTests`.
        var diagStep: DiagEvent.OnboardingStep { .init(rawValue: rawValue)! }
    }

    /// What the guided dictation has managed to prove so far. `landed` is the
    /// one claim about three subsystems at once; `tapDead` is the only place in
    /// the flow that names a relaunch.
    enum TryItPhase: Equatable {
        case idle
        case recording
        case landed
        case tapDead
    }

    /// One reading of the dictation subsystem, taken together. The flow reaches
    /// the pipeline through this single seam.
    struct DictationReading: Equatable, Sendable {
        var tapAlive = false
        var state: DictationState = .idle
        var audioLevel: Float = 0
        /// Exactly what `TextInserter` put on the pasteboard and pressed ⌘V for.
        var lastPasted: String?
    }

    // MARK: - Live state

    private(set) var step: Step = .welcome
    private(set) var permissions = PermissionSnapshot()
    private(set) var fnAction: FnKeyAction = .doNothing
    private(set) var tryIt: TryItPhase = .idle

    /// Which permission card is expanded. Trails `permissions.current` by the
    /// dwell, so a card flips green and *then* the next one opens.
    private(set) var expandedGrant: RequiredGrant? = .microphone

    /// The Fn hold's elapsed seconds, for the `0:03` readout.
    private(set) var recordingSeconds = 0

    /// Bound to the Try-it field. Non-empty is not proof on its own — see
    /// `noteTypedTextChange`.
    var typedText = "" {
        didSet { noteTypedTextChange() }
    }

    /// Ready's consent line: "Start using lore" is inert until it is ticked, so
    /// completing setup *is* the acknowledgement (doc, Consent).
    var acceptedRecordingObligations = false

    // MARK: - Collaborators

    /// Arms the dictation subsystem for Try it — after Accessibility is granted,
    /// because a tap created before the grant stays dead.
    @ObservationIgnored var startDictationForTryIt: (() -> Void)?

    /// The dictation subsystem, read live. Called from the flow's body as well
    /// as from the poll, so SwiftUI keeps observing the coordinator's own
    /// properties through it.
    @ObservationIgnored var readDictation: (() -> DictationReading)?

    /// Setup finished — write the flag and boot the app.
    @ObservationIgnored var onFinish: (() -> Void)?

    /// The window's close button and ⌘W follow the required set.
    @ObservationIgnored var onClosableChanged: ((Bool) -> Void)?

    /// Fronts the window after a System Settings round trip.
    @ObservationIgnored var onWantsFront: (() -> Void)?

    // MARK: - Polling

    /// Serialized, off the main actor: these reads block, and on a main-RunLoop
    /// timer that is the AltTab freeze.
    @ObservationIgnored private let pollQueue = DispatchQueue(
        label: "com.lore.app.onboarding.permissions",
        qos: .userInitiated
    )
    @ObservationIgnored private var pollTimer: DispatchSourceTimer?

    /// The board's two pauses: a card flips green and *then* the next expands,
    /// and the Fn step says "Detected — continuing…" before it hands off.
    /// Separate timers because they must not cancel each other.
    @ObservationIgnored private let revealDwell: DwellTimer
    @ObservationIgnored private let handoffDwell: DwellTimer

    @ObservationIgnored private var recordingStartedAt: Date?
    /// The previous tick's set, so a grant landing can be told from one that was
    /// already there — and the first reading is the baseline, not a transition.
    @ObservationIgnored private var lastPermissions = PermissionSnapshot()
    @ObservationIgnored private var didReadPermissions = false
    /// macOS shows the Accessibility prompt at most once per install; after that
    /// the button is the deep link.
    @ObservationIgnored private var didPromptAccessibility = false
    @ObservationIgnored private var didRegisterInputMonitoring = false
    @ObservationIgnored private var didArmDictation = false
    /// The poll saw a capture during Try it: the half of the success claim that
    /// typing into the box cannot fake.
    @ObservationIgnored private var didObserveCapture = false

    init(dwell: Duration = .milliseconds(450)) {
        revealDwell = DwellTimer(duration: dwell)
        handoffDwell = DwellTimer(duration: dwell)
    }

    // MARK: - Lifecycle

    /// Start the poll. The first tick fires on the same background queue as
    /// every later one — a synchronous baseline here would block the first frame.
    func start() {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(400))
        timer.setEventHandler { [weak self] in
            let snapshot = PermissionReader.snapshot()
            let fn = FnKeySetting.current()
            Task { @MainActor [weak self] in
                self?.apply(permissions: snapshot, fn: fn)
            }
        }
        pollTimer = timer
        timer.resume()
        DiagStore.record(.onboardingStarted)
    }

    /// The poller is scoped to the window, not to a step: a green that stops
    /// being watched is a latched verdict (doc, Decisions).
    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        revealDwell.cancel()
        handoffDwell.cancel()
    }

    // MARK: - Reading → state

    /// One tick applied. Internal rather than private: the poller's cadence is
    /// the thing the dwells have to survive, so tests drive it directly.
    func apply(permissions snapshot: PermissionSnapshot, fn: FnKeyAction) {
        let previous = lastPermissions
        let isBaseline = !didReadPermissions
        didReadPermissions = true
        lastPermissions = snapshot
        permissions = snapshot
        fnAction = fn

        if !isBaseline {
            for grant in RequiredGrant.allCases where snapshot[grant] != previous[grant] {
                DiagStore.record(
                    .permissionTransition(permission: grant.diagPermission, granted: snapshot[grant])
                )
            }
        }

        // Board 2b/2c: the card flips green immediately, the next one expands
        // after the dwell. No Next button ever follows a grant.
        if expandedGrant != snapshot.current {
            revealDwell.arm(for: snapshot.current) { [weak self] in
                self?.expandedGrant = snapshot.current
            }
        } else {
            revealDwell.cancel()
        }

        onClosableChanged?(snapshot.allGranted)

        // Otherwise the flow advances behind System Settings' window.
        if !isBaseline, snapshot != previous, NSApp?.isActive == false {
            onWantsFront?()
        }

        refreshStepForReading()
        refreshTryIt()
    }

    /// The steps with no button of their own advance on the reading, and a
    /// revocation takes the flow back with it — through the same `advance`, so a
    /// walk-back is traced and disarms whatever dwell was counting down.
    private func refreshStepForReading() {
        switch step {
        case .welcome, .permissions:
            break
        case .fnKey:
            if !permissions.allGranted {
                advance(to: .permissions)
            } else if !fnAction.conflictsWithHotkey {
                // Board 3b: "Detected — continuing…", then hand off.
                handoffDwell.arm(for: Step.tryIt) { [weak self] in
                    guard let self, self.step == .fnKey else { return }
                    self.advance(to: .tryIt)
                }
            } else {
                handoffDwell.cancel()
            }
        case .tryIt, .ready:
            if !permissions.allGranted {
                advance(to: .permissions)
            } else if fnAction.conflictsWithHotkey, step == .tryIt, tryIt != .landed {
                advance(to: .fnKey)
            }
        }
    }

    // MARK: - Navigation

    /// Welcome's single Continue, and the Permissions step's Continue at the
    /// boundary of the required set. Nothing else in the flow has one.
    func advanceFromButton() {
        switch step {
        case .welcome:
            advance(to: .permissions)
        case .permissions:
            guard permissions.allGranted else { return }
            advance(to: fnAction.conflictsWithHotkey ? .fnKey : .tryIt)
        case .fnKey:
            break
        case .tryIt:
            advance(to: .ready)
        case .ready:
            finish()
        }
    }

    /// Try-it is a teaching step, so it is the one place a quiet Skip is allowed.
    func skipTryIt() {
        guard step == .tryIt else { return }
        advance(to: .ready)
    }

    /// The only user-driven backwards move — the other is a revocation walking
    /// the flow back on its own. Through `advance` like everything else, so it
    /// is traced and it disarms whatever dwell was counting down. It cannot skip
    /// anything: coming forward again re-derives the next step from the live
    /// reading, so a condition that still holds is shown again.
    func back() {
        switch step {
        case .welcome, .ready: break
        case .permissions: advance(to: .welcome)
        case .fnKey, .tryIt: advance(to: .permissions)
        }
    }

    /// The footer's quiet Back control: present on the three middle steps, absent
    /// on the first (nothing behind it) and the last (setup is one click away).
    var canGoBack: Bool { step != .welcome && step != .ready }

    private func advance(to next: Step) {
        guard step != next else { return }
        revealDwell.cancel()
        handoffDwell.cancel()
        step = next
        DiagStore.record(.onboardingStepShown(step: next.diagStep))
        if next == .tryIt { armDictation() }
    }

    private func finish() {
        guard acceptedRecordingObligations else { return }
        stop()
        DiagStore.record(.onboardingCompleted)
        onFinish?()
    }

    // MARK: - Permission actions

    /// The one two-tier button in the flow. Its label stays "Allow"; the caption
    /// under it is what tells the truth about which of the two it will do.
    func requestGrant(_ grant: RequiredGrant) {
        switch grant {
        case .microphone:
            guard permissions.microphoneUndetermined else {
                openPane(.microphone)
                return
            }
            Task { _ = await MicrophonePermission.request() }

        case .accessibility:
            // The prompting variant registers lore in the Accessibility list.
            if didPromptAccessibility {
                openPane(.accessibility)
            } else {
                didPromptAccessibility = true
                // Blocks while its dialog is up, so it runs off the main actor.
                pollQueue.async { TextInserter.requestAccessibilityIfNeeded() }
            }

        case .inputMonitoring:
            // Always the pane, per the board. The request is made once purely so
            // lore has a row in it — nothing here depends on it presenting
            // anything, which is why the AX-prompt ordering bug cannot bite (doc).
            if !didRegisterInputMonitoring {
                didRegisterInputMonitoring = true
                pollQueue.async { _ = CGRequestListenEventAccess() }
            }
            openPane(.inputMonitoring)
        }
    }

    /// Deep-link into System Settings. The Fn step's button opens `.keyboard`;
    /// the permission cards route here through `requestGrant`.
    func openPane(_ pane: SettingsPane) {
        guard let url = pane.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Try it

    /// The tap is created here, not at launch: a tap built before Accessibility
    /// is granted stays dead for the life of the process.
    private func armDictation() {
        guard !didArmDictation else { return }
        didArmDictation = true
        startDictationForTryIt?()
    }

    /// Live re-derivation of the Try-it card, so the recovery variant withdraws
    /// itself if the tap comes back.
    private func refreshTryIt() {
        guard step == .tryIt, tryIt != .landed, let reading = readDictation?() else { return }

        if didArmDictation, !reading.tapAlive {
            tryIt = .tapDead
            return
        }

        switch reading.state {
        case .recording, .loadingModel, .processing:
            // Downstream states count: they are reached only from a capture, so
            // a hold shorter than a poll tick is still seen.
            didObserveCapture = true
        case .idle, .done:
            break
        }

        if reading.state == .recording {
            if recordingStartedAt == nil { recordingStartedAt = Date() }
            recordingSeconds = Int(Date().timeIntervalSince(recordingStartedAt ?? Date()))
            tryIt = .recording
        } else {
            recordingStartedAt = nil
            recordingSeconds = 0
            tryIt = .idle
        }
    }

    /// The success line names three subsystems, so all three have to have run:
    /// a capture the poll saw open, and the pipeline's own text in the field.
    /// Typing exercises neither. Terminal once true.
    private func noteTypedTextChange() {
        guard step == .tryIt, tryIt != .landed, didObserveCapture,
              let pasted = readDictation?().lastPasted, !pasted.isEmpty,
              typedText.contains(pasted)
        else { return }
        tryIt = .landed
        recordingStartedAt = nil
        DiagStore.record(.onboardingDictationLanded)
    }

    /// The only relaunch offered anywhere in the flow.
    func relaunchForDeadTap() {
        stop()
        AppRelauncher.relaunch()
    }

    // MARK: - Derived view state

    var audioLevel: Float { readDictation?().audioLevel ?? 0 }

    /// `0:03` under the Try-it field.
    var recordingClock: String {
        String(format: "%d:%02d", recordingSeconds / 60, recordingSeconds % 60)
    }

    /// Which of the four dots the flow stands on; `nil` on Welcome and Ready,
    /// which show no row. A machine that skips the Fn step passes through it in
    /// zero time — the dot stays and reads as passed, because a row that changes
    /// length under the user says less than one dot the user never stopped on.
    var dotIndex: Int? {
        guard step != .ready else { return nil }
        return Step.dotted.firstIndex(of: step)
    }
}

/// A delay armed on the *edge* of a condition: `arm` starts the clock the first
/// time a condition is seen and leaves the running task alone while it holds. A
/// dwell re-armed by every 400 ms tick never reaches its own 450 ms deadline,
/// which is how both hand-offs in the flow deadlocked (doc, Detection).
@MainActor
final class DwellTimer {
    private let duration: Duration
    private var armed: AnyHashable?
    private var task: Task<Void, Never>?

    init(duration: Duration) {
        self.duration = duration
    }

    var isArmed: Bool { armed != nil }

    func arm(for condition: some Hashable, _ body: @escaping @MainActor () -> Void) {
        let token = AnyHashable(condition)
        guard armed != token else { return }
        cancel()
        armed = token
        let duration = duration
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.armed == token else { return }
            self.armed = nil
            self.task = nil
            body()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        armed = nil
    }
}
