import AppKit
import Carbon.HIToolbox
import LoreCore
import os

@MainActor
final class HotkeyManager {
    /// One logger, one category. Three of these existed (two sharing a category),
    /// so `log stream --predicate 'category == "Hotkey"'` missed half the file.
    /// Static so the CGEvent tap's C callback, where `self` is inaccessible, uses it too.
    private static let hkLog = Logger(subsystem: "com.lore.app", category: "Hotkey")
    private weak var coordinator: DictationCoordinator?
    private weak var settings: AppSettings?
    /// Read Aloud (#105): Fn+R reads the selection, Fn+Q enqueues it. Set by
    /// the dictation setup alongside `install`; nil simply disables the chords.
    ///
    /// Both keys are the selection's only while agent replies are off, which is
    /// the default — see `fnChord`.
    weak var readAloudController: ReadAloudController? {
        didSet { observeClaimInputs(); syncHotKeys() }
    }
    /// Agent replies (#259): with the switch on, the letters on the talk key
    /// are the player's — R play/pause, [ previous, ] next, J the reply's chat,
    /// M mute — a tap of the talk key alone shows or hides the player (#278),
    /// and Esc stops a reply that is being read aloud. Set by the dictation
    /// setup alongside `install`; nil, or the switch off, leaves every key
    /// exactly what it was.
    weak var agentReplies: AgentReplyController? {
        // Assigned after `install`: the observation starts again so its
        // switch is tracked (#342), and the set re-derived (#346).
        didSet { observeClaimInputs(); syncHotKeys() }
    }
    /// Where Fn+J goes (#258). Nil leaves that one key inert, the way a nil
    /// `readAloudController` leaves the selection's keys inert.
    weak var agentChats: AgentChatNavigator?

    private var globalFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?

    private var fnDown = false {
        didSet { if fnDown != oldValue { syncHotKeys() } }
    }
    /// The Fn key's own flag, from the last flags-changed event (#342) — what
    /// the letters on Fn ride when the talk key is another key. Flags-changed
    /// survives secure input, so this does too.
    private var fnFlagDown = false {
        didSet { if fnFlagDown != oldValue { syncHotKeys() } }
    }
    private var fnTimer: Task<Void, Never>?
    /// Debounce timer for Fn release — Fn modifier flag flickers when other keys pressed
    private var fnReleaseDebounce: Task<Void, Never>? {
        didSet { if (fnReleaseDebounce == nil) != (oldValue == nil) { syncHotKeys() } }
    }
    /// What the debounced release does once it stands.
    private var pendingRelease: (@MainActor (HotkeyManager) -> Void)?
    /// When the talk key last came up, by the event's own clock
    /// (`NSEvent.timestamp`, seconds since boot).
    private var releasedAt: TimeInterval = 0
    private static let releaseDebounce: Duration = .milliseconds(30)
    private static let releaseDebounceSeconds = releaseDebounce / .seconds(1)
    private var isHoldMode = false
    /// True when Fn was held at the moment Space locked. First Fn release after this should be ignored.
    private var fnHeldAtLock = false
    /// Another key went down while the talk key was held (#278): the press was
    /// a chord — Fn+R, Fn+[, Fn+V, Fn+arrow for Home — and not a tap, even when
    /// it is let go inside the window. A flicker's re-press keeps it; a press
    /// after a settled release starts clean.
    private var pressCarriedKey = false

    /// The talk key's decision window (#279): held when it closes, the press is
    /// a dictation; let go inside it, a tap. A press let go before it has never
    /// shown a face, written a history row or pasted a word. 200 ms, where the
    /// shortest take that ever pasted (501 ms of audio, the 300 ms tail in it)
    /// was a hold of about 270 ms.
    static let holdToRecordThreshold: Duration = .milliseconds(200)
    /// The longest a release the system has seen, and lore has not read yet,
    /// is waited for before the press counts as held after all (#343). The
    /// wait starts once the main thread is free again, so a queued release is
    /// read in milliseconds; the ceiling is three times the worst stall
    /// measured (330 ms, #279) and only matters if lore never gets that event.
    static let unreadReleaseCeiling: Duration = .seconds(1)
    /// Slack between the system's clock for its last modifier change and an
    /// event's timestamp. A real release follows its press by tens of ms.
    private static let clockSlack: TimeInterval = 0.01
    /// How long it must be held *inside a locked recording* to open the bubble
    /// (#205). Its own number, deliberately longer than the one above: that one
    /// decides whether a recording begins, this one decides what an already
    /// running one does, and a tap has to stay comfortably under it because a
    /// tap is still the dictation's ending.
    static let lockedHoldThreshold: Duration = .milliseconds(300)
    /// The same figure the predicate below compares against, since a `Date`
    /// interval is what it has to hand.
    private static let lockedHoldSeconds = lockedHoldThreshold / .seconds(1)

    /// When the press now holding the hotkey down inside a locked recording
    /// began (#205). Set at the two moments such a press can start — locking
    /// with the key already down, and pressing it again later — and dropped when
    /// it is let go.
    ///
    /// A timestamp rather than a timer: the indicator polls every 50 ms, so the
    /// bubble opens within a tick of the threshold either way, and one recorded
    /// instant cannot fall out of step with itself the way a second `Task` and
    /// the flag it sets could.
    private var lockedHoldStart: Date?

    /// This press has been down past the threshold. The one fact the bubble and
    /// the release both read, so they cannot disagree about whether it was a
    /// hold.
    private var lockedHoldPassedThreshold: Bool {
        guard let lockedHoldStart else { return false }
        return Date().timeIntervalSince(lockedHoldStart) >= Self.lockedHoldSeconds
    }

    /// The bubble is open, held there by the key (#205) — read by the indicator's
    /// poll beside `isLocked`.
    ///
    /// Derived rather than stored, so it cannot outlive what holds it: letting
    /// go, unlocking, Esc, a dead tap and the recording ending all close the
    /// bubble without a line of their own.
    var isFnHoldingBubble: Bool { isLocked && fnDown && lockedHoldPassedThreshold }
    /// True while a key recorder is open (#226). The press the user makes there
    /// is them choosing a talk key, not holding one, so no gesture may start.
    /// Only the start: a recording already running still ends on its release,
    /// because a suspended release would leave the mic open under no key.
    var isSuspended = false

    /// The keycode the tap has to own end to end, because the chosen talk key is
    /// not a modifier (#226). Nil for Fn and Right Option, which ride
    /// `flagsChanged` — and nil is the common case, so the tap's extra branch
    /// costs one dictionary-free comparison per key.
    ///
    /// Also nil while a recorder is open, and that is the whole of it being
    /// *swallowed*: the tap consumes this key on every press, so a suspension
    /// that only stopped the gesture would still eat the keystroke and the
    /// recorder — listening on an NSEvent monitor downstream of the tap — would
    /// wait forever for a key the user is pressing. Suspended, the key is
    /// nobody's and passes straight through to the prompt.
    var recordedTalkKeyCode: UInt16? {
        guard !isSuspended else { return nil }
        return settings?.hotkeyKey.tapKeyCode
    }

    /// Locked = recording continues after the talk key's release; the key ends
    /// it, the key with Space pauses it, and Esc cancels it (#206, #233).
    private(set) var isLocked = false {
        didSet { if isLocked != oldValue { syncHotKeys() } }
    }
    /// Set synchronously so the local monitor closure can check it without main actor hop
    nonisolated(unsafe) private var isRecordingFlag = false
    /// Synchronous mirror of isLocked for CGEvent tap callback
    nonisolated(unsafe) private var isLockedFlag = false
    /// Synchronous mirror: true during pre-buffer phase (before hold confirmed)
    nonisolated(unsafe) private var isPreBufferingFlag = false

    /// Health monitor: periodic check of event tap, permissions, SecureInput
    private var healthMonitorTask: Task<Void, Never>?
    /// When our tap's own callback last received a key-down. Stamped **there and
    /// nowhere else** — that is the whole of #97 (see `runHealthCheck` step 4).
    ///
    /// `nil` until the first one arrives, so "no key-down has ever reached our
    /// tap" is a fact we hold rather than a short silence that looks like health
    /// (#135). Seeding it with `Date()` made every launch read as fed for 30 s;
    /// seeding it with `.distantPast` would make every launch read as starved.
    private var lastTapKeyDown: Date?
    /// Fired once per launch, when the first *real* key-down reaches our tap —
    /// the fact that closes the #135 signing migration. With the 5 s health
    /// cycle gone (#140), the acknowledge has to ride the event itself: the
    /// launch path wires this to one `HealthMonitor.refresh()`.
    var onFirstRealKeyDown: (() -> Void)?
    /// The floor a silence is measured from before any key-down has arrived.
    private let launchedAt = Date()
    /// Previous permission state, tracked per permission so each carries its own edge
    private var lastAccessibilityOK = true
    private var lastInputMonitoringOK = true
    /// The last secure-input reading of the 5 s health cycle, to record the
    /// flag's edges and to notice any change in what the panel would say.
    private var lastSecureInput: SecureInput.State?
    /// The secure-input reading changed — the flag, the holder or the lock —
    /// or the keys it would stop did (`deadShortcuts`, #346), so an open
    /// health panel re-reads and its row never states a stale holder or key
    /// (#341). The launch path wires this to one `HealthMonitor.refresh()`.
    var onSecureInputChanged: (() -> Void)?

    /// CGEvent tap for consuming Space/Esc when external apps are focused
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// How many consecutive rebuilds of a dead tap the 5 s health cycle may
    /// attempt (#149). Three, then it stops until something actually changes.
    private static let maxTapRepairs = 3
    /// The live repair budget. Refilled by a real signal only — never by the
    /// cycle that spends it. See `refillTapRepairBudget`.
    private var tapRepairs = RetryBudget(limit: maxTapRepairs)
    private var wakeObserver: NSObjectProtocol?

    /// Read-only liveness of the existing tap, for the health panel (#83, #97).
    /// Never creates a tap — reports on the one this manager already owns, so the
    /// panel reads the same tap the hotkey uses rather than installing a second.
    ///
    /// Updated by `runHealthCheck` every 5 s. Carries both the enabled/existence
    /// fact and the measured starvation, because they are different questions: a
    /// tap can be enabled yet starved (the reported "Fn dead, all toggles on"
    /// incident), and only the pair is an honest verdict.
    private(set) var tapLiveness = TapLiveness()

    /// The last attempt to create the tap failed (#338). The launch attempt
    /// happens before the health monitor listens, so the monitor reads this
    /// once when it starts: the effect it is told about, not a guess.
    private(set) var lastTapCreateFailed = false

