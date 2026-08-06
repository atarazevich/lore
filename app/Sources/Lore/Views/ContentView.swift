import SwiftUI

struct ContentView: View {
    @Bindable var settings: AppSettings
    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(ShellModel.self) private var shell
    @State private var liveSessionController: LiveSessionController?
    @State private var askLore = AskLoreChatModel()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var showConsentSheet = false

    var body: some View {
        bodyWithModifiers
    }

    private var rootContent: some View {
        let controllerState = liveSessionController?.state ?? LiveSessionState()
        let startedAt = recordingStartedAt

        return VStack(spacing: 0) {
            header(state: controllerState, startedAt: startedAt)

            // Failure surfacing (MREC-60/61/63): same conditions and recovery
            // paths as before, rendered in the Stage E errorBanner vocabulary.
            if let error = controllerState.errorMessage {
                errorBanner(error)
            }

            // Model download gate (MREC-44) — flow and copy unchanged.
            if controllerState.needsDownload && !controllerState.isRunning {
                downloadPrompt
            }

            // Model loading / downloading status.
            if let status = controllerState.statusMessage, status != "Ready" {
                statusBanner(status: status, progress: controllerState.downloadProgress)
            }

            if let startedAt {
                recordingBanner(state: controllerState, startedAt: startedAt)
            }

            postSessionBanner(state: controllerState)

            // Batch progress/completion surfaces in the review layout
            // (processing pane + fresh dot), which is always reachable via
            // the recording-time Live/Meetings switch.

            LoreDivider()

            HStack(spacing: 0) {
                transcriptPane(state: controllerState, startedAt: startedAt)
                if let startedAt {
                    rail(state: controllerState, startedAt: startedAt)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// True recording start (same source as the shell REC pill) so the banner
    /// clock and the duration stat card tick from the real session start.
    /// Non-nil exactly while `coordinator.state` is `.recording` — the single
    /// state source for the Stop label, banner, stats, AND the toggle action.
    private var recordingStartedAt: Date? {
        if case .recording(let metadata) = coordinator.state {
            return metadata.startedAt
        }
        return nil
    }

    // MARK: - Header (MREC-01/02)

    private func header(state: LiveSessionState, startedAt: Date?) -> some View {
        // No "Recording N:NN" meta line — the red banner is the one ticking
        // recording indicator (#57).
        LoreScreenHeader {
            Text("New recording")
        } meta: {
        } trailing: {
            // Transcript affordances stay while the finished session's
            // transcript is still showing, not only mid-recording.
            if state.showLiveTranscript, !state.liveTranscript.isEmpty {
                LoreCopyButton(label: "Copy transcript") {
                    copyTranscript()
                }
            }

            // Label and action key off the same coordinator-phase source
            // (recordingStartedAt): a "Stop" can never route to start.
            LoreStartStopButton(isRecording: startedAt != nil) {
                if startedAt != nil {
                    stopSession()
                } else {
                    startSession()
                }
            }
            .accessibilityIdentifier("app.controlBar.toggle")
        }
    }

    // MARK: - Live banner (MREC-10)

    /// Red recording banner: pulsing dot, "Recording", mono clock, waveform
    /// bars driven by the real audio level, mute toggle, right-aligned hint.
    private func recordingBanner(state: LiveSessionState, startedAt: Date) -> some View {
        HStack(spacing: 12) {
            LorePulsingDot(size: 10)
            Text("Recording")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LoreTheme.Accent.red)
            Text(startedAt, style: .timer)
                .font(LoreTheme.Typography.mono(12.5))
                .foregroundStyle(LoreTheme.TextColor.primary)
            LoreLiveWaveform(level: state.isMicMuted ? 0 : state.audioLevel)
                .frame(height: 16)
                .opacity(state.isMicMuted ? 0.35 : 1)
            muteToggle(isMuted: state.isMicMuted)
            Spacer(minLength: 20)
            Text("Live transcription \u{2014} notes when you stop")
                .font(.system(size: 11.5))
                .foregroundStyle(LoreTheme.TextColor.muted)
                .lineLimit(1)
        }
        .loreBanner(tint: LoreTheme.Accent.red)
    }

    /// Mic mute (MREC-06) — the only pause-like control; restyled into the
    /// banner. System audio keeps flowing while muted.
    private func muteToggle(isMuted: Bool) -> some View {
        Button {
            liveSessionController?.toggleMicMute()
        } label: {
            Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isMuted ? LoreTheme.Accent.red : LoreTheme.TextColor.muted)
                .frame(width: 24, height: 24)
                .background(
                    Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                )
        }
        .buttonStyle(LorePressButtonStyle())
        .help(isMuted ? "Unmute microphone" : "Mute microphone")
        .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
        .accessibilityIdentifier("app.controlBar.muteToggle")
    }

    // MARK: - Status / error / download surfaces

    /// Red token error line (Stage E vocabulary; MREC-63).
    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(LoreTheme.Accent.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.bottom, 8)
    }

    private var downloadPrompt: some View {
        HStack(spacing: 12) {
            Text("Transcription requires a one-time model download.")
                .font(LoreTheme.Typography.secondary)
                .foregroundStyle(LoreTheme.TextColor.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            pillButton("Download Now", tint: LoreTheme.Accent.blue) {
                confirmDownload()
            }
        }
        .loreBanner()
    }

    private func statusBanner(status: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if progress == nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .accessibilityIdentifier("app.controlBar.status")
            }
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(LoreTheme.Accent.blue)
                    .accessibilityIdentifier("app.controlBar.downloadProgress")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.bottom, 8)
    }

