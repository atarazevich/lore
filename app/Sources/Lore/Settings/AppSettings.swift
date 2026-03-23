import AppKit
import Foundation
import Observation
import Security
import CoreAudio

enum LLMProvider: String, CaseIterable, Identifiable {
    case openRouter
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        }
    }
}

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case parakeetV2
    case parakeetV3
    case qwen3ASR06B

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeetV2: "Parakeet TDT v2"
        case .parakeetV3: "Parakeet TDT v3"
        case .qwen3ASR06B: "Qwen3 ASR 0.6B"
        }
    }

    var downloadPrompt: String {
        switch self {
        case .parakeetV2, .parakeetV3:
            "Transcription requires a one-time model download."
        case .qwen3ASR06B:
            "Qwen3 ASR requires a one-time model download."
        }
    }
}

enum HotkeyKey: String, CaseIterable, Identifiable, Codable {
    case fn
    case rightOption

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: "Fn (Globe)"
        case .rightOption: "Right Option (⌥)"
        }
    }

    /// Check if this key matches the given flags-changed event.
    func matchesPress(_ event: NSEvent) -> Bool {
        switch self {
        case .fn:
            return event.modifierFlags.contains(.function)
        case .rightOption:
            return event.modifierFlags.contains(.option) && event.keyCode == 61
        }
    }
}

enum EmbeddingProvider: String, CaseIterable, Identifiable {
    case voyageAI
    case ollama
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .voyageAI: "Voyage AI"
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI Compatible"
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    var kbFolderPath: String {
        didSet { UserDefaults.standard.set(kbFolderPath, forKey: "kbFolderPath") }
    }

    var notesFolderPath: String {
        didSet { UserDefaults.standard.set(notesFolderPath, forKey: "notesFolderPath") }
    }

