import AppKit
import AVFoundation
import Foundation
import Observation
import os

private let notesLog = Logger(subsystem: "com.lore.app", category: "NotesController")

// MARK: - State

struct NotesState {
    var sessionHistory: [SessionIndex] = []
    var selectedSessionID: String?
    /// The loaded transcript: its raw lines (`records`), read through its
    /// speaker map and names (#269) — a label per line and the turns. Built
    /// once per load or naming change.
    var transcript: MeetingTranscript = .empty
    /// False while the selected session's transcript load is in flight
    /// (#166): the pane renders none of its three faces until the load
    /// lands — an empty array must mean "no text", never "not read yet".
    var transcriptLoaded = false
    var loadedNotes: EnhancedNotes?
    /// Ask Lore exchanges persisted with the session (#60); empty for
    /// legacy sessions (no chat.json).
    var loadedChat: [ChatExchange] = []
    var showingOriginal: Bool = false
    /// Active tag filter for sidebar (nil = show all).
    var tagFilter: String?
    /// Directory for the currently selected session (used for image loading).
    var selectedSessionDirectory: URL?
    /// URL of the playable audio file for the selected session (nil if no audio).
    var audioFileURL: URL?
    /// Whether audio is currently playing.
    var isPlayingAudio: Bool = false
}

// MARK: - Controller

/// Owns all notes/history business logic previously embedded in NotesView.
/// NotesView becomes a pure projection of `state`.
@Observable
@MainActor
final class NotesController {
    private(set) var state = NotesState()

    private let coordinator: AppCoordinator

    /// Audio player for session recordings.
    @ObservationIgnored private var audioPlayer: AVPlayer?
    @ObservationIgnored private var playerObservation: Any?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Lifecycle

    /// Called when the Notes window appears. Loads history and handles pending navigation.
    /// Returns true if a deep-link session selection was consumed (caller should switch to notes tab).
    @discardableResult
    func onAppear() async -> Bool {
        await loadHistory()

        if let requested = coordinator.consumeRequestedSessionSelection() {
            selectSession(requested)
            return true
        } else if let last = coordinator.lastEndedSession {
            selectSession(last.id)
        }
        return false
    }

    /// React to a deep-link session selection request.
    /// Returns true if a request was consumed (caller may want to switch to notes tab).
    func handleRequestedSessionSelection() -> Bool {
        if let requested = coordinator.consumeRequestedSessionSelection() {
            selectSession(requested)
            return true
        }
        return false
    }

    // MARK: - Session Selection

    func selectSession(_ sessionID: String?) {
        state.selectedSessionID = sessionID
        stopAudio()

        guard let sessionID else {
            state.loadedNotes = nil
            state.transcript = .empty
            state.transcriptLoaded = false
            state.loadedChat = []
            state.selectedSessionDirectory = nil
            state.audioFileURL = nil
            return
        }

        state.loadedNotes = nil
        state.transcript = .empty
        state.transcriptLoaded = false
        state.loadedChat = []
        state.audioFileURL = nil
        state.selectedSessionDirectory = coordinator.sessionRepository.sessionsDirectoryURL
            .appendingPathComponent(sessionID, isDirectory: true)
        state.showingOriginal = false

        let token = nextTranscriptToken()
        let audioToken = nextAudioToken()
        Task {
            let notes = await coordinator.sessionRepository.loadNotes(sessionID: sessionID)
            let meeting = await coordinator.sessionRepository.meetingTranscript(sessionID: sessionID)
            let audioURL = await coordinator.sessionRepository.audioFileURL(for: sessionID)
            let chat = await coordinator.sessionRepository.loadChat(sessionID: sessionID)

            guard state.selectedSessionID == sessionID else { return }

            state.loadedNotes = notes
            if token == transcriptToken { state.transcript = meeting }
            state.transcriptLoaded = true
            state.loadedChat = chat
            if audioToken == self.audioToken { state.audioFileURL = audioURL }

            // Open summons a job (#166): a meeting with nothing to read —
            // missing, damaged, or interrupted mid-processing — gets a fresh
            // repair attempt the moment it is opened, while audio exists.
            // The healer dedupes against running/queued jobs, excludes the
            // live session, and answers "unavailable" when nothing can be
            // made — the pane's three faces derive from exactly that.
            if meeting.records.isEmpty {
                coordinator.transcriptHealer?.ensure(sessionID: sessionID, opened: true)
            }
        }
    }

