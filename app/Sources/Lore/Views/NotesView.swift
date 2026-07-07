import SwiftUI

/// Meetings review (XMO Stage E, MREV-01…40): designed header + 228px meeting
/// list rail + Transcript/Notes detail pane. Presentation only — all business
/// logic stays in NotesController (D-031: current behavior wins).
struct NotesView: View {
    @Bindable var settings: AppSettings
    /// False while the unified shell shows another destination/section.
    /// Gates the Cmd+1/Cmd+2 shortcuts (`.keyboardShortcut` fires even at
    /// opacity 0) and defers controller creation + session auto-select until
    /// the review layout is first shown.
    var isActiveInShell: Bool = true
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(ShellModel.self) private var shell
    @State private var notesController: NotesController?
    @State private var renamingSessionID: String?
    @State private var renameText: String = ""
    /// Header click-to-edit rename (#61) — separate from the list-row rename
    /// state so editing one surface doesn't flip the other.
    @State private var headerRenaming = false
    @State private var headerRenameText: String = ""
    @FocusState private var headerTitleFocused: Bool
    @State private var sessionToDelete: String?
    @State private var showDeleteConfirmation = false
    @State private var bulkDeleteMode = false
    @State private var bulkDeleteSelection: Set<String> = []
    @State private var showBulkDeleteConfirmation = false
    @State private var editingTagsSessionID: String?
    @State private var editingTags: [String] = []
    @State private var newTagText: String = ""
    @State private var availableTags: [String] = []
    /// Review chat model (#62): one conversation at a time, swapped (with a
    /// generation bump) whenever the selected session changes.
    @State private var reviewChat = AskXMOChatModel(isLive: false)
    /// Dedupe guard: the engine keeps `.completed` while the poll loop resets
    /// and re-copies it, so the same completion arrives more than once.
    @State private var lastHandledBatchCompletion: String?
    /// True once the user selects a meeting themselves during a recording —
    /// the fresh-meeting auto-select at recording end must not clobber it.
    @State private var userNavigatedDuringRecording = false

    enum DetailViewMode: String {
        case transcript = "Transcript"
        case chat = "Chat"
        case notes = "Notes"
    }

    @State private var detailViewMode: DetailViewMode = .transcript

    /// Transcript | Chat for every meeting; a read-only Notes tab only for
    /// meetings that already have stored notes (legacy generations, Granola
    /// imports) — generation itself is gone (#62).
    private func availableModes(state: NotesState) -> [DetailViewMode] {
        selectedSession(state)?.hasNotes == true
            ? [.transcript, .chat, .notes]
            : [.transcript, .chat]
    }

    private func selectedSession(_ state: NotesState) -> SessionIndex? {
        state.sessionHistory.first { $0.id == state.selectedSessionID }
    }

    var body: some View {
        Group {
            if let controller = notesController {
                mainContent(controller: controller)
            } else {
                ProgressView()
            }
        }
        .task(id: isActiveInShell) {
            // Deferred until the review layout is first shown — at launch this
            // view is mounted (keep-alive) but hidden, and auto-selecting a
            // session then would be invisible work.
            guard isActiveInShell, notesController == nil else { return }
            let controller = NotesController(coordinator: coordinator)
            notesController = controller
            await controller.loadHistory()

            // Handle pending navigation — inline rather than via controller
            // to ensure @State detailViewMode update happens in the same
            // transaction as session selection (matches pre-Phase 6 behavior).
            if let requested = coordinator.consumeRequestedSessionSelection() {
                controller.selectSession(requested)
                applyDetailMode(for: requested, controller: controller)
            } else if let last = coordinator.lastEndedSession {
                controller.selectSession(last.id)
            }
        }
    }

    /// Deep links (post-session banner, notifications) land on the stored
    /// notes when the meeting has them, otherwise on the transcript.
    private func applyDetailMode(for sessionID: String?, controller: NotesController) {
        let hasNotes = controller.state.sessionHistory
            .first(where: { $0.id == sessionID })?.hasNotes == true
        detailViewMode = hasNotes ? .notes : .transcript
    }

