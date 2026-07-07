import XCTest
@testable import LoreKit

@MainActor
final class TranscriptStoreTests: XCTestCase {

    private func makeStore() -> TranscriptStore {
        TranscriptStore()
    }

    private func makeUtterance(
        text: String,
        speaker: Speaker = .them,
        timestamp: Date = Date()
    ) -> Utterance {
        Utterance(text: text, speaker: speaker, timestamp: timestamp)
    }

    // MARK: - Append

    func testAppendAddsUtterance() {
        let store = makeStore()
        let u = makeUtterance(text: "Hello world")
        let accepted = store.append(u)
        XCTAssertTrue(accepted)
        XCTAssertEqual(store.utterances.count, 1)
        XCTAssertEqual(store.utterances.first?.text, "Hello world")
    }

    func testAppendMultipleUtterances() {
        let store = makeStore()
        store.append(makeUtterance(text: "First", speaker: .them))
        store.append(makeUtterance(text: "Second", speaker: .you))
        store.append(makeUtterance(text: "Third", speaker: .them))
        XCTAssertEqual(store.utterances.count, 3)
    }

    // MARK: - Clear

    func testClearRemovesAllUtterances() {
        let store = makeStore()
        store.append(makeUtterance(text: "One"))
        store.append(makeUtterance(text: "Two"))
        XCTAssertEqual(store.utterances.count, 2)

        store.clear()
        XCTAssertTrue(store.utterances.isEmpty)
        XCTAssertEqual(store.volatileYouText, "")
        XCTAssertEqual(store.volatileThemText, "")
    }

    // MARK: - Last Them Utterance

    func testLastRemoteUtteranceReturnsCorrectOne() {
        let store = makeStore()
        store.append(makeUtterance(text: "Them first", speaker: .them))
        store.append(makeUtterance(text: "You reply", speaker: .you))
        store.append(makeUtterance(text: "Them second", speaker: .them))

        XCTAssertEqual(store.lastRemoteUtterance?.text, "Them second")
    }

    func testLastRemoteUtteranceWhenNone() {
        let store = makeStore()
        store.append(makeUtterance(text: "You only", speaker: .you))
        XCTAssertNil(store.lastRemoteUtterance)
    }

    // MARK: - Recent Utterances

    func testRecentUtterancesReturnsUpTo10() {
        let store = makeStore()
        for i in 1...15 {
            store.append(makeUtterance(text: "Utterance \(i)", speaker: .them))
        }
        XCTAssertEqual(store.recentUtterances.count, 10)
        XCTAssertEqual(store.recentUtterances.first?.text, "Utterance 6")
        XCTAssertEqual(store.recentUtterances.last?.text, "Utterance 15")
    }

    func testRecentExchangeReturnsUpTo6() {
        let store = makeStore()
        for i in 1...10 {
            store.append(makeUtterance(text: "U\(i)", speaker: i.isMultiple(of: 2) ? .you : .them))
        }
        XCTAssertEqual(store.recentExchange.count, 6)
    }

    func testRecentRemoteUtterancesFiltersCorrectly() {
        let store = makeStore()
        store.append(makeUtterance(text: "Them 1", speaker: .them))
        store.append(makeUtterance(text: "You 1", speaker: .you))
        store.append(makeUtterance(text: "Them 2", speaker: .them))
        store.append(makeUtterance(text: "You 2", speaker: .you))

        let recent = store.recentRemoteUtterances
        XCTAssertEqual(recent.count, 2)
        XCTAssertTrue(recent.allSatisfy { $0.speaker.isRemote })
    }

    // MARK: - Acoustic Echo Suppression (forward: you echoes existing them)

    func testForwardEchoSuppressesIdenticalMicUtterance() {
        let store = makeStore()
        let now = Date()
        store.append(makeUtterance(text: "Нам нужен этот бандал для имплементации клиента", speaker: .them, timestamp: now))
        let accepted = store.append(makeUtterance(text: "Нам нужен этот бандал для имплементации клиента", speaker: .you, timestamp: now.addingTimeInterval(1.0)))
        XCTAssertFalse(accepted, "Identical mic utterance within window should be suppressed")
        XCTAssertEqual(store.utterances.count, 1)
    }

    func testForwardEchoSuppressesSimilarMicUtterance() {
        let store = makeStore()
        let now = Date()
        store.append(makeUtterance(text: "Просто их будет намного проще мы не будем давать клиенту", speaker: .them, timestamp: now))
        let accepted = store.append(makeUtterance(text: "Просто X будет намного проще мы не будем давать клиенту", speaker: .you, timestamp: now.addingTimeInterval(2.0)))
        XCTAssertFalse(accepted, "Similar mic utterance (j≈0.8) within window should be suppressed")
        XCTAssertEqual(store.utterances.count, 1)
    }

