import Foundation

/// The clock the paste moment runs on (#211, retimed by #218).
///
/// The mark takes the spinner's slot the instant the words go and then bursts
/// where it stands — it does not travel. The fall to the cursor, and the second
/// window that carried it there, were retired after a day of real pastes: "this
/// flying away of the green dot, I changed my mind, let's not do this at all …
/// as if this green circle exploded in place."
enum PasteMark {
    /// How long the mark stands in the slot before it bursts. The board's
    /// "≤150 ms after the text is ready" is the latency of its appearing, not a
    /// wait; this is the beat between its two frames.
    static let standing: Duration = .milliseconds(150)

    /// The burst itself: the mark scales up as it fades, and the bubble's own
    /// close plays over the same fifth of a second, so mark and shape are gone
    /// together rather than one after the other.
    static let burst: TimeInterval = 0.2

    /// How big the mark gets on its way out. Enough to read as a burst inside
    /// the row it stands in, and not enough to reach the shape's own edges.
    static let grow: CGFloat = 1.6

    /// How late the shape may be in learning that the words went. The indicator
    /// reads the coordinator on a poll, so a whole tick of it can pass before
    /// the mark even starts standing (`DictationIndicatorManager.pollInterval`,
    /// bound to this by `PasteCheckmarkTests`).
    static let notice: Duration = .milliseconds(50)

    /// How long the shape is held after the words go, which is the latest the
    /// burst can possibly end.
    ///
    /// This is what keeps the bubble from blinking out mid-burst: the
    /// coordinator counts from the paste and the mark counts from the tick that
    /// noticed it, so the hold has to cover the gap between the two. It is one
    /// number in one place for the same reason — two clocks that disagree end
    /// either with a shape standing there empty or with one taken away
    /// mid-fade.
    static var hold: Duration {
        notice + standing + .milliseconds(Int(burst * 1000))
    }
}
