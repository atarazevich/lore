import Foundation
import Security

struct AppSecretStore: Sendable {
    let loadValue: @Sendable (String) -> String?
    let saveValue: @Sendable (String, String) -> Void

    func load(key: String) -> String? {
        loadValue(key)
    }

    func save(key: String, value: String) {
        saveValue(key, value)
    }

    /// Production store (#134): owner-only secrets file, never the system
    /// Keychain. Reads touch no Security API at all; a *successful* save
    /// additionally deletes the pre-#134 login-keychain item (delete never
    /// prompts), so legacy secrets are cleaned up the first time a key is
    /// re-entered. The gate matters: if the file write failed, the keychain
    /// item is the last surviving copy of the key and must be left alone.
    static let localFile = AppSecretStore(
        loadValue: { SecretsFileStore.live.load(key: $0) },
        saveValue: { key, value in
            guard SecretsFileStore.live.save(key: key, value: value) else { return }
            LegacyKeychain.deleteItem(key: key)
        }
    )

    static let ephemeral = AppSecretStore(
        loadValue: { _ in nil },
        saveValue: { _, _ in }
    )
}

struct SettingsStorage {
    let defaults: UserDefaults
    let secretStore: AppSecretStore
    let defaultNotesDirectory: URL
    /// The folders the #148 move may take notes *from*. No default on purpose:
    /// the real value is the owner's `~/Documents`, so a test that forgot to
    /// name its own would list it. Required here, it cannot be forgotten.
    let legacyNotesDirectories: [URL]
    let runMigrations: Bool

    static func live(defaults: UserDefaults = .standard) -> SettingsStorage {
        SettingsStorage(
            defaults: defaults,
            secretStore: .localFile,
            // Was ~/Documents/Lore until #148 — a TCC-protected location the
            // app created at launch, which is what made a fresh install ask
            // for Documents access before the user had done anything.
            defaultNotesDirectory: NotesFolder.applicationSupportDefault,
            legacyNotesDirectories: NotesFolder.legacyDefaults,
            runMigrations: true
        )
    }
}

/// Backward-compatible alias for existing test code.
typealias AppSettingsStorage = SettingsStorage

// MARK: - Secrets File Store (#134)

/// API keys live in an owner-only (0600) JSON file, not the Keychain.
///
/// Why: keychain generic passwords bind their ACL to the exact signing
/// certificate, so any cert change makes every launch pop the macOS
/// "wants to access keychain" dialog — which reads as malware. This app's
/// SwiftPM build carries no provisioning profile, so the data-protection
/// keychain (the dialog-free alternative) is unavailable: its required
/// `keychain-access-groups`/`application-identifier` entitlements get the
/// process SIGKILLed by AMFI under both our signing identities (probed
/// 2026-08-05). A 0600 file has the same practical protection as the
/// login keychain against other *users*, and no dialog can ever appear.
final class SecretsFileStore: @unchecked Sendable {
    static let live = SecretsFileStore(
        fileURL: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Lore/secrets.json")
    )

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load(key: String) -> String? {
        lock.withLock { readAll()[key] }
    }

    /// Returns whether the value actually reached disk — `AppSecretStore`
    /// deletes the legacy keychain copy only on `true`.
    @discardableResult
    func save(key: String, value: String) -> Bool {
        lock.withLock {
            var secrets = readAll()
            secrets[key] = value
            return writeAll(secrets)
        }
    }

    private func readAll() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func writeAll(_ secrets: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(secrets) else { return false }
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Create the temp file 0600 from the first byte, then swap it in with
        // a single replace: the secrets are never on disk with default 0644
        // permissions, and no interruption can leave the store missing — the
        // file always holds either the old keys or the new ones.
        // `.usingNewMetadataOnly` is load-bearing: the default carries the
        // *replaced* file's mode over, so a once-loose file would stay loose.
        let temp = directory.appendingPathComponent(".secrets.json.tmp")
        guard fm.createFile(
            atPath: temp.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return false }
        do {
            _ = try fm.replaceItemAt(fileURL, withItemAt: temp, options: .usingNewMetadataOnly)
            return true
        } catch {
            try? fm.removeItem(at: temp)
            return false
        }
    }
}

// MARK: - Legacy Keychain Cleanup (#134)

/// Pre-#134 builds stored keys as login-keychain generic passwords whose
/// ACLs bind to the signing cert. Those items are NEVER read — reading is
/// exactly what triggers the keychain dialog. They are only deleted
/// (SecItemDelete does not prompt) when a key is saved to the new store.
/// A user who never re-enters a key keeps an orphaned legacy item, which
/// is harmless: nothing ever touches it again.
enum LegacyKeychain {
    private static let service = "com.lore.app"

    /// Regression guard: unit tests must never reach the real Keychain —
    /// tests inject `AppSecretStore.ephemeral` or a temp-file
    /// `SecretsFileStore`; this trips (debug builds only) if any test path
    /// forgets.
    private static func assertNotRunningUnitTests() {
        assert(
            !RuntimeEnvironment.isRunningUnitTests,
            "LegacyKeychain used from a unit test — inject AppSecretStore.ephemeral instead"
        )
    }

    static func deleteItem(key: String) {
        assertNotRunningUnitTests()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