    func testForwardEchoAllowsGenuineDifferentSpeech() {
        let store = makeStore()
        let now = Date()
        store.append(makeUtterance(text: "Мне кажется нужно обсудить этот вопрос на следующей встрече", speaker: .them, timestamp: now))
        let accepted = store.append(makeUtterance(text: "Да согласен давай сделаем это завтра утром", speaker: .you, timestamp: now.addingTimeInterval(1.0)))
        XCTAssertTrue(accepted, "Genuinely different speech should not be suppressed")
        XCTAssertEqual(store.utterances.count, 2)
    }

    func testForwardEchoIgnoresUtteranceOutsideWindow() {
        let store = makeStore()
        let now = Date()
        store.append(makeUtterance(text: "Нам нужен этот бандал для имплементации клиента", speaker: .them, timestamp: now))
        let accepted = store.append(makeUtterance(text: "Нам нужен этот бандал для имплементации клиента", speaker: .you, timestamp: now.addingTimeInterval(5.0)))
        XCTAssertTrue(accepted, "Echo outside 4s window should not be suppressed")
        XCTAssertEqual(store.utterances.count, 2)
    }

    // MARK: - Short-text strict branch (#59)
    // Sub-threshold texts are never Jaccard/containment-scored; instead an
    // exact-normalized-equality rule applies within a tighter 2s window.
    // (Supersedes the old "short utterances are skipped" expectation.)

    /// The observed leak: them='Orders.' then you='Orders.' 1.0s later —
    /// a verbatim short dup must drop (forward arrival order).
    func testForwardShortExactDupDropped() {
        let store = makeStore()
        let now = Date()
        store.append(makeUtterance(text: "Orders.", speaker: .them, timestamp: now))
        let accepted = store.append(makeUtterance(text: "Orders.", speaker: .you, timestamp: now.addingTimeInterval(1.0)))
        XCTAssertFalse(accepted, "Short verbatim dup within 2s should be suppressed")
        XCTAssertEqual(store.utterances.count, 1)
        XCTAssertEqual(store.utterances.first?.speaker, .them)
    }

    /// Same pair, real reverse configuration (#59 follow-up): the mic copy
    /// finalizes with a LATER timestamp (them ts is 1.0s EARLIER) but arrives
    /// first; the system twin lands second (isDelayed remote path). The
    /// retroactive check sees timeDelta = −1.0 and must still remove the mic copy.
    func testReverseShortExactDupDropped() {
        let store = makeStore()
        let now = Date()
        store.append(makeUtterance(text: "Orders.", speaker: .you, timestamp: now.addingTimeInterval(1.0)))
        store.append(makeUtterance(text: "Orders.", speaker: .them, timestamp: now))
        XCTAssertEqual(store.utterances.count, 1)
        XCTAssertEqual(store.utterances.first?.speaker, .them)
    }

    /// Long texts keep the asymmetric 0...window rule: a system utterance
    /// with an EARLIER timestamp than the mic copy (negative delta) must NOT
    /// trigger retroactive removal — loosening it risks false drops.
    func testReverseLongTextNegativeDeltaKept() {
        let store = makeStore()
        let now = Date()
        store.append(makeUtterance(text: "Нам нужен этот бандал для имплементации клиента", speaker: .you, timestamp: now.addingTimeInterval(1.0)))
        store.append(makeUtterance(text: "Нам нужен этот бандал для имплементации клиента", speaker: .them, timestamp: now))
        XCTAssertEqual(store.utterances.count, 2, "Long-text negative delta must not match")
    }

    /// Short but non-exact: strict equality only — no containment for
    /// shorts ("yeah" ⊂ "yeah right" must NOT match).
    func testShortNonExactKept() {
        let store = makeStore()
        let now = Date()
        store.append(makeUtterance(text: "yeah right", speaker: .them, timestamp: now))
        let accepted = store.append(makeUtterance(text: "Yeah.", speaker: .you, timestamp: now.addingTimeInterval(0.5)))
        XCTAssertTrue(accepted, "Short non-exact texts should never match")
        XCTAssertEqual(store.utterances.count, 2)
    }

    /// Exact short dup outside the 2s strict window (but inside the 4s
    /// long-text window) is kept — likely a genuine backchannel.
    func testShortExactDupOutsideStrictWindowKept() {
        let store = makeStore()
        let now = Date()
        store.append(makeUtterance(text: "Orders.", speaker: .them, timestamp: now))
        let accepted = store.append(makeUtterance(text: "Orders.", speaker: .you, timestamp: now.addingTimeInterval(3.0)))
        XCTAssertTrue(accepted, "Short exact dup outside 2s should not be suppressed")
        XCTAssertEqual(store.utterances.count, 2)
    }