    var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }

    var transcriptionLocale: String {
        didSet { UserDefaults.standard.set(transcriptionLocale, forKey: "transcriptionLocale") }
    }

    var transcriptionModel: TranscriptionModel {
        didSet { UserDefaults.standard.set(transcriptionModel.rawValue, forKey: "transcriptionModel") }
    }

    /// Stored as the AudioDeviceID integer. 0 means "use system default".
    var inputDeviceID: AudioDeviceID {
        didSet { UserDefaults.standard.set(Int(inputDeviceID), forKey: "inputDeviceID") }
    }

    var openRouterApiKey: String {
        didSet { KeychainHelper.save(key: "openRouterApiKey", value: openRouterApiKey) }
    }

    var voyageApiKey: String {
        didSet { KeychainHelper.save(key: "voyageApiKey", value: voyageApiKey) }
    }

    var llmProvider: LLMProvider {
        didSet { UserDefaults.standard.set(llmProvider.rawValue, forKey: "llmProvider") }
    }

    var embeddingProvider: EmbeddingProvider {
        didSet { UserDefaults.standard.set(embeddingProvider.rawValue, forKey: "embeddingProvider") }
    }

    var ollamaBaseURL: String {
        didSet { UserDefaults.standard.set(ollamaBaseURL, forKey: "ollamaBaseURL") }
    }

    var ollamaLLMModel: String {
        didSet { UserDefaults.standard.set(ollamaLLMModel, forKey: "ollamaLLMModel") }
    }

    var ollamaEmbedModel: String {
        didSet { UserDefaults.standard.set(ollamaEmbedModel, forKey: "ollamaEmbedModel") }
    }

    var openAIEmbedBaseURL: String {
        didSet { UserDefaults.standard.set(openAIEmbedBaseURL, forKey: "openAIEmbedBaseURL") }
    }

    var openAIEmbedApiKey: String {
        didSet { KeychainHelper.save(key: "openAIEmbedApiKey", value: openAIEmbedApiKey) }
    }

    var openAIEmbedModel: String {
        didSet { UserDefaults.standard.set(openAIEmbedModel, forKey: "openAIEmbedModel") }
    }

    /// Whether the user has acknowledged their obligation to comply with recording consent laws.
    var hasAcknowledgedRecordingConsent: Bool {
        didSet { UserDefaults.standard.set(hasAcknowledgedRecordingConsent, forKey: "hasAcknowledgedRecordingConsent") }
    }

    /// When true, all app windows are invisible to screen sharing / recording.
    var hideFromScreenShare: Bool {
        didSet {
            UserDefaults.standard.set(hideFromScreenShare, forKey: "hideFromScreenShare")
            applyScreenShareVisibility()
        }
    }

    var dictationEnabled: Bool {
        didSet { UserDefaults.standard.set(dictationEnabled, forKey: "dictationEnabled") }
    }

    var hotkeyKey: HotkeyKey {
        didSet { UserDefaults.standard.set(hotkeyKey.rawValue, forKey: "hotkeyKey") }
    }

    /// Which cleanup preset is active: clean, concise, or custom.
    var cleanupPreset: CleanupPreset {
        didSet { UserDefaults.standard.set(cleanupPreset.rawValue, forKey: "cleanupPreset") }
    }

    /// User's custom cleanup prompt (used when cleanupPreset == .custom).
    var customCleanupPrompt: String {
        didSet { UserDefaults.standard.set(customCleanupPrompt, forKey: "customCleanupPrompt") }
    }

    /// The resolved cleanup prompt based on the active preset.
    var activeCleanupPrompt: String {
        CleanupMode.prompt(for: cleanupPreset, customPrompt: customCleanupPrompt)
    }

    /// When true, dictation output is automatically cleaned up via LLM before pasting.
    var cleanupByDefault: Bool {
        didSet {
            UserDefaults.standard.set(cleanupByDefault, forKey: "dictationCleanupEnabled")
        }
    }

    /// When true, dictation output is cleaned up AND translated to English before pasting.
    var translationByDefault: Bool {
        didSet {
            UserDefaults.standard.set(translationByDefault, forKey: "dictationTranslationEnabled")
        }
    }

    var openaiApiKey: String {
        didSet { KeychainHelper.save(key: "openaiApiKey", value: openaiApiKey) }
    }


    init() {
        let defaults = UserDefaults.standard

        // One-time migrations from previous bundle IDs
        Self.migrateFromOldBundleIfNeeded(defaults: defaults)
        Self.migrateFromOpenGranolaIfNeeded(defaults: defaults)
        Self.migrateFromOpenOatsIfNeeded(defaults: defaults)

        self.kbFolderPath = defaults.string(forKey: "kbFolderPath") ?? ""

        let defaultNotesPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Lore").path
        self.notesFolderPath = defaults.string(forKey: "notesFolderPath") ?? defaultNotesPath
        self.selectedModel = defaults.string(forKey: "selectedModel") ?? "google/gemini-3-flash-preview"
        self.transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "en-US"
        self.transcriptionModel = TranscriptionModel(
            rawValue: defaults.string(forKey: "transcriptionModel") ?? ""
        ) ?? .parakeetV3
        self.inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        self.openRouterApiKey = KeychainHelper.load(key: "openRouterApiKey") ?? ""
        self.voyageApiKey = KeychainHelper.load(key: "voyageApiKey") ?? ""
        self.llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .openRouter
        self.embeddingProvider = EmbeddingProvider(rawValue: defaults.string(forKey: "embeddingProvider") ?? "") ?? .voyageAI
        self.ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        self.ollamaLLMModel = defaults.string(forKey: "ollamaLLMModel") ?? "qwen3:8b"
        self.ollamaEmbedModel = defaults.string(forKey: "ollamaEmbedModel") ?? "nomic-embed-text"
        self.openAIEmbedBaseURL = defaults.string(forKey: "openAIEmbedBaseURL") ?? "http://localhost:8080"
        self.openAIEmbedApiKey = KeychainHelper.load(key: "openAIEmbedApiKey") ?? ""
        self.openAIEmbedModel = defaults.string(forKey: "openAIEmbedModel") ?? "text-embedding-3-small"
        self.hasAcknowledgedRecordingConsent = defaults.bool(forKey: "hasAcknowledgedRecordingConsent")

        // Default to true (hidden) if key has never been set
        if defaults.object(forKey: "hideFromScreenShare") == nil {
            self.hideFromScreenShare = true
        } else {
            self.hideFromScreenShare = defaults.bool(forKey: "hideFromScreenShare")
        }

        if defaults.object(forKey: "dictationEnabled") == nil {
            self.dictationEnabled = true
        } else {
            self.dictationEnabled = defaults.bool(forKey: "dictationEnabled")
        }

        self.hotkeyKey = HotkeyKey(
            rawValue: defaults.string(forKey: "hotkeyKey") ?? ""
        ) ?? .fn

        // Cleanup preset — migrate from legacy dictationCleanupPrompt if needed
        let oldLegacyPrompt = "You are a dictation cleanup assistant. Fix grammar, punctuation, and formatting of the transcribed speech. Keep the original meaning and tone. Output only the cleaned text, nothing else."
        if let savedPreset = defaults.string(forKey: "cleanupPreset"),
           let preset = CleanupPreset(rawValue: savedPreset) {
            self.cleanupPreset = preset
        } else if let legacyPrompt = defaults.string(forKey: "dictationCleanupPrompt"),
                  legacyPrompt != oldLegacyPrompt {
            // User had a custom prompt — preserve it
            self.cleanupPreset = .custom
            defaults.set(CleanupPreset.custom.rawValue, forKey: "cleanupPreset")
        } else {
            self.cleanupPreset = .clean
        }
        self.customCleanupPrompt = defaults.string(forKey: "customCleanupPrompt")
            ?? defaults.string(forKey: "dictationCleanupPrompt")
            ?? CleanupMode.cleanPrompt

        self.cleanupByDefault = defaults.bool(forKey: "dictationCleanupEnabled")
        self.translationByDefault = defaults.bool(forKey: "dictationTranslationEnabled")

        self.openaiApiKey = KeychainHelper.load(key: "openaiApiKey") ?? ""

        // Ensure notes folder exists
        try? FileManager.default.createDirectory(
            atPath: notesFolderPath,
            withIntermediateDirectories: true
        )

    }

    /// Migrate settings from the old "On The Spot" (com.onthespot.app) bundle.
    /// Copies UserDefaults and Keychain entries to the current bundle, then marks migration as done.
    private static func migrateFromOldBundleIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateFromOnTheSpot"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        // Migrate UserDefaults from old bundle
        guard let oldDefaults = UserDefaults(suiteName: "com.onthespot.app") else { return }

        let keysToMigrate = [
            "kbFolderPath", "selectedModel", "transcriptionLocale", "transcriptionModel", "inputDeviceID",
            "llmProvider", "embeddingProvider", "ollamaBaseURL", "ollamaLLMModel",
            "ollamaEmbedModel", "hideFromScreenShare",
            "isTranscriptExpanded", "hasCompletedOnboarding"
        ]
        for key in keysToMigrate {
            if let value = oldDefaults.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        // Migrate Keychain entries from old service
        let oldService = "com.onthespot.app"
        let keychainKeys = ["openRouterApiKey", "voyageApiKey"]
        for key in keychainKeys {
            if KeychainHelper.load(key: key) == nil,
               let oldValue = Self.loadKeychain(service: oldService, key: key) {
                KeychainHelper.save(key: key, value: oldValue)
            }
        }
    }

    /// Migrate settings from the previous "OpenGranola" (com.opengranola.app) bundle.
    private static func migrateFromOpenGranolaIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateFromOpenGranola"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        // --- Migrate UserDefaults ---
        guard let oldDefaults = UserDefaults(suiteName: "com.opengranola.app") else {
            // Even without old defaults, migrate file-backed state
            migrateFilesFromOpenGranola(defaults: defaults)
            return
        }

        let keysToMigrate = [
            "kbFolderPath", "selectedModel", "transcriptionLocale", "transcriptionModel", "inputDeviceID",
            "llmProvider", "embeddingProvider", "ollamaBaseURL", "ollamaLLMModel",
            "ollamaEmbedModel", "hideFromScreenShare",
            "isTranscriptExpanded", "hasCompletedOnboarding",
            "hasAcknowledgedRecordingConsent"
        ]
        for key in keysToMigrate {
            if let value = oldDefaults.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        // --- Migrate Keychain ---
        let oldService = "com.opengranola.app"
        let keychainKeys = ["openRouterApiKey", "voyageApiKey"]
        for key in keychainKeys {
            if KeychainHelper.load(key: key) == nil,
               let oldValue = Self.loadKeychain(service: oldService, key: key) {
                KeychainHelper.save(key: key, value: oldValue)
            }
        }

        // --- Migrate file-backed state ---
        migrateFilesFromOpenGranola(defaults: defaults)
    }

    /// Migrate file-backed state (sessions, templates, KB cache, transcripts)
    /// from ~/Library/Application Support/OpenGranola/ to Lore/ and
    /// handle the implicit KB folder default.
    private static func migrateFilesFromOpenGranola(defaults: UserDefaults) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        let oldAppSupportDir = appSupport.appendingPathComponent("OpenGranola")
        let newAppSupportDir = appSupport.appendingPathComponent("Lore")

        // Migrate Application Support: sessions/, templates.json, kb_cache.json
        if fm.fileExists(atPath: oldAppSupportDir.path) {
            try? fm.createDirectory(at: newAppSupportDir, withIntermediateDirectories: true)

            // Sessions directory (JSONL files + sidecars)
            let oldSessions = oldAppSupportDir.appendingPathComponent("sessions")
            let newSessions = newAppSupportDir.appendingPathComponent("sessions")
            if fm.fileExists(atPath: oldSessions.path) && !fm.fileExists(atPath: newSessions.path) {
                try? fm.moveItem(at: oldSessions, to: newSessions)
            }

            // Templates
            let oldTemplates = oldAppSupportDir.appendingPathComponent("templates.json")
            let newTemplates = newAppSupportDir.appendingPathComponent("templates.json")
            if fm.fileExists(atPath: oldTemplates.path) && !fm.fileExists(atPath: newTemplates.path) {
                try? fm.moveItem(at: oldTemplates, to: newTemplates)
            }

            // KB embedding cache
            let oldCache = oldAppSupportDir.appendingPathComponent("kb_cache.json")
            let newCache = newAppSupportDir.appendingPathComponent("kb_cache.json")
            if fm.fileExists(atPath: oldCache.path) && !fm.fileExists(atPath: newCache.path) {
                try? fm.moveItem(at: oldCache, to: newCache)
            }
        }

        // KB folder: leave unset by default. Only preserve an explicitly-set path
        // that pointed at the old OpenGranola directory (user chose it themselves).
        let oldDocDir = home.appendingPathComponent("Documents/OpenGranola")
        let newDocDir = home.appendingPathComponent("Documents/Lore")

        // Migrate notes folder: if the old default directory has content,
        // use it as the notes folder so transcript archives stay accessible.
        if defaults.string(forKey: "notesFolderPath") == nil {
            if fm.fileExists(atPath: oldDocDir.path) {
                let contents = (try? fm.contentsOfDirectory(atPath: oldDocDir.path)) ?? []
                if !contents.isEmpty {
                    defaults.set(oldDocDir.path, forKey: "notesFolderPath")
                }
            }
        }

        // Migrate transcript archives: move files from ~/Documents/OpenGranola/
        // into ~/Documents/Lore/ so new sessions and old archives coexist.
        // Skip if the old dir is the active KB folder or notes folder (files stay in place).
        let activeKB = defaults.string(forKey: "kbFolderPath") ?? ""
        let activeNotes = defaults.string(forKey: "notesFolderPath") ?? ""
        if fm.fileExists(atPath: oldDocDir.path) && oldDocDir.path != activeKB && oldDocDir.path != activeNotes {
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

    /// Migrate data from the previous "OpenOats" app.
    /// Note: OpenOats inherited the com.opengranola.app bundle ID and never changed it,
    /// so keychain entries were already migrated by migrateFromOpenGranolaIfNeeded().
    /// This migration only moves file-backed state (Application Support, Documents).
    private static func migrateFromOpenOatsIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateFromOpenOats"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        // --- Migrate file-backed state ---
        migrateFilesFromOpenOats(defaults: defaults)
    }

    /// Migrate file-backed state (sessions, templates, KB cache, transcripts, dictation audio)
    /// from ~/Library/Application Support/OpenOats/ to Lore/ and
    /// from ~/Documents/OpenOats/ to ~/Documents/Lore/.
    private static func migrateFilesFromOpenOats(defaults: UserDefaults) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        let oldAppSupportDir = appSupport.appendingPathComponent("OpenOats")
        let newAppSupportDir = appSupport.appendingPathComponent("Lore")

        // Migrate Application Support: sessions/, templates.json, kb_cache.json, DictationAudio/
        if fm.fileExists(atPath: oldAppSupportDir.path) {
            try? fm.createDirectory(at: newAppSupportDir, withIntermediateDirectories: true)

            let subdirs = ["sessions", "DictationAudio"]
            for sub in subdirs {
                let oldDir = oldAppSupportDir.appendingPathComponent(sub)
                let newDir = newAppSupportDir.appendingPathComponent(sub)
                if fm.fileExists(atPath: oldDir.path) && !fm.fileExists(atPath: newDir.path) {
                    try? fm.moveItem(at: oldDir, to: newDir)
                }
            }

            let files = ["templates.json", "kb_cache.json"]
            for file in files {
                let oldFile = oldAppSupportDir.appendingPathComponent(file)
                let newFile = newAppSupportDir.appendingPathComponent(file)
                if fm.fileExists(atPath: oldFile.path) && !fm.fileExists(atPath: newFile.path) {
                    try? fm.moveItem(at: oldFile, to: newFile)
                }
            }
        }

        // Migrate Documents: ~/Documents/OpenOats/ -> ~/Documents/Lore/
        let oldDocDir = home.appendingPathComponent("Documents/OpenOats")
        let newDocDir = home.appendingPathComponent("Documents/Lore")

        // Update notesFolderPath if it pointed at the old location
        if let notes = defaults.string(forKey: "notesFolderPath"), notes == oldDocDir.path {
            defaults.set(newDocDir.path, forKey: "notesFolderPath")
        }

        // Move transcript archives
        let activeKB = defaults.string(forKey: "kbFolderPath") ?? ""
        let activeNotes = defaults.string(forKey: "notesFolderPath") ?? ""
        if fm.fileExists(atPath: oldDocDir.path) && oldDocDir.path != activeKB && oldDocDir.path != activeNotes {
            try? fm.createDirectory(at: newDocDir, withIntermediateDirectories: true)
            if let items = try? fm.contentsOfDirectory(at: oldDocDir, includingPropertiesForKeys: nil) {
                for item in items where item.pathExtension == "txt" {
                    let dest = newDocDir.appendingPathComponent(item.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: item, to: dest)
                    }
                }
            }
        }
    }

    /// Read a keychain entry from a specific service (used for migration only).
    private static func loadKeychain(service: String, key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Apply current screen-share visibility to all app windows.
    /// Skips windows already set to `.readOnly` (e.g. DictationIndicator panel)
    /// so we don't override their explicit sharing configuration.
    func applyScreenShareVisibility() {
        let type: NSWindow.SharingType = hideFromScreenShare ? .none : .readOnly
        for window in NSApp.windows {
            guard window.sharingType != .readOnly else { continue }
            window.sharingType = type
        }
    }

    var kbFolderURL: URL? {
        guard !kbFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: kbFolderPath)
    }

    var locale: Locale {
        Locale(identifier: transcriptionLocale)
    }

    var transcriptionModelDisplay: String {
        transcriptionModel.displayName
    }

    /// The model name to display in the UI, respecting the active LLM provider.
    var activeModelDisplay: String {
        let raw: String
        switch llmProvider {
        case .openRouter: raw = selectedModel
        case .ollama: raw = ollamaLLMModel
        }
        return raw.split(separator: "/").last.map(String.init) ?? raw
    }

}

// MARK: - Keychain Helper

enum KeychainHelper {
    private static let service = "com.lore.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