    // MARK: - Speakers (#269)

    /// Every read or change of the open transcript takes a token; only the
    /// latest may land, so a slow reload cannot put back what a naming change
    /// replaced.
    @ObservationIgnored private var transcriptToken = 0

    private func nextTranscriptToken() -> Int {
        transcriptToken += 1
        return transcriptToken
    }

    /// The open meeting's speaker pass is running or waiting: the meta line's
    /// "finding who spoke…".
    var isFindingSpeakers: Bool {
        guard let id = state.selectedSessionID else { return false }
        return coordinator.transcriptHealer?.isFindingSpeakers(id) ?? false
    }

    /// Reads the open meeting's transcript again, as it is on disk — after a
    /// speaker pass settled, or a naming change that did not land.
    func reloadSpeakers() {
        guard let sessionID = state.selectedSessionID, state.transcriptLoaded else { return }
        let token = nextTranscriptToken()
        Task {
            let meeting = await coordinator.sessionRepository.meetingTranscript(sessionID: sessionID)
            guard token == transcriptToken, state.selectedSessionID == sessionID else { return }
            state.transcript = meeting
        }
    }

    /// Known people for the naming popover, most alike to this speaker first.
    func suggestions(for key: SpeakerKey) -> [SpeakerSuggestion] {
        state.transcript.speakers?.suggestions(for: key) ?? []
    }

    /// Merge a speaker into another speaker of this meeting (by any of its
    /// voices), someone known, or You.
    func assignSpeaker(_ key: SpeakerKey, to target: SpeakerKey) {
        changeSpeakers(.assign(key, to: target))
    }

    /// Name a speaker as someone new.
    func nameSpeaker(_ key: SpeakerKey, as name: String) {
        changeSpeakers(.name(key, name))
    }

    /// A new name for someone known, wherever they were named.
    func renamePerson(_ personID: String, to name: String) {
        changeSpeakers(.renamePerson(personID, to: name))
    }

    /// The change lands on disk (names, then the Markdown mirror) against the
    /// transcript on screen, the open meeting reads through it, and its
    /// summary is made again. A change that was refused, changed nothing or
    /// failed to save leaves the screen reading the meeting from disk — as an
    /// earlier change that landed while this one was on its way does.
    private func changeSpeakers(_ change: SessionRepository.SpeakerChange) {
        guard let sessionID = state.selectedSessionID, state.transcriptLoaded else { return }
        let basis = state.transcript
        let token = nextTranscriptToken()
        Task {
            let result: SessionRepository.SpeakerChangeResult?
            do {
                result = try await coordinator.sessionRepository.changeSpeakers(change, sessionID: sessionID, basis: basis)
            } catch {
                notesLog.error("speaker names not saved: \(error.localizedDescription, privacy: .private)")
                result = nil
            }
            guard case .changed(let changed) = result else {
                if token == transcriptToken { reloadSpeakers() }
                return
            }
            if token == transcriptToken, state.selectedSessionID == sessionID { state.transcript = changed }
            await coordinator.resummarizeAfterNaming(sessionID: sessionID)
        }
    }

    // MARK: - Audio Playback

    /// Every read of the open meeting's recording takes a token; only the
    /// latest may land, so an open's read from before the export settled
    /// cannot put back "no recording" over the one found after.
    @ObservationIgnored private var audioToken = 0

    private func nextAudioToken() -> Int {
        audioToken += 1
        return audioToken
    }

    /// Looks for the open meeting's recording again — after an export
    /// settled (#290), which lands after the meeting was listed and opened.
    func reloadAudio() {
        guard let sessionID = state.selectedSessionID else { return }
        let token = nextAudioToken()
        Task {
            let audioURL = await coordinator.sessionRepository.audioFileURL(for: sessionID)
            guard token == audioToken, state.selectedSessionID == sessionID else { return }
            state.audioFileURL = audioURL
        }
    }

