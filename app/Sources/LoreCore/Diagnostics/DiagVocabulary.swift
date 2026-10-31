import Foundation

// Closed sets the Mac app records in `DiagEvent` (#82), declared here so the
// event stream builds without the Mac code that produces them (#305). Each
// one's behavior stays with that code in LoreKit, as an extension.

/// Why a fresh reading could not be had. The poll then keeps the reading
/// it had — a green never comes from anywhere else — and the event stream
/// says so.
public enum GrantCheckFailure: String, Error, Codable, Sendable, CaseIterable {
    /// This process is not lore's bundle (tests, `swift run`).
    case unavailable
    /// The child could not be started, or did not finish within `timeout`.
    case noAnswer
    /// The child answered something that is not a `Reading`.
    case unreadable
}

/// What kind of thing rode along with a dictation (#192). A closed set: the
/// clipboard door classifies file-url > image > url > text and nothing else
/// becomes an item.
public enum DictationItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case fileURL
    case url

    /// Whether the item is a file on disk. These are the two kinds a composer
    /// has to be *handed* rather than told about (#195); the other two are text
    /// and travel inside the paste like the spoken words do.
    public var isFile: Bool { self == .image || self == .fileURL }
}

/// One contextual hint (#235). Declaration order is the priority order the
/// arbiter reads: `allCases` is that list.
public enum DictationHint: String, Codable, Sendable, CaseIterable {
    /// H5 — frames are arriving and none of them carry sound.
    case silentMic
    /// H1 — ten seconds into a held recording, from the open lock.
    case lock
    /// H1b — the first lock ever, from the closed lock.
    case howItEnds
    /// H2 — twenty seconds of quiet inside a locked recording, from the dot.
    case pause
    /// H3 — two minutes in with cleanup unarmed, from the `V` keycap.
    case cleanup
}

/// Which form a dictation's items take in the app receiving the paste (#195).
public enum PasteTarget: String, Codable, Sendable, CaseIterable {
    /// A terminal, or an editor that hosts a command-line agent: an item is its
    /// absolute path in the text, and the whole dictation is one paste — the
    /// form #192 ships.
    case path
    /// Everything else — a web chat composer, a native chat app: a picture or a
    /// file travels on the pasteboard as a file, and the text names it by the
    /// filename the composer will show.
    case web
}