    /// Enabled/existence only — NOT event flow. Feeds `TapLiveness.isAlive`.
    /// Read live by the health probe and by the onboarding Try-it step (#150),
    /// which offers its one recovery card off it. Deliberately not a stored
    /// verdict: the card withdraws itself if the tap comes back.
    var isEventTapAlive: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    /// The one place `lastTapKeyDown` is stamped (#97), called by the tap
    /// callback for every real (non-synthetic) key-down. On the first one it
    /// feeds the liveness measurement itself and only then fires
    /// `onFirstRealKeyDown` — the order is the #135 ack's correctness: the
    /// refresh that callback runs reads `tapLiveness`, and the 5 s repair loop
    /// has usually not ticked between the key-down and the refresh, so without
    /// the fresh observe the one-shot would be consumed reading the stale
    /// pre-key-down value and the migration would never acknowledge.
    /// Internal so the wiring is pinned by `SigningMigrationTests`.
    func noteRealKeyDown() {
        let isFirst = lastTapKeyDown == nil
        lastTapKeyDown = Date()
        guard isFirst, let onFirstRealKeyDown else { return }
        Task { @MainActor in
            // Off the tap callback's critical path — the key event must not
            // wait on a registry read or a probe pass.
            self.observeTapLiveness(secureInputActive: SecureInput.read().active)
            onFirstRealKeyDown()
        }
    }