    func toggleAudioPlayback() {
        guard let url = state.audioFileURL else { return }

        if state.isPlayingAudio {
            audioPlayer?.pause()
            state.isPlayingAudio = false
            return
        }

        if audioPlayer?.currentItem?.asset != AVURLAsset(url: url) {
            stopAudio()
            let player = AVPlayer(url: url)
            audioPlayer = player
            playerObservation = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                self?.state.isPlayingAudio = false
            }
        }

        audioPlayer?.play()
        state.isPlayingAudio = true
    }

    func stopAudio() {
        audioPlayer?.pause()
        if let obs = playerObservation {
            NotificationCenter.default.removeObserver(obs)
            playerObservation = nil
        }
        audioPlayer = nil
        state.isPlayingAudio = false
    }

    func revealAudioInFinder() {
        guard let url = state.audioFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func toggleShowingOriginal() {
        state.showingOriginal.toggle()
    }

    // MARK: - Ask Lore chat (#62)

    /// Write-through echo: a review exchange just persisted for `sessionID`
    /// also lands in the in-memory chat — but only while that session is
    /// still the selected one — so `loadedChat` keeps matching disk without
    /// a reselect.
    func appendLoadedChat(sessionID: String, exchange: ChatExchange) {
        guard state.selectedSessionID == sessionID else { return }
        state.loadedChat.append(exchange)
    }

    // MARK: - Session Management

    func renameSession(sessionID: String, newTitle: String) {
        Task {
            await coordinator.sessionRepository.renameSession(sessionID: sessionID, title: newTitle)
            await loadHistory()
        }
    }

    func deleteSession(sessionID: String) {
        Task {
            await coordinator.sessionRepository.deleteSession(sessionID: sessionID)
            if state.selectedSessionID == sessionID {
                selectSession(nil)
            }
            await loadHistory()
        }
    }

    func deleteSessions(sessionIDs: Set<String>) {
        Task {
            for id in sessionIDs {
                await coordinator.sessionRepository.deleteSession(sessionID: id)
            }
            if let selected = state.selectedSessionID, sessionIDs.contains(selected) {
                selectSession(nil)
            }
            await loadHistory()
        }
    }

    /// Clear the fresh/unviewed marker once the user views a processed
    /// meeting (MREV-39). Updates the in-memory index in place so the green
    /// dot clears without a full history reload.
    func markViewed(sessionID: String) {
        Task {
            await coordinator.sessionRepository.markSessionViewed(sessionID: sessionID)
            if let i = state.sessionHistory.firstIndex(where: { $0.id == sessionID }) {
                state.sessionHistory[i].unviewed = nil
            }
        }
    }

    // MARK: - Tags

    /// Sessions filtered by active tag filter.
    var filteredSessions: [SessionIndex] {
        guard let filter = state.tagFilter else { return state.sessionHistory }
        return state.sessionHistory.filter { session in
            session.tags?.contains(where: { $0.localizedCaseInsensitiveCompare(filter) == .orderedSame }) ?? false
        }
    }

    func updateSessionTags(sessionID: String, tags: [String]) {
        Task {
            await coordinator.sessionRepository.updateSessionTags(sessionID: sessionID, tags: tags)
            await loadHistory()
        }
    }

    func setTagFilter(_ tag: String?) {
        state.tagFilter = tag
    }

    func allTags() async -> [String] {
        await coordinator.sessionRepository.allTags()
    }

    // MARK: - History

    func loadHistory() async {
        state.sessionHistory = await coordinator.sessionRepository.listSessions()
        // Stale-filter guard: when the last session carrying the filtered tag
        // disappears (deleted, or the tag removed via the editor), the chip
        // vanishes from the filter bar and the sidebar would be blank with no
        // affordance — fall back to All.
        if let filter = state.tagFilter,
           !state.sessionHistory.contains(where: { session in
               session.tags?.contains(where: {
                   $0.localizedCaseInsensitiveCompare(filter) == .orderedSame
               }) ?? false
           }) {
            state.tagFilter = nil
        }
    }
}