    @ViewBuilder
    private func mainContent(controller: NotesController) -> some View {
        let state = controller.state
        VStack(spacing: 0) {
            reviewHeader(controller: controller, state: state)
            XMODivider()
            HStack(spacing: 0) {
                sidebar(controller: controller, state: state)
                    .frame(width: 228)
                XMOTheme.Surface.line.frame(width: 1)
                detailContent(controller: controller, state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: coordinator.lastEndedSession?.id) {
            Task {
                await controller.loadHistory()
                // Fresh-meeting auto-select (MREV-34) — unless the user
                // navigated to another meeting during this recording.
                if !userNavigatedDuringRecording, let last = coordinator.lastEndedSession {
                    controller.selectSession(last.id)
                }
                userNavigatedDuringRecording = false
            }
        }
        .onChange(of: coordinator.sessionHistory.count) {
            Task { await controller.loadHistory() }
        }
        .onChange(of: coordinator.requestedSessionSelectionID) {
            if controller.handleRequestedSessionSelection() {
                applyDetailMode(for: controller.state.selectedSessionID, controller: controller)
                if coordinator.state != .idle {
                    userNavigatedDuringRecording = true
                }
            }
        }
        .onChange(of: coordinator.state) { _, newState in
            // Keyed to the full state, not a derived `== .idle` Bool — a
            // coalesced .ending → .idle → .recording frame would leave the
            // Bool unchanged and carry a stale "don't auto-select" into the
            // next recording.
            if case .recording = newState { userNavigatedDuringRecording = false }
        }
        // Review chat lifecycle (#62): a selection change immediately swaps
        // (and generation-guards) the conversation and rebinds persistence to
        // the new session ID; the async chat.json load then hydrates it.
        .onChange(of: controller.state.selectedSessionID, initial: true) { _, newID in
            rewireReviewChat(controller: controller, sessionID: newID)
            if !availableModes(state: controller.state).contains(detailViewMode) {
                detailViewMode = .transcript
            }
        }
        .onChange(of: controller.state.loadedChat) { _, exchanges in
            reviewChat.loadPersistedHistory(exchanges)
        }
        // Batch completion: refresh the index (utterance counts change) and,
        // if the fresh meeting is selected, resolve the Processing state into
        // the enhanced Transcript (MREV-30/32). Deduped — the poll loop
        // re-copies `.completed` from the engine after its 3s auto-dismiss.
        .onChange(of: coordinator.batchStatus) { _, newStatus in
            switch newStatus {
            case .completed(let sid):
                guard lastHandledBatchCompletion != sid else { return }
                lastHandledBatchCompletion = sid
                Task { await controller.loadHistory() }
                if controller.state.selectedSessionID == sid {
                    controller.selectSession(sid)
                    detailViewMode = .transcript
                }
            case .loading, .transcribing:
                // A new run (e.g. retry) may complete the same session again.
                lastHandledBatchCompletion = nil
            default:
                break
            }
        }
        // Fresh/green-dot lifetime (MREV-39): clears once the user views the
        // meeting while no batch is in flight for it.
        .onChange(of: viewedClearCandidate(controller: controller), initial: true) { _, candidate in
            if let candidate {
                controller.markViewed(sessionID: candidate)
            }
        }
    }

    // MARK: - Fresh marker (MREV-03/39)

    /// Session whose `unviewed` marker should be cleared right now, or nil.
    /// A failed batch/import (#43) never clears: batchStatus is memory-only,
    /// so the persisted dot is what still marks the failed import after a
    /// relaunch — it stays until a retry succeeds.
    private func viewedClearCandidate(controller: NotesController) -> String? {
        guard isActiveInShell,
              let id = controller.state.selectedSessionID,
              !isBatchInFlight(sessionID: id),
              !isBatchFailed(sessionID: id),
              controller.state.sessionHistory.first(where: { $0.id == id })?.unviewed == true
        else { return nil }
        return id
    }

    private func isBatchFailed(sessionID: String) -> Bool {
        if case .failed(_, let sid) = coordinator.batchStatus { return sid == sessionID }
        return false
    }

    private func isBatchInFlight(sessionID: String) -> Bool {
        switch coordinator.batchStatus {
        case .loading(let sid), .transcribing(_, let sid):
            return sid == sessionID
        default:
            return false
        }
    }

    /// Green dot: batch/import in flight, or processed but not yet viewed.
    private func isFresh(_ session: SessionIndex) -> Bool {
        session.unviewed == true || isBatchInFlight(sessionID: session.id)
    }

    // MARK: - Header (MREV-05)

    @ViewBuilder
    private func reviewHeader(controller: NotesController, state: NotesState) -> some View {
        let selected = state.sessionHistory.first { $0.id == state.selectedSessionID }
        XMOScreenHeader {
            headerTitle(controller: controller, selected: selected)
        } meta: {
            if let selected {
                dateDotTime(selected.startedAt)
                    + Text(" \u{00B7} \(selected.utteranceCount) utterances")
            } else {
                Text("\(state.sessionHistory.count) recorded")
            }
        } trailing: {
            // Routes into the existing guarded start/stop flows in ContentView.
            // While recording (review side shown via the header switch) the
            // button reads Stop and stops the session — it must never say
            // "Start recording" over a running one.
            let recordingActive = shell.isRecordingActive()
            XMOStartStopButton(isRecording: recordingActive) {
                (recordingActive ? shell.requestMeetingRecordingStop
                                 : shell.requestMeetingRecordingStart)?()
            }
            .accessibilityIdentifier("meetings.startRecordingButton")
        }
        .onChange(of: state.selectedSessionID) {
            headerRenaming = false
        }
    }

    /// Click-to-edit title (#61): same repository rename as the list row's
    /// context menu. Return commits; losing focus (blur) commits too; Esc
    /// cancels — it flips `headerRenaming` off while still focused, so the
    /// subsequent focus loss is guarded out and never commits. Clearing the
    /// field commits an empty title, which falls back to the derived
    /// default name.
    @ViewBuilder
    private func headerTitle(controller: NotesController, selected: SessionIndex?) -> some View {
        if let selected {
            if headerRenaming {
                TextField("Title", text: $headerRenameText, onCommit: {
                    commitHeaderRename(controller: controller, sessionID: selected.id)
                })
                .textFieldStyle(.plain)
                .frame(maxWidth: 420)
                .focused($headerTitleFocused)
                .onAppear { headerTitleFocused = true }
                .onChange(of: headerTitleFocused) { _, focused in
                    if !focused && headerRenaming {
                        commitHeaderRename(controller: controller, sessionID: selected.id)
                    }
                }
                .onExitCommand {
                    headerRenaming = false
                }
            } else {
                Text(selected.displayTitle)
                    .onTapGesture {
                        // Prefill with what's on screen: the stored title, or
                        // the derived default (committing it unchanged simply
                        // stores that name).
                        headerRenameText = selected.displayTitle
                        headerRenaming = true
                    }
                    .help("Click to rename")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Rename meeting")
            }
        } else {
            Text("No meeting selected")
                .foregroundStyle(XMOTheme.TextColor.muted)
        }
    }

    private func commitHeaderRename(controller: NotesController, sessionID: String) {
        guard headerRenaming else { return }
        headerRenaming = false
        controller.renameSession(sessionID: sessionID, newTitle: headerRenameText)
    }

    private func dateDotTime(_ date: Date) -> Text {
        Text(date, style: .date) + Text(" \u{00B7} ") + Text(date, style: .time)
    }

    /// Compact recorded duration for the list row meta (#58), derived from
    /// SessionIndex startedAt/endedAt. Nil when endedAt is missing (legacy
    /// or still-recording rows) — the row then shows utterances only.
    private func durationLabel(_ session: SessionIndex) -> String? {
        guard let endedAt = session.endedAt else { return nil }
        let seconds = endedAt.timeIntervalSince(session.startedAt)
        guard seconds >= 0 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "<1 min" }
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes) min"
    }

