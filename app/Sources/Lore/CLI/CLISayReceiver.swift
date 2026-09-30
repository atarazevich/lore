import Foundation
import LoreCLIKit

/// `lore say` inside the app (#257): one request off the wire becomes one reply
/// in the queue, or nothing at all.
///
/// The switch gates the request, not the socket. `lore transcribe` (#254) owns
/// the socket and keeps working whatever this feature does, so a lore with
/// `agentRepliesEnabled` off does not go quiet — it says it is not taking
/// replies, and the command speaks the words through `say` as terminals did
/// before this feature.
@MainActor
enum CLISayReceiver {

    /// Answers at once: the queue takes the reply and the reading happens
    /// afterwards, so the agent's terminal never waits for speech. Nil when
    /// there is no one left to answer, and then nothing is queued and nothing
    /// is written back.
    ///
    /// The queue's own switch decides, not the setting it follows. The
    /// controller turns itself on when the setting changes, a moment later;
    /// answering `.queued` from the setting alone would drop a reply into a
    /// queue that is not listening yet, with no `say` behind it.
    static func respond(
        to said: CLISayRequest,
        replies: AgentReplyController,
        recordEvent: (DiagEvent) -> Void = { DiagStore.record($0) }
    ) -> CLIResponse? {
        // The command has gone — Ctrl-C, or the two seconds it waits ran out
        // and it spoke the words through `say` itself. Queueing them now would
        // read the same reply a second time.
        guard !Task.isCancelled else { return nil }
        guard replies.isEnabled else {
            recordEvent(.agentReplyDeclined(reason: .switchOff))
            return .notAccepted
        }
        replies.enqueue(AgentReply(said: said))
        return .queued
    }
}
