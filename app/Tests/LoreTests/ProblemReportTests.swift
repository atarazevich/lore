import XCTest
@testable import LoreKit

/// The client half of #84's promise, tested at the model layer (the form UI is
/// manual QA). Four guarantees:
///
/// 1. **Privacy** — a report built over a synthetic session that transcribed
///    fixture text on a named device carries none of those strings. The third
///    guardrail on the same promise as `DiagEventPrivacyTests` /
///    `HealthSnapshotPrivacyTests`.
/// 2. **Size** — a typical and a worst-case event set both stay well under the
///    1 MiB cap, and the client guard trips on an over-cap body.
/// 3. **Summary** — the "What this means" tab maps snapshot states to the right
///    sentences.
/// 4. **Uploader** — builds the correct request and, critically, posts the exact
///    bytes the preview shows (one serialization, no drift). Driven by a stub
///    URLProtocol — never the network.
final class ProblemReportTests: XCTestCase {

    // MARK: - Fixtures a report must never contain (mirrors the #82/#83 discipline)

    private static let transcript =
        "Remind me to email Sam about the Q3 revenue projections before Friday"
    private static let deviceName = "Sam's AirPods Pro"
    private static let filePath = "~/Downloads/private_notes_final.m4a"
    private static let apiKey = "sk-proj-abcdef1234567890"

    private static var fixtures: [String] {
        [transcript, deviceName, filePath, apiKey]
    }

    private static var fixtureTokens: [String] {
        fixtures
            .flatMap { $0.split(whereSeparator: { " /_-".contains($0) }) }
            .map(String.init)
            .filter { $0.count >= 4 && $0.contains(where: \.isLetter) }
    }

    /// A report over a session that recorded on a named wireless device and
    /// transcribed the fixture transcript. The device *name* only ever existed
    /// as a transport class; the transcript only ever as a character count.
    private static func syntheticReport(message: String, store: DiagStore) -> ProblemReport {
        store.record(.captureStart(deviceKind: .wireless, ms: 42))
        store.record(.transcribed(chunks: 1, failedChunks: 0, samples: 16_000, characters: transcript.count, ms: 300))
        store.record(.dictationPasted(characters: transcript.count, cleaned: true))
        store.record(.inputDeviceSelected(kind: .wireless, redirectedToBuiltIn: false))
        return ProblemReport.build(message: message, health: worstCaseSnapshot, store: store)
    }

    /// Every probe present and failing with every optional field populated — the
    /// snapshot that leaks the most, if anything could.
    private static var worstCaseSnapshot: HealthSnapshot {
        HealthSnapshot(
            marketingVersion: "2.0.4",
            build: "2.0.231",
            results: HealthProbeID.allCases.map { id in
                HealthResult(
                    id: id, status: .failed,
                    secureInputHolderPID: .max, signingCert: .adHoc,
                    freeDiskGB: 0, lastAttempt: HealthLastAttempt(outcome: .failed, ageSeconds: 99)
                )
            }
        )
    }

