import AppKit
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
    weak var readAloudController: ReadAloudController?
    /// Agent replies (#259): with the switch on, the letters on the talk key
    /// are the player's — R play/pause, [ previous, ] next, J the reply's chat,
    /// M mute — a tap of the talk key alone shows or hides the player (#278),
    /// and Esc stops a reply that is being read aloud. Set by the dictation
    /// setup alongside `install`; nil, or the switch off, leaves every key
    /// exactly what it was.
    weak var agentReplies: AgentReplyController?
    /// Where Fn+J goes (#258). Nil leaves that one key inert, the way a nil
    /// `readAloudController` leaves the selection's keys inert.
    weak var agentChats: AgentChatNavigator?

    private var globalFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?

    private var fnDown = false
    private var fnTimer: Task<Void, Never>?
    /// Debounce timer for Fn release — Fn modifier flag flickers when other keys pressed
    private var fnReleaseDebounce: Task<Void, Never>?
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
    private(set) var isLocked = false
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
    /// Tracks previous SecureInput state to log only on transitions
    private var lastSecureInputActive = false

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
                self?.handleKeyDown(event)
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

            // A letter on Fn → consume (#105, #259): the player's keys while
            // agent replies are on, Fn+R / Fn+Q reading the selection while they
            // are off. Mirror of the CGEvent tap branch for when the tap is dead
            // and Lore itself is focused; when both are live the tap consumes
            // first. A letter that is nobody's is fully inert — not even consumed.
            if event.modifierFlags.contains(.function),
               let chord = self.fnChord(keyCode: event.keyCode) {
                Task { @MainActor in
                    self.handleFnChord(chord)
                }
                return nil
            }

            // Fn+V/T/K/S while recording → consume (use event's own Fn flag, not tracked flag)
            if event.modifierFlags.contains(.function) && self.isRecordingFlag {
                if (event.keyCode == 9 && self.modifierOn({ $0.modifierCleanupEnabled }))
                    || (event.keyCode == 17 && self.modifierOn({ $0.modifierTranslateEnabled }))
                    || (event.keyCode == 40 && self.operatorSendOn()) // V, T, or K (#122/#223)
                    || (event.keyCode == 1 && RichInputSettings.screenshotsEnabled) { // S (#192)
                    Task { @MainActor in
                        self.handleKeyDown(event)
                    }
                    return nil
                }
            }

            // Space inside a recording → lock it, or pause and resume a locked
            // one with the talk key held (#233). Consumed only when it is
            // lore's: a bare Space inside a locked recording is a space.
            if event.keyCode == HotkeyKey.spaceKeyCode {
                let action = self.spaceAction(talkKeyHeld: self.talkKeyHeld(event.modifierFlags))
                if action != .passThrough {
                    // Auto-repeat is the same press still down: swallowed with
                    // the press it belongs to, acted on once (#233).
                    let isRepeat = event.isARepeat
                    Task { @MainActor in
                        self.handleSpace(action, isRepeat: isRepeat)
                    }
                    return nil // swallow the Space
                }
            }

            // Esc → a dictation's cancel, an agent reply's pause, the player
            // going away, or the app in front's own key (#206, #233, #259,
            // #263). The decision is taken here rather than in the Task, so
            // consuming and acting cannot disagree: only lore's Esc is
            // swallowed, and while the system screenshot crosshair is up the
            // key belongs to the crosshair.
            if event.keyCode == DictationEscape.keyCode {
                let action = self.escapeAction
                // A pass-through reaches the handler only when it has something
                // to record — a reply an earlier Esc stopped, still inside the
                // window. Esc is pressed all day long with nothing of lore's
                // happening, and it used to cost a main-actor hop and a log line
                // every time (#259).
                if action != .passThrough
                    || self.agentReplies?.escapeRepeatIsWorthRecording == true {
                    let isRepeat = event.isARepeat
                    Task { @MainActor in
                        self.handleEscape(action, isRepeat: isRepeat)
                    }
                }
                return action == .passThrough ? event : nil
            }

            // All other keys pass through normally
            Task { @MainActor in
                self.handleKeyDown(event)
            }
            return event
        }

        // A fresh install is a fresh signal (#149).
        tapRepairs.reset()
        installEventTap()

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

        fnTimer?.cancel()
        fnTimer = nil
        cancelRelease()
        lockedHoldStart = nil
        coordinator?.onRecordingEnding = nil
        coordinator = nil
        settings = nil
        HotkeyManager.hkLog.info("Hotkey manager uninstalled")
    }

    /// Modifier enable toggle lookup (DSET-05): Space lock, Fn+V cleanup,
    /// Fn+T translate and Fn+K send-to-the-operator each gate on one
    /// SettingsStore flag; absent settings default to enabled. (Fn+S is not
    /// here — its switch is Copying's own, read live through
    /// `RichInputSettings`.) The NSEvent
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

    /// The Fn+K master switch (#223), read strictly: with no settings wired the
    /// answer is *off*, where `modifierOn` answers on for its siblings. They
    /// default to enabled and gate a key the user already knows; this one is off
    /// on every fresh install, so "cannot tell" may not mean yes here. It is the
    /// same reading `DictationCoordinator.toggleOperatorAddressed` takes.
    nonisolated private func operatorSendOn() -> Bool {
        MainActor.assumeIsolated { settings?.operatorSendEnabled == true }
    }

    /// Internal, not private, so `LockedFnHoldTests` can put a real
    /// flags-changed event through the one function that decides what a press
    /// means (#205). The NSEvent monitors are its only other callers.
    func handleFlagsChanged(_ event: NSEvent) {
        let hotkeyKey = settings?.hotkeyKey ?? .fn
        // A recorded talk key that is not a modifier never appears here: it
        // arrives as a key-down and a key-up through the tap (#226), and asking
        // `matchesPress` about it would answer no on every flag change.
        guard hotkeyKey.isModifier else { return }
        let hotkeyPressed = hotkeyKey.matchesPress(event)

        let flags = event.modifierFlags.rawValue
        HotkeyManager.hkLog.info("[HK] flags=\(String(flags, radix: 16)) pressed=\(hotkeyPressed) fnDown=\(self.fnDown) locked=\(self.isLocked) hold=\(self.isHoldMode)")

        if hotkeyPressed && !fnDown {
            beginHotkeyPress(at: event.timestamp)
        } else if !hotkeyPressed && fnDown {
            endHotkeyPress(at: event.timestamp)
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

        isHoldMode = false
        fnTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.holdToRecordThreshold)
            guard !Task.isCancelled, let self else { return }
            // Let go inside the window, its release not read yet: that
            // release decides, and it is a tap.
            if self.talkKeyWasLetGo(self.settings?.hotkeyKey ?? .fn, time) { return }
            self.decideTalkKeyPress(heldThroughWindow: true)
        }
    }

    /// Whether the talk key pressed at `pressTime` (the event's clock) has
    /// been let go with its release not yet read (#279). The main thread reads
    /// events late while a cold microphone opens — 330 ms was measured on the
    /// first tap after a launch — and the window's clock must not outrun a
    /// release it has not seen. Injected only by tests, which have no keyboard.
    private let talkKeyWasLetGo: @MainActor (HotkeyKey, TimeInterval) -> Bool

    init(talkKeyWasLetGo: @escaping @MainActor (HotkeyKey, TimeInterval) -> Bool = HotkeyManager.systemSaysLetGo) {
        self.talkKeyWasLetGo = talkKeyWasLetGo
    }

    /// The system's own keyboard state, which is ahead of the events lore has
    /// read, says a modifier talk key is up. Asked only when the system saw
    /// this press at all (its last flags change is no older than the press); a
    /// recorded key that is not a modifier leaves its key-up as the only witness.
    private static func systemSaysLetGo(_ key: HotkeyKey, pressedAt pressTime: TimeInterval) -> Bool {
        let isDown: Bool
        switch key {
        case .fn: isDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        case .rightOption: isDown = CGEventSource.keyState(.combinedSessionState, key: HotkeyKey.rightOptionKeyCode)
        case .custom(let keyCode):
            guard key.isModifier else { return false }
            isDown = CGEventSource.keyState(.combinedSessionState, key: keyCode)
        }
        let sinceChange = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .flagsChanged)
        return !isDown && sinceChange <= ProcessInfo.processInfo.systemUptime - pressTime
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
        fnTimer?.cancel()
        fnTimer = nil
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
    private func handleKeyDown(_ event: NSEvent) {
        guard let coordinator else {
            HotkeyManager.hkLog.error("[HK] coordinator is nil in handleKeyDown — events being dropped")
            return
        }

        // Fn+V/T while recording → set pre-paste cleanup mode
        // Use event's own .function flag (reliable even when Fn modifier flickers)
        if event.modifierFlags.contains(.function) && (coordinator.state == .recording || coordinator.isPreBuffering) {
            if event.keyCode == 9, modifierOn({ $0.modifierCleanupEnabled }) { // V
                coordinator.setPendingMode(.cleanup)
                if isLocked { fnHeldAtLock = true }
                HotkeyManager.hkLog.debug("[HOTKEY] Fn+V → pending cleanup")
                return
            } else if event.keyCode == 17, modifierOn({ $0.modifierTranslateEnabled }) { // T
                coordinator.setPendingMode(.translate)
                if isLocked { fnHeldAtLock = true }
                HotkeyManager.hkLog.debug("[HOTKEY] Fn+T → pending translate")
                return
            } else if event.keyCode == 40, operatorSendOn() { // K (#122/#223)
                // Not a duplicate of the entry gates, for the same reason V and
                // T carry their own: the local monitor's last branch passes
                // every other key through to here, so this is reachable ungated
                // whenever lore itself is focused. `toggleOperatorAddressed`
                // would refuse anyway, but the two lines below are not its —
                // an unswitched K counting as a chord would swallow the Fn
                // release that ends a locked recording. Strict, like the entry
                // sites: no settings means off.
                coordinator.toggleOperatorAddressed()
                if isLocked { fnHeldAtLock = true }
                HotkeyManager.hkLog.debug("[HOTKEY] Fn+K → operator addressed")
                return
            } else if event.keyCode == 1, RichInputSettings.screenshotsEnabled { // S (#192/#198)
                // Still consumed while paused, and deliberately does nothing:
                // the clipboard door is shut (#206), so a screenshot taken here
                // would land on the user's clipboard and join no prompt.
                if !coordinator.isPaused { TextInserter.postScreenshotToClipboard() }
                if isLocked { fnHeldAtLock = true }
                HotkeyManager.hkLog.debug("[HOTKEY] Fn+S → screenshot to clipboard")
                return
            }
        }

        // Esc is not here: both event paths decide it where they consume it
        // (#233, #259), so this function is never reached for one.

        // Ctrl+Cmd+V to re-paste last transcript
        if HotkeyManager.isRepasteChord(event) {
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
        EscapeAction.decide(
            dictating: coordinator?.state == .recording || coordinator?.isPreBuffering == true,
            helpPinned: agentReplies?.isHelpPinned == true,
            replySpeaking: agentReplies?.canStopSpeech == true,
            playerShowing: agentReplies?.isPlayerShowing == true,
            screenshotUIIsUp: DictationEscape.screenshotUIIsUp
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
                fnTimer?.cancel()
                fnTimer = nil
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
    /// `matchesPress` sets by keycode exactly as `handleFlagsChanged` does, and
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
        fnTimer?.cancel()
        fnTimer = nil
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
        fnTimer?.cancel()
        fnTimer = nil
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
        event.keyCode == 9
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.control, .command]
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

                // Fn+V/T while recording → set pre-paste mode
                // Use the EVENT's own Fn flag (reliable) instead of tracked fnDown (flickers)
                let fnHeld = flags.contains(.maskSecondaryFn)
                if fnHeld && manager.isRecordingFlag {
                    if keyCode == 9, manager.modifierOn({ $0.modifierCleanupEnabled }) { // V
                        Task { @MainActor in
                            manager.coordinator?.setPendingMode(.cleanup)
                            if manager.isLocked { manager.fnHeldAtLock = true }
                            HotkeyManager.hkLog.debug("[HOTKEY] Fn+V (CGEvent) → pending cleanup")
                        }
                        return nil
                    } else if keyCode == 17, manager.modifierOn({ $0.modifierTranslateEnabled }) { // T
                        Task { @MainActor in
                            manager.coordinator?.setPendingMode(.translate)
                            if manager.isLocked { manager.fnHeldAtLock = true }
                            HotkeyManager.hkLog.debug("[HOTKEY] Fn+T (CGEvent) → pending translate")
                        }
                        return nil
                    } else if keyCode == 1, RichInputSettings.screenshotsEnabled { // S (#192/#198)
                        Task { @MainActor in
                            // The system's own crosshair, pressed for the user —
                            // the image lands on the clipboard and the door
                            // collects it at the second it happened. Not while
                            // paused: that door is shut (#206).
                            if manager.coordinator?.isPaused != true {
                                TextInserter.postScreenshotToClipboard()
                            }
                            if manager.isLocked { manager.fnHeldAtLock = true }
                            HotkeyManager.hkLog.debug("[HOTKEY] Fn+S (CGEvent) → screenshot to clipboard")
                        }
                        return nil
                    } else if keyCode == 40, manager.operatorSendOn() { // K (#122/#223)
                        Task { @MainActor in
                            manager.coordinator?.toggleOperatorAddressed()
                            if manager.isLocked { manager.fnHeldAtLock = true }
                            HotkeyManager.hkLog.debug("[HOTKEY] Fn+K (CGEvent) → operator addressed")
                        }
                        return nil
                    }
                }

                // A letter on Fn → consume (#105, #259): the player's keys while
                // agent replies are on, the selection's two while they are off.
                // Unlike Fn+V/T these fire regardless of recording state — the
                // chord handler ends the dictation gesture itself, and only for a
                // key that turns out to have something to act on, so the flags
                // are not cleared here. A letter that is nobody's passes through
                // untouched. The tap source is on CFRunLoopGetMain (see
                // `lastTapKeyDown` above), so assumeIsolated is valid here.
                if fnHeld, let code = UInt16(exactly: keyCode),
                   let chord = MainActor.assumeIsolated({ manager.fnChord(keyCode: code) }) {
                    Task { @MainActor in
                        manager.handleFnChord(chord)
                    }
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
                        HotkeyManager.hkLog.debug(
                            "[HOTKEY] Cmd+Shift+3/4 (CGEvent) → screenshot to clipboard"
                        )
                    }
                    return nil
                }

                // Space inside a recording → consume, and lock it or — with the
                // talk key held — pause and resume a locked one (#233). The
                // decision is taken here rather than in the Task, so consuming
                // and acting cannot disagree; the tap source is on
                // CFRunLoopGetMain, so the callback runs on the main thread and
                // assumeIsolated is valid. `CGEventFlags` and
                // `NSEvent.ModifierFlags` are the same bits (both are the CG
                // constants), which is what lets one predicate read either.
                if keyCode == Int64(HotkeyKey.spaceKeyCode) {
                    let action = MainActor.assumeIsolated {
                        manager.spaceAction(talkKeyHeld: manager.talkKeyHeld(
                            NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
                        ))
                    }
                    guard action != .passThrough else {
                        return Unmanaged.passRetained(event)
                    }
                    // Auto-repeat is the same press still down: swallowed with
                    // the press it belongs to, acted on once — `handleSpace`
                    // refuses it, so both event paths refuse it alike (#233).
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    // The sync mirrors, before the Task: the next event in this
                    // same turn has to see the lock the user just took.
                    if action == .lock, !isRepeat {
                        manager.isLockedFlag = true
                        manager.isPreBufferingFlag = false
                        manager.isRecordingFlag = true
                    }
                    Task { @MainActor in manager.handleSpace(action, isRepeat: isRepeat) }
                    return nil
                }

                // Esc → cancel a dictation into history (#206, #233), pause a
                // reply being read aloud (#259), put the player away (#263), or
                // nothing at all. Read here for the same reason Space is; while
                // the screenshot crosshair is up the key is not lore's and falls
                // through to it untouched.
                // An Esc that is not lore's is passed on either way, and reaches
                // the handler only when it has something to record: a second Esc
                // right after one that stopped a reply. Every other one — which
                // is nearly all of them — returns here, off the main actor's back.
                if keyCode == DictationEscape.keyCode {
                    let action = MainActor.assumeIsolated { manager.escapeAction }
                    if action != .passThrough
                        || MainActor.assumeIsolated({
                            manager.agentReplies?.escapeRepeatIsWorthRecording == true
                        }) {
                        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                        Task { @MainActor in manager.handleEscape(action, isRepeat: isRepeat) }
                    }
                    return action == .passThrough ? Unmanaged.passRetained(event) : nil
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: userInfo
        )

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
            fnTimer?.cancel()
            fnTimer = nil
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
        if secureInput.active {
            if !lastSecureInputActive {
                DiagStore.record(.secureInputChanged(active: true, holderPID: secureInput.pid))
                // The holder's *name* identifies software the user runs — os.Logger only.
                HotkeyManager.hkLog.error("[HK] Health: SecureInput active — associated with \(secureInput.name ?? "an unnamed process", privacy: .private) (pid \(secureInput.pid.map(String.init) ?? "none", privacy: .public))")
            }
            lastSecureInputActive = true
        } else if lastSecureInputActive {
            DiagStore.record(.secureInputChanged(active: false, holderPID: nil))
            HotkeyManager.hkLog.info("[HK] Health: SecureInput cleared")
            lastSecureInputActive = false
        }

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
