import XCTest
@testable import LoreKit

/// The audio-retention deletion decision (#52): pruning fires only when the
/// effective limit shrinks. 0 is the unlimited sentinel on both sides.
final class SettingsViewTests: XCTestCase {

    func testShouldPruneImmediately() {
        // ∞ → finite is a decrease: prune.
        XCTAssertTrue(SettingsView.shouldPruneImmediately(current: 0, next: 100))
        // Finite → ∞ deletes nothing.
        XCTAssertFalse(SettingsView.shouldPruneImmediately(current: 1000, next: 0))
        // Plain decrease: prune.
        XCTAssertTrue(SettingsView.shouldPruneImmediately(current: 500, next: 100))
        // Increase never deletes (and never resurrects).
        XCTAssertFalse(SettingsView.shouldPruneImmediately(current: 100, next: 500))
        // Off-ladder current (hand-edited defaults) still prunes on decrease.
        XCTAssertTrue(SettingsView.shouldPruneImmediately(current: 750, next: 500))
    }

    /// One directory pass returns the recording count AND the total bytes (#89),
    /// counting only the `.raw` audio files and ignoring strays.
    func testMeasureAudioFolder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoreAudioTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Three audio files of known sizes.
        try Data(count: 100).write(to: dir.appendingPathComponent("dictation-a.raw"))
        try Data(count: 250).write(to: dir.appendingPathComponent("dictation-b.raw"))
        try Data(count: 650).write(to: dir.appendingPathComponent("dictation-c.raw"))
        // A stray non-audio file must not be counted or summed.
        try Data(count: 9999).write(to: dir.appendingPathComponent(".DS_Store"))

        let usage = SettingsView.measureAudioFolder(at: dir)
        XCTAssertEqual(usage?.count, 3)
        XCTAssertEqual(usage?.bytes, 1000)

        // Unreadable/absent directory → nil.
        let missing = dir.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertNil(SettingsView.measureAudioFolder(at: missing))
    }

    /// The subtitle states present reality once measured, and never a
    /// projection; before measurement it shows the policy alone (#89).
    func testKeepAudioSubtitle() {
        // Measured: present-tense count + "on disk", and none of the words
        // that would frame it as a projection of the cap.
        let sub = SettingsView.keepAudioSubtitle(cap: 500, usage: (count: 247, bytes: 245_760_000))
        XCTAssertTrue(sub.hasPrefix("247 recordings on disk now"))
        XCTAssertTrue(sub.contains("on disk"))
        for projection in ["last", "kept", "up to", "keep"] {
            XCTAssertFalse(sub.lowercased().contains(projection), "subtitle must not read as a projection: \(sub)")
        }
        // Cap does not alter the measured reality: ∞ reads the same as finite.
        XCTAssertEqual(
            SettingsView.keepAudioSubtitle(cap: 0, usage: (count: 247, bytes: 245_760_000)),
            sub
        )
        // Singular noun for a single recording.
        let one = SettingsView.keepAudioSubtitle(cap: 500, usage: (count: 1, bytes: 1000))
        XCTAssertTrue(one.hasPrefix("1 recording on disk now"))
        XCTAssertFalse(one.contains("1 recordings"))
        // Fresh install: empty folder measured (0 recordings, 0 bytes).
        XCTAssertEqual(
            SettingsView.keepAudioSubtitle(cap: 500, usage: (count: 0, bytes: 0)),
            "0 recordings on disk now \u{00B7} Zero KB"
        )
        // Not yet measured: policy only, no fabricated count.
        XCTAssertEqual(
            SettingsView.keepAudioSubtitle(cap: 500, usage: nil),
            "Keeping up to 500 recordings for Retry"
        )
        XCTAssertEqual(
            SettingsView.keepAudioSubtitle(cap: 0, usage: nil),
            "Keeping every recording for Retry"
        )
    }
}
