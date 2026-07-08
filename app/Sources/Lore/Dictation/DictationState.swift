/// The dictation coordinator's lifecycle state.
///
/// Payload-free and already closed, so it doubles as its own diagnostic vocabulary:
/// `DiagEvent.dictationDiscarded` carries it directly rather than a mirror enum whose
/// only job would be to restate these five cases (#82).
enum DictationState: String, Codable, Sendable, Equatable, CaseIterable {
    case idle
    case recording
    case loadingModel
    case processing
    case done
}
