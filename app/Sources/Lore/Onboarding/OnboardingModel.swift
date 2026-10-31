import AppKit
import AVFoundation
import Foundation
import LoreCore
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

    /// Starts the speech model's download and preparation without waiting for
    /// it (#294). Called from the first screen, so by Try it — and the first
    /// real dictation — the model is ready; Try it joins the load rather than
    /// starting a second. The one job that runs before setup finishes: it needs
    /// no permission and captures nothing (`docs/decisions.md`, #150 amended).
    @ObservationIgnored var prepareModel: (() -> Void)?

    /// Arms the dictation subsystem for Try it — after Accessibility is granted,
    /// because a tap created before the grant stays dead.
    @ObservationIgnored var startDictationForTryIt: (() -> Void)?

    /// The dictation subsystem, read live. Called from the flow's body as well
    /// as from the poll, so SwiftUI keeps observing the coordinator's own
    /// properties through it.
    @ObservationIgnored var readDictation: (() -> DictationReading)?

    /// The talk key, read live and written by the Fn step (#226). Read from the
    /// flow's body as well as from `apply`, the same way `readDictation` is, so
    /// SwiftUI keeps observing the settings store through it. Defaults keep a
    /// model built without a store on the shipped answer.
    @ObservationIgnored var readHotkeyKey: () -> HotkeyKey = { .fn }
    @ObservationIgnored var writeHotkeyKey: (HotkeyKey) -> Void = { _ in }

    /// Quiets hold-to-talk while the step's key recorder listens: the press
    /// there is the user choosing a key, not holding one. The step normally
    /// runs before the hotkey manager exists, but a walk back from Try it
    /// reaches it with the manager installed.
    @ObservationIgnored var onHotkeyRecorderListening: (Bool) -> Void = { _ in }

    /// Setup finished — write the flag and boot the app.
    @ObservationIgnored var onFinish: (() -> Void)?

    /// The window's close button and ⌘W follow the required set.
    @ObservationIgnored var onClosableChanged: ((Bool) -> Void)?

    /// Fronts the window after a System Settings round trip.
    @ObservationIgnored var onWantsFront: (() -> Void)?

    /// The drag card docked by System Settings for the two list grants (#300).
    /// The model decides when it shows and when it goes; it never decides a
    /// grant from anything the card saw.
    @ObservationIgnored var grantCard: GrantCardControl?

    // MARK: - Polling

    /// Serialized, off the main actor: these reads block, and on a main-RunLoop
    /// timer that is the AltTab freeze.
    @ObservationIgnored private let pollQueue = DispatchQueue(
        label: "com.lore.app.onboarding.permissions",
        qos: .userInitiated
    )
    @ObservationIgnored private var pollTimer: DispatchSourceTimer?
    @ObservationIgnored private let freshCheckQueue = DispatchQueue(
        label: "com.lore.app.onboarding.grant-check",
        qos: .userInitiated
    )
    @ObservationIgnored private var freshCheckInFlight = false

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
    @ObservationIgnored private var didRegisterInputMonitoring = false
    /// The last fresh-reading failure, so the event stream gets its edge rather
    /// than one event per tick.
    @ObservationIgnored private var lastGrantCheckFailure: GrantCheckFailure?
    @ObservationIgnored private var didArmDictation = false
    /// The poll saw a capture during Try it: the half of the success claim that
    /// typing into the box cannot fake.
    @ObservationIgnored private var didObserveCapture = false

    init(dwell: Duration = .milliseconds(450)) {
        revealDwell = DwellTimer(duration: dwell)
        handoffDwell = DwellTimer(duration: dwell)
    }

    // MARK: - Lifecycle

    /// Start the poll, and the model's preparation beside it. The first tick
    /// fires on the same background queue as every later one — a synchronous
    /// baseline here would block the first frame.
    func start() {
        guard pollTimer == nil else { return }
        prepareModel?()
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(400))
        timer.setEventHandler(handler: makePollTick())
        pollTimer = timer
        timer.resume()
        DiagStore.record(.onboardingStarted)
    }

    /// One tick exactly as the source runs it: the two blocking reads on the
    /// poll queue, a hop, and every mutation on the far side of it. Nothing here
    /// may touch the model — the readings cross as values.
    ///
    /// Handed over by a `nonisolated` factory with an explicit `@Sendable` type
    /// rather than written inline at `setEventHandler`, and that indirection *is*
    /// the fix: a closure literal inside a `@MainActor` method inherits that
    /// isolation, `DispatchSourceTimer` runs it on `pollQueue` regardless, and
    /// the runtime's executor check then traps in the closure's prologue —
    /// before its first line, so the hop below never got the chance to help. The
    /// first tick is scheduled at `.now()`, so a fresh install died there, ahead
    /// of the Welcome frame. Only a test that lets the real source fire can see
    /// it: driving `apply` from a test actor is already main.
    private nonisolated func makePollTick() -> @Sendable () -> Void {
        { [weak self] in
            let mic = MicrophonePermission.status
            let fn = FnKeySetting.current()
            Task { @MainActor [weak self] in
                self?.applyTick(microphone: mic, fn: fn)
            }
        }
    }

    /// The poll's own reading: the microphone and the Fn setting, read here.
    /// Accessibility and Input Monitoring are carried over from the last fresh
    /// reading (#300) — a green for them comes from nowhere else.
    private func applyTick(microphone: AVAuthorizationStatus, fn: FnKeyAction) {
        var snapshot = lastPermissions
        snapshot.microphone = microphone == .authorized
        snapshot.microphoneUndetermined = microphone == .notDetermined
        apply(permissions: snapshot, fn: fn)
        startFreshCheckIfWanted()
    }

    /// The two list grants from a process that did not exist a moment ago
    /// (#300), only while the Permissions step waits on one of them. On its own
    /// queue and one at a time, so a hung child holds neither the microphone
    /// and Fn readings nor a queue of children behind it.
    private func startFreshCheckIfWanted() {
        guard !freshCheckInFlight, step == .permissions,
              permissions.current == .accessibility || permissions.current == .inputMonitoring
        else { return }
        freshCheckInFlight = true
        freshCheckQueue.async { [weak self] in
            let result = GrantCheck.readFresh()
            Task { @MainActor [weak self] in
                self?.freshCheckInFlight = false
                self?.applyFresh(result)
            }
        }
    }

    /// A fresh reading lands; a failed one keeps the reading there was and is
    /// traced on its edge.
    func applyFresh(_ result: Result<GrantCheck.Reading, GrantCheckFailure>) {
        let failure: GrantCheckFailure?
        switch result {
        case .success(let reading):
            failure = nil
            var snapshot = lastPermissions
            snapshot.accessibility = reading.accessibility
            snapshot.inputMonitoring = reading.inputMonitoring
            apply(permissions: snapshot, fn: fnAction)
        case .failure(let reason):
            failure = reason
        }
        if failure != lastGrantCheckFailure {
            lastGrantCheckFailure = failure
            if let failure { DiagStore.record(.grantCheckFailed(reason: failure)) }
        }
    }

    /// The poller is scoped to the window, not to a step: a green that stops
    /// being watched is a latched verdict (doc, Decisions).
    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        revealDwell.cancel()
        handoffDwell.cancel()
        grantCard?.close(.onboardingMoved)
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

        // The card's one claim waits on this reading, never on a drop.
        if let shown = grantCard?.shownGrant, snapshot[shown] {
            grantCard?.allowed()
        }

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

    /// The talk key the flow is teaching.
    var hotkeyKey: HotkeyKey { readHotkeyKey() }

    /// Whether the Fn step has anything to say (#226). It is not a gate any
    /// more: it stands only while Fn is the key the user holds *and* macOS has
    /// taken it. Choosing another key clears it, which is the exit the step
    /// used not to have.
    var fnStepNeeded: Bool { hotkeyKey == .fn && fnAction.conflictsWithHotkey }

    /// The step's alternatives: a key chosen here becomes the talk key, and the
    /// step hands off to Try it exactly the way freeing up Fn does — the dwell
    /// gives the user the moment to see what they picked.
    func chooseHotkey(_ key: HotkeyKey) {
        writeHotkeyKey(key)
        refreshStepForReading()
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
            } else if !fnStepNeeded {
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
            } else if fnStepNeeded, step == .tryIt, tryIt != .landed {
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
            advance(to: fnStepNeeded ? .fnKey : .tryIt)
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
        if next != .permissions { grantCard?.close(.onboardingMoved) }
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

    /// "Allow" on all three cards. The microphone is the one two-tier button —
    /// the caption under it tells which of the two it will do. The two list
    /// grants open their pane and dock the drag card under it (#300).
    func requestGrant(_ grant: RequiredGrant) {
        switch grant {
        case .microphone:
            guard permissions.microphoneUndetermined else {
                openPane(.microphone)
                return
            }
            Task { _ = await MicrophonePermission.request() }

        case .accessibility:
            // Straight to the pane: Apple's prompt is no longer fired, the card
            // carries lore into the list (#300 board, §06).
            openPane(.accessibility)
            grantCard?.show(.accessibility)

        case .inputMonitoring:
            // The request is made once purely so lore has a row in the pane —
            // nothing here depends on it presenting anything (doc).
            if !didRegisterInputMonitoring {
                didRegisterInputMonitoring = true
                pollQueue.async { _ = CGRequestListenEventAccess() }
            }
            openPane(.inputMonitoring)
            grantCard?.show(.inputMonitoring)
        }
    }

    /// Deep-link into System Settings. The Fn step's button opens `.keyboard`;
    /// the permission cards route here through `requestGrant`. The same deep
    /// link the health panel's remedies use; a seam so tests can press Allow
    /// without System Settings opening.
    @ObservationIgnored var openPane: (SettingsPane) -> Void = { $0.open() }

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