    // MARK: - Acoustic Echo Suppression (reverse: them removes earlier you echo)

    func testReverseEchoRemovesMicEchoWhenThemArrives() {
        let store = makeStore()
        let now = Date()
        // Mic processes faster — "you" arrives first with the other person's words (j≈0.67)
        store.append(makeUtterance(text: "Там купає додаткових тогрів от чи вони також мають у нас якимось дивом спиратися на інформацію", speaker: .you, timestamp: now))
        // System audio arrives later — clean version
        store.append(makeUtterance(text: "От чи вони також мають у нас якимось дивом спиратися на інформацію і вмикатися", speaker: .them, timestamp: now.addingTimeInterval(2.0)))
        // The "you" echo should be retroactively removed, "them" kept
        XCTAssertEqual(store.utterances.count, 1)
        XCTAssertEqual(store.utterances.first?.speaker, .them)
    }

    func testReverseEchoKeepsBothWhenDifferentContent() {
        let store = makeStore()
        let now = Date()
        store.append(makeUtterance(text: "Я думаю что нам нужно обсудить архитектуру модуля", speaker: .you, timestamp: now))
        store.append(makeUtterance(text: "Давай посмотрим на результаты тестирования производительности", speaker: .them, timestamp: now.addingTimeInterval(1.0)))
        XCTAssertEqual(store.utterances.count, 2, "Different content should not trigger reverse echo removal")
    }

    func testReverseEchoIgnoresOutsideWindow() {
        let store = makeStore()
        let now = Date()
        store.append(makeUtterance(text: "Нам нужен этот бандал для имплементации клиента", speaker: .you, timestamp: now))
        store.append(makeUtterance(text: "Нам нужен этот бандал для имплементации клиента", speaker: .them, timestamp: now.addingTimeInterval(5.0)))
        XCTAssertEqual(store.utterances.count, 2, "Reverse echo outside 4s window should not remove")
    }

    func testReverseEchoDoesNotRemoveThemUtterances() {
        let store = makeStore()
        let now = Date()
        // Only "you" should be removed by reverse check, never "them"
        store.append(makeUtterance(text: "Нам нужен бандал для имплементации", speaker: .them, timestamp: now))
        store.append(makeUtterance(text: "Нам нужен бандал для имплементации клиента полностью", speaker: .them, timestamp: now.addingTimeInterval(1.0)))
        XCTAssertEqual(store.utterances.count, 2, "Reverse check should only remove .you utterances")
    }

    func testReverseEchoFindsYouBehindInterleavedThem() {
        let store = makeStore()
        let now = Date()
        // "you" echo at t=0
        store.append(makeUtterance(text: "Нам нужен этот бандал для имплементации клиента полностью по всем документам", speaker: .you, timestamp: now))
        // Unrelated "them" at t=1 (sits between the echo and the incoming "them")
        store.append(makeUtterance(text: "Хорошо давай обсудим другой вопрос", speaker: .them, timestamp: now.addingTimeInterval(1.0)))
        // Clean "them" arrives at t=2 — should find and remove the "you" at t=0
        store.append(makeUtterance(text: "Нам нужен этот бандал для имплементации клиента по всем документам полностью", speaker: .them, timestamp: now.addingTimeInterval(2.0)))
        // Should have: the unrelated "them" + the clean "them". "you" echo removed.
        XCTAssertEqual(store.utterances.count, 2)
        XCTAssertTrue(store.utterances.allSatisfy { $0.speaker != .you })
    }

    func testReverseEchoHandlesMultilingual() {
        let store = makeStore()
        let now = Date()
        // Same speech, different transliteration (real scenario from logs)
        store.append(makeUtterance(text: "Але для Anceлей їх немає це треба шукати тому я от зараз", speaker: .you, timestamp: now))
        store.append(makeUtterance(text: "Але для анцілерів ну їх немає це прям треба шукати тому я от зараз", speaker: .them, timestamp: now.addingTimeInterval(2.0)))
        XCTAssertEqual(store.utterances.count, 1)
        XCTAssertEqual(store.utterances.first?.speaker, .them)
    }

    // MARK: - Volatile Text

    func testVolatileTextDefaultsEmpty() {
        let store = makeStore()
        XCTAssertEqual(store.volatileYouText, "")
        XCTAssertEqual(store.volatileThemText, "")
    }

    func testVolatileTextCanBeSet() {
        let store = makeStore()
        store.volatileYouText = "partial you input"
        store.volatileThemText = "partial them input"
        XCTAssertEqual(store.volatileYouText, "partial you input")
        XCTAssertEqual(store.volatileThemText, "partial them input")
    }
}
