import AppKit
import CoreAudio
import Foundation
import Observation

@Observable
@MainActor
final class SettingsStore {
    private let defaults: UserDefaults
    private let secretStore: AppSecretStore

    // MARK: - AI Settings

    @ObservationIgnored nonisolated(unsafe) private var _enableTranscriptRefinement: Bool
    var enableTranscriptRefinement: Bool {
        get { access(keyPath: \.enableTranscriptRefinement); return _enableTranscriptRefinement }
        set {
            withMutation(keyPath: \.enableTranscriptRefinement) {
                _enableTranscriptRefinement = newValue
                defaults.set(newValue, forKey: "enableTranscriptRefinement")
            }
        }
    }

    // MARK: - Capture Settings

    @ObservationIgnored nonisolated(unsafe) private var _inputDeviceID: AudioDeviceID
    var inputDeviceID: AudioDeviceID {
        get { access(keyPath: \.inputDeviceID); return _inputDeviceID }
        set {
            withMutation(keyPath: \.inputDeviceID) {
                _inputDeviceID = newValue
                defaults.set(Int(newValue), forKey: "inputDeviceID")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _transcriptionLocale: String
    var transcriptionLocale: String {
        get { access(keyPath: \.transcriptionLocale); return _transcriptionLocale }
        set {
            withMutation(keyPath: \.transcriptionLocale) {
                _transcriptionLocale = newValue
                defaults.set(newValue, forKey: "transcriptionLocale")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _saveAudioRecording: Bool
    var saveAudioRecording: Bool {
        get { access(keyPath: \.saveAudioRecording); return _saveAudioRecording }
        set {
            withMutation(keyPath: \.saveAudioRecording) {
                _saveAudioRecording = newValue
                defaults.set(newValue, forKey: "saveAudioRecording")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _enableBatchRefinement: Bool
    var enableBatchRefinement: Bool {
        get { access(keyPath: \.enableBatchRefinement); return _enableBatchRefinement }
        set {
            withMutation(keyPath: \.enableBatchRefinement) {
                _enableBatchRefinement = newValue
                defaults.set(newValue, forKey: "enableBatchRefinement")
            }
        }
    }

    // MARK: - Detection Settings

    @ObservationIgnored nonisolated(unsafe) private var _meetingAutoDetectEnabled: Bool
    var meetingAutoDetectEnabled: Bool {
        get { access(keyPath: \.meetingAutoDetectEnabled); return _meetingAutoDetectEnabled }
        set {
            withMutation(keyPath: \.meetingAutoDetectEnabled) {
                _meetingAutoDetectEnabled = newValue
                defaults.set(newValue, forKey: "meetingAutoDetectEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _customMeetingAppBundleIDs: [String]
    var customMeetingAppBundleIDs: [String] {
        get { access(keyPath: \.customMeetingAppBundleIDs); return _customMeetingAppBundleIDs }
        set {
            withMutation(keyPath: \.customMeetingAppBundleIDs) {
                _customMeetingAppBundleIDs = newValue
                defaults.set(newValue, forKey: "customMeetingAppBundleIDs")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _ignoredAppBundleIDs: [String]
    var ignoredAppBundleIDs: [String] {
        get { access(keyPath: \.ignoredAppBundleIDs); return _ignoredAppBundleIDs }
        set {
            withMutation(keyPath: \.ignoredAppBundleIDs) {
                _ignoredAppBundleIDs = newValue
                defaults.set(newValue, forKey: "ignoredAppBundleIDs")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _silenceTimeoutMinutes: Int
    var silenceTimeoutMinutes: Int {
        get { access(keyPath: \.silenceTimeoutMinutes); return _silenceTimeoutMinutes }
        set {
            withMutation(keyPath: \.silenceTimeoutMinutes) {
                _silenceTimeoutMinutes = newValue
                defaults.set(newValue, forKey: "silenceTimeoutMinutes")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _hasShownAutoDetectExplanation: Bool
    var hasShownAutoDetectExplanation: Bool {
        get { access(keyPath: \.hasShownAutoDetectExplanation); return _hasShownAutoDetectExplanation }
        set {
            withMutation(keyPath: \.hasShownAutoDetectExplanation) {
                _hasShownAutoDetectExplanation = newValue
                defaults.set(newValue, forKey: "hasShownAutoDetectExplanation")
            }
        }
    }

    // MARK: - Privacy Settings

    @ObservationIgnored nonisolated(unsafe) private var _hasAcknowledgedRecordingConsent: Bool
    var hasAcknowledgedRecordingConsent: Bool {
        get { access(keyPath: \.hasAcknowledgedRecordingConsent); return _hasAcknowledgedRecordingConsent }
        set {
            withMutation(keyPath: \.hasAcknowledgedRecordingConsent) {
                _hasAcknowledgedRecordingConsent = newValue
                defaults.set(newValue, forKey: "hasAcknowledgedRecordingConsent")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _hideFromScreenShare: Bool
    var hideFromScreenShare: Bool {
        get { access(keyPath: \.hideFromScreenShare); return _hideFromScreenShare }
        set {
            withMutation(keyPath: \.hideFromScreenShare) {
                _hideFromScreenShare = newValue
                defaults.set(newValue, forKey: "hideFromScreenShare")
                applyScreenShareVisibility()
            }
        }
    }

    // MARK: - Import Settings

    @ObservationIgnored nonisolated(unsafe) private var _granolaApiKey: String
    var granolaApiKey: String {
        get { access(keyPath: \.granolaApiKey); return _granolaApiKey }
        set {
            withMutation(keyPath: \.granolaApiKey) {
                _granolaApiKey = newValue
                secretStore.save(key: "granolaApiKey", value: newValue)
            }
        }
    }

    // MARK: - Dictation Settings

    @ObservationIgnored nonisolated(unsafe) private var _soundOnDictationStart: Bool
    /// DSET-16: play a short chime exactly when dictation capture starts. Default off.
    var soundOnDictationStart: Bool {
        get { access(keyPath: \.soundOnDictationStart); return _soundOnDictationStart }
        set {
            withMutation(keyPath: \.soundOnDictationStart) {
                _soundOnDictationStart = newValue
                defaults.set(newValue, forKey: "soundOnDictationStart")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _dictationAudioRetentionCount: Int
    /// #52: how many recent recordings keep their audio (audio powers Retry;
    /// text history is uncapped since #51). 0 is the "unlimited" sentinel —
    /// pruning is skipped entirely. Absent key defaults to 500, the previous
    /// hardcoded policy, so existing installs migrate for free.
    var dictationAudioRetentionCount: Int {
        get { access(keyPath: \.dictationAudioRetentionCount); return _dictationAudioRetentionCount }
        set {
            withMutation(keyPath: \.dictationAudioRetentionCount) {
                _dictationAudioRetentionCount = newValue
                defaults.set(newValue, forKey: "dictationAudioRetention")
            }
        }
    }

    // Modifier enable toggles (Settings MODIFIERS section, DSET-05/06). Each
    // gates one hardcoded key path in HotkeyManager; all default on. Esc is
    // not a modifier and has no toggle.

    @ObservationIgnored nonisolated(unsafe) private var _modifierLockEnabled: Bool
    /// Space = lock while recording.
    var modifierLockEnabled: Bool {
        get { access(keyPath: \.modifierLockEnabled); return _modifierLockEnabled }
        set {
            withMutation(keyPath: \.modifierLockEnabled) {
                _modifierLockEnabled = newValue
                defaults.set(newValue, forKey: "modifierLockEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _modifierCleanupEnabled: Bool
    /// Fn+V = pending cleanup while recording.
    var modifierCleanupEnabled: Bool {
        get { access(keyPath: \.modifierCleanupEnabled); return _modifierCleanupEnabled }
        set {
            withMutation(keyPath: \.modifierCleanupEnabled) {
                _modifierCleanupEnabled = newValue
                defaults.set(newValue, forKey: "modifierCleanupEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _modifierTranslateEnabled: Bool
    /// Fn+T = pending translate while recording.
    var modifierTranslateEnabled: Bool {
        get { access(keyPath: \.modifierTranslateEnabled); return _modifierTranslateEnabled }
        set {
            withMutation(keyPath: \.modifierTranslateEnabled) {
                _modifierTranslateEnabled = newValue
                defaults.set(newValue, forKey: "modifierTranslateEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _modifierUpgradeKeysEnabled: Bool
    /// C/T = post-paste upgrade keys while the upgrade panel shows.
    var modifierUpgradeKeysEnabled: Bool {
        get { access(keyPath: \.modifierUpgradeKeysEnabled); return _modifierUpgradeKeysEnabled }
        set {
            withMutation(keyPath: \.modifierUpgradeKeysEnabled) {
                _modifierUpgradeKeysEnabled = newValue
                defaults.set(newValue, forKey: "modifierUpgradeKeysEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _hotkeyKey: HotkeyKey
    var hotkeyKey: HotkeyKey {
        get { access(keyPath: \.hotkeyKey); return _hotkeyKey }
        set {
            withMutation(keyPath: \.hotkeyKey) {
                _hotkeyKey = newValue
                defaults.set(newValue.rawValue, forKey: "hotkeyKey")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _cleanupPreset: CleanupPreset
    var cleanupPreset: CleanupPreset {
        get { access(keyPath: \.cleanupPreset); return _cleanupPreset }
        set {
            withMutation(keyPath: \.cleanupPreset) {
                _cleanupPreset = newValue
                defaults.set(newValue.rawValue, forKey: "cleanupPreset")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _customCleanupPrompt: String
    var customCleanupPrompt: String {
        get { access(keyPath: \.customCleanupPrompt); return _customCleanupPrompt }
        set {
            withMutation(keyPath: \.customCleanupPrompt) {
                _customCleanupPrompt = newValue
                defaults.set(newValue, forKey: "customCleanupPrompt")
            }
        }
    }

    var activeCleanupPrompt: String {
        CleanupMode.prompt(for: cleanupPreset, customPrompt: customCleanupPrompt)
    }

    @ObservationIgnored nonisolated(unsafe) private var _cleanupByDefault: Bool
    var cleanupByDefault: Bool {
        get { access(keyPath: \.cleanupByDefault); return _cleanupByDefault }
        set {
            withMutation(keyPath: \.cleanupByDefault) {
                _cleanupByDefault = newValue
                defaults.set(newValue, forKey: "dictationCleanupEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _translationByDefault: Bool
    var translationByDefault: Bool {
        get { access(keyPath: \.translationByDefault); return _translationByDefault }
        set {
            withMutation(keyPath: \.translationByDefault) {
                _translationByDefault = newValue
                defaults.set(newValue, forKey: "dictationTranslationEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openaiApiKey: String
    var openaiApiKey: String {
        get { access(keyPath: \.openaiApiKey); return _openaiApiKey }
        set {
            withMutation(keyPath: \.openaiApiKey) {
                _openaiApiKey = newValue
                secretStore.save(key: "openaiApiKey", value: newValue)
            }
        }
    }

    // MARK: - UI Settings

    @ObservationIgnored nonisolated(unsafe) private var _recPillEnabled: Bool
    /// SET-11: "Recording status in toolbar" — governs the toolbar REC pill
    /// (shown only while recording AND this is on AND current view ≠ Meetings).
    /// Default on. The sidebar live dots are NOT gated by this.
    var recPillEnabled: Bool {
        get { access(keyPath: \.recPillEnabled); return _recPillEnabled }
        set {
            withMutation(keyPath: \.recPillEnabled) {
                _recPillEnabled = newValue
                defaults.set(newValue, forKey: "recPillEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _showLiveTranscript: Bool
    var showLiveTranscript: Bool {
        get { access(keyPath: \.showLiveTranscript); return _showLiveTranscript }
        set {
            withMutation(keyPath: \.showLiveTranscript) {
                _showLiveTranscript = newValue
                defaults.set(newValue, forKey: "showLiveTranscript")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _notesFolderPath: String
    var notesFolderPath: String {
        get { access(keyPath: \.notesFolderPath); return _notesFolderPath }
        set {
            withMutation(keyPath: \.notesFolderPath) {
                _notesFolderPath = newValue
                defaults.set(newValue, forKey: "notesFolderPath")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _hasSeenLaunchAtLoginSuggestion: Bool
    var hasSeenLaunchAtLoginSuggestion: Bool {
        get { access(keyPath: \.hasSeenLaunchAtLoginSuggestion); return _hasSeenLaunchAtLoginSuggestion }
        set {
            withMutation(keyPath: \.hasSeenLaunchAtLoginSuggestion) {
                _hasSeenLaunchAtLoginSuggestion = newValue
                defaults.set(newValue, forKey: "hasSeenLaunchAtLoginSuggestion")
            }
        }
    }

    // MARK: - Initialization

    init(storage: SettingsStorage = .live()) {
        self.defaults = storage.defaults
        self.secretStore = storage.secretStore

        let defaults = storage.defaults

        // One-time migrations from previous bundle IDs
        if storage.runMigrations {
            Self.migrateFromOldBundleIfNeeded(defaults: defaults)
            Self.migrateFromOpenGranolaIfNeeded(defaults: defaults)

            // #53: vocabulary learning removed — wipe the collected data once.
            defaults.removeObject(forKey: "learnedWords")
            defaults.removeObject(forKey: "transcriptionCustomVocabulary")
        }

        // AI Settings
        // The suggestion-verbosity, embeddings, and LLM-provider defaults keys
        // (llmProvider, ollamaBaseURL, ollamaLLMModel, mlxBaseURL, mlxModel)
        // are retired (#70, #74) — stored values are left in place, just no
        // longer read. Refinement is OpenAI-only via openaiApiKey.
        self._enableTranscriptRefinement = defaults.bool(forKey: "enableTranscriptRefinement")

        // Capture Settings
        self._inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        self._transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "en-US"
        self._saveAudioRecording = defaults.bool(forKey: "saveAudioRecording")

        if defaults.object(forKey: "enableBatchRefinement") == nil {
            self._enableBatchRefinement = false
        } else {
            self._enableBatchRefinement = defaults.bool(forKey: "enableBatchRefinement")
        }

        // Detection Settings — default to false until meeting mode is stable
        if defaults.object(forKey: "meetingAutoDetectEnabled") == nil {
            self._meetingAutoDetectEnabled = false
        } else {
            self._meetingAutoDetectEnabled = defaults.bool(forKey: "meetingAutoDetectEnabled")
        }
        self._customMeetingAppBundleIDs = defaults.stringArray(forKey: "customMeetingAppBundleIDs") ?? []
        self._ignoredAppBundleIDs = defaults.stringArray(forKey: "ignoredAppBundleIDs") ?? []
        self._silenceTimeoutMinutes = defaults.object(forKey: "silenceTimeoutMinutes") != nil
            ? defaults.integer(forKey: "silenceTimeoutMinutes") : 15
        self._hasShownAutoDetectExplanation = defaults.bool(forKey: "hasShownAutoDetectExplanation")

        // Privacy Settings
        self._hasAcknowledgedRecordingConsent = defaults.bool(forKey: "hasAcknowledgedRecordingConsent")
        if defaults.object(forKey: "hideFromScreenShare") == nil {
            self._hideFromScreenShare = true
        } else {
            self._hideFromScreenShare = defaults.bool(forKey: "hideFromScreenShare")
        }

        // Import Settings
        self._granolaApiKey = storage.secretStore.load(key: "granolaApiKey") ?? ""

        // Dictation Settings
        self._soundOnDictationStart = defaults.bool(forKey: "soundOnDictationStart")
        self._dictationAudioRetentionCount = defaults.object(forKey: "dictationAudioRetention") as? Int ?? 500
        // Modifier toggles default on (key absent == enabled)
        self._modifierLockEnabled = defaults.object(forKey: "modifierLockEnabled") as? Bool ?? true
        self._modifierCleanupEnabled = defaults.object(forKey: "modifierCleanupEnabled") as? Bool ?? true
        self._modifierTranslateEnabled = defaults.object(forKey: "modifierTranslateEnabled") as? Bool ?? true
        self._modifierUpgradeKeysEnabled = defaults.object(forKey: "modifierUpgradeKeysEnabled") as? Bool ?? true
        self._hotkeyKey = HotkeyKey(
            rawValue: defaults.string(forKey: "hotkeyKey") ?? ""
        ) ?? .fn
        if let savedPreset = defaults.string(forKey: "cleanupPreset"),
           let preset = CleanupPreset(rawValue: savedPreset) {
            self._cleanupPreset = preset
        } else {
            self._cleanupPreset = .clean
        }
        self._customCleanupPrompt = defaults.string(forKey: "customCleanupPrompt") ?? ""
        self._cleanupByDefault = defaults.bool(forKey: "dictationCleanupEnabled")
        self._translationByDefault = defaults.bool(forKey: "dictationTranslationEnabled")
        self._openaiApiKey = storage.secretStore.load(key: "openaiApiKey") ?? ""

        // UI Settings
        self._recPillEnabled = defaults.object(forKey: "recPillEnabled") as? Bool ?? true
        if defaults.object(forKey: "showLiveTranscript") == nil {
            self._showLiveTranscript = true
        } else {
            self._showLiveTranscript = defaults.bool(forKey: "showLiveTranscript")
        }
        let defaultNotesPath = storage.defaultNotesDirectory.path
        self._notesFolderPath = defaults.string(forKey: "notesFolderPath") ?? defaultNotesPath
        self._hasSeenLaunchAtLoginSuggestion = defaults.bool(forKey: "hasSeenLaunchAtLoginSuggestion")

        // Ensure notes folder exists
        try? FileManager.default.createDirectory(
            atPath: notesFolderPath,
            withIntermediateDirectories: true
        )

        // Prevent Spotlight from indexing transcript contents
        Self.dropMetadataNeverIndex(atPath: notesFolderPath)
    }

    // MARK: - Computed Properties

    var locale: Locale {
        Locale(identifier: transcriptionLocale)
    }

    // MARK: - Screen Share Visibility

    /// Sharing type all app windows should carry. Absence of the stored key
    /// defaults to hidden (privacy-first, set in init).
    var screenSharingType: NSWindow.SharingType {
        Self.screenSharingType(hidden: hideFromScreenShare)
    }

    /// Same decision for callers that only hold a UserDefaults reference
    /// (panels constructed before any SettingsStore is in reach).
    nonisolated static func screenSharingType(from defaults: UserDefaults) -> NSWindow.SharingType {
        screenSharingType(hidden: defaults.object(forKey: "hideFromScreenShare") as? Bool ?? true)
    }

    private nonisolated static func screenSharingType(hidden: Bool) -> NSWindow.SharingType {
        hidden ? .none : .readOnly
    }

    /// Apply current screen-share visibility to all app windows.
    func applyScreenShareVisibility() {
        let type = screenSharingType
        for window in NSApp.windows {
            window.sharingType = type
        }
    }

    // MARK: - Spotlight Indexing

    /// Place a .metadata_never_index sentinel so Spotlight skips the directory.
    private static func dropMetadataNeverIndex(atPath directoryPath: String) {
        let sentinel = URL(fileURLWithPath: directoryPath).appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: sentinel.path) {
            FileManager.default.createFile(atPath: sentinel.path, contents: nil)
        }
    }
}

// MARK: - Migration

extension SettingsStore {
    /// Migrate settings from the old "On The Spot" (com.onthespot.app) bundle.
    /// Copies UserDefaults entries to the current bundle, then marks migration as done.
    private static func migrateFromOldBundleIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateFromOnTheSpot"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        guard let oldDefaults = UserDefaults(suiteName: "com.onthespot.app") else { return }

        let keysToMigrate = [
            "transcriptionLocale", "inputDeviceID",
            "hideFromScreenShare",
            "hasCompletedOnboarding",
        ]
        for key in keysToMigrate {
            if let value = oldDefaults.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }

    /// Migrate settings from the previous "OpenGranola" (com.opengranola.app) bundle.
    private static func migrateFromOpenGranolaIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateFromOpenGranola"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        guard let oldDefaults = UserDefaults(suiteName: "com.opengranola.app") else {
            migrateFilesFromOpenGranola(defaults: defaults)
            return
        }

        let keysToMigrate = [
            "transcriptionLocale", "inputDeviceID",
            "hideFromScreenShare",
            "hasCompletedOnboarding",
            "hasAcknowledgedRecordingConsent",
        ]
        for key in keysToMigrate {
            if let value = oldDefaults.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        migrateFilesFromOpenGranola(defaults: defaults)
    }

    /// Migrate file-backed state (sessions, templates, KB cache, transcripts)
    /// from ~/Library/Application Support/OpenGranola/ to OpenOats/ and
    /// handle the implicit KB folder default.
    private static func migrateFilesFromOpenGranola(defaults: UserDefaults) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        let oldAppSupportDir = appSupport.appendingPathComponent("OpenGranola")
        let newAppSupportDir = appSupport.appendingPathComponent("Lore")

        if fm.fileExists(atPath: oldAppSupportDir.path) {
            try? fm.createDirectory(at: newAppSupportDir, withIntermediateDirectories: true)

            let oldSessions = oldAppSupportDir.appendingPathComponent("sessions")
            let newSessions = newAppSupportDir.appendingPathComponent("sessions")
            if fm.fileExists(atPath: oldSessions.path) && !fm.fileExists(atPath: newSessions.path) {
                try? fm.moveItem(at: oldSessions, to: newSessions)
            }

            let oldTemplates = oldAppSupportDir.appendingPathComponent("templates.json")
            let newTemplates = newAppSupportDir.appendingPathComponent("templates.json")
            if fm.fileExists(atPath: oldTemplates.path) && !fm.fileExists(atPath: newTemplates.path) {
                try? fm.moveItem(at: oldTemplates, to: newTemplates)
            }
        }

        let oldDocDir = home.appendingPathComponent("Documents/OpenGranola")
        let newDocDir = home.appendingPathComponent("Documents/Lore")

        if defaults.string(forKey: "notesFolderPath") == nil {
            if fm.fileExists(atPath: oldDocDir.path) {
                let contents = (try? fm.contentsOfDirectory(atPath: oldDocDir.path)) ?? []
                if !contents.isEmpty {
                    defaults.set(oldDocDir.path, forKey: "notesFolderPath")
                }
            }
        }

        let activeNotes = defaults.string(forKey: "notesFolderPath") ?? ""
        if fm.fileExists(atPath: oldDocDir.path) && oldDocDir.path != activeNotes {
            try? fm.createDirectory(at: newDocDir, withIntermediateDirectories: true)
            if let files = try? fm.contentsOfDirectory(at: oldDocDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "txt" {
                    let dest = newDocDir.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: file, to: dest)
                    }
                }
            }
        }
    }

}

/// Backward-compatible alias so existing code continues to compile during migration.
typealias AppSettings = SettingsStore
