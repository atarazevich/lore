import AppKit
import AVFoundation
import Foundation
import Observation

// MARK: - State

struct NotesState {
    var sessionHistory: [SessionIndex] = []
    var selectedSessionID: String?
    var loadedTranscript: [SessionRecord] = []
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
            state.loadedTranscript = []
            state.loadedChat = []
            state.selectedSessionDirectory = nil
            state.audioFileURL = nil
            return
        }

        state.loadedNotes = nil
        state.loadedTranscript = []
        state.loadedChat = []
        state.audioFileURL = nil
        state.selectedSessionDirectory = coordinator.sessionRepository.sessionsDirectoryURL
            .appendingPathComponent(sessionID, isDirectory: true)
        state.showingOriginal = false

        Task {
            let notes = await coordinator.sessionRepository.loadNotes(sessionID: sessionID)
            let transcript = await coordinator.sessionRepository.loadTranscript(sessionID: sessionID)
            let audioURL = await coordinator.sessionRepository.audioFileURL(for: sessionID)
            let chat = await coordinator.sessionRepository.loadChat(sessionID: sessionID)

            guard state.selectedSessionID == sessionID else { return }

            state.loadedNotes = notes
            state.loadedTranscript = transcript
            state.loadedChat = chat
            state.audioFileURL = audioURL
        }
    }

    // MARK: - Audio Playback

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

    // MARK: - Transcript Rebuild (MREV-32, #109)

    /// True while a rebuild (including its confirmation prompt) is running —
    /// a second click is a no-op instead of stacking modal alerts and
    /// concurrent engine passes.
    @ObservationIgnored private var rebuildInFlight = false

    /// Rebuild a session's transcript from its audio. Serves both the failed
    /// banner's Retry (MREV-32/#43) and the chunked indicator's
    /// click-to-rebuild (#109). The repository resolves the source ONCE
    /// (`resolveRebuild`): per-track stash → `process()` (keeps You/Them),
    /// merged audio (session copy or notes-folder m4a export) → the
    /// import-style pass, anchored at the session's real start — and that
    /// same resolution answers whether the rebuild would collapse an
    /// existing multi-speaker transcript, which asks for confirmation first
    /// (#129). The session's identity (title, tags, source) is untouched —
    /// the import path only replaces the transcript. No audio findable →
    /// `.failed`, so the retry banner says why instead of running a doomed
    /// pass.
    func rebuildTranscript(sessionID: String, settings: AppSettings) {
        guard let batchEngine = coordinator.batchEngine, !rebuildInFlight else { return }
        rebuildInFlight = true
        let notesDir = URL(fileURLWithPath: settings.notesFolderPath)
        let repo = coordinator.sessionRepository
        let startedAt = state.sessionHistory.first { $0.id == sessionID }?.startedAt
        Task {
            defer { rebuildInFlight = false }

            guard let resolved = await repo.resolveRebuild(sessionID: sessionID) else {
                // Surface the real problem instead of a wrong path.
                await batchEngine.markFailed(
                    "Original audio no longer available",
                    sessionID: sessionID
                )
                return
            }

            // #129: the per-track stash is gone and the merged-file pass
            // would mark every line as the other speaker — unrecoverable.
            // Confirm before destroying an existing multi-speaker transcript.
            if resolved.wouldCollapseSpeakers, !Self.confirmSpeakerCollapse() {
                return
            }

            // Fresh marker (MREV-39): green dot / processing state survive
            // relaunch mid-rebuild, same as the auto kickoff.
            await repo.markSessionUnviewed(sessionID: sessionID)

            switch resolved.source {
            case .tracks:
                await batchEngine.process(
                    sessionID: sessionID,
                    sessionRepository: repo,
                    notesDirectory: notesDir
                )
            case .file(let audioURL):
                await batchEngine.importFile(
                    url: audioURL,
                    sessionID: sessionID,
                    sessionRepository: repo,
                    startDate: startedAt
                )
            }
        }
    }

    /// #129 confirmation: standard alert, Cancel is the default button
    /// (Return and Esc both cancel); the destructive rebuild takes a click.
    private static func confirmSpeakerCollapse() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Rebuild without speaker separation?"
        alert.informativeText = "Separate speaker tracks are no longer available for this meeting. Rebuilding will mark every line as the other speaker."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
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
