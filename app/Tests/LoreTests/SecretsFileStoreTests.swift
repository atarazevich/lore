import XCTest
@testable import LoreKit

/// #134: API keys live in an owner-only file, never the system Keychain,
/// so no keychain dialog can ever appear. These tests run against a temp
/// file — they must never construct `SecretsFileStore.live`.
final class SecretsFileStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecretsFileStoreTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> SecretsFileStore {
        SecretsFileStore(fileURL: directory.appendingPathComponent("secrets.json"))
    }

    func testLoadWithoutFileReturnsNil() {
        XCTAssertNil(makeStore().load(key: "openaiApiKey"))
    }

    func testSaveThenLoadRoundtrip() {
        let store = makeStore()
        store.save(key: "openaiApiKey", value: "sk-test-123")
        XCTAssertEqual(store.load(key: "openaiApiKey"), "sk-test-123")
    }

    func testValuesPersistAcrossInstances() {
        makeStore().save(key: "speechifyApiKey", value: "sp-abc")
        XCTAssertEqual(makeStore().load(key: "speechifyApiKey"), "sp-abc")
    }

    func testSavePreservesOtherKeys() {
        let store = makeStore()
        store.save(key: "openaiApiKey", value: "sk-1")
        store.save(key: "speechifyApiKey", value: "sp-2")
        store.save(key: "openaiApiKey", value: "sk-updated")
        XCTAssertEqual(store.load(key: "openaiApiKey"), "sk-updated")
        XCTAssertEqual(store.load(key: "speechifyApiKey"), "sp-2")
    }

    private func permissions(of fileURL: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).uint16Value
    }

    /// The swapped-in file carries the temp file's 0600, on the first save and
    /// on every overwrite. Seeded 0644 because the atomic replace defaults to
    /// keeping the *replaced* file's mode — without the seed the assertion
    /// would pass even if that mode leaked through.
    func testFileIsOwnerOnly() throws {
        let fileURL = directory.appendingPathComponent("secrets.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: fileURL.path,
            contents: Data("{}".utf8),
            attributes: [.posixPermissions: 0o644]
        ))

        let store = makeStore()
        XCTAssertTrue(store.save(key: "openaiApiKey", value: "sk-perm"))
        XCTAssertEqual(try permissions(of: fileURL), 0o600)

        XCTAssertTrue(store.save(key: "openaiApiKey", value: "sk-perm-2"))
        XCTAssertEqual(try permissions(of: fileURL), 0o600)
        XCTAssertEqual(store.load(key: "openaiApiKey"), "sk-perm-2")
    }

    /// Gates the legacy-keychain cleanup in `AppSecretStore.localFile`: a save
    /// that never reached disk must report failure, or the last surviving copy
    /// of the key gets deleted.
    func testSaveReportsFailureWhenFileCannotBeWritten() {
        let store = SecretsFileStore(
            fileURL: URL(fileURLWithPath: "/dev/null/unwritable/secrets.json")
        )
        XCTAssertFalse(store.save(key: "openaiApiKey", value: "sk-lost"))
    }

    func testCorruptFileReadsAsEmpty() throws {
        let fileURL = directory.appendingPathComponent("secrets.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let store = SecretsFileStore(fileURL: fileURL)
        XCTAssertNil(store.load(key: "openaiApiKey"))
        store.save(key: "openaiApiKey", value: "sk-recovered")
        XCTAssertEqual(store.load(key: "openaiApiKey"), "sk-recovered")
    }
}