    /// Post-session banner. The Generate Notes offer is gone with notes
    /// generation itself (#62); a single View button opens the review (its
    /// Notes tab still surfaces stored notes on legacy meetings).
    @ViewBuilder
    private func postSessionBanner(state: LiveSessionState) -> some View {
        if let lastSession = state.lastEndedSession, lastSession.utteranceCount > 0 {
            HStack(spacing: 12) {
                Text("Session ended \u{00B7} \(lastSession.utteranceCount) utterances")
                    .font(LoreTheme.Typography.secondary)
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .accessibilityIdentifier("app.sessionEndedBanner")
                Spacer()
                pillButton("View meeting") {
                    shell.showMeetingsReview()
                }
                .accessibilityIdentifier("app.viewMeetingButton")
            }
            .loreBanner()
        }
    }

    /// 12.5/600 pill: `tint` fill + white text, or neutral white .06 fill.
    private func pillButton(
        _ title: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint == nil ? LoreTheme.TextColor.primary : .white)
                .padding(.vertical, 7)
                .padding(.horizontal, 13)
                .background(
                    tint ?? Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                )
        }
        .buttonStyle(LorePressButtonStyle())
    }

    // MARK: - Transcript pane (MREC-11/12/13)

    @ViewBuilder
    private func transcriptPane(state: LiveSessionState, startedAt: Date?) -> some View {
        if state.showLiveTranscript {
            TranscriptView(
                utterances: state.liveTranscript,
                volatileYouText: state.volatileYouText,
                volatileThemText: state.volatileThemText,
                startedAt: startedAt
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if startedAt != nil {
            // Live display off (MREC-13): recording still runs; the
            // transcript appears after processing.
            Text("Live transcription is off \u{2014} the transcript appears after the recording stops.")
                .font(LoreTheme.Typography.secondary)
                .foregroundStyle(LoreTheme.TextColor.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Rail (MREC-20/21)

    /// 344px right rail, left hairline: MEETING STATS on top and Ask Lore
    /// (MREC-30, Stage G) filling the rest — visible only while recording;
    /// chat history clears when a new recording starts.
    private func rail(state: LiveSessionState, startedAt: Date) -> some View {
        VStack(spacing: 0) {
            statsSection(state: state, startedAt: startedAt)
            LoreDivider()
            AskLoreSection(
                model: askLore,
                utterances: state.liveTranscript,
                apiKey: settings.openaiApiKey
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 344)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .leading) {
            LoreTheme.Surface.line.frame(width: 1)
        }
    }

    private func statsSection(state: LiveSessionState, startedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LoreSectionLabel(text: "Meeting stats", size: 11)
                .padding(.bottom, 12)
            HStack(spacing: 10) {
                statCard(
                    value: Text(startedAt, style: .timer),
                    label: "duration"
                )
                statCard(
                    value: Text("\(state.liveTranscript.count)"),
                    label: "utterances"
                )
            }
            .padding(.bottom, 14)
            // Both speakers at zero words → rows hidden rather than a
            // fake 50/50: no data is more honest than invented parity.
            if let split = talkSplit(state.liveTranscript) {
                talkSplitRow(
                    label: "You \(split.you)%",
                    percent: split.you,
                    labelColor: LoreTheme.Accent.blue,
                    fill: LoreTheme.Accent.blue
                )
                .padding(.bottom, 7)
                talkSplitRow(
                    label: "Them \(split.them)%",
                    percent: split.them,
                    labelColor: LoreTheme.TextColor.muted,
                    fill: Color.white.opacity(0.32)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.init(top: 15, leading: 18, bottom: 15, trailing: 18))
    }

    /// `.stat` card: card-2 fill, 6px radius, mono 15/600 value, 11px label.
    private func statCard(value: Text, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            value
                .font(LoreTheme.Typography.mono(15, weight: .semibold))
                .foregroundStyle(LoreTheme.TextColor.primary)
            Text(label)
                .font(LoreTheme.Typography.meta)
                .foregroundStyle(LoreTheme.TextColor.muted)
        }
        .padding(.init(top: 9, leading: 11, bottom: 9, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LoreTheme.Surface.card2,
            in: RoundedRectangle(cornerRadius: LoreTheme.Radius.chip)
        )
    }

    /// Talk-split proxy (MREC-21): utterances carry no audio durations, so
    /// the split uses per-speaker word counts of finalized utterances as a
    /// first-order approximation of talk time. Rounded; forced to sum to 100
    /// (them = 100 − you). Returns nil until the first words arrive.
    private func talkSplit(_ utterances: [Utterance]) -> (you: Int, them: Int)? {
        var youWords = 0
        var themWords = 0
        for utterance in utterances {
            let words = utterance.displayText
                .split(whereSeparator: \.isWhitespace).count
            if utterance.speaker.isRemote {
                themWords += words
            } else {
                youWords += words
            }
        }
        let total = youWords + themWords
        guard total > 0 else { return nil }
        let you = Int((Double(youWords) / Double(total) * 100).rounded())
        return (you: you, them: 100 - you)
    }

    /// 64px "You NN%"/"Them NN%" label + 7px rounded bar on a white .1 track.
    private func talkSplitRow(
        label: String,
        percent: Int,
        labelColor: Color,
        fill: Color
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(labelColor)
                .frame(width: 64, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(fill)
                        .frame(width: geo.size.width * CGFloat(percent) / 100)
                }
            }
            .frame(height: 7)
        }
    }

    private var bodyWithModifiers: some View {
        contentWithLifecycle
    }

    private var sizedRootContent: some View {
        rootContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contentWithOverlay: some View {
        sizedRootContent.overlay {
            if showOnboarding {
                OnboardingView(isPresented: $showOnboarding)
                    .transition(.opacity)
            }
            if showConsentSheet {
                RecordingConsentView(
                    isPresented: $showConsentSheet,
                    settings: settings
                )
                .transition(.opacity)
            }
        }
    }

    private var contentWithLifecycle: some View {
        contentWithOverlay
        .onChange(of: showOnboarding) { _, isShowing in
            if isShowing {
                // The overlay renders inside this (possibly hidden) section —
                // bring it on screen; a gate must never block invisibly.
                shell.pinMeetingsLive()
            } else {
                hasCompletedOnboarding = true
                // Gate dismissed without a recording — back to the review layout.
                if !coordinator.isRecording {
                    shell.meetingsPinnedLive = false
                }
            }
        }
        .onChange(of: showConsentSheet) { _, isShowing in
            if isShowing {
                shell.pinMeetingsLive()
            }
            if !isShowing && settings.hasAcknowledgedRecordingConsent
                && !(liveSessionController?.state.isRunning ?? false) {
                liveSessionController?.startSession(settings: settings)
            }
            if !isShowing && !settings.hasAcknowledgedRecordingConsent {
                // Consent declined — no recording will start; show review again.
                shell.meetingsPinnedLive = false
            }
        }
        .task {
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
            // Idempotent: AppContainer guards with its own
            // didInitializeServices flag, so re-runs are no-ops.
            container.ensureServicesInitialized(settings: settings, coordinator: coordinator)

            // Create and wire the controller
            let controller = LiveSessionController(coordinator: coordinator, container: container)
            controller.showPastMeetings = {
                shell.showMeetingsReview()
            }

            // The review header's "Start recording" button (Stage E) reuses
            // the existing consent-gated start flow. The live view is pinned
            // only when a gate (consent, model download) needs to render
            // there — otherwise the recording state itself brings it up, and
            // a request that starts nothing leaves no stale pin behind.
            shell.requestMeetingRecordingStart = {
                guard let controller = liveSessionController else { return }
                // Boundary reset at dispatch: covers the narrow case where
                // the review flip is still true from a previous recording
                // whose end MeetingsDestination never observed (destination
                // unmounted at the time) and this start is ungated (#43).
                shell.resetMeetingsForRecordingBoundary()
                if !settings.hasAcknowledgedRecordingConsent
                    || controller.state.needsDownload {
                    shell.pinMeetingsLive()
                }
                startSession()
            }
            shell.requestMeetingRecordingStop = {
                stopSession()
            }

            coordinator.liveSessionController = controller
            liveSessionController = controller

            // Ask Lore persistence (#60): write-through per successful
            // exchange so the chat survives crashes and stop. If the answer
            // lands in the narrow stop→finalize window, the just-ended
            // session is still the right target.
            askLore.onExchange = { [weak controller, weak coordinator] question, answer in
                guard let coordinator else { return }
                guard let sessionID = controller?.activeSessionID
                        ?? coordinator.lastEndedSession?.id else { return }
                let repo = coordinator.sessionRepository
                let exchange = ChatExchange(question: question, answer: answer)
                Task {
                    await repo.appendChatExchange(sessionID: sessionID, exchange: exchange)
                }
            }

            await container.seedIfNeeded(coordinator: coordinator)
            controller.handlePendingExternalCommandIfPossible(settings: settings) {
                shell.showMeetingsReview()
            }

            await controller.performInitialSetup()

            // Setup meeting detection if enabled
            if settings.meetingAutoDetectEnabled {
                container.enableDetection(settings: settings, coordinator: coordinator)
                await container.detectionController?.evaluateImmediate()
            }

            // Start the 100ms polling loop (runs until task cancelled)
            await controller.runPollingLoop(settings: settings)
        }
        // Ask Lore lifecycle (Stage G): chat is per recording session — clear
        // when a new one starts (any start path: manual, detection, external
        // command). The clear also bumps the generation guard, so responses
        // from the previous session are dropped; the section itself unmounts
        // at stop, so no explicit end handling is needed.
        .onChange(of: recordingStartedAt) { _, new in
            if new != nil {
                askLore.startNewSession()
            }
        }
        .onChange(of: settings.meetingAutoDetectEnabled) {
            if settings.meetingAutoDetectEnabled {
                container.enableDetection(settings: settings, coordinator: coordinator)
                Task {
                    await container.detectionController?.evaluateImmediate()
                }
            } else {
                container.disableDetection(coordinator: coordinator)
            }
        }
    }

    // MARK: - Actions

    private func startSession() {
        guard settings.hasAcknowledgedRecordingConsent else {
            withAnimation(.easeInOut(duration: 0.25)) {
                showConsentSheet = true
            }
            return
        }
        liveSessionController?.startSession(settings: settings)
    }

    private func stopSession() {
        liveSessionController?.stopSession(settings: settings)
    }

    private func copyTranscript() {
        guard let controller = liveSessionController else { return }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let lines = controller.state.liveTranscript.map { u in
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker.displayLabel): \(u.displayText)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func confirmDownload() {
        guard settings.hasAcknowledgedRecordingConsent else {
            withAnimation(.easeInOut(duration: 0.25)) {
                showConsentSheet = true
            }
            return
        }
        liveSessionController?.confirmDownloadAndStart(settings: settings)
    }
}

// MARK: - Banner chrome

private extension View {
    /// Full-width banner under the header: 8×16 inner padding, 7px-radius
    /// card, 1px border, 26px horizontal inset. `tint` (the recording red)
    /// colors fill (.09) and border (.32); default is card-2 + line.
    func loreBanner(tint: Color? = nil) -> some View {
        padding(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
            .background(
                tint?.opacity(0.09) ?? LoreTheme.Surface.card2,
                in: RoundedRectangle(cornerRadius: LoreTheme.Radius.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LoreTheme.Radius.card)
                    .strokeBorder(
                        tint?.opacity(0.32) ?? LoreTheme.Surface.line,
                        lineWidth: 1
                    )
            )
            .padding(.horizontal, 26)
            .padding(.bottom, 13)
    }
}