    /// Feed one measurement to `TapLiveness`: step 4 of the health cycle, and
    /// the first-real-keydown path above.
    private func observeTapLiveness(secureInputActive: Bool) {
        tapLiveness.observe(
            isAlive: isEventTapAlive,
            hasReceivedKeyDown: lastTapKeyDown != nil,
            tapSilent: Date().timeIntervalSince(lastTapKeyDown ?? launchedAt),
            sessionSilent: CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: .keyDown
            ),
            secureInputActive: secureInputActive
        )
    }

    func install(coordinator: DictationCoordinator, settings: AppSettings) {
        self.coordinator = coordinator
        self.settings = settings

        // The lock is a fact only this manager's own paths used to clear —
        // Fn-release, the lock glyph's click. Any other ending (a cancel, a
        // discard, a failure) had no way to tell it, and left the sidebar's
        // dot pulsing after the recording was long gone (#225). This is the one
        // subscription that covers every such path; see `clearStaleLock` and
        // `DictationCoordinator.onRecordingEnding`'s own comment.
        coordinator.onRecordingEnding = { [weak self] in
            self?.clearStaleLock()
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }

        // INVARIANT (#95): a global NSEvent monitor cannot consume — it has no
        // return value, and by the time its closure runs the keystroke has
        // already been delivered to the focused app. So it must never handle a
        // key that must be consumed. Every consumable key (Space lock, Esc,
        // Fn+V/T/K/S) is owned by the CGEvent tap, which can return nil; this
        // monitor is narrowed to the one chord it uniquely owns and
        // that may pass through: Ctrl+Cmd+V re-paste, which the tap does not
        // carry. Routing all keys here once made Space lock leak a literal
        // space into the user's document whenever the tap missed the event.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard HotkeyManager.isRepasteChord(event) else { return }
            Task { @MainActor in
                self?.handleKeyDown(event, on: .globalMonitor)
            }
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
            return event
        }

        // Local key monitor — return nil to consume events we handle
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // The tap's own mirror, for when the tap is dead and lore is in
            // front: a key inside a press makes it a chord (#278). Idempotent,
            // so the tap and this both marking one key is one mark.
            self.noteKeyDown(keyCode: event.keyCode)

            // Lore's controls — the Fn letters, Space, Esc — through the one
            // decision the tap and the hot keys take (`controlPress`), for when
            // the tap is dead and lore is in front; when both are live the tap
            // consumes first. Only lore's keys are swallowed: a bare Space
            // inside a locked recording is a space, and while the screenshot
            // crosshair is up Esc is the crosshair's.
            if self.isDuplicatePress(event.keyCode, on: .localMonitor) { return nil }
            if let press = self.controlPress(
                keyCode: event.keyCode, fnHeld: event.modifierFlags.contains(.function),
                talkKeyHeld: self.talkKeyHeld(event.modifierFlags)
            ) {
                // Auto-repeat is the same press still down: swallowed with the
                // press it belongs to, acted on once (#233).
                let isRepeat = event.isARepeat
                self.noteActed(event.keyCode, on: .localMonitor)
                Task { @MainActor in self.perform(press, isRepeat: isRepeat) }
                return nil
            }
            // An Esc that is not lore's reaches the handler only when it has
            // something to record: a reply an earlier Esc stopped, still
            // inside the window (#259).
            if event.keyCode == DictationEscape.keyCode {
                if self.agentReplies?.escapeRepeatIsWorthRecording == true {
                    let isRepeat = event.isARepeat
                    Task { @MainActor in self.handleEscape(.passThrough, isRepeat: isRepeat) }
                }
                return event
            }

            // All other keys pass through normally
            Task { @MainActor in
                self.handleKeyDown(event, on: .localMonitor)
            }
            return event
        }

        // A fresh install is a fresh signal (#149).
        tapRepairs.reset()
        installEventTap()

        // The recording's control keys as hot keys (#342): delivered while
        // another app holds secure input, when the tap above gets nothing.
        // The system releases them when the process exits or crashes.
        hotKeys.registrar.onEvent = { [weak self] key, pressed in
            self?.handleHotKey(key, pressed: pressed)
        }
        observeClaimInputs()

        // Wake is the other genuine signal (#149): the tap can be refused while
        // WindowServer is still coming back, and nothing else would try again.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refillTapRepairBudget() }
        }

        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { break }
                self.runHealthCheck()
            }
        }

        HotkeyManager.hkLog.info("Hotkey manager installed")
    }

    func uninstall() {
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalFlagsMonitor = nil
        globalKeyMonitor = nil
        localFlagsMonitor = nil
        localKeyMonitor = nil

        healthMonitorTask?.cancel()
        healthMonitorTask = nil

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil

        teardownEventTap()

        cancelHoldWindow()
        cancelRelease()
        lockedHoldStart = nil
        coordinator?.onRecordingEnding = nil
        coordinator = nil
        settings = nil
        screenshotUIPending = false
        pollTask?.cancel()
        pollTask = nil
        hotKeys.apply([])
        hotKeys.registrar.onEvent = nil
        HotkeyManager.hkLog.info("Hotkey manager uninstalled")
    }

    /// Modifier enable toggle lookup (DSET-05): Space lock, Fn+V cleanup and
    /// Fn+T translate each gate on one SettingsStore flag; absent settings
    /// default to enabled. (Fn+K has no switch. Fn+S is not here — its switch
    /// is Copying's own, read live through `RichInputSettings`.) The NSEvent
    /// monitors and the CGEvent tap callback all run on the main thread (the
    /// tap source is added to CFRunLoopGetMain — see the Space path's
    /// assumeIsolated precedent), so this is a cheap cached-property read in
    /// the event path. Esc is not a modifier and is never gated.
    nonisolated private func modifierOn(_ read: @MainActor (AppSettings) -> Bool) -> Bool {
        MainActor.assumeIsolated {
            guard let settings else { return true }
            return read(settings)
        }
    }

    /// Internal, not private, so `LockedFnHoldTests` can put a real
    /// flags-changed event through the one function that decides what a press
    /// means (#205). The NSEvent monitors are its only other callers.
    func handleFlagsChanged(_ event: NSEvent) {
        // A synthetic event may carry no timestamp: it was read now, and must
        // not leave the window believing a change is still unread (#343).
        let time = event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime
        lastFlagsChangeRead = max(lastFlagsChangeRead, time)
        fnFlagDown = event.modifierFlags.contains(.function)
        let hotkeyKey = settings?.hotkeyKey ?? .fn
        // A recorded talk key that is not a modifier never appears here: it
        // arrives as a key-down and a key-up through the tap (#226), and asking
        // `isDown` about it would answer no on every flag change.
        guard hotkeyKey.isModifier else { return }
        let hotkeyPressed = hotkeyKey.isDown(after: event, wasDown: fnDown)

        let flags = event.modifierFlags.rawValue
        HotkeyManager.hkLog.info("[HK] flags=\(String(flags, radix: 16)) pressed=\(hotkeyPressed) fnDown=\(self.fnDown) locked=\(self.isLocked) hold=\(self.isHoldMode)")

        if hotkeyPressed && !fnDown {
            beginHotkeyPress(at: time)
        } else if !hotkeyPressed && fnDown {
            endHotkeyPress(at: time)
        }
    }

    /// The recorded talk key's key-down / key-up, handed over by the CGEvent tap
    /// (#226). It reaches the same two functions the modifier path does, so a
    /// hold, a lock, a chord and a release mean exactly what they always meant —
    /// only the event that carries them is different.
    ///
    /// Internal so tests drive it the way `handleFlagsChanged` is driven.
    func handleRecordedKey(down: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if down {
            guard !fnDown else { return }  // auto-repeat: still one press
            beginHotkeyPress(at: now)
        } else if fnDown {
            endHotkeyPress(at: now)
        }
    }

    /// The talk key went down, at `time` by the event's own clock.
    private func beginHotkeyPress(at time: TimeInterval) {
        // A key recorder is open: this press is the user choosing a key, not a
        // hold (#226). Nothing is armed, so the release has nothing to unwind.
        guard !isSuspended else { return }

        // A re-press within the debounce of the release, by the events' own
        // clock, is the Fn flag flickering under another key: the same press,
        // chord mark and all. A later one is a new press however late the main
        // thread reads it — a pre-buffer opening can hold it past the debounce
        // — and the release before it is settled first, so a tap is never lost
        // to the next one (#279).
        if fnReleaseDebounce != nil, time - releasedAt >= Self.releaseDebounceSeconds {
            settleRelease()
        }
        if fnReleaseDebounce == nil { pressCarriedKey = false }
        pressedAt = time
        awaitingUnreadRelease = false
        fnDown = true
        cancelRelease()

        if coordinator == nil {
            HotkeyManager.hkLog.error("[HK] coordinator is nil in beginHotkeyPress — events being dropped")
        }

        if isLocked {
            // Don't stop yet — V/T chord may follow. Stop happens on Fn release.
            // And the press is one of two gestures, told apart by the clock
            // (#205): a tap stops and pastes, as a locked recording has always
            // ended; held past the threshold it opens the bubble for as long
            // as the key is down, which is exactly when Fn+T, Fn+K and Fn+S
            // are pressed.
            lockedHoldStart = Date()
            HotkeyManager.hkLog.debug("[HOTKEY] hotkey pressed while locked → waiting for chord or release")
            return
        }

        // The microphone opens now, so the first syllable is not clipped. It
        // is lore's own and a signal to nobody (#279); what the press is gets
        // decided in `decideTalkKeyPress`.
        isPreBufferingFlag = true
        coordinator?.startPreBuffer()
        // Now, not on the observation's next turn: a Space right after the
        // talk key must find its hot key registered (#342).
        syncHotKeys()

        isHoldMode = false
        fnTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.holdToRecordThreshold)
            guard !Task.isCancelled, let self else { return }
            // The system's keyboard runs ahead of the events lore has read
            // (#279). It saying "up" is believed only when it has also seen a
            // modifier change lore has not read yet: that release is on its way,
            // and it decides. With nothing unread, no release happened — the
            // reading is wrong (#343: a held Right Option read as up) — and the
            // press is the hold it is.
            let key = self.settings?.hotkeyKey ?? .fn
            if case .keyUp(let lastChange) = self.systemRelease(key) {
                if lastChange > self.lastFlagsChangeRead + Self.clockSlack {
                    // Its own timestamp decides when it lands (`endHotkeyPress`).
                    self.awaitingUnreadRelease = true
                    try? await Task.sleep(for: Self.unreadReleaseCeiling)
                    if Task.isCancelled { return }
                    self.awaitingUnreadRelease = false
                }
                DiagStore.record(.talkKeyReleasedInWindow(key: key.diagTalkKey, confirmed: false))
            }
            self.decideTalkKeyPress(heldThroughWindow: true)
        }
    }

    /// What the system's keyboard says about the talk key when the window
    /// closes. Injected only by tests, which have no keyboard.
    enum SystemRelease: Equatable {
        /// Down, or a key flags cannot read (its key-up is the only witness).
        case noClaim
        /// Up, the system's last modifier change at `lastFlagsChange`, on the
        /// clock event timestamps use.
        case keyUp(lastFlagsChange: TimeInterval)
    }

    private let systemRelease: @MainActor (HotkeyKey) -> SystemRelease

    /// The timestamp of the last flags-changed event lore has read.
    private var lastFlagsChangeRead: TimeInterval = 0
    /// The hold window ends undecided — a release, Esc, a lock, a chord, a
    /// teardown — and nothing it was waiting for may outlive it.
    private func cancelHoldWindow() {
        fnTimer?.cancel()
        fnTimer = nil
        awaitingUnreadRelease = false
    }

    /// The current press's timestamp, by the event's clock.
    private var pressedAt: TimeInterval = 0
    /// The window closed on a release the system had seen and lore had not
    /// read (#343): when it lands, its timestamp says whether the key was held
    /// through the window, not the moment lore got to it.
    private var awaitingUnreadRelease = false

    /// The system registrar is passed in by the app alone (`AppCoordinator`):
    /// the default registers nothing, so no test can take the owner's Space.
    init(
        systemRelease: @escaping @MainActor (HotkeyKey) -> SystemRelease = HotkeyManager.liveSystemRelease,
        hotKeys registrar: HotKeyRegistering = InertHotKeys()
    ) {
        self.systemRelease = systemRelease
        self.hotKeys = RecordingHotKeys(registrar: registrar)
    }

    private static func liveSystemRelease(_ key: HotkeyKey) -> SystemRelease {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
        guard key.isHeld(in: flags) == false else { return .noClaim }
        let since = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .flagsChanged)
        return .keyUp(lastFlagsChange: ProcessInfo.processInfo.systemUptime - since)
    }

    /// What a press of the talk key is, decided here alone (#279): held when
    /// the window closes, a dictation — everything it brings starts here; let
    /// go inside it, a tap (the player, nothing else) or, with a key in it, a chord.
    private func decideTalkKeyPress(heldThroughWindow: Bool) {
        isPreBufferingFlag = false
        if heldThroughWindow {
            isHoldMode = true
            isRecordingFlag = true
            HotkeyManager.hkLog.debug("[HOTKEY] held through the window → dictation")
            readAloudController?.pauseForDictation()
            coordinator?.confirmRecording()
            // The letters inside a recording are claimed from now (#342).
            syncHotKeys()
            return
        }
        coordinator?.cancelPreBuffer()
        // A sticky mic error can surface on a tap too (synchronous .denied
        // path); startPreBuffer cancels its grace hide on the next press.
        coordinator?.dismissMicErrorAfterRelease()
        afterReleaseDebounce { manager in
            guard !manager.pressCarriedKey else { return }
            manager.agentReplies?.togglePlayer()
        }
    }

    /// The talk key came up, at `time` by the event's own clock.
    private func endHotkeyPress(at time: TimeInterval) {
        fnDown = false
        releasedAt = time
        let releaseWasAwaited = awaitingUnreadRelease
        cancelHoldWindow()
        // A press that lasted past the threshold was a hold: it opened the
        // bubble, so letting go closes the bubble and does nothing else —
        // swallowed by the latch every chord already uses (#205). Read
        // before the timestamp is dropped, so what opened the bubble and
        // what swallows the release are one fact and not two.
        if isLocked && lockedHoldPassedThreshold { fnHeldAtLock = true }
        lockedHoldStart = nil

        if isLocked {
            if fnHeldAtLock {
                // First release after lock-while-holding — just continue recording.
                // Still a genuine Fn release: clear any sticky mic error (no-op when none
                // is showing). The `.sticky` hide path leaves autoHideTask nil, so without
                // this an error reached through this branch would never clear.
                fnHeldAtLock = false
                HotkeyManager.hkLog.debug("[HOTKEY] hotkey released after lock → continues (initial release)")
                coordinator?.dismissMicErrorAfterRelease()
                return
            }
            // Subsequent release — stop recording (with debounce for Fn flag flicker)
            afterReleaseDebounce { manager in
                manager.isLocked = false
                manager.isLockedFlag = false
                manager.isRecordingFlag = false
                HotkeyManager.hkLog.debug("[HOTKEY] hotkey released while locked → stop + paste")
                // Genuine release (past the 30ms flag-flicker debounce): if a sticky
                // mic error is showing, begin its grace hide; otherwise stop normally.
                // stopRecording only spawns the coordinator-owned pipeline (#104):
                // the next Fn press cancels this debounce Task, and the in-flight
                // transcription must not die with it.
                manager.coordinator?.dismissMicErrorAfterRelease()
                manager.coordinator?.stopRecording()
            }
            return
        }

        if releaseWasAwaited {
            // The release the window waited for (#343), decided by its own
            // timestamp: held through the window, the press records and this
            // release ends it like any hold's; let go inside it, a tap.
            let heldThroughWindow = time - pressedAt >= Self.holdToRecordThreshold / .seconds(1)
            DiagStore.record(.talkKeyReleasedInWindow(
                key: (settings?.hotkeyKey ?? .fn).diagTalkKey, confirmed: !heldThroughWindow
            ))
            if heldThroughWindow { decideTalkKeyPress(heldThroughWindow: true) }
        }

        if isHoldMode {
            // Debounce hold-to-talk release too (same Fn flag flickering issue).
            afterReleaseDebounce { manager in
                manager.isHoldMode = false
                manager.isRecordingFlag = false
                HotkeyManager.hkLog.debug("[HOTKEY] hold mode release → stop + paste")
                // Genuine release (past the 30ms flag-flicker debounce): if a sticky
                // mic error is showing, begin its grace hide; otherwise stop normally.
                // As above, stopRecording spawns the pipeline elsewhere (#104).
                manager.coordinator?.dismissMicErrorAfterRelease()
                manager.coordinator?.stopRecording()
            }
            return
        }

        decideTalkKeyPress(heldThroughWindow: false)
    }

    /// A release acts 30 ms later, and only if the key is still up: the Fn flag
    /// flickers when other keys are pressed, and a flicker's re-press cancels
    /// this (`beginHotkeyPress`). The one debounce every release path shares.
    private func afterReleaseDebounce(_ act: @escaping @MainActor (HotkeyManager) -> Void) {
        cancelRelease()
        pendingRelease = act
        fnReleaseDebounce = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseDebounce)
            guard !Task.isCancelled, let self, !self.fnDown else { return }
            self.settleRelease()
        }
    }

    /// The pending release acts now.
    private func settleRelease() {
        let act = pendingRelease
        cancelRelease()
        act?(self)
    }

    /// The pending release is dropped without acting.
    private func cancelRelease() {
        fnReleaseDebounce?.cancel()
        fnReleaseDebounce = nil
        pendingRelease = nil
    }

    /// A key went down (#278). While the talk key is held that makes the press
    /// a chord, never a tap. Called by both event paths for every real
    /// key-down; the recorded talk key's own auto-repeat is excluded by its
    /// caller.
    ///
    /// Not the Globe key's own key-down (#279): macOS sends one, without the fn
    /// flag, just before the flag clears at the release of every short press of
    /// fn. It is the talk key being let go, and counting it made every tap a
    /// chord — the player never came up on a real keyboard.
    func noteKeyDown(keyCode: UInt16) {
        guard fnDown else { return }
        if keyCode == HotkeyKey.globeKeyCode, (settings?.hotkeyKey ?? .fn) == .fn { return }
        pressCarriedKey = true
    }

    /// Callers: the local key monitor and the global monitor's Ctrl+Cmd+V chord
    /// only — invariant at the global monitor's installation (#95). The local
    /// monitor is meant to consume Space / Esc / Fn+V/T itself before routing
    /// here; known exception: during pre-buffer its narrower `isRecordingFlag`
    /// guard lets Fn+V/T fall through to its unconsuming fallthrough, so the
    /// keystroke lands in Lore's own field while the branch below still applies
    /// the mode. Space is not here at all: `spaceAction` is the whole decision,
    /// taken at the monitor itself (#233).
    private func handleKeyDown(_ event: NSEvent, on channel: PressChannel) {
        guard let coordinator else {
            HotkeyManager.hkLog.error("[HK] coordinator is nil in handleKeyDown — events being dropped")
            return
        }

        // Fn+V/T while recording → set pre-paste cleanup mode
        // Use event's own .function flag (reliable even when Fn modifier flickers)
        if event.modifierFlags.contains(.function) && (coordinator.state == .recording || coordinator.isPreBuffering),
           let chord = recordingChord(keyCode: Int64(event.keyCode)) {
            handleRecordingChord(chord)
            return
        }

        // Esc is not here: both event paths decide it where they consume it
        // (#233, #259), so this function is never reached for one.

        // Ctrl+Cmd+V to re-paste last transcript. Under secure input the hot
        // key has it too (#346): one press, one paste.
        if HotkeyManager.isRepasteChord(event),
           !isDuplicatePress(Self.repasteHotKey.keyCode, on: channel) {
            noteActed(Self.repasteHotKey.keyCode, on: channel)
            coordinator.pasteLastTranscript()
        }
    }

    // MARK: - Escape (#206, cancels since #233, stops a reply since #259)

    /// What this Esc is — one decision, taken by whichever event path saw the
    /// key and handed to `handleEscape`, so consuming and acting cannot
    /// disagree (the reason Space is read this way too).
    enum EscapeAction: Equatable, Sendable {
        /// Not lore's: the app in front receives the key.
        case passThrough
        /// A live dictation ends into history and nothing is pasted (#233).
        case cancelDictation
        /// An agent reply being read aloud pauses (#259), whether the player is
        /// shown or put away (#277); the player stays as it was.
        case pauseReply
        /// The player is up with nothing speaking: it goes away (#263). Which is
        /// what the second Esc does, the first one having paused the reply.
        case hidePlayer
        /// The ?'s card is pinned on the player (#289): it closes before Esc
        /// does anything else of the player's.
        case closeHelp

        /// The whole table, as a function of five readings — so the precedence
        /// can be walked without a keyboard, a microphone or a crosshair, the
        /// way `SpaceAction.decide` is (#263). Stated here and nowhere else: a
        /// caller that restated its first line would be a second place for the
        /// precedence to drift.
        ///
        /// A dictation outranks everything of the player's: ending a recording
        /// is what Esc has meant since #233, and the microphone that recording
        /// holds has paused the reply anyway. The crosshair outranks even that —
        /// consuming the key there would leave the user unable to cancel a
        /// screenshot they are taking *into* this dictation. And with none of
        /// the three, the app in front keeps its key.
        ///
        /// A reply speaking is a claim of its own (#277): the voice is lore's
        /// wherever the player is, so the first thing Esc does to it is stop it
        /// — shown or put away, whichever app is in front, and from the chat's
        /// name to the reply's last word, the gap between them included. Only
        /// the hide needs the plate on screen: a player nobody can see cannot
        /// be put away, so with nothing speaking and the player away the key is
        /// the front app's, which is what is drawn (`no-false-positives.md`).
        ///
        /// The ?'s card pinned on the player (#289) comes before both: it is
        /// what he last opened, and Esc closes it before it pauses a reply or
        /// hides the plate — the order after that is #277's. A recording still
        /// outranks it: a card left open costs nothing, a dictation Esc failed
        /// to cancel pastes.
        ///
        /// `screenshotUIIsUp` is taken unevaluated: that reading walks every
        /// running application and every on-screen window, this is called inside
        /// a system-wide event tap on the main thread, and Esc is pressed all
        /// day long with no dictation and nothing of lore's speaking or on
        /// screen — so the line above it is all the hot path pays.
        static func decide(
            dictating: Bool, helpPinned: Bool, replySpeaking: Bool, playerShowing: Bool,
            screenshotUIIsUp: @autoclosure () -> Bool
        ) -> Self {
            guard dictating || helpPinned || replySpeaking || playerShowing,
                  !screenshotUIIsUp()
            else {
                return .passThrough
            }
            if dictating { return .cancelDictation }
            if helpPinned { return .closeHelp }
            return replySpeaking ? .pauseReply : .hidePlayer
        }
    }

    /// Whose this Esc is — the one reading both event paths take, so a key
    /// cannot be consumed by the local monitor and ignored by the tap. Every
    /// reading is live here; which of them wins is `EscapeAction.decide`, and
    /// only there.
    ///
    /// The dictation's is `state == .recording`, and the talk key's window
    /// before it (#279): a press still inside it is a dictation in waiting,
    /// and Esc cancels it before it becomes one.
    ///
    /// The ?'s card pinned on a player on screen (#289) → close it, first of
    /// everything the player claims.
    ///
    /// The player's is a reply speaking, on screen or not (#277) → pause —
    /// only while the pause would take, so an Esc in the instant after the last
    /// word is not swallowed for nothing; and
    /// the plate on screen with nothing speaking (#263) → hide, which is what
    /// its own strip says Esc will do. The waiting capsule is not the player —
    /// it carries no strip, so it promises nothing about Esc, and the key stays
    /// the app's in front. So does every other moment, which is nearly all of
    /// them.
    ///
    /// The switch needs no reading of its own: with it off the controller holds
    /// no reply, speaks none and draws nothing.
    var escapeAction: EscapeAction {
        escapeAction(dictating: isDictating, screenshotUIIsUp: readScreenshotUI())
    }

    /// The same reading with the two inputs the hot key set states itself
    /// (#346): no dictation, and the crosshair lore knows of instead of the
    /// window walk.
    func escapeAction(dictating: Bool, screenshotUIIsUp: @autoclosure () -> Bool) -> EscapeAction {
        EscapeAction.decide(
            dictating: dictating,
            helpPinned: agentReplies?.isHelpPinned == true,
            replySpeaking: agentReplies?.canStopSpeech == true,
            playerShowing: agentReplies?.isPlayerShowing == true,
            screenshotUIIsUp: screenshotUIIsUp()
        )
    }

    /// Esc taken. A dictation ends into history and nothing is pasted (#233) —
    /// the same key in a held, a locked and a paused recording alike, and the
    /// only way to it since #234, which retired the paused bubble's `Cancel`
    /// pill. A reply being read aloud pauses and stays where it is (#259), and
    /// the press after that puts the player away (#263).
    ///
    /// Idempotent by the coordinator's own latch, which is what a held Esc
    /// needs: auto-repeat reaches this ~30 times a second while the key is down,
    /// and the reply's own pause refuses everything but a speaking reply. The
    /// lock, if there was one, is cleared by the ending itself (#225).
    ///
    /// `isRepeat` is that same press still down, and three branches care. The
    /// pass-through's: a repeat is not the second Esc that meant the app in
    /// front. The pause's: the press that closed the ?'s card (#289) goes on
    /// repeating while it is held, and nothing but a *second press* may pause
    /// the reply. And the hide's, for the same reason: the press that paused a
    /// reply may not also take the player away. It is read here rather than at
    /// the two event paths so both refuse it identically — the reason
    /// `handleSpace` takes it too.
    ///
    /// Internal, not private, so `DictationPauseTests` drives the one function
    /// both event paths converge on — the same reason `handleFlagsChanged` is.
    func handleEscape(_ action: EscapeAction, isRepeat: Bool) {
        switch action {
        case .passThrough:
            HotkeyManager.hkLog.debug("[HOTKEY] Esc → not ours, passed through")
            // An Esc the owner pressed again right after one that stopped a
            // reply: they meant the app in front, and that is the whole point
            // of measuring it (#259). The controller holds the window and the
            // event; it records nothing outside it.
            if !isRepeat { agentReplies?.escapePassedThrough() }
        case .cancelDictation:
            guard let coordinator else { return }
            if coordinator.isPreBuffering {
                // Inside the talk key's window (#279): the press would become
                // a dictation at 200 ms, so Esc cancels it now — no recording,
                // and its release is no tap.
                HotkeyManager.hkLog.debug("[HOTKEY] Esc → pending dictation cancelled")
                cancelHoldWindow()
                isPreBufferingFlag = false
                pressCarriedKey = true
                coordinator.cancelPreBuffer()
                return
            }
            HotkeyManager.hkLog.debug("[HOTKEY] Esc → cancelled into history")
            coordinator.cancelRecording()
        case .closeHelp:
            HotkeyManager.hkLog.debug("[HOTKEY] Esc → the player's help card closed")
            agentReplies?.help.close()
        case .pauseReply:
            guard !isRepeat else { return }
            HotkeyManager.hkLog.debug("[HOTKEY] Esc → agent reply paused")
            agentReplies?.pauseByEscape()
        case .hidePlayer:
            guard !isRepeat else { return }
            HotkeyManager.hkLog.debug("[HOTKEY] Esc → agent replies player hidden")
            agentReplies?.hidePlayer(by: .escape)
        }
    }

    // MARK: - Space (#201, and the pause chord since #233)

    /// What Space means to a live dictation right now — one decision, taken by
    /// both event paths, so the key cannot be swallowed by one and ignored by
    /// the other.
    ///
    /// The coordinator's own state is consulted rather than the sync mirrors: a
    /// failed pre-buffer parks in `.done` and leaves `isPreBufferingFlag` stale,
    /// which would phantom-lock onto a recording that never started.
    ///
    /// Internal so `DictationPauseTests` can walk the table without a keyboard.
    func spaceAction(talkKeyHeld: Bool) -> SpaceAction {
        guard let coordinator, modifierOn({ $0.modifierLockEnabled }),
              coordinator.state == .recording || coordinator.isPreBuffering
        else { return .passThrough }
        return SpaceAction.decide(
            locked: isLocked, paused: coordinator.isPaused, talkKeyHeld: talkKeyHeld
        )
    }

    /// What Space does — the one table the key, the lock glyph and the row's own
    /// glyph slot all read (#233, #234), so what a surface offers and what the
    /// key does cannot drift apart.
    ///
    /// The rail's Space cap read it too until #235 retired the cap: since #234
    /// the lock glyph and the dot *are* those controls, so a keycap naming the
    /// same action was a second name for one thing (`ui-language.md` rule 1).
    /// The table itself is untouched — the chord still locks, pauses and
    /// resumes — and only `cap(talkKey:)`, which drew the label and the line
    /// under it, went with the cap.
    enum SpaceAction: Equatable, Sendable, CaseIterable {
        /// Not lore's — a bare Space inside a locked recording is a space.
        case passThrough
        case lock
        case pause
        case resume

        /// The whole rule, pure: `locked` and `paused` are the dictation's,
        /// `talkKeyHeld` the keyboard's — and for a glyph clicked by pointer,
        /// which is the chord's pointer form, it is true by definition.
        static func decide(locked: Bool, paused: Bool, talkKeyHeld: Bool) -> SpaceAction {
            // Space alone locks a held recording, exactly as it always has.
            guard locked else { return .lock }
            // Locked, the key is the user's own — they are typing — unless the
            // talk key is down with it: the pause is the second press of the
            // key the thumb is already on.
            guard talkKeyHeld else { return .passThrough }
            return paused ? .resume : .pause
        }
    }

    /// Space taken. Internal for the same reason `handleEscape` is.
    ///
    /// `isRepeat` is the key still being held down, and it is refused here so
    /// both event paths refuse it identically: a held chord re-read
    /// `coordinator.isPaused` on every repeat and flipped pause and resume at
    /// the key-repeat rate (#233). One physical press, one action. The repeat
    /// is still swallowed by the path that read it — the key is lore's for the
    /// whole press, and letting the repeats through would type spaces into the
    /// document under a held chord.
    func handleSpace(_ action: SpaceAction, isRepeat: Bool) {
        guard let coordinator, !isRepeat else { return }
        switch action {
        case .passThrough:
            break
        case .lock:
            lockRecording(coordinator)
            HotkeyManager.hkLog.debug("[HOTKEY] Space → confirm + locked")
        case .pause:
            coordinator.pauseRecording()
            // The talk key's next release is the end of the chord and not the
            // end of the dictation — the same latch Fn+V, Fn+T, Fn+K and Fn+S
            // set at their own sites.
            if isLocked { fnHeldAtLock = true }
            HotkeyManager.hkLog.debug("[HOTKEY] talk key + Space → paused")
        case .resume:
            coordinator.resumeRecording()
            if isLocked { fnHeldAtLock = true }
            HotkeyManager.hkLog.debug("[HOTKEY] talk key + Space → resumed")
        }
    }

    /// Is the talk key down for a chord arriving with these flags (#233)?
    ///
    /// Only Fn is read off the event's own flags, and only because there is one
    /// Fn key on the keyboard: its flag *is* the key, and the flag is what every
    /// other chord reads, since the tracked press flickers. Every other talk key
    /// shares its mask with the twin on the other side of the keyboard —
    /// `.option` is Left Option's too — so a mask cannot tell whose press this
    /// is, and answering off one would swallow Left Option+Space, or Cmd+Space
    /// with a recorded Right Command. Those read the tracked press, which
    /// `isDown(after:wasDown:)` sets from the key's own transition, and
    /// which is also the only fact about a recorded key that raises no flag at
    /// all (#226).
    func talkKeyHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        if (settings?.hotkeyKey ?? .fn) == .fn, flags.contains(.function) { return true }
        return fnDown
    }


    // MARK: - The lock, by pointer (#201)

    /// Confirm and lock — the Space key's own steps, shared with the recording
    /// bubble's lock glyph so there is one lock and not two.
    private func lockRecording(_ coordinator: DictationCoordinator) {
        cancelHoldWindow()
        isHoldMode = false
        isPreBufferingFlag = false
        fnHeldAtLock = fnDown  // Track: if Fn held at lock, first release should continue
        // A hold already under way counts from here (#205). Locking with the key
        // still down and keeping it down past the threshold opens the bubble,
        // exactly as pressing again later does — and locking that way is the
        // commonest route into a locked recording, so without this the gesture
        // would be unreachable by the people most likely to reach for it.
        lockedHoldStart = fnDown ? Date() : nil
        if coordinator.isPreBuffering {
            readAloudController?.pauseForDictation()
            coordinator.confirmRecording()
        }
        isLocked = true
        isLockedFlag = true
        isRecordingFlag = true
        // Every lock, from the one place both routes cross (#235). Without it a
        // hands-free dictation is invisible in the stream —
        // `dictationRecorded(samples:durationMs:)` says nothing about how the
        // key was held — and "did the lock hint change anything" has no answer.
        DiagStore.record(.dictationLocked)
    }

    /// The bubble's lock glyph (#201). Locking is the Space path itself.
    /// Unlocking here and the Fn release are the two endings this manager
    /// starts itself — stop and paste — so both clear the lock synchronously,
    /// before `stopRecording` even reaches the coordinator. Every other ending
    /// (a cancel by Esc, a discard) goes through `clearStaleLock` instead, via
    /// `DictationCoordinator.onRecordingEnding` (#225).
    func toggleLockByClick() {
        guard let coordinator else { return }
        if isLocked {
            cancelRelease()
            fnHeldAtLock = false
            isLocked = false
            isLockedFlag = false
            isRecordingFlag = false
            HotkeyManager.hkLog.debug("[HOTKEY] lock glyph → unlocked → stop + paste")
            coordinator.dismissMicErrorAfterRelease()
            coordinator.stopRecording()
            return
        }
        guard modifierOn({ $0.modifierLockEnabled }),
              coordinator.state == .recording || coordinator.isPreBuffering else { return }
        lockRecording(coordinator)
        HotkeyManager.hkLog.debug("[HOTKEY] lock glyph → confirm + locked")
    }

    /// The shared seam for every ending that is not this manager's own (#225):
    /// `DictationCoordinator.onRecordingEnding` calls this for a cancel,
    /// a discard, and a failure ending alike, since all of them run through
    /// the coordinator's `finish`/`discardRecording` regardless of outcome.
    ///
    /// Guarded on `isLocked` so this is a genuine no-op for the two endings
    /// above: both already clear the lock themselves, synchronously, before
    /// `stopRecording` is even called — by the time the coordinator's hook
    /// fires, there is nothing left here to clear.
    private func clearStaleLock() {
        guard isLocked else { return }
        HotkeyManager.hkLog.debug(
            "[HOTKEY] recording ended outside the lock's own path → lock cleared (#225)"
        )
        cancelRelease()
        fnHeldAtLock = false
        isLocked = false
        isLockedFlag = false
        isRecordingFlag = false
    }

    // MARK: - The letters on the talk key (#105, and the player's since #259)

    /// What a letter pressed with Fn means — one table both event paths read,
    /// so a key cannot be swallowed by one and ignored by the other.
    enum FnChord: Equatable, Sendable {
        /// The agent-replies player (#259). Each of its keys carries its own
        /// keycode, so a key and what it does stay one fact.
        case reply(AgentReplyChord)
        /// Read Aloud (#105): read the selection now, or add it to the queue.
        /// R is the player's own `playOrPause` keycode — one key in two
        /// worlds, and one number — and Q is the one letter that is the
        /// selection's alone.
        case readSelection(enqueue: Bool)
        /// A chord that was taught and now does nothing: Fn+Q while the player
        /// has the keys. Taken all the same — a swallowed key is silence, an
        /// unswallowed one types a `q` into the app in front (#259).
        case retired
    }

    /// The player's keys, as the board prints them
    /// (`docs/design/prototypes/agent-replies-player.html`, its key strip). The
    /// raw value is the keycode, so the key and what it does are one fact and
    /// not two.
    enum AgentReplyChord: UInt16, Equatable, Sendable, CaseIterable {
        /// R — Play / Pause, the play key again (#278). From #263 to #278 it
        /// showed and hid the player; that is a tap of the talk key now.
        case playOrPause = 15
        /// `[` — Previous.
        case previous = 33
        /// `]` — Next.
        case next = 30
        /// J — Go to / Open the reply's chat.
        case goToChat = 38
        /// M — Mute / Unmute.
        case mute = 46
    }

    /// Q's keycode, stated once here because it is the only letter that is not
    /// one of the player's keys above.
    private static let queueSelectionKey: UInt16 = 12

    /// Every key `fnChord` can claim, in one list: read there and by the hot
    /// keys (#342), so the two cannot name different letters.
    static let fnChordKeys: [UInt16] = AgentReplyChord.allCases.map(\.rawValue) + [queueSelectionKey]

    /// Whose this letter is, with Fn held, or nil when it is nobody's — nil
    /// being the common case, and the answer for every key the chord table
    /// does not name.
    ///
    /// The switch decides which set exists, and this is the whole of "while it
    /// is off, every key behaves exactly as today" (#259): on, the player's five
    /// keys, and Q taken but retired so a taught chord cannot type its letter;
    /// off, Fn+R and Fn+Q read the selection as they have since #105. A
    /// recipient that is not wired at all makes its own keys nobody's, which is
    /// what keeps them from even being consumed.
    ///
    /// Internal so tests walk the table without a keyboard.
    func fnChord(keyCode: UInt16) -> FnChord? {
        guard Self.fnChordKeys.contains(keyCode) else { return nil }
        if agentReplies?.isEnabled == true {
            if let key = AgentReplyChord(rawValue: keyCode) { return .reply(key) }
            return keyCode == Self.queueSelectionKey ? .retired : nil
        }
        guard readAloudController != nil else { return nil }
        switch keyCode {
        case AgentReplyChord.playOrPause.rawValue: return .readSelection(enqueue: false)
        case Self.queueSelectionKey: return .readSelection(enqueue: true)
        default: return nil
        }
    }

    /// A letter chord taken. Internal for the same reason `handleEscape` is.
    ///
    /// Whether the key does anything at all is decided *before* the dictation
    /// gesture it arrived under is ended: the Fn that carried the letter has a
    /// microphone open under it, and a key with nothing to act on — an empty
    /// queue, no chat to go to, a retired chord — must not cost the recording
    /// it was pressed inside. It used to, leaving the words nowhere: no paste,
    /// no history entry, no surface (#259).
    func handleFnChord(_ chord: FnChord) {
        let key = String(describing: chord)
        guard let act = action(for: chord) else {
            HotkeyManager.hkLog.debug("[HOTKEY] Fn chord \(key, privacy: .public) → nothing to do")
            return
        }
        HotkeyManager.hkLog.debug("[HOTKEY] Fn chord \(key, privacy: .public)")
        endGestureForChord()
        act()
    }

    /// What this chord would do right now, or nil when it would do nothing.
    /// Every answer is the recipient's own — the queue says whether it has a
    /// reply for the key, the navigator whether it has a chat to go to — so the
    /// question asked here and the action that follows cannot disagree.
    ///
    /// The closure is not `Sendable` on purpose: it holds the recipient and is
    /// called by the line after the one that asked for it, on this actor.
    private func action(for chord: FnChord) -> (() -> Void)? {
        switch chord {
        case .retired:
            return nil
        case .readSelection(let enqueue):
            // No controller wired → fully inert: no gesture teardown, no discard.
            guard let readAloudController else { return nil }
            return {
                Task { @MainActor in
                    if enqueue {
                        await readAloudController.enqueueSelection()
                    } else {
                        await readAloudController.readSelectionNow()
                    }
                }
            }
        case .reply(let key):
            guard let replies = agentReplies else { return nil }
            switch key {
            // Play or pause (#278). With no reply at the position there is
            // nothing to play, and the key is a dead one, which is what keeps
            // it off a live dictation.
            case .playOrPause:
                return replies.canPlayOrPause ? { replies.playOrPause() } : nil
            case .previous: return replies.canPlayPrevious ? { replies.previous() } : nil
            case .next: return replies.canPlayNext ? { replies.next() } : nil
            // Mute is not a reply's action but the state arriving replies are
            // held by, so it is the one key an empty queue still answers.
            case .mute: return { replies.toggleMute() }
            case .goToChat:
                guard let chats = agentChats, chats.canOpenCurrent else { return nil }
                return { Task { @MainActor in await chats.openCurrent() } }
            }
        }
    }

    /// Ends the dictation gesture a letter chord arrived under, without pasting.
    ///
    /// A chord and a dictation are the same press of the same key: the Fn that
    /// carries the letter has already opened the microphone (pre-buffer), and
    /// the two gestures are mutually exclusive, so the chord wins and any
    /// gesture in flight (pre-buffer, hold, locked) aborts before it acts.
    /// Unlike Fn+V/T nothing "pending" is set; the subsequent Fn release then
    /// falls through the tap path as a no-op (timer cancelled, flags cleared
    /// here) — and is not a tap for the player, because the letter marked the
    /// press as a chord (`noteKeyDown`, #278).
    private func endGestureForChord() {
        cancelHoldWindow()
        cancelRelease()
        isHoldMode = false
        fnHeldAtLock = false
        isLocked = false
        isLockedFlag = false
        isRecordingFlag = false
        isPreBufferingFlag = false
        // Abort only a live capture gesture — never a `.processing` transcription
        // of an earlier dictation, which discardRecording would also kill.
        if let coordinator, coordinator.isPreBuffering || coordinator.state == .recording {
            coordinator.discardRecording()
            // What the discarded dictation did to a reply is undone, so the
            // chord acts on the reply as the press found it (#279).
            agentReplies?.dictationDiscardedByChord()
        }
    }

    /// Ctrl+Cmd+V exactly — a superset like Ctrl+Cmd+Shift+V is someone else's
    /// shortcut. The one chord the global keyDown monitor may handle (see the
    /// invariant at its installation, #95).
    private static func isRepasteChord(_ event: NSEvent) -> Bool {
        event.keyCode == repasteHotKey.keyCode
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.control, .command]
    }

    /// Control-Command-V as a hot key (#346), registered only while secure
    /// input is held: otherwise the chord reaches the app in front as well.
    static let repasteHotKey = ControlHotKey(keyCode: 9, modifiers: UInt32(controlKey | cmdKey))

    // MARK: - The letters inside a recording (Fn+V/T/S/K)

    /// A letter on Fn that acts on the recording itself. The raw value is the
    /// keycode, so the key and what it does are one fact.
    enum RecordingChord: UInt16, Equatable, Sendable, CaseIterable {
        case cleanup = 9      // V
        case translate = 17   // T
        case screenshot = 1   // S (#192/#198)
        case mark = 40        // K (#324: always on)
    }

    /// Whose this letter is inside a recording, Fn held: the one reading the
    /// tap, the local monitor and the hot keys (#342) take. Nil when the key is
    /// none of them or its switch is off.
    func recordingChord(keyCode: Int64) -> RecordingChord? {
        guard let code = UInt16(exactly: keyCode), let chord = RecordingChord(rawValue: code) else {
            return nil
        }
        switch chord {
        case .cleanup: return modifierOn({ $0.modifierCleanupEnabled }) ? chord : nil
        case .translate: return modifierOn({ $0.modifierTranslateEnabled }) ? chord : nil
        case .screenshot: return RichInputSettings.screenshotsEnabled ? chord : nil
        case .mark: return chord
        }
    }

    /// A recording chord taken.
    func handleRecordingChord(_ chord: RecordingChord) {
        guard let coordinator else { return }
        switch chord {
        case .cleanup: coordinator.setPendingMode(.cleanup)
        case .translate: coordinator.setPendingMode(.translate)
        case .mark: coordinator.toggleMark()
        case .screenshot:
            // The system's own crosshair, pressed for the user — the image
            // lands on the clipboard and the door collects it. Still consumed
            // while paused, and does nothing: that door is shut (#206).
            if !coordinator.isPaused {
                TextInserter.postScreenshotToClipboard()
                noteScreenshotPosted()
            }
        }
        // The talk key's next release ends the chord, not the dictation.
        if isLocked { fnHeldAtLock = true }
        HotkeyManager.hkLog.debug("[HOTKEY] Fn chord \(String(describing: chord), privacy: .public) inside a recording")
    }

    // MARK: - One decision for a control key

    /// What a key-down is to lore right now: the one decision the tap, the
    /// local monitor and the hot keys take, so none of them can claim a key
    /// another passes, or act in another order. Nil: not lore's — the key is
    /// passed on (or, arriving as a hot key, swallowed: see `handleHotKey`).
    enum ControlPress: Equatable {
        case recordingChord(RecordingChord)
        case fnChord(FnChord)
        case space(SpaceAction)
        case escape(EscapeAction)
        /// Control-Command-V: paste the last transcript again. Reaches
        /// `perform` only as a hot key (#346); the monitors take it in
        /// `handleKeyDown`.
        case repaste
    }

    /// `fnHeld` and `talkKeyHeld` are the event's own readings; the keycodes
    /// of the four kinds do not overlap, so the order only states precedence.
    func controlPress(keyCode: UInt16, fnHeld: Bool, talkKeyHeld: Bool) -> ControlPress? {
        if fnHeld, isRecordingFlag, let chord = recordingChord(keyCode: Int64(keyCode)) {
            return .recordingChord(chord)
        }
        if fnHeld, let chord = fnChord(keyCode: keyCode) { return .fnChord(chord) }
        if keyCode == HotkeyKey.spaceKeyCode {
            let action = spaceAction(talkKeyHeld: talkKeyHeld)
            return action == .passThrough ? nil : .space(action)
        }
        if keyCode == DictationEscape.keyCode {
            let action = escapeAction
            return action == .passThrough ? nil : .escape(action)
        }
        return nil
    }

    /// A control key taken, whichever path saw it.
    func perform(_ press: ControlPress, isRepeat: Bool) {
        switch press {
        case .recordingChord(let chord): handleRecordingChord(chord)
        case .fnChord(let chord): handleFnChord(chord)
        case .space(let action): handleSpace(action, isRepeat: isRepeat)
        case .escape(let action): handleEscape(action, isRepeat: isRepeat)
        case .repaste: coordinator?.pasteLastTranscript()
        }
    }

    // MARK: - The recording's keys as hot keys (#342)

    /// The registered hot keys, kept equal to `claimedHotKeys`.
    private let hotKeys: RecordingHotKeys

    /// A screenshot crosshair owns Esc, so Esc leaves the hot key set while
    /// one is up: from the moment lore posts the shortcut, or from an Esc hot
    /// key pressed while one is up (one the user raised, or lore's taking
    /// longer than `screenshotAppearWindow`) — that one press is the
    /// documented loss, and the next Esc reaches the crosshair. Cleared by the
    /// poll (`pollTick`) once the crosshair is gone, and by every recording's
    /// end (`syncHotKeys`).
    private var screenshotUIPending = false
    /// Before this the crosshair is given time to appear and is not read.
    private var screenshotUIDeadline = ContinuousClock.now
    /// How long the crosshair is given to appear after lore posts it.
    static let screenshotAppearWindow: Duration = .seconds(1)
    /// The crosshair reading. Injected only by tests, which have no screen.
    var readScreenshotUI: @MainActor () -> Bool = { DictationEscape.screenshotUIIsUp }
    /// The secure-input flag alone, cheap enough for every poll tick (#346).
    /// Injected only by tests, which never hold secure input for real.
    var readSecureInputFlag: @MainActor () -> Bool = { IsSecureEventInputEnabled() }

    /// Called right after lore posts a screenshot shortcut (Fn+S, the
    /// Cmd+Shift+3/4 redirect). Internal so tests drive it without raising a
    /// real crosshair.
    func noteScreenshotPosted() { watchScreenshotUI(appearing: Self.screenshotAppearWindow) }

    /// Esc out of the set until no crosshair is up, `appearing` given first.
    private func watchScreenshotUI(appearing: Duration) {
        screenshotUIPending = true
        screenshotUIDeadline = ContinuousClock.now + appearing
        syncHotKeys()
    }

    /// A recording is live: the talk key's window or the recording itself.
    private var isDictating: Bool {
        guard let coordinator else { return false }
        return coordinator.state == .recording || coordinator.isPreBuffering
    }

    /// The talk key counts as held for registration until its release settles
    /// — the Fn flag flickers under other keys, and a Space pressed inside a
    /// flicker must still find its hot key — except in a locked recording,
    /// where a Space in that window is the user's typing to the tap too.
    private var talkKeyEngaged: Bool { fnDown || (!isLocked && fnReleaseDebounce != nil) }

    /// Every key the tap would claim right now, as hot keys — derived from the
    /// tap's own decisions (`spaceAction`, `escapeAction`'s dictation line,
    /// `recordingChord`, `fnChord`), never a list of its own. Empty outside a
    /// recording unless secure input is held. Inside a locked recording with
    /// the talk key up, Space and the letters are the user's typing and are
    /// not here; Esc is, except while lore's own screenshot crosshair is up.
    ///
    /// A Carbon hot key matches its modifiers exactly, Fn included (measured
    /// live: with Fn held only a registration carrying the Fn bit fires). So
    /// each key is registered in the shape the press will have. Space and Esc,
    /// which the tap claims with any modifiers: bare, and while the talk key
    /// is held also with its modifier (Fn's bit, Option for Right Option).
    /// The letters, which the tap claims only with the Fn flag: with Fn's bit,
    /// plus the talk key's modifier while it is held.
    /// Keys the tap claims that are no control of a recording (Fn+P's probe,
    /// the Cmd+Shift+3/4 redirect) are left to the tap.
    ///
    /// While secure input is held (#346), what the tap and the monitors act on
    /// outside a recording joins the set, under the conditions they act on
    /// it: Control-Command-V; the letters on fn that `fnChord` claims now
    /// (Read aloud's R and Q, or the player's keys with agent replies on);
    /// and bare Esc while `escapeAction` makes it lore's with no dictation —
    /// a reply speaking, the player or its pinned help on screen — unless a
    /// crosshair lore knows of owns it. Never a bare letter: typing stays
    /// typing.
    var claimedHotKeys: Set<ControlHotKey> {
        var keys: Set<ControlHotKey> = []
        if secureInputHeld, coordinator != nil {
            keys.insert(Self.repasteHotKey)
            // Fn's shape only, narrower than `controlPress` (which takes the
            // letter with any other modifier too), on purpose: no typing
            // combination is taken system-wide.
            keys.formUnion(Self.hotKeys(Self.fnChordKeys.filter { fnChord(keyCode: $0) != nil },
                                        in: [HotkeyKey.fn.carbonModifier]))
            if escapeAction(dictating: false, screenshotUIIsUp: screenshotUIPending) != .passThrough {
                keys.insert(ControlHotKey(keyCode: DictationEscape.keyCode, modifiers: 0))
            }
        }
        guard isDictating else { return keys }
        let talkKey = settings?.hotkeyKey ?? .fn
        let talkHeld = talkKeyEngaged
        var codes: [UInt16] = []
        if spaceAction(talkKeyHeld: talkHeld) != .passThrough { codes.append(HotkeyKey.spaceKeyCode) }
        // `EscapeAction.decide`'s first claim: a dictation takes Esc — and its
        // one exception, a screenshot crosshair (`screenshotUIPending`).
        if !screenshotUIPending { codes.append(DictationEscape.keyCode) }
        let held: UInt32 = talkHeld ? talkKey.carbonModifier : 0
        let fn = HotkeyKey.fn.carbonModifier
        let fnHeld = talkKey == .fn ? talkHeld : fnFlagDown
        let fnShape: Set<UInt32> = [fn, fn | held]
        // Space and Esc gain Fn's shape whenever Fn is down, whatever the talk
        // key (Right Option+Fn+Space).
        let anyShape: Set<UInt32> = fnHeld ? fnShape.union([0, held]) : [0, held]
        keys.formUnion(Self.hotKeys(codes, in: anyShape))
        if fnHeld {
            let letters = (RecordingChord.allCases.map(\.rawValue) + Self.fnChordKeys).filter {
                (isRecordingFlag && recordingChord(keyCode: Int64($0)) != nil) || fnChord(keyCode: $0) != nil
            }
            keys.formUnion(Self.hotKeys(letters, in: fnShape))
        }
        return keys
    }

    /// The last secure-input reading says another app holds it on an unlocked
    /// console: the tap and the monitors receive no key-down. Behind a locked
    /// console nothing is claimed and nothing polls.
    private var secureInputHeld: Bool { lastSecureInput?.isProblem == true }

    /// The one poll: re-derives the set every 250 ms while a crosshair may be
    /// up or secure input is held. It watches the crosshair; under secure
    /// input it re-reads the flag, so the set drops within a tick of the flag
    /// clearing rather than at the next 5 s health reading, and it catches
    /// what makes Esc the player's but nothing observes (the linger running
    /// out on the clock, the speaker becoming pausable).
    private var pollTask: Task<Void, Never>?

    /// Each key in each shape. Carbon's registry counts a Caps Lock twin as
    /// the base key (-9868, measured 2026-10-31), so no twin is registered.
    /// Shift is not added — a Shift-modified press under secure input is a
    /// documented gap (`docs/features/fn-hotkey.md`).
    private static func hotKeys(_ codes: [UInt16], in shapes: Set<UInt32>) -> Set<ControlHotKey> {
        Set(codes.flatMap { code in shapes.map { ControlHotKey(keyCode: code, modifiers: $0) } })
    }

    /// What is registered now — read by tests.
    var registeredHotKeys: Set<ControlHotKey> { hotKeys.registered }

    /// Register what the tap claims now and unregister the rest. Called on
    /// every change of what the set reads: the talk key, its release, the
    /// lock, the Fn flag, the crosshair, the secure-input reading, and —
    /// through `observeClaimInputs` — the dictation's state, the settings and
    /// the reply state behind the decisions. Outside a recording, with secure
    /// input off, the set is empty, so every way a recording ends — finish,
    /// cancel, discard, failure — unregisters everything.
    private func syncHotKeys() {
        // Every recording's end, in one place: no crosshair watch outlives it —
        // unless secure input keeps the player's Esc in play (#346), where
        // the poll clears it once the crosshair is gone.
        if !isDictating, !secureInputHeld { screenshotUIPending = false }
        hotKeys.apply(claimedHotKeys)
        let dead = deadShortcuts
        if dead != lastDeadShortcuts {
            lastDeadShortcuts = dead
            onSecureInputChanged?()
        }
        guard pollTask == nil, screenshotUIPending || secureInputHeld else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                guard self.pollTick() else { self.pollTask = nil; return }
            }
        }
    }

    /// One tick of the poll; false once there is nothing left to watch.
    private func pollTick() -> Bool {
        if screenshotUIPending, ContinuousClock.now >= screenshotUIDeadline, !readScreenshotUI() {
            screenshotUIPending = false
        }
        if secureInputHeld, !readSecureInputFlag() {
            // The 5 s health reading fills in the rest; the flag is what the
            // set follows.
            noteSecureInput(SecureInput.State(
                active: false, pid: nil, consoleLocked: lastSecureInput?.consoleLocked ?? false,
                attribution: .nobody, name: nil
            ))
        }
        syncHotKeys()
        return screenshotUIPending || secureInputHeld
    }

    /// The lore keys that cannot work while another app holds secure input
    /// (#346): a talk key that is a recorded non-modifier key, which only the
    /// tap reads, and every hot key lore wants and the system refused. Read by
    /// the health panel, which shows them only while secure input stands.
    var deadShortcuts: DeadShortcuts {
        // The board's order: Control-Command-V, the fn letters, esc.
        func rank(_ key: ControlHotKey) -> (Int, Int, String) {
            if key == Self.repasteHotKey { return (0, 0, key.displayName) }
            switch key.keyCode {
            case DictationEscape.keyCode: return (3, 0, key.displayName)
            case HotkeyKey.spaceKeyCode: return (2, 0, key.displayName)
            default: return (1, Self.letterOrder.firstIndex(of: key.keyCode) ?? .max, key.displayName)
            }
        }
        var names: [String] = []
        for key in hotKeys.refused.sorted(by: { rank($0) < rank($1) }) where !names.contains(key.displayName) {
            names.append(key.displayName)
        }
        return DeadShortcuts(talkKey: settings.map { !$0.hotkeyKey.isModifier } ?? false, keys: names)
    }
    private var lastDeadShortcuts = DeadShortcuts()
    /// The fn letters in the order Settings lists them, then the recording's.
    private static let letterOrder: [UInt16] = AgentReplyChord.allCases.map(\.rawValue) + [queueSelectionKey]
        + RecordingChord.allCases.map(\.rawValue)

    /// One secure-input reading (#341, #346): its edges are traced, an open
    /// health panel re-reads, and the hot keys follow. Called by the 5 s
    /// health cycle; internal so tests hand it a reading.
    func noteSecureInput(_ secureInput: SecureInput.State) {
        let wasActive = lastSecureInput?.active ?? false
        if secureInput.active, !wasActive {
            DiagStore.record(.secureInputChanged(active: true, holderPID: secureInput.pid))
            // The holder's *name* identifies software the user runs — os.Logger only.
            HotkeyManager.hkLog.error("[HK] Health: SecureInput active — associated with \(secureInput.name ?? "an unnamed process", privacy: .private) (pid \(secureInput.pid.map(String.init) ?? "none", privacy: .public))")
        } else if !secureInput.active, wasActive {
            DiagStore.record(.secureInputChanged(active: false, holderPID: nil))
            HotkeyManager.hkLog.info("[HK] Health: SecureInput cleared")
        }
        guard secureInput != lastSecureInput else { return }
        lastSecureInput = secureInput
        onSecureInputChanged?()
        syncHotKeys()
    }

    /// The one observation point for every input of `claimedHotKeys` that is
    /// not this manager's own: the dictation's state, the talk key setting,
    /// the lock and chord switches, the screenshot switch, and the agent
    /// replies switch. Re-armed on every change, so an ending this manager did
    /// not start (an error, a model failure) or a setting flipped mid-recording
    /// reaches the registration.
    private func observeClaimInputs() {
        // One chain at a time: a second install or a late `agentReplies`
        // starts a new one, and the old one stops at its next change.
        observationGeneration &+= 1
        let generation = observationGeneration
        guard let coordinator else { return }
        withObservationTracking {
            _ = coordinator.state
            _ = coordinator.isPreBuffering
            _ = settings?.hotkeyKey
            _ = settings?.modifierLockEnabled
            _ = settings?.modifierCleanupEnabled
            _ = settings?.modifierTranslateEnabled
            _ = settings?.richInputSwitches
            _ = agentReplies?.isEnabled
            // What makes Esc the player's outside a recording (#346).
            _ = agentReplies?.isHelpPinned
            _ = agentReplies?.canStopSpeech
            _ = agentReplies?.isPlayerShowing
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observationGeneration == generation else { return }
                self.syncHotKeys()
                self.observeClaimInputs()
            }
        }
    }

    private var observationGeneration = 0

    /// This key-down is a press another channel already acted on (#342):
    /// every channel asks first, before deciding, and swallows it.
    func isDuplicatePress(_ keyCode: UInt16, on channel: PressChannel) -> Bool {
        hotKeys.isDuplicate(keyCode, on: channel, now: ProcessInfo.processInfo.systemUptime)
    }

    /// A channel acts on this key-down.
    func noteActed(_ keyCode: UInt16, on channel: PressChannel) {
        hotKeys.noteActed(keyCode, on: channel, now: ProcessInfo.processInfo.systemUptime)
    }

    /// A registered key went down or up. A fresh press acts through the same
    /// decision the tap takes (`controlPress`), read live.
    ///
    /// A press that decision passes on is swallowed, not handed back: posting
    /// a synthetic key into the app in front could land out of order, unpaired
    /// or in a password field. The set follows every input of the decision, so
    /// such a press needs a change the set has not caught up with yet; the
    /// chosen trade is that a residual miss costs at most one press during a
    /// recording. Outside a recording, under secure input, the one such press
    /// is the player's Esc after a reading nothing observes has changed (the
    /// linger running out): swallowed, at most for one 250 ms poll tick.
    ///
    /// Internal so tests can press a hot key without a keyboard.
    func handleHotKey(_ key: ControlHotKey, pressed: Bool) {
        guard hotKeys.takePress(key, pressed: pressed) else { return }
        var outcome = HotKeyOutcome.notOurs
        // Every fresh press, whatever came of it, so a live test reads from events.json.
        defer { DiagStore.record(.hotKeyPressed(key: key.diagKey, outcome: outcome)) }
        guard !isDuplicatePress(key.keyCode, on: .hotKey) else { outcome = .duplicate; return }
        noteKeyDown(keyCode: key.keyCode)
        let flags = NSEvent.ModifierFlags(
            rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)
        )
        // Control-Command-V is matched by its exact shape, which only it has.
        guard let press = key == Self.repasteHotKey ? .repaste : controlPress(
            keyCode: key.keyCode, fnHeld: flags.contains(.function) || fnFlagDown,
            talkKeyHeld: talkKeyHeld(flags)
        ) else {
            HotkeyManager.hkLog.debug("[HOTKEY] hot key \(key.keyCode, privacy: .public) not ours now → swallowed")
            // A crosshair is up and owns Esc: Esc steps aside until it goes,
            // so the next press reaches it.
            if key.keyCode == DictationEscape.keyCode, readScreenshotUI() {
                watchScreenshotUI(appearing: .zero)
            }
            return
        }
        noteActed(key.keyCode, on: .hotKey)
        outcome = .acted
        HotkeyManager.hkLog.debug("[HOTKEY] hot key \(key.keyCode, privacy: .public) pressed")
        perform(press, isRepeat: false)
    }

    // MARK: - Event Tap Lifecycle

    /// Create the CGEvent tap and attach it to the main run loop.
    private func installEventTap() {
        // Key-up is in the mask for exactly one key: a recorded talk key that is
        // not a modifier (#226). Everything else here is a key-down, and the
        // callback returns any other key-up untouched before it reads a thing.
        let eventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        // SAFETY: self must outlive the event tap. Currently guaranteed because
        // HotkeyManager is owned by AppDelegate for the app's entire lifetime.
        // If ownership changes, this must become passRetained + release in teardown.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                // If the tap is disabled by the system, re-enable it
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    DiagStore.record(.tapDisabledByOS)
                    HotkeyManager.hkLog.error("[HK] CGEvent tap was disabled, re-enabling")
                    if let refcon {
                        let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                        if let tap = mgr.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passRetained(event)
                }

                guard let refcon else { return Unmanaged.passRetained(event) }

                // Lore's own synthetic chords (paste's Cmd+V/Z, Read Aloud's
                // Cmd+C) arrive here too — cghidEventTap injection is upstream
                // of the session tap. They are not the user's keyboard: letting
                // them stamp liveness made every paste self-certify the tap as
                // fed and silently acknowledge the #135 migration (#140). None
                // of them is a key Lore handles, so pass straight through.
                if SyntheticKeyEvent.isOurs(event) { return Unmanaged.passRetained(event) }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

                // A real key-down from the user's keyboard (the synthetic guard
                // above) — the fact the health check exists to measure and never
                // did (#97). A key-up is the same press seen twice and must not
                // count as a second one.
                //
                // The tap's source is on CFRunLoopGetMain (see below), so this runs on
                // the main thread: the same assumption `modifierOn` and the Space path
                // already make, and why no `nonisolated(unsafe)` mirror is needed.
                if type == .keyDown {
                    MainActor.assumeIsolated {
                        manager.noteRealKeyDown()
                    }
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags

                // A recorded talk key that is not a modifier (#226): the tap is
                // its only owner, because it has to be swallowed — the key does
                // nothing else, and it is held for the length of a sentence.
                // Auto-repeat is that same press still down, not a second one.
                if let talkKey = MainActor.assumeIsolated({ manager.recordedTalkKeyCode }),
                   keyCode == Int64(talkKey) {
                    if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                        return nil
                    }
                    let down = (type == .keyDown)
                    Task { @MainActor in
                        manager.handleRecordedKey(down: down)
                        HotkeyManager.hkLog.debug(
                            "[HOTKEY] recorded key \(down ? "down" : "up", privacy: .public) (CGEvent)"
                        )
                    }
                    return nil
                }

                // Past here everything reads a key-down. Every other key-up is
                // in the mask only because the one above had to be.
                guard type == .keyDown else { return Unmanaged.passRetained(event) }

                // Any other key while the talk key is held makes the press a
                // chord, not a tap (#278) — read before a single branch below
                // can return, so a key lore swallows counts as much as one it
                // passes on.
                if let code = UInt16(exactly: keyCode) {
                    MainActor.assumeIsolated { manager.noteKeyDown(keyCode: code) }
                }

                // Lore's controls — the Fn letters inside a recording, the Fn
                // letters of Read aloud and the player, Space, Esc — through the
                // one decision the local monitor and the hot keys take
                // (`controlPress`), read here rather than in the Task so
                // consuming and acting cannot disagree. The event's own Fn flag
                // is read, not the tracked press, which flickers.
                // `CGEventFlags` and `NSEvent.ModifierFlags` are the same bits.
                // The tap source is on CFRunLoopGetMain, so assumeIsolated is
                // valid here.
                let fnHeld = flags.contains(.maskSecondaryFn)
                // A hot key already acted on this press (#342): swallowed —
                // neither acted on twice nor passed on to the app in front.
                if let code = UInt16(exactly: keyCode),
                   MainActor.assumeIsolated({ manager.isDuplicatePress(code, on: .tap) }) {
                    return nil
                }
                if let code = UInt16(exactly: keyCode),
                   let press = MainActor.assumeIsolated({
                       manager.controlPress(
                           keyCode: code, fnHeld: fnHeld,
                           talkKeyHeld: manager.talkKeyHeld(NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)))
                       )
                   }) {
                    MainActor.assumeIsolated { manager.noteActed(code, on: .tap) }
                    // Auto-repeat is the same press still down: swallowed with
                    // the press it belongs to; Space and Esc refuse to act on it.
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    // The sync mirrors, before the Task: the next event in this
                    // same turn has to see the lock the user just took.
                    if case .space(.lock) = press, !isRepeat {
                        manager.isLockedFlag = true
                        manager.isPreBufferingFlag = false
                        manager.isRecordingFlag = true
                    }
                    Task { @MainActor in manager.perform(press, isRepeat: isRepeat) }
                    return nil
                }

                // Fn+P while recording → the paste-protection probe (#192, step
                // 0). Removable with `ClipboardProbe`: three pasteboard reads,
                // 1.5 s apart, so a system alert can be attributed to one of
                // them. Gated on isRecordingFlag like the sibling chords above —
                // otherwise this diagnostic fires on every Fn+P system-wide.
                if fnHeld && keyCode == 35 && manager.isRecordingFlag {
                    Task { @MainActor in
                        await ClipboardProbe.run()
                        HotkeyManager.hkLog.debug("[HOTKEY] Fn+P (CGEvent) → clipboard probe")
                    }
                    return nil
                }

                // Cmd+Shift+4/3 while dictating → the clipboard variant, so a
                // screenshot taken mid-sentence joins the prompt instead of
                // landing in a folder nothing is reading (#199). The one place
                // lore changes system behaviour: only during a recording, only
                // with both switches on, and only for the bare chord.
                if manager.isRecordingFlag,
                   let shortcut = ScreenshotShortcut(keyCode: keyCode, flags: flags),
                   RichInputSettings.screenshotsEnabled,
                   RichInputSettings.redirectsSystemScreenshot,
                   // Nothing collects while the dictation stands paused (#206),
                   // so nothing is redirected either: a picture sent to the
                   // clipboard that no door is open for is a screenshot the user
                   // asked their own system for and lore quietly moved.
                   !MainActor.assumeIsolated({ manager.coordinator?.isPaused ?? false }) {
                    let fullScreen = shortcut.isFullScreen
                    DiagStore.record(.dictationScreenshotRedirected(fullScreen: fullScreen))
                    Task { @MainActor in
                        TextInserter.postScreenshotToClipboard(fullScreen: fullScreen)
                        manager.noteScreenshotPosted()
                        HotkeyManager.hkLog.debug(
                            "[HOTKEY] Cmd+Shift+3/4 (CGEvent) → screenshot to clipboard"
                        )
                    }
                    return nil
                }

                // An Esc that is not lore's is passed on, and reaches the
                // handler only when it has something to record: a second Esc
                // right after one that stopped a reply (#259). Every other one —
                // nearly all of them — returns here, off the main actor's back.
                if keyCode == DictationEscape.keyCode,
                   MainActor.assumeIsolated({ manager.agentReplies?.escapeRepeatIsWorthRecording == true }) {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    Task { @MainActor in manager.handleEscape(.passThrough, isRepeat: isRepeat) }
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: userInfo
        )

        lastTapCreateFailed = eventTap == nil
        if let eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            DiagStore.record(.tapCreate(outcome: .ok, osStatus: nil))
            HotkeyManager.hkLog.info("[HK] CGEvent tap installed")
        } else {
            // CGEvent.tapCreate reports no OSStatus — the nil is the honest answer.
            DiagStore.record(.tapCreate(outcome: .failed, osStatus: nil))
            HotkeyManager.hkLog.error("[HK] Failed to create CGEvent tap")
        }
        // The health loop sleeps before its first tick, so without this the panel
        // could be opened in the first 5 s and read the default rather than a tap.
        tapLiveness.isAlive = isEventTapAlive
    }

    /// Remove the CGEvent tap from the run loop and release resources.
    private func teardownEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Tear down and recreate the CGEvent tap from scratch.
    private func reinstallEventTap() {
        HotkeyManager.hkLog.error("[HK] Reinstalling CGEvent tap")

        // If a recording was in progress, the tap death means we lost Fn tracking.
        // Stop the recording so it doesn't get orphaned.
        if fnDown || isHoldMode || isLocked {
            DiagStore.record(.tapDiedDuringRecording)
            fnDown = false
            isHoldMode = false
            isLocked = false
            isLockedFlag = false
            isRecordingFlag = false
            isPreBufferingFlag = false
            cancelHoldWindow()
            coordinator?.stopRecording()
        }

        teardownEventTap()
        installEventTap()
        // installEventTap() already recorded the tapCreate attempt; this records
        // whether the *reinstall* as a whole left us with a live tap.
        DiagStore.record(.tapReinstall(outcome: .init(success: eventTap != nil)))
    }

    /// Rebuild a dead tap, bounded (#149; rationale in diagnostics.md §6).
    ///
    /// A missing grant is not a fault to retry: `CGEvent.tapCreate` cannot succeed
    /// without Accessibility and Input Monitoring, so while either reads off we
    /// attempt nothing at all — no budget spent, no give-up claimed, and the
    /// permission edge already watched in `runHealthCheck` resumes us the moment
    /// it flips. The budget then covers only the transient class that a retry can
    /// actually fix: a post-wake WindowServer refusal, a tap lost to a session
    /// switch.
    private func repairEventTap() {
        guard PermissionReader.accessibilityGranted(),
              PermissionReader.inputMonitoringGranted() else { return }
        guard tapRepairs.allowsAttempt else { return }
        reinstallEventTap()
        if eventTap != nil {
            tapRepairs.reset()
        } else if tapRepairs.noteFailure() {
            DiagStore.record(.tapGaveUp(attempts: Self.maxTapRepairs))
            HotkeyManager.hkLog.error(
                "[HK] Health: tap rebuild gave up after \(Self.maxTapRepairs, privacy: .public) attempts"
            )
        }
    }

    /// Something changed that a retry could now get past: a permission came back,
    /// the Mac woke, or the user opened the health panel at the row that says the
    /// tap is dead. Each is a real signal, never a timer — refill and try at once
    /// rather than making the user wait out a cycle.
    func refillTapRepairBudget() {
        tapRepairs.reset()
        if eventTap == nil { repairEventTap() }
    }

    // MARK: - Health Monitor

    private func runHealthCheck() {
        // 1. Tap alive check
        if let tap = eventTap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                DiagStore.record(.tapDisabledByOS)
                HotkeyManager.hkLog.error("[HK] Health: event tap found disabled, attempting re-enable")
                CGEvent.tapEnable(tap: tap, enable: true)
                // Verify re-enable stuck
                if !CGEvent.tapIsEnabled(tap: tap) {
                    HotkeyManager.hkLog.error("[HK] Health: re-enable failed, reinstalling tap")
                    repairEventTap()
                }
            }
        } else {
            HotkeyManager.hkLog.error("[HK] Health: event tap is nil, reinstalling")
            repairEventTap()
        }

        // 2. Permissions check. Each permission carries its own edge: a combined
        //    `permOK` flag reported both as restored when only one had dropped, and
        //    went deaf to the second one dropping while the first was already down.
        let axOK = PermissionReader.accessibilityGranted()
        let inputOK = PermissionReader.inputMonitoringGranted()
        if axOK != lastAccessibilityOK {
            DiagStore.record(.permissionTransition(permission: .accessibility, granted: axOK))
            if axOK {
                refillTapRepairBudget()
                HotkeyManager.hkLog.info("[HK] Health: Accessibility permission restored")
            } else {
                HotkeyManager.hkLog.error("[HK] Health: Accessibility permission lost (AXIsProcessTrusted = false)")
            }
            lastAccessibilityOK = axOK
        }
        if inputOK != lastInputMonitoringOK {
            DiagStore.record(.permissionTransition(permission: .inputMonitoring, granted: inputOK))
            if inputOK {
                refillTapRepairBudget()
                HotkeyManager.hkLog.info("[HK] Health: Input Monitoring permission restored")
            } else {
                HotkeyManager.hkLog.error("[HK] Health: Input Monitoring permission lost (IOHIDCheckAccess and the preflight both say no)")
            }
            lastInputMonitoringOK = inputOK
        }

        // 3. SecureInput check (record only on transitions to avoid spam). The
        //    flag alone decides the edge: a holder pid is decoration the registry
        //    often cannot supply, and gating on it is what kept this event from
        //    ever firing (#93).
        let secureInput = SecureInput.read()
        noteSecureInput(secureInput)

        // 4. Tap liveness. "We saw no key events for 30s" is not a fault — the user
        //    was reading. The fault is "the session received key-downs and our tap
        //    did not", and both halves of that are now measured from the same
        //    vantage: `lastTapKeyDown` is stamped by the tap's own callback, against
        //    the session's key-downs *alone*. Neither held before (#97) — our side
        //    was stamped by the NSEvent monitors, which starve alongside the tap and
        //    are reset by Fn, and the session side min'd in flagsChanged, an event
        //    type `eventsOfInterest` (`installEventTap`) never asks for, so it could
        //    never have a counterpart on our side and could only ever fabricate
        //    starvation. Secure input, read at step 3, makes that comparison
        //    unmeasurable rather than false — see `TapLiveness.observe`.
        //    The verdict latches in `TapLiveness` and feeds the panel row only:
        //    the stalled/resumed edges are no longer recorded (#140) — a
        //    silence-derived verdict is too weak for the event stream (one
        //    recorded "stall" was 8.8 hours of the user not typing).
        observeTapLiveness(secureInputActive: secureInput.active)
    }
}