    // MARK: - Meeting list rail (MREV-01…10)

    @ViewBuilder
    private func sidebar(controller: NotesController, state: NotesState) -> some View {
        VStack(spacing: 0) {
            tagFilterBar(controller: controller, state: state)

            // Bulk delete toolbar
            if bulkDeleteMode {
                HStack(spacing: 8) {
                    Button("Select All") {
                        bulkDeleteSelection = Set(controller.filteredSessions.map(\.id))
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(XMOTheme.Accent.blue)
                    Spacer()
                    if !bulkDeleteSelection.isEmpty {
                        Button("Delete \(bulkDeleteSelection.count)") {
                            showBulkDeleteConfirmation = true
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(XMOTheme.Accent.red)
                    }
                    Button("Done") {
                        bulkDeleteMode = false
                        bulkDeleteSelection = []
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(XMOTheme.Accent.blue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                XMODivider()
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(controller.filteredSessions) { session in
                        sessionRow(controller: controller, session: session)
                    }
                }
                .padding(10)
            }
        }
        .frame(maxHeight: .infinity)
        .alert("Delete Meeting?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let id = sessionToDelete {
                    controller.deleteSession(sessionID: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the transcript and any generated notes.")
        }
        .alert("Delete \(bulkDeleteSelection.count) Meetings?", isPresented: $showBulkDeleteConfirmation) {
            Button("Delete \(bulkDeleteSelection.count)", role: .destructive) {
                controller.deleteSessions(sessionIDs: bulkDeleteSelection)
                bulkDeleteMode = false
                bulkDeleteSelection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the selected transcripts and any generated notes.")
        }
    }

    @ViewBuilder
    private func sessionRow(controller: NotesController, session: SessionIndex) -> some View {
        sessionRowButton(controller: controller, session: session)
            .contextMenu {
                if !bulkDeleteMode {
                    Button("Rename...") {
                        renameText = session.title ?? ""
                        renamingSessionID = session.id
                    }
                    Button("Edit Tags...") {
                        editingTags = session.tags ?? []
                        newTagText = ""
                        editingTagsSessionID = session.id
                        Task {
                            availableTags = await controller.allTags()
                        }
                    }
                    Divider()
                    Button("Select Multiple...") {
                        bulkDeleteMode = true
                        bulkDeleteSelection = [session.id]
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        sessionToDelete = session.id
                        showDeleteConfirmation = true
                    }
                }
            }
            .popover(isPresented: Binding(
                get: { editingTagsSessionID == session.id },
                set: { if !$0 { editingTagsSessionID = nil } }
            )) {
                tagEditorPopover(controller: controller, sessionID: session.id)
            }
    }

    @ViewBuilder
    private func sessionRowButton(controller: NotesController, session: SessionIndex) -> some View {
        let isSelected = !bulkDeleteMode && controller.state.selectedSessionID == session.id
        let isBulkSelected = bulkDeleteMode && bulkDeleteSelection.contains(session.id)
        let styled = sessionRowContent(
            controller: controller,
            session: session,
            isSelected: isSelected,
            isBulkSelected: isBulkSelected
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .xmoSelectableRow(
            isActive: isSelected || isBulkSelected,
            activeFill: XMOTheme.Surface.card3
        )

        Group {
            if renamingSessionID == session.id {
                // No button wrapper while renaming — it would swallow the
                // clicks the inline TextField needs.
                styled
            } else {
                Button {
                    if bulkDeleteMode {
                        if isBulkSelected {
                            bulkDeleteSelection.remove(session.id)
                        } else {
                            bulkDeleteSelection.insert(session.id)
                        }
                    } else {
                        controller.selectSession(session.id)
                        if coordinator.state != .idle {
                            userNavigatedDuringRecording = true
                        }
                    }
                } label: {
                    styled
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("notes.session.\(session.id)")
    }

    @ViewBuilder
    private func sessionRowContent(
        controller: NotesController,
        session: SessionIndex,
        isSelected: Bool,
        isBulkSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if bulkDeleteMode {
                    Image(systemName: isBulkSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(isBulkSelected ? XMOTheme.Accent.green
                                                        : XMOTheme.TextColor.muted)
                }
                if isFresh(session) {
                    Circle()
                        .fill(XMOTheme.Accent.green)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("New")
                }
                if renamingSessionID == session.id {
                    TextField("Title", text: $renameText, onCommit: {
                        controller.renameSession(sessionID: session.id, newTitle: renameText)
                        renamingSessionID = nil
                    })
                    .font(.system(size: 13, weight: .semibold))
                    .textFieldStyle(.plain)
                    .onExitCommand {
                        renamingSessionID = nil
                    }
                } else {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : XMOTheme.TextColor.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let snap = session.templateSnapshot {
                    Image(systemName: snap.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(XMOTheme.TextColor.muted)
                }
                if session.hasNotes {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(XMOTheme.TextColor.muted)
                        .accessibilityLabel("Has notes")
                }
            }

            dateDotTime(session.startedAt)
                .font(XMOTheme.Typography.monoMeta)
                .foregroundStyle(XMOTheme.TextColor.muted)
                .lineLimit(1)

            Text(
                [durationLabel(session), "\(session.utteranceCount) utterances"]
                    .compactMap { $0 }
                    .joined(separator: " \u{00B7} ")
            )
            .font(XMOTheme.Typography.monoMeta)
            .foregroundStyle(XMOTheme.TextColor.muted)

            if let tags = session.tags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10))
                            .foregroundStyle(XMOTheme.TextColor.muted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(XMOTheme.Surface.card3)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Tag Filter Bar (MREV-09)

    @ViewBuilder
    private func tagFilterBar(controller: NotesController, state: NotesState) -> some View {
        let allTags = uniqueTags(from: state.sessionHistory)
        if !allTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(allTags, id: \.self) { tag in
                        let isActive = state.tagFilter?.localizedCaseInsensitiveCompare(tag) == .orderedSame
                        Button {
                            controller.setTagFilter(isActive ? nil : tag)
                        } label: {
                            Text(tag)
                                .font(.system(size: 11))
                                .foregroundStyle(isActive ? Color.white : XMOTheme.TextColor.muted)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(isActive ? Color.white.opacity(0.12) : Color.clear)
                                .overlay(
                                    Capsule()
                                        .strokeBorder(XMOTheme.Surface.line, lineWidth: 1)
                                )
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            XMODivider()
        }
    }

    private func uniqueTags(from sessions: [SessionIndex]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for session in sessions {
            for tag in session.tags ?? [] {
                let key = tag.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    result.append(tag)
                }
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Tag Editor Popover

    @ViewBuilder
    private func tagEditorPopover(controller: NotesController, sessionID: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags")
                .font(.headline)

            // Current tags as removable chips
            if !editingTags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(editingTags, id: \.self) { tag in
                        HStack(spacing: 3) {
                            Text(tag)
                                .font(.system(size: 12))
                            Button {
                                editingTags.removeAll { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
                                controller.updateSessionTags(sessionID: sessionID, tags: editingTags)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .clipShape(Capsule())
                    }
                }
            }

            if editingTags.count < 5 {
                HStack(spacing: 6) {
                    TextField("Add tag...", text: $newTagText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit {
                            commitNewTag(controller: controller, sessionID: sessionID)
                        }
                    Button("Add") {
                        commitNewTag(controller: controller, sessionID: sessionID)
                    }
                    .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // Autocomplete suggestions
                let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let suggestions = availableTags.filter { suggestion in
                    guard !trimmed.isEmpty else { return false }
                    let lower = suggestion.lowercased()
                    return lower.contains(trimmed) && !editingTags.contains(where: { $0.localizedCaseInsensitiveCompare(suggestion) == .orderedSame })
                }
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(suggestions.prefix(5), id: \.self) { suggestion in
                            Button {
                                editingTags.append(suggestion)
                                newTagText = ""
                                controller.updateSessionTags(sessionID: sessionID, tags: editingTags)
                            } label: {
                                Text(suggestion)
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            } else {
                Text("Maximum 5 tags per session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func commitNewTag(controller: NotesController, sessionID: String) {
        let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !editingTags.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else {
            newTagText = ""
            return
        }
        guard editingTags.count < 5 else { return }
        editingTags.append(trimmed)
        newTagText = ""
        controller.updateSessionTags(sessionID: sessionID, tags: editingTags)
    }

    // MARK: - Detail

    @ViewBuilder
    private func detailContent(controller: NotesController, state: NotesState) -> some View {
        Group {
            if let sessionID = state.selectedSessionID {
                if isBatchInFlight(sessionID: sessionID) {
                    // Processing state (MREV-30): controls hidden while the
                    // batch/import pass runs for the selected meeting.
                    processingView
                } else {
                    VStack(spacing: 0) {
                        detailToolbar(controller: controller, state: state)
                        XMODivider()
                        detailBody(controller: controller, state: state, sessionID: sessionID)
                    }
                }
            } else {
                ContentUnavailableView("Select a Session", systemImage: "doc.text", description: Text("Choose a session from the sidebar to view its transcript and chat."))
            }
        }
        .background {
            // Gated: .keyboardShortcut fires app-wide even at opacity 0,
            // and this view stays mounted while other destinations show.
            if isActiveInShell {
                Group {
                    Button("") { detailViewMode = .transcript }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("") { detailViewMode = .chat }
                        .keyboardShortcut("2", modifiers: .command)
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Processing state (MREV-30/32)

    private var processingView: some View {
        VStack(spacing: 10) {
            XMOPulsingDot(color: XMOTheme.Accent.blue, size: 10)
            Text("Transcribing\u{2026}")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(XMOTheme.TextColor.primary)
            Text(coordinator.batchIsImporting
                 ? "Importing \u{2014} the transcript will appear here in a moment"
                 : "The enhanced transcript will appear here in a moment")
                .font(XMOTheme.Typography.secondary)
                .foregroundStyle(XMOTheme.TextColor.muted)
            if case .transcribing(let progress, _) = coordinator.batchStatus, progress > 0 {
                Text("\(Int(progress * 100))%")
                    .font(XMOTheme.Typography.monoMeta)
                    .foregroundStyle(XMOTheme.TextColor.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("meetings.processing")
    }

    // MARK: - Detail toolbar (MREV-11/28)

    @ViewBuilder
    private func detailToolbar(controller: NotesController, state: NotesState) -> some View {
        HStack(spacing: 11) {
            segmentedControl(state: state)
            Spacer(minLength: 4)
            HStack(spacing: 7) {
                if detailViewMode == .transcript {
                    transcriptToolbarActions(controller: controller, state: state)
                }

                if state.audioFileURL != nil {
                    audioPlaybackButton(controller: controller, state: state)
                }

                XMOCopyButton {
                    copyCurrentContent(state: state)
                }
                .disabled(copyContentIsEmpty(state: state))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    /// Design `.seg`: white .05 track, active segment white .12 + white text.
    private func segmentedControl(state: NotesState) -> some View {
        HStack(spacing: 3) {
            ForEach(availableModes(state: state), id: \.self) { mode in
                segmentButton(mode)
            }
        }
        .padding(3)
        .background(
            XMOTheme.Surface.hover,
            in: RoundedRectangle(cornerRadius: XMOTheme.Radius.chip)
        )
    }

    private func segmentButton(_ mode: DetailViewMode) -> some View {
        let isOn = detailViewMode == mode
        return Button {
            detailViewMode = mode
        } label: {
            Text(mode.rawValue)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : XMOTheme.TextColor.muted)
                .padding(.vertical, 6)
                .padding(.horizontal, 14)
                .background(
                    isOn ? Color.white.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: XMOTheme.Radius.chip)
                )
                .contentShape(RoundedRectangle(cornerRadius: XMOTheme.Radius.chip))
        }
        .buttonStyle(.plain)
    }

    /// 30×30 icon label for the audio menu.
    private func iconMenuLabel(systemName: String, tint: Color = XMOTheme.TextColor.muted) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(
                XMOTheme.Surface.card3,
                in: RoundedRectangle(cornerRadius: XMOTheme.Radius.button)
            )
    }

    @ViewBuilder
    private func audioPlaybackButton(controller: NotesController, state: NotesState) -> some View {
        Menu {
            Button {
                controller.toggleAudioPlayback()
            } label: {
                Label(
                    state.isPlayingAudio ? "Pause" : "Play Recording",
                    systemImage: state.isPlayingAudio ? "pause.fill" : "play.fill"
                )
            }
            Divider()
            Button {
                controller.revealAudioInFinder()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        } label: {
            iconMenuLabel(
                systemName: state.isPlayingAudio ? "pause.fill" : "play.fill",
                tint: state.isPlayingAudio ? XMOTheme.Accent.blue : XMOTheme.TextColor.muted
            )
        } primaryAction: {
            controller.toggleAudioPlayback()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help(state.isPlayingAudio ? "Pause audio recording" : "Play audio recording")
        .accessibilityLabel(state.isPlayingAudio ? "Pause audio recording" : "Play audio recording")
    }

    /// Transcript-mode extra: the Show Original toggle, shown once any
    /// utterance carries refined text (live refinement or batch enhance).
    @ViewBuilder
    private func transcriptToolbarActions(controller: NotesController, state: NotesState) -> some View {
        if state.loadedTranscript.contains(where: { $0.refinedText != nil }) {
            showOriginalButton(controller: controller, state: state)
        }
    }

    /// Raw ↔ cleaned toggle (MREV-17): ↺ while the cleaned text is shown,
    /// ✦ while the original is shown. Same semantics as before, dictation
    /// row treatment.
    private func showOriginalButton(controller: NotesController, state: NotesState) -> some View {
        XMOIconButton(
            systemName: state.showingOriginal ? "sparkles" : "arrow.uturn.backward",
            label: state.showingOriginal ? "Show cleaned transcript" : "Show original transcript",
            tint: state.showingOriginal ? XMOTheme.Accent.amber : XMOTheme.TextColor.muted
        ) {
            controller.toggleShowingOriginal()
        }
        .help(state.showingOriginal ? "Showing original transcript" : "Show original transcript")
    }

    // MARK: - Detail body

    @ViewBuilder
    private func detailBody(controller: NotesController, state: NotesState, sessionID: String) -> some View {
        Group {
            switch detailViewMode {
            case .transcript:
                transcriptView(controller: controller, state: state)
            case .chat:
                chatTab(state: state)
            case .notes:
                // The tab exists only when the index says notes are stored;
                // the brief nil window is the async load.
                if let notes = state.loadedNotes {
                    notesContentView(notes, sessionDirectory: state.selectedSessionDirectory)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func notesContentView(_ notes: EnhancedNotes, sessionDirectory: URL?) -> some View {
        ScrollView {
            markdownContent(notes.markdown, sessionDirectory: sessionDirectory)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("notes.renderedMarkdown")
        }
    }

    // MARK: - Transcript view (MREV-12…17)

    @ViewBuilder
    private func transcriptView(controller: NotesController, state: NotesState) -> some View {
        VStack(spacing: 0) {
            // Failed batch/import banner (MREV-32, #43): above the content —
            // not inside the scroll — so it also shows when the transcript
            // is empty, which is what a failed import leaves behind.
            if case .failed(let batchError, let sid) = coordinator.batchStatus,
               sid == state.selectedSessionID {
                let isImport = selectedSession(state)?.source == SessionIndex.importedSource
                errorBanner(isImport
                            ? "Import failed: \(batchError)"
                            : "Transcript enhancement failed: \(batchError)") {
                    controller.retryBatch(sessionID: sid, settings: settings)
                }
                .padding(.top, 12)
            }
            if state.loadedTranscript.isEmpty {
                ContentUnavailableView("No Transcript", systemImage: "waveform", description: Text("This session has no recorded utterances."))
            } else {
                ScrollView {
                    // Elapsed-stamp anchor (#63): the session's recorded start,
                    // falling back to the first utterance's timestamp for legacy
                    // sessions whose metadata never stored one.
                    let anchor = ElapsedStamp.anchor(
                        startedAt: selectedSession(state)?.startedAt,
                        firstTimestamp: state.loadedTranscript.first?.timestamp
                    )
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(state.loadedTranscript.enumerated()), id: \.offset) { _, record in
                            transcriptRow(record: record, anchor: anchor, showingOriginal: state.showingOriginal)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Ask Lore chat tab (#62)

    /// The rail chat, re-hosted: persisted exchanges plus a live input over
    /// the STORED transcript of the selected session. Same speaker-labeled
    /// context lines as the live path (`Speaker.displayLabel: displayText`).
    private func chatTab(state: NotesState) -> some View {
        AskXMOSection(
            model: reviewChat,
            utterances: state.loadedTranscript.map {
                Utterance(
                    text: $0.text,
                    speaker: $0.speaker,
                    timestamp: $0.timestamp,
                    refinedText: $0.refinedText
                )
            },
            apiKey: settings.openaiApiKey,
            isLive: false
        )
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Selection changed: swap the conversation and bind persistence to the
    /// new session ID. The ID is captured here, at bind time, and the model
    /// captures the hook at send time — so a completed exchange always lands
    /// in its ORIGIN session's chat.json, even when the user has switched
    /// away (the generation bump only suppresses rendering it). The echo
    /// into `loadedChat` keeps the in-memory copy matching disk while that
    /// session is still the selected one.
    private func rewireReviewChat(controller: NotesController, sessionID: String?) {
        reviewChat.loadPersistedHistory(controller.state.loadedChat)
        guard let sessionID else {
            reviewChat.onExchange = nil
            return
        }
        let repo = coordinator.sessionRepository
        reviewChat.onExchange = { question, answer in
            let exchange = ChatExchange(question: question, answer: answer)
            Task {
                await repo.appendChatExchange(sessionID: sessionID, exchange: exchange)
            }
            controller.appendLoadedChat(sessionID: sessionID, exchange: exchange)
        }
    }

    /// Red token error line; optional retry (batch failures, MREV-32).
    @ViewBuilder
    private func errorBanner(_ message: String, retryAction: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(XMOTheme.Accent.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retryAction {
                XMOIconButton(
                    systemName: "arrow.clockwise",
                    label: "Retry",
                    tint: XMOTheme.Accent.red,
                    background: XMOTheme.Accent.red.opacity(0.12),
                    action: retryAction
                )
                .help("Retry transcript enhancement")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
    }

    /// Speaker rows (MREV-13, #63): the live view's stamped row — elapsed
    /// mono stamp + 64px speaker label — with the raw/original choice made
    /// here. Copy keeps absolute HH:MM:SS (see copyCurrentContent).
    private func transcriptRow(record: SessionRecord, anchor: Date?, showingOriginal: Bool) -> some View {
        TranscriptSpeakerRow(
            speaker: record.speaker,
            text: showingOriginal ? record.text : (record.refinedText ?? record.text),
            elapsed: record.timestamp.timeIntervalSince(anchor ?? record.timestamp)
        )
    }

    private func copyContentIsEmpty(state: NotesState) -> Bool {
        switch detailViewMode {
        case .transcript:
            return state.loadedTranscript.isEmpty
        case .chat:
            return !reviewChat.messages.contains { $0.role != .failure }
        case .notes:
            return state.loadedNotes == nil
        }
    }

    // MARK: - Markdown Rendering (MREV-20)

    /// Renders template-generated markdown in the design's notes style:
    /// H2 headings become uppercase mono section labels, H3 a smaller
    /// heading, list items get blue markers. Arbitrary template sections
    /// render as-is.
    private func markdownContent(_ markdown: String, sessionDirectory: URL? = nil) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            let sections = parseMarkdownSections(markdown)
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 11) {
                    if let heading = section.heading {
                        headingView(heading, level: section.level)
                    }
                    if !section.body.isEmpty {
                        sectionBodyView(section.body, sessionDirectory: sessionDirectory)
                    }
                }
            }
        }
    }

    /// H1 15/600 · H2 uppercase mono section label · H3 12/600 — hierarchy
    /// survives, and inline markdown is stripped before uppercasing rather
    /// than uppercased raw.
    @ViewBuilder
    private func headingView(_ heading: String, level: Int) -> some View {
        let plain = plainInline(heading)
        switch level {
        case ...1:
            Text(plain)
                .font(XMOTheme.Typography.heading)
                .foregroundStyle(XMOTheme.TextColor.primary)
        case 2:
            XMOSectionLabel(text: plain, size: 11, mono: true, trackingEm: 0.07)
        default:
            Text(plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(XMOTheme.TextColor.primary)
        }
    }

    /// Strip inline markdown (emphasis, code, links) down to plain characters.
    private func plainInline(_ text: String) -> String {
        guard let attributed = try? AttributedString(markdown: text) else { return text }
        return String(attributed.characters)
    }

    @ViewBuilder
    private func sectionBodyView(_ body: String, sessionDirectory: URL?) -> some View {
        let blocks = parseBodyBlocks(body)
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .text(let text):
                textBlockView(text)
            case .image(let path):
                if let dir = sessionDirectory,
                   let nsImage = NSImage(contentsOf: dir.appendingPathComponent(path)) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 500, maxHeight: 400)
                        .clipShape(RoundedRectangle(cornerRadius: XMOTheme.Radius.chip))
                } else {
                    Label("Image not found", systemImage: "photo")
                        .font(.system(size: 12))
                        .foregroundStyle(XMOTheme.TextColor.muted)
                }
            }
        }
    }

    /// Paragraphs, bulleted items (blue dot) and ordered items (blue number),
    /// with nesting preserved as insets.
    private func textBlockView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            let items = parseTextItems(text)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .paragraph(let content):
                    bodyText(content)
                case .bullet(let content, let indent):
                    listRow(indent: indent, content: content) {
                        Circle()
                            .fill(XMOTheme.Accent.blue)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                    }
                case .ordered(let number, let content, let indent):
                    listRow(indent: indent, content: content) {
                        Text("\(number).")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(XMOTheme.Accent.blue)
                            .padding(.top, 1)
                    }
                }
            }
        }
    }

    private func listRow(
        indent: Int,
        content: String,
        @ViewBuilder marker: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            marker()
            bodyText(content)
        }
        .padding(.leading, CGFloat(indent) * 14)
    }

    private func bodyText(_ content: String) -> some View {
        inlineMarkdownText(content)
            .font(XMOTheme.Typography.body)
            .lineSpacing(3)
            .foregroundStyle(XMOTheme.TextColor.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum TextItem {
        case paragraph(String)
        case bullet(text: String, indent: Int)
        case ordered(number: String, text: String, indent: Int)
    }

    private func parseTextItems(_ text: String) -> [TextItem] {
        var items: [TextItem] = []
        var paragraphLines: [String] = []
        var lastWasListItem = false

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                items.append(.paragraph(joined))
            }
            paragraphLines = []
        }

        func appendToLastListItem(_ line: String) {
            guard let last = items.indices.last else { return }
            switch items[last] {
            case .bullet(let text, let indent):
                items[last] = .bullet(text: text + "\n" + line, indent: indent)
            case .ordered(let number, let text, let indent):
                items[last] = .ordered(number: number, text: text + "\n" + line, indent: indent)
            case .paragraph:
                paragraphLines.append(line)
            }
        }

        for line in text.components(separatedBy: "\n") {
            let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = min(leading / 2, 4)

            if let marker = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
                flushParagraph()
                items.append(.bullet(text: String(trimmed.dropFirst(marker.count)), indent: indent))
                lastWasListItem = true
            } else if let match = trimmed.firstMatch(of: /^(\d+)[.)]\s+/) {
                flushParagraph()
                items.append(.ordered(
                    number: String(match.1),
                    text: String(trimmed[match.range.upperBound...]),
                    indent: indent
                ))
                lastWasListItem = true
            } else if trimmed.isEmpty {
                flushParagraph()
                lastWasListItem = false
            } else if lastWasListItem && leading >= 2 {
                // Continuation line stays attached to its list item.
                appendToLastListItem(trimmed)
            } else {
                paragraphLines.append(line)
                lastWasListItem = false
            }
        }
        flushParagraph()

        return items
    }

    private func inlineMarkdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }

    private enum BodyBlock {
        case text(String)
        case image(path: String)
    }

    private func parseBodyBlocks(_ body: String) -> [BodyBlock] {
        var blocks: [BodyBlock] = []
        var scanner = body[...]

        while let imgStart = scanner.range(of: "![") {
            let before = String(scanner[scanner.startIndex..<imgStart.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.text(before))
            }

            let afterBracket = scanner[imgStart.upperBound...]
            guard let closeBracket = afterBracket.range(of: "]("),
                  let closeParen = afterBracket[closeBracket.upperBound...].range(of: ")") else {
                blocks.append(.text(String(scanner)))
                return blocks
            }

            let path = String(afterBracket[closeBracket.upperBound..<closeParen.lowerBound])
            blocks.append(.image(path: path))
            scanner = afterBracket[closeParen.upperBound...]
        }

        let tail = String(scanner)
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(tail))
        }

        return blocks
    }

    private struct MarkdownSection {
        var heading: String?
        var level: Int
        var body: String
    }

    private func parseMarkdownSections(_ markdown: String) -> [MarkdownSection] {
        let lines = markdown.components(separatedBy: "\n")
        var sections: [MarkdownSection] = []
        var currentBody: [String] = []
        var currentHeading: String?
        var currentLevel = 0

        for line in lines {
            if line.hasPrefix("# ") {
                if currentHeading != nil || !currentBody.isEmpty {
                    sections.append(MarkdownSection(heading: currentHeading, level: currentLevel, body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentHeading = String(line.dropFirst(2))
                currentLevel = 1
                currentBody = []
            } else if line.hasPrefix("## ") {
                if currentHeading != nil || !currentBody.isEmpty {
                    sections.append(MarkdownSection(heading: currentHeading, level: currentLevel, body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentHeading = String(line.dropFirst(3))
                currentLevel = 2
                currentBody = []
            } else if line.hasPrefix("### ") {
                if currentHeading != nil || !currentBody.isEmpty {
                    sections.append(MarkdownSection(heading: currentHeading, level: currentLevel, body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentHeading = String(line.dropFirst(4))
                currentLevel = 3
                currentBody = []
            } else {
                currentBody.append(line)
            }
        }

        if currentHeading != nil || !currentBody.isEmpty {
            sections.append(MarkdownSection(heading: currentHeading, level: currentLevel, body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return sections
    }

    // MARK: - Actions

    private func copyCurrentContent(state: NotesState) {
        let text: String
        switch detailViewMode {
        case .transcript:
            text = state.loadedTranscript.map { record in
                let label = record.speaker.displayLabel
                let content = state.showingOriginal ? record.text : (record.refinedText ?? record.text)
                return "[\(Self.transcriptTimeFormatter.string(from: record.timestamp))] \(label): \(content)"
            }.joined(separator: "\n")
        case .chat:
            // The conversation as Q:/A: lines; failure bubbles are transient
            // UI, not conversation.
            text = reviewChat.messages
                .filter { $0.role != .failure }
                .map { "\($0.role == .user ? "Q" : "A"): \($0.text)" }
                .joined(separator: "\n")
        case .notes:
            text = state.loadedNotes?.markdown ?? ""
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static let transcriptTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// FlowLayout moved to FlowLayout.swift
