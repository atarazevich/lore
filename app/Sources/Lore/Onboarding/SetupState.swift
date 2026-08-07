import Foundation

/// The one bit that decides which world the process runs in (#150): before it is
/// set the onboarding window is the only surface. What it replaces, and why the
/// retired keys are migrated rather than deleted, is in
/// `docs/features/onboarding.md`.
enum SetupState {

    /// The single source of truth. Present and true ⟹ the app boots straight
    /// into the configured world.
    static let completedKey = "didCompleteSetup"

    /// The old 2-step meetings tour. It granted nothing and configured nothing,
    /// so on its own it is not evidence that setup ever happened.
    static let tourCompletedKey = "hasCompletedOnboarding"

    /// The old dictation flow — the one that actually collected the permissions.
    static let dictationCompletedKey = "completedDictationOnboarding"

    /// The old recording-consent sheet.
    static let consentAcknowledgedKey = "hasAcknowledgedRecordingConsent"

    /// The retired keys, owned here so no other file spells them by hand. Left
    /// in the domain after migration: `NotesFolderMigration` reads two of them
    /// as its "an earlier launch happened here" evidence.
    static let legacyCompletionKeys = [
        tourCompletedKey,
        dictationCompletedKey,
        consentAcknowledgedKey,
    ]

    /// Resolve the flag, migrating an older install on the way. Idempotent, and
    /// safe to call on every launch.
    ///
    /// Ordering: must run *after* `NotesFolderMigration` (which reads the legacy
    /// keys as fresh-install evidence) — `SettingsStore.init` places it there.
    @discardableResult
    static func resolve(defaults: UserDefaults) -> Bool {
        if let stored = defaults.object(forKey: completedKey) as? Bool {
            return stored
        }
        // A machine that finished the dictation flow holds the grants and is set
        // up. The tour alone proves nothing; paired with the consent sheet it is
        // an install that went through both of the old gates.
        let completedBefore = defaults.bool(forKey: dictationCompletedKey)
            || (defaults.bool(forKey: tourCompletedKey)
                && defaults.bool(forKey: consentAcknowledgedKey))
        // Persist the verdict for a fresh install too: the absence of the key is
        // what the next launch would otherwise re-derive from keys that the new
        // flow no longer writes.
        defaults.set(completedBefore, forKey: completedKey)
        return completedBefore
    }
}