    private func makeStore() -> DiagStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ProblemReport-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return DiagStore(directory: dir)
    }

    /// Mutable box so a test can flip the tap probe between two health cycles,
    /// proving the composer's freeze holds against a genuinely changing snapshot.
    private final class StalledBox { var stalled = false }

    /// A `HealthMonitor` whose `tap` probe is driven by `stalled` — everything
    /// else reads the real (test-process) OS state, which is fine: the test only
    /// needs one probe it can flip.
    ///
    /// Except secure input, which is injected: the tap verdict is gated on it
    /// (#94), so the live read would make `stalled` stop moving the verdict on any
    /// host that happens to have secure input up — a `sudo` in a terminal, a
    /// password prompt — and this test's lever would silently vanish.
    @MainActor
    private static func makeMonitor(stalled: StalledBox) -> HealthMonitor {
        let prober = HealthProber(
            readTapLiveness: { HealthProberTests.liveness(alive: true, stalled: stalled.stalled) },
            readSecureInput: { HealthProberTests.secureInputState(active: false) },
            hasOpenAIKey: { true }
        )
        return HealthMonitor(prober: prober)
    }

    // MARK: - 1. Privacy

    func testEncodedReportContainsNoSessionFixture() throws {
        // The user's own message is theirs to send; the guarantee is about the
        // diagnostic payload, so the message here is deliberately benign.
        let report = Self.syntheticReport(message: "Fn key stopped working", store: makeStore())
        let json = String(decoding: try report.encoded(), as: UTF8.self)

        for fixture in Self.fixtures {
            XCTAssertFalse(json.contains(fixture), "report leaked fixture: \(fixture)")
        }
        for token in Self.fixtureTokens {
            XCTAssertFalse(
                json.localizedCaseInsensitiveContains(token),
                "report leaked token from a transcript/device/path/key: \(token)"
            )
        }
    }

    func testEnvironmentCarriesNoUserSetName() {
        // hw.model is a class identifier ("Mac15,3"), never the computer's name.
        let env = ProblemReport.Environment.current()
        XCTAssertFalse(env.macModel.isEmpty)
        XCTAssertFalse(env.macModel.contains(" "), "hw.model must be a bare identifier, not a user-set name")
    }

    /// The real guardrail: the *actual* host names on this machine — the ones a
    /// future edit adding a hostname field would leak — never appear in the
    /// bytes. Synthetic fixtures can't prove this; the machine's own names can.
    func testEnvironmentOmitsThisHostsRealNames() throws {
        let report = Self.syntheticReport(message: "benign message", store: makeStore())
        let json = String(decoding: try report.encoded(), as: UTF8.self)

        // ComputerName (Host.localizedName), the DNS host name, and the login
        // name — the three ways this Mac's owner shows up in system facts.
        let hostNames = [
            Host.current().localizedName,
            ProcessInfo.processInfo.hostName,
            NSUserName(),
            NSFullUserName(),
        ]
        .compactMap { $0 }
        .filter { $0.count >= 4 }

        XCTAssertFalse(hostNames.isEmpty, "expected at least one real host name to check against")
        for name in hostNames {
            XCTAssertFalse(
                json.localizedCaseInsensitiveContains(name),
                "report leaked a real host/user name: \(name)"
            )
        }
    }

    // MARK: - 2. Size

    func testTypicalAndWorstCaseBodiesStayUnderTheCap() throws {
        let store = makeStore()
        // Worst case: fill the ring past the report's event limit with the
        // longest-encoding events, then take the tail the report would send.
        for _ in 0..<(ProblemReport.eventLimit + 200) {
            store.record(.captureFailed(stage: .createIOProc, osStatus: .min))
        }
        let worst = ProblemReport.build(message: String(repeating: "x", count: 500), health: Self.worstCaseSnapshot, store: store)
        let worstBytes = try worst.encoded().count

        // Typical: a couple dozen events, a short message.
        let typicalStore = makeStore()
        for _ in 0..<25 { typicalStore.record(.appLaunched(build: 231)) }
        let typical = ProblemReport.build(message: "Fn key stopped working", health: Self.worstCaseSnapshot, store: typicalStore)
        let typicalBytes = try typical.encoded().count

        XCTAssertLessThanOrEqual(worst.events.count, ProblemReport.eventLimit)
        XCTAssertLessThan(worstBytes, ProblemReport.maxPayloadBytes / 4,
                          "worst-case body \(worstBytes) should sit well under the 1 MiB cap")
        XCTAssertLessThan(typicalBytes, worstBytes)
        // Surface the measured sizes in the test log.
        print("ProblemReport encoded size — typical: \(typicalBytes) bytes, worst-case: \(worstBytes) bytes")
    }

    func testUploaderRefusesAnOversizedBody() async throws {
        // A report whose encoded body exceeds the cap must be refused client-side,
        // never streamed to the server. A giant message is the simplest way over.
        let store = makeStore()
        let huge = ProblemReport.build(
            message: String(repeating: "A", count: ProblemReport.maxPayloadBytes + 1_000),
            health: Self.worstCaseSnapshot, store: store
        )
        let uploader = ReportUploader(session: StubURLProtocol.session())
        StubURLProtocol.reset()

        do {
            _ = try await uploader.upload(huge)
            XCTFail("expected the client guard to trip")
        } catch let error as ReportUploader.UploadError {
            guard case .tooLarge = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertNil(StubURLProtocol.lastRequest, "an oversized report must never reach the network")
    }

    // MARK: - 3. Summary

    func testSummaryNamesAFailedAccessibilityCheck() {
        let snapshot = HealthSnapshot(
            marketingVersion: "2.0.4", build: "2.0.231",
            results: [
                HealthResult(id: .accessibility, status: .failed),
                HealthResult(id: .microphone, status: .ok),
                HealthResult(id: .asrModel, status: .ok),
            ]
        )
        let lines = ProblemReportSummary.lines(for: snapshot)
        XCTAssertTrue(lines.contains { $0.contains("Accessibility") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("Microphone") }, "an ok check must not appear")
    }

    func testSummaryIsReassuringWhenEverythingPasses() {
        let snapshot = HealthSnapshot(
            marketingVersion: "2.0.4", build: "2.0.231",
            results: HealthProbeID.allCases.map { HealthResult(id: $0, status: .ok) }
        )
        let lines = ProblemReportSummary.lines(for: snapshot)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].lowercased().contains("all checks pass"), "\(lines)")
    }

    /// #94, the fourth surface: the report preview's "What this means" tab is the
    /// screen the reporting user of 8763HGZT was staring at. Under secure input the
    /// tap reads `.warning` meaning "no verdict", so this tab must not print "The Fn
    /// key isn't being received" directly beneath the sentence naming the real
    /// condition — the same one-issue rule the footer applies.
    func testSummaryUnderSecureInputNamesTheConditionAndNotTheFnKey() {
        let snapshot = HealthSnapshot(
            marketingVersion: "2.0.4", build: "2.0.231",
            results: [
                HealthResult(id: .tap, status: .warning),
                HealthResult(id: .secureInput, status: .failed),
            ]
        )
        let lines = ProblemReportSummary.lines(for: snapshot)
        XCTAssertEqual(lines, ["Secure input is active, blocking the hotkey."], "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("Fn key") },
                       "no surface may tell the user their Fn key is broken for a system-wide lock")
    }

    /// The same false name, in the report's own words. A failed tap does print a
    /// sentence here, and it may not be about the Fn key: the tap never carries it
    /// (#97), so the one surface a reader takes at face value must say what broke —
    /// the shortcuts Lore intercepts while another app is focused.
    func testTheTapsPlainLanguageIssueDoesNotBlameTheFnKey() {
        let snapshot = HealthSnapshot(
            marketingVersion: "2.0.4", build: "2.0.231",
            results: [HealthResult(id: .tap, status: .failed)]
        )
        let lines = ProblemReportSummary.lines(for: snapshot)
        XCTAssertEqual(lines.count, 1, "a failed tap is a problem worth a sentence — \(lines)")
        XCTAssertFalse(lines[0].contains("Fn key"), "the tap cannot answer for the Fn key")
    }

    func testSummaryIgnoresAnUntestedExpensiveProbe() {
        // An expensive probe that was never run reads as .warning ("not tested"),
        // which must not surface as a problem — same rule as the footer.
        let snapshot = HealthSnapshot(
            marketingVersion: "2.0.4", build: "2.0.231",
            results: [HealthResult(id: .micCapture, status: .warning)]
        )
        XCTAssertEqual(ProblemReportSummary.lines(for: snapshot).first?.lowercased().contains("all checks pass"), true)
    }

    // MARK: - 4. Uploader request shape + preview == posted

    func testUploaderBuildsTheCorrectRequestAndReadsTheID() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.responder = { _ in (200, Data(#"{"id":"NNGEB8YS"}"#.utf8)) }
        let uploader = ReportUploader(
            endpoint: URL(string: "https://reports.example/report")!,
            token: "test-token-value",
            session: StubURLProtocol.session()
        )
        let report = Self.syntheticReport(message: "hello", store: makeStore())

        let id = try await uploader.upload(report)

        XCTAssertEqual(id, "NNGEB8YS")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://reports.example/report")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Lore-Token"), "test-token-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    /// The honesty contract, tested through the real build-once flow. The preview
    /// reads `composer.report()` and the uploader posts `composer.report()`; the
    /// composer freezes the volatile diagnostics (snapshot + event tail) at
    /// `prepare()`, so even when the store gains an event and a probe flips
    /// between the preview and the send, the posted bytes equal the previewed
    /// bytes. Against a composer that re-read the store or re-probed at send time
    /// (the drift this feature exists to preclude) these would differ and this
    /// test would fail.
    @MainActor
    func testComposerFreezesDiagnosticsSoPreviewEqualsPost() async throws {
        let store = makeStore()
        store.record(.appLaunched(build: 1))   // one event frozen into the report

        let stalled = StalledBox()
        let monitor = Self.makeMonitor(stalled: stalled)
        let composer = ProblemReportComposer(
            healthMonitor: monitor,
            uploader: ReportUploader(session: StubURLProtocol.session()),
            store: store
        )
        StubURLProtocol.reset()
        composer.message = "drift check"
        composer.prepare()

        let previewedReport = composer.report()          // what the Raw data tab renders
        let previewedBytes = try previewedReport.encoded()
        let previewedTap = previewedReport.health.results.first { $0.id == .tap }?.status

        // The world changes underfoot: a new event lands and the tap probe flips.
        store.record(.appLaunched(build: 2))
        stalled.stalled = true
        monitor.refresh()

        // The drift lever is real: a *fresh* probe now reports the tap
        // differently (a measured starvation reads `.warning` since #140).
        XCTAssertEqual(previewedTap, .ok)
        XCTAssertEqual(monitor.snapshot.results.first { $0.id == .tap }?.status, .warning)

        _ = try await composer.send()
        let postedBytes = try XCTUnwrap(StubURLProtocol.lastBody)

        XCTAssertEqual(postedBytes, previewedBytes,
                       "the report must post exactly the frozen bytes the preview showed")
    }

    /// A failed send keeps the same frozen instance, so "Try again" resends those
    /// bytes rather than rebuilding with a newer snapshot.
    @MainActor
    func testRetryResendsTheSameBytes() async throws {
        let store = makeStore()
        store.record(.appLaunched(build: 1))
        let monitor = Self.makeMonitor(stalled: StalledBox())
        let composer = ProblemReportComposer(
            healthMonitor: monitor,
            uploader: ReportUploader(session: StubURLProtocol.session()),
            store: store
        )
        composer.message = "retry check"
        composer.prepare()
        let firstBytes = try composer.report().encoded()

        StubURLProtocol.reset()
        StubURLProtocol.responder = { _ in (500, Data(#"{"error":"boom"}"#.utf8)) }
        await composer.send()
        guard case .failed = composer.phase else { return XCTFail("expected failure, got \(composer.phase)") }

        // The store changes, but the retry must resend the frozen bytes.
        store.record(.appLaunched(build: 2))
        StubURLProtocol.reset()
        await composer.send()

        let resentBytes = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertEqual(resentBytes, firstBytes)
    }

    func testUploaderMapsAServerErrorStatus() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.responder = { _ in (413, Data(#"{"error":"too large"}"#.utf8)) }
        let uploader = ReportUploader(session: StubURLProtocol.session())
        do {
            _ = try await uploader.upload(Self.syntheticReport(message: "x", store: makeStore()))
            XCTFail("expected a server error")
        } catch let error as ReportUploader.UploadError {
            XCTAssertEqual(error, .server(status: 413))
        }
    }
}
