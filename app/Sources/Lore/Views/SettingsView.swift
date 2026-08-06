import AVFoundation
import SwiftUI
import CoreAudio
import LaunchAtLogin
import Sparkle

/// Lore Settings destination (Stage D): one scrollable screen of grouped cards
/// that consolidates every setting previously split across the macOS Settings
/// scene and the Dictation window's settings tab (SET-06). Sections:
/// GENERAL / TALK / MODIFIERS / MEETINGS / NOTES / ADVANCED.
///
/// D-031: every control preserves its exact current semantics and persistence
/// key — this is a UI relocation plus restyle, not a behavior change. New
/// settings (REC pill, sound on start, modifier toggles) are additive.
struct SettingsView: View {
    private enum TemplateField: Hashable {
        case name
    }

    @Bindable var settings: AppSettings
    var updater: SPUUpdater
    /// False while the unified shell shows another destination. The view is
    /// kept alive, so state refresh happens on each activation, not once.
    var isActiveInShell = true
    @Environment(AppCoordinator.self) private var coordinator

    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []
    @State private var automaticallyChecksForUpdates = false
    @StateObject private var updatesViewModel: CheckForUpdatesViewModel
    @State private var templates: [MeetingTemplate] = []
    @State private var isAddingTemplate = false
    @State private var newTemplateName = ""
    @State private var newTemplateIcon = "doc.text"
    @State private var newTemplatePrompt = ""
    @FocusState private var focusedTemplateField: TemplateField?
    @State private var showAutoDetectExplanation = false
    @State private var showProblemReport = false
    @State private var showMicPicker = false
    @State private var isTemplatesExpanded = false
    @State private var isCustomMeetingAppsExpanded = false
    /// OpenAI key liveness (#50): last probe verdict, nil before the first
    /// probe completes. `keyProbeTask` is the in-flight (possibly debounced)
    /// probe — replaced wholesale so stale results never land.
    @State private var keyHealth: KeyHealthStatus?
    @State private var keyProbeTask: Task<Void, Never>?
    /// Present state of the dictation-audio folder (#52/#89): how many audio
    /// recordings are on disk right now and the bytes they occupy, from one
    /// enumeration pass. Nil until the first off-main measurement lands.
    /// Refreshed on each Settings activation and after an immediate prune.
    /// `diskUsageTask` is the in-flight measurement — replaced wholesale (same
    /// pattern as `keyProbeTask`) so a stale pre-prune result never lands after
    /// a fresher post-prune one.
    @State private var audioUsage: (count: Int, bytes: Int64)?
    @State private var diskUsageTask: Task<Void, Never>?
    /// Read Aloud voice pickers (#105): the Speechify sides of the grouped
    /// menus, from the cached `/v1/voices` catalog; empty without a key.
    @State private var ruSpeechifyVoices: [SpeechifyVoice] = []
    @State private var enSpeechifyVoices: [SpeechifyVoice] = []
    @State private var singleSpeechifyVoices: [SpeechifyVoice] = []
    /// Holders for the ▶ voice previews (must outlive the tap).
    @State private var voicePreviewPlayer: AVPlayer?
    @State private var previewSynthesizer = AVSpeechSynthesizer()
    /// Which voice row's picker popover is open, keyed by the row name.
    @State private var openVoicePicker: String?

    init(settings: AppSettings, updater: SPUUpdater, isActiveInShell: Bool = true) {
        self.settings = settings
        self.updater = updater
        self.isActiveInShell = isActiveInShell
        self._updatesViewModel = StateObject(
            wrappedValue: CheckForUpdatesViewModel(updater: updater)
        )
        // Seed the toggle from the real Sparkle setting (#91) so it reflects
        // reality (default ON via Info.plist SUEnableAutomaticChecks) from first
        // render, not a hardcoded false. refreshViewState re-reads it on every
        // activation; the .onChange push writes user edits back to the updater.
        self._automaticallyChecksForUpdates = State(
            initialValue: updater.automaticallyChecksForUpdates
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                generalSection
                talkSection
                readAloudSection
                modifiersSection
                meetingsSection
                notesSection
                advancedSection
            }
            .padding(EdgeInsets(top: 18, leading: 26, bottom: 26, trailing: 26))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("settings.form")
        .sheet(isPresented: $showAutoDetectExplanation) {
            autoDetectExplanationSheet
        }
        .sheet(isPresented: $showProblemReport) {
            if let monitor = coordinator.healthMonitor {
                ProblemReportView(healthMonitor: monitor, onClose: { showProblemReport = false })
            }
        }
        .onChange(of: isActiveInShell, initial: true) { _, isActive in
            // Re-read devices, update-check toggle, and templates each time
            // the destination is shown (the view stays mounted in the shell).
            if isActive {
                refreshViewState()
            }
        }
        .onChange(of: automaticallyChecksForUpdates) { _, newValue in
            updater.automaticallyChecksForUpdates = newValue
        }
        .onChange(of: settings.openaiApiKey) { _, _ in
            // Debounced so a keystroke-by-keystroke paste probes once; the
            // previous verdict is cleared because it described another key.
            keyHealth = nil
            scheduleKeyProbe(debounce: true)
        }
        .onChange(of: settings.speechifyApiKey) { _, _ in
            // Progressive disclosure (#105): key present → load the Speechify
            // voice groups; key removed → they empty, system voices remain.
            refreshSpeechifyVoices()
        }
    }

    // MARK: - GENERAL (SET-10/11)

    private var generalSection: some View {
        SettingsSection(label: "General") {
            SettingsRow(
                name: "Launch at login",
                sub: "Start \(LoreTheme.wordmark) when your Mac starts"
            ) {
                // Existing SMAppService wrapper — semantics and default unchanged.
                LaunchAtLogin.Toggle("Launch at login")
                    .toggleStyle(LoreToggleStyle())
                    .labelsHidden()
            }
            LoreDivider()
            toggleRow(
                "Recording status in toolbar",
                sub: "Show the red REC timer while recording",
                isOn: $settings.recPillEnabled
            )
        }
    }

    // MARK: - TALK (DSET-01/09…21)

    private var talkSection: some View {
        SettingsSection(label: "Talk") {
            SettingsRow(name: "Hotkey", sub: "Hold to talk, anywhere") {
                // Cycles the current option set only (Fn / Right Option, DSET-03).
                LoreMonoValueButton(title: settings.hotkeyKey.displayName) {
                    settings.hotkeyKey = nextCase(after: settings.hotkeyKey)
                }
            }
            LoreDivider()
            toggleRow(
                "Sound on start",
                sub: "Chime when the mic goes live",
                isOn: $settings.soundOnDictationStart
            )
            LoreDivider()
            keepAudioRow
            LoreDivider()
            // Cleanup/translation mutual coupling preserved (DSET-13):
            // cleanup off forces translation off; translation on forces cleanup on.
            toggleRow(
                "Cleanup by default",
                sub: "Run the cleanup pass on every dictation",
                isOn: Binding(
                    get: { settings.cleanupByDefault },
                    set: { newValue in
                        settings.cleanupByDefault = newValue
                        if !newValue {
                            settings.translationByDefault = false
                        }
                    }
                )
            )
            LoreDivider()
            toggleRow(
                "Translation by default",
                sub: settings.translationByDefault
                    ? "Translation includes cleanup automatically"
                    : "Translate to English on every dictation",
                isOn: Binding(
                    get: { settings.translationByDefault },
                    set: { newValue in
                        settings.translationByDefault = newValue
                        if newValue {
                            settings.cleanupByDefault = true
                        }
                    }
                )
            )
            LoreDivider()
            cleanupPromptRows
            LoreDivider()
            // API key lives next to its consumer (cleanup/translate) per SET-47/Q7.
            SettingsRow(
                name: "OpenAI API key",
                sub: openAIKeySub,
                subColor: openAIKeySubIsRed ? LoreTheme.Accent.red : LoreTheme.TextColor.muted
            ) {
                chipField("sk-...", text: $settings.openaiApiKey, isSecure: true)
            }
        }
    }

    /// DSET-21: cleanup/translate need a key; warn while either default is on
    /// and the Keychain entry is empty.
    private var openAIKeyWarningActive: Bool {
        (settings.cleanupByDefault || settings.translationByDefault)
            && settings.openaiApiKey.isEmpty
    }

    /// Key row sub-line (#50): the empty-key warning keeps priority, then the
    /// liveness verdict — checking… / rejected (red) / OK (muted). An
    /// inconclusive probe (offline) falls back to the neutral description.
    private var openAIKeySub: String {
        if openAIKeyWarningActive { return "OpenAI API key required" }
        guard !settings.openaiApiKey.isEmpty else {
            return "Powers cleanup, translation, refinement, Ask Lore"
        }
        switch keyHealth {
        case .invalid: return "Key rejected by OpenAI (401)"
        case .ok: return "Key OK \u{2014} powers cleanup, translation, refinement, Ask Lore"
        case .unknown: return "Powers cleanup, translation, refinement, Ask Lore"
        case nil:
            return keyProbeTask == nil
                ? "Powers cleanup, translation, refinement, Ask Lore" : "Checking key\u{2026}"
        }
    }

    private var openAIKeySubIsRed: Bool {
        openAIKeyWarningActive
            || (!settings.openaiApiKey.isEmpty && keyHealth == .invalid)
    }

    /// Probe the key against `GET /v1/models` (#50). Never blocks the UI;
    /// replacing the task cancels any stale probe. No-op on an empty key —
    /// that case is owned by the existing empty-key warning.
    private func scheduleKeyProbe(debounce: Bool) {
        keyProbeTask?.cancel()
        let key = settings.openaiApiKey
        guard !key.isEmpty else {
            keyProbeTask = nil
            keyHealth = nil
            return
        }
        keyProbeTask = Task {
            if debounce {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            let status = await KeyHealthCheck.probe(apiKey: key)
            guard !Task.isCancelled else { return }
            // An inconclusive probe (offline, timeout) must not erase a prior
            // definitive verdict for the same key — it only fills an empty
            // state. Definitive results always replace.
            if status != .unknown || keyHealth == nil {
                keyHealth = status
            }
            keyProbeTask = nil
        }
    }

    /// Cleanup preset picker + prompt editor/preview (DSET-14). Always visible:
    /// the active prompt also powers the C/T upgrade keys and per-row wand
    /// actions even when cleanup-by-default is off.
    @ViewBuilder
    private var cleanupPromptRows: some View {
        SettingsRow(
            name: "Cleanup prompt",
            sub: "Used by defaults, chords, and upgrade keys"
        ) {
            LoreMonoValueButton(title: settings.cleanupPreset.displayName) {
                settings.cleanupPreset = nextCase(after: settings.cleanupPreset)
            }
        }
        Group {
            if settings.cleanupPreset == .custom {
                TextEditor(text: $settings.customCleanupPrompt)
                    .font(LoreTheme.Typography.mono(11))
                    .scrollContentBackground(.hidden)
                    .frame(height: 80)
                    .padding(6)
                    .background(LoreTheme.Surface.card3)
                    .clipShape(RoundedRectangle(cornerRadius: LoreTheme.Radius.chip))
            } else {
                // Full prompt, un-clipped and selectable, with a copy chip in
                // the card footer (#146) — read, copy, switch to Custom, paste.
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.activeCleanupPrompt)
                        .font(LoreTheme.Typography.mono(11))
                        .foregroundStyle(LoreTheme.TextColor.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Spacer()
                        CleanupPromptCopyChip(text: settings.activeCleanupPrompt)
                    }
                }
                .padding(6)
                .background(LoreTheme.Surface.card2)
                .clipShape(RoundedRectangle(cornerRadius: LoreTheme.Radius.chip))
            }
        }
        .padding(EdgeInsets(top: 0, leading: 16, bottom: 13, trailing: 16))
    }

    // MARK: - READ ALOUD (#105)

    /// Paid tier is disclosed by key presence: Speechify voice groups and the
    /// voices-mode row appear only with a key. System voices are the free
    /// default — Read Aloud works with no key at all.
    private var hasSpeechifyKey: Bool { !settings.speechifyApiKey.isEmpty }

    private var readAloudSection: some View {
        SettingsSection(label: "Read aloud") {
            SettingsRow(
                name: "Speechify API key",
                sub: hasSpeechifyKey
                    ? "Paid voices enabled" : "Optional \u{2014} system voices are free"
            ) {
                chipField("API key", text: $settings.speechifyApiKey, isSecure: true)
            }
            Link("Get API key", destination: URL(string: "https://console.sws.speechify.com")!)
                .font(.system(size: 11))
                .foregroundStyle(LoreTheme.Accent.blue)
                .padding(EdgeInsets(top: 0, leading: 16, bottom: 13, trailing: 16))
            LoreDivider()
            if hasSpeechifyKey {
                SettingsRow(
                    name: "Voices",
                    sub: "One voice per detected language, or one for everything"
                ) {
                    LoreMonoValueButton(title: settings.readAloudVoiceMode.displayName) {
                        settings.readAloudVoiceMode = nextCase(after: settings.readAloudVoiceMode)
                    }
                }
                LoreDivider()
            }
            if hasSpeechifyKey && settings.readAloudVoiceMode == .singleVoice {
                voiceRow(
                    "Voice", sub: "Multilingual \u{2014} reads every language",
                    selection: $settings.readAloudVoiceSingle,
                    speechify: singleSpeechifyVoices,
                    systemPrefix: nil,
                    includeAuto: false
                )
            } else {
                voiceRow(
                    "Russian voice", sub: "For texts detected as Russian",
                    selection: $settings.readAloudVoiceRu,
                    speechify: ruSpeechifyVoices,
                    systemPrefix: "ru",
                    includeAuto: true
                )
                LoreDivider()
                voiceRow(
                    "English voice", sub: "For texts detected as English",
                    selection: $settings.readAloudVoiceEn,
                    speechify: enSpeechifyVoices,
                    systemPrefix: "en",
                    includeAuto: true
                )
                LoreDivider()
                voiceRow(
                    "Other languages", sub: "System voice matches the detected language",
                    selection: $settings.readAloudVoiceOther,
                    speechify: singleSpeechifyVoices,
                    systemPrefix: nil,
                    includeAuto: true
                )
            }
            LoreDivider()
            SettingsRow(name: "Playback speed", sub: "Starting rate for each reading") {
                LoreMonoValueButton(title: ReadAloudController.speedLabel(settings.readAloudSpeed)) {
                    settings.readAloudSpeed = ReadAloudController.nextSpeed(after: settings.readAloudSpeed)
                }
            }
            LoreDivider()
            SettingsRow(
                name: "Max text length",
                sub: "Longer selections are refused, never billed"
            ) {
                // Empty/invalid/≤0 input reverts to the default; the store's
                // setter additionally floors the value at 100.
                numberField(
                    value: Binding(
                        get: { settings.readAloudCharLimit },
                        set: {
                            settings.readAloudCharLimit =
                                $0 > 0 ? $0 : ReadAloudController.defaultCharLimit
                        }
                    ),
                    unit: "chars", width: 72
                )
            }
            LoreDivider()
            toggleRow(
                "Resume reading after dictation",
                sub: "Continue playback when a dictation recording ends",
                isOn: $settings.readAloudResumeAfterDictation
            )
            LoreDivider()
            shortcutRow(key: "fn R", name: "Read selection aloud", sub: "Replaces the current reading")
            LoreDivider()
            shortcutRow(key: "fn Q", name: "Add selection to queue", sub: "Reads after the current text")
        }
    }

    /// Static shortcut chip row — same `.keybtn` idiom as the Modifiers rows.
    private func shortcutRow(key: String, name: String, sub: String) -> some View {
        SettingsRow(name: name, sub: sub) {
            LoreMonoValueButton(title: key, width: 64)
        } trailing: {
            EmptyView()
        }
    }

    /// Voice picker row: popover list behind the mono value chip — grouped
    /// Speechify voices above free System voices, every row with its own ▶
    /// preview. `systemPrefix` filters installed system voices ("ru"/"en");
    /// nil offers no per-locale system group (the auto entry covers it).
    private func voiceRow(
        _ name: String, sub: String?,
        selection: Binding<ReadAloudVoiceChoice>,
        speechify: [SpeechifyVoice],
        systemPrefix: String?,
        includeAuto: Bool
    ) -> some View {
        SettingsRow(name: name, sub: sub) {
            LoreMonoValueButton(title: selection.wrappedValue.name) {
                openVoicePicker = openVoicePicker == name ? nil : name
            }
            .popover(
                isPresented: Binding(
                    get: { openVoicePicker == name },
                    set: { if !$0 { openVoicePicker = nil } }
                ),
                arrowEdge: .bottom
            ) {
                voicePickerList(
                    selection: selection, speechify: speechify,
                    systemPrefix: systemPrefix, includeAuto: includeAuto
                )
            }
        }
    }

    /// The popover behind a voice row. Rows select on tap; each carries its
    /// own ▶ preview (Speechify: free CDN clip; system: local sample) so
    /// voices can be auditioned before choosing.
    private func voicePickerList(
        selection: Binding<ReadAloudVoiceChoice>,
        speechify: [SpeechifyVoice],
        systemPrefix: String?,
        includeAuto: Bool
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if includeAuto {
                    voicePickerRow(
                        choice: .systemAuto, detail: "macOS picks per detected language",
                        previewURL: nil, samplePrefix: systemPrefix, selection: selection
                    )
                }
                if !speechify.isEmpty {
                    voicePickerHeader("Speechify")
                    ForEach(speechify) { voice in
                        voicePickerRow(
                            choice: ReadAloudVoiceChoice(
                                engine: .speechify, id: voice.id, name: voice.name
                            ),
                            detail: voice.tagLabel,
                            previewURL: voice.previewURL,
                            samplePrefix: systemPrefix,
                            selection: selection
                        )
                    }
                }
                if let systemPrefix {
                    let systemChoices = ReadAloudVoices.systemVoices(languagePrefix: systemPrefix)
                    if !systemChoices.isEmpty {
                        voicePickerHeader("System (free)")
                        ForEach(systemChoices, id: \.id) { choice in
                            voicePickerRow(
                                choice: choice, detail: nil, previewURL: nil,
                                samplePrefix: systemPrefix, selection: selection
                            )
                        }
                    }
                }
            }
        }
        .frame(width: 300)
        .frame(maxHeight: 380)
        .lorePopoverChrome()
    }

    private func voicePickerHeader(_ text: String) -> some View {
        LoreSectionLabel(text: text, size: 9, mono: true)
            .padding(EdgeInsets(top: 8, leading: 9, bottom: 4, trailing: 9))
    }

    private func voicePickerRow(
        choice: ReadAloudVoiceChoice,
        detail: String?,
        previewURL: URL?,
        samplePrefix: String?,
        selection: Binding<ReadAloudVoiceChoice>
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                selection.wrappedValue = choice
                openVoicePicker = nil
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(choice.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(LoreTheme.TextColor.primary)
                            .lineLimit(1)
                        if let detail {
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundStyle(LoreTheme.TextColor.faint)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if selection.wrappedValue == choice {
                        Text("\u{2713}")
                            .font(.system(size: 12))
                            .foregroundStyle(LoreTheme.Accent.amber)
                    }
                }
                .padding(EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            LoreIconButton(systemName: "play.fill", label: "Preview \(choice.name)") {
                previewVoice(choice, previewURL: previewURL, samplePrefix: samplePrefix)
            }
            .padding(.trailing, 6)
        }
        .loreHoverFill(cornerRadius: LoreTheme.Radius.chip)
    }

    /// ▶ preview on a picker row: Speechify voices play their CDN preview
    /// clip; system voices speak a short local sample in the row's language.
    private func previewVoice(
        _ choice: ReadAloudVoiceChoice, previewURL: URL?, samplePrefix: String?
    ) {
        switch choice.engine {
        case .speechify:
            guard let previewURL else { return }
            previewSynthesizer.stopSpeaking(at: .immediate)
            let player = AVPlayer(url: previewURL)
            voicePreviewPlayer = player
            player.play()
        case .system:
            let sample = samplePrefix == "ru"
                ? "Привет! Так звучит этот голос."
                : "Hi! This is how this voice sounds."
            let utterance = AVSpeechUtterance(string: sample)
            utterance.voice = SystemSpeechSynthesizer.resolveVoice(
                id: choice.id, languageCode: samplePrefix ?? "en"
            )
            voicePreviewPlayer?.pause()
            previewSynthesizer.stopSpeaking(at: .immediate)
            previewSynthesizer.speak(utterance)
        }
    }

    /// Refresh the Speechify sides of the voice pickers from the cached
    /// catalog. No key → empty groups (system voices remain).
    private func refreshSpeechifyVoices() {
        let key = settings.speechifyApiKey
        guard !key.isEmpty else {
            ruSpeechifyVoices = []
            enSpeechifyVoices = []
            singleSpeechifyVoices = []
            return
        }
        Task {
            let catalog = SpeechifyVoiceCatalog.shared
            ruSpeechifyVoices = await catalog.voices(localePrefixes: ["ru"], apiKey: key)
            enSpeechifyVoices = await catalog.voices(localePrefixes: ["en"], apiKey: key)
            // Single-voice / other-languages list: multilingual-capable
            // voices of the ru + en locales.
            singleSpeechifyVoices = await catalog.voices(
                localePrefixes: ["ru", "en"], model: "simba-multilingual", apiKey: key
            )
        }
    }

    // MARK: - Keep audio (#52)

    /// Cycle order for the retention value button; 0 is the unlimited sentinel.
    private static let audioRetentionOptions = [100, 500, 1000, 0]

    /// Audio retention (#52): value button cycles 100 → 500 → 1000 → ∞.
    /// Lowering the limit prunes immediately; the sub line never suggests
    /// deleted audio can come back.
    private var keepAudioRow: some View {
        SettingsRow(name: "Keep audio", sub: keepAudioSub) {
            LoreMonoValueButton(title: audioRetentionTitle) {
                cycleAudioRetention()
            }
        }
        .accessibilityIdentifier("settings.audioRetention")
    }

    private var audioRetentionTitle: String {
        let count = settings.dictationAudioRetentionCount
        return count == 0 ? "\u{221E}" : "\(count)"
    }

    private var keepAudioSub: String {
        Self.keepAudioSubtitle(cap: settings.dictationAudioRetentionCount, usage: audioUsage)
    }

    /// Present-tense subtitle for the Keep-audio row (#89). Once the folder is
    /// measured, states current reality — how many recordings are on disk right
    /// now and the space they occupy — so nothing reads as a projection of the
    /// cap (the cap is the value button's job). Before the first measurement
    /// lands (`usage` nil), falls back to the retention policy alone, never a
    /// fabricated count. `cap` is the retention limit (0 = unlimited).
    static func keepAudioSubtitle(cap: Int, usage: (count: Int, bytes: Int64)?) -> String {
        guard let usage else {
            return cap == 0
                ? "Keeping every recording for Retry"
                : "Keeping up to \(cap) recordings for Retry"
        }
        let size = ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
        let noun = usage.count == 1 ? "recording" : "recordings"
        return "\(usage.count) \(noun) on disk now \u{00B7} \(size)"
    }

    private func cycleAudioRetention() {
        let options = Self.audioRetentionOptions
        let current = settings.dictationAudioRetentionCount
        let index = options.firstIndex(of: current) ?? 0
        let next = options[(index + 1) % options.count]
        settings.dictationAudioRetentionCount = next
        if Self.shouldPruneImmediately(current: current, next: next) {
            coordinator.dictationCoordinator.history.pruneAudio(keeping: next)
        }
        refreshAudioDiskUsage()
    }

    /// The deletion decision, pure and testable: lowering the limit
    /// (including ∞ → finite) reclaims disk right away; raising it — or
    /// going unlimited — deletes nothing (and never resurrects anything).
    /// 0 is the unlimited sentinel on both sides.
    static func shouldPruneImmediately(current: Int, next: Int) -> Bool {
        next != 0 && (current == 0 || next < current)
    }

    /// Directory enumeration happens on a detached task — never on the main
    /// actor (the folder can hold ~1000 files); only the (count, bytes) result
    /// hops back to update `audioUsage`. Cancel-and-replace: a re-entry
    /// (e.g. prune right after activation) invalidates the older measurement.
    private func refreshAudioDiskUsage() {
        diskUsageTask?.cancel()
        let directory = coordinator.dictationCoordinator.history.audioDirectory
        diskUsageTask = Task { @MainActor in
            let usage = await Task.detached(priority: .utility) {
                Self.measureAudioFolder(at: directory)
            }.value
            guard !Task.isCancelled else { return }
            audioUsage = usage
        }
    }

    /// One directory pass yields both the recording count and the total bytes
    /// (one source of truth for the present-state subtitle, #89). Counts only
    /// the `.raw` audio files `saveAudio` writes, so a stray file (e.g.
    /// `.DS_Store`) never inflates the count or size. Nil when the folder can't
    /// be read.
    nonisolated static func measureAudioFolder(at directory: URL) -> (count: Int, bytes: Int64)? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return nil }
        // The on-disk `.raw` set, deliberately — this is what "N recordings on
        // disk now" claims. It's not strictly the in-memory
        // `entries where audioFilename != nil` set the cap prunes against; the
        // two can diverge on an orphaned file (a crash between saveAudio and
        // the entry add) or one removed outside the app. The subtitle reports
        // physical reality, so the on-disk count is the honest number here.
        let audio = files.filter { $0.pathExtension == "raw" }
        let bytes = audio.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return (count: audio.count, bytes: bytes)
    }

    // MARK: - MODIFIERS (DSET-04…07)

    /// Short hotkey label for the section title ("WHILE HOLDING FN").
    private var hotkeyShortLabel: String {
        switch settings.hotkeyKey {
        case .fn: "Fn"
        case .rightOption: "R\u{2325}"
        }
    }

    private var modifiersSection: some View {
        // Rows reflect the CURRENT hardcoded keymap truthfully (D-031): key
        // chips are static — no remapping this stage. The enable toggles are
        // new and gate HotkeyManager + the dictation footer kbd bar.
        SettingsSection(
            label: "Modifiers \u{2014} while holding \(hotkeyShortLabel)",
            note: "Tap a key while talking to say where the words go. Remapping comes later."
        ) {
            modifierRow(
                key: "Space",
                name: "Lock",
                sub: "Keep the mic open without holding",
                isOn: $settings.modifierLockEnabled
            )
            LoreDivider()
            modifierRow(
                key: "V",
                name: "Cleanup",
                sub: "Remove fillers and false starts before inserting",
                isOn: $settings.modifierCleanupEnabled
            )
            LoreDivider()
            modifierRow(
                key: "T",
                name: "Translate",
                sub: "Translate to English before inserting",
                isOn: $settings.modifierTranslateEnabled
            )
            LoreDivider()
            modifierRow(
                key: "C/T",
                name: "Upgrade keys",
                sub: "Right after pasting: C cleans up, T translates",
                isOn: $settings.modifierUpgradeKeysEnabled
            )
        }
    }

    /// Modifier row: 64px static key chip (the shared `.keybtn` spec, not
    /// remappable yet) + name/sub + enable toggle.
    private func modifierRow(
        key: String, name: String, sub: String, isOn: Binding<Bool>
    ) -> some View {
        SettingsRow(name: name, sub: sub) {
            LoreMonoValueButton(title: key, width: 64)
        } trailing: {
            Toggle(name, isOn: isOn)
                .toggleStyle(LoreToggleStyle())
                .labelsHidden()
        }
    }

    // MARK: - MEETINGS (SET-20/21, SET-37…41, SET-44)

    private var meetingsSection: some View {
        SettingsSection(label: "Meetings") {
            // First-enable privacy gate preserved (SET-20): flip back off and
            // show the explanation sheet until it has been accepted once.
            toggleRow(
                "Auto-detect meetings",
                sub: "Offer to record when a call starts",
                isOn: $settings.meetingAutoDetectEnabled
            )
            .onChange(of: settings.meetingAutoDetectEnabled) {
                if settings.meetingAutoDetectEnabled && !settings.hasShownAutoDetectExplanation {
                    settings.meetingAutoDetectEnabled = false
                    showAutoDetectExplanation = true
                }
            }
            if settings.meetingAutoDetectEnabled {
                LoreDivider()
                SettingsRow(
                    name: "Silence timeout",
                    sub: "Auto-detected sessions stop after this much silence"
                ) {
                    numberField(value: $settings.silenceTimeoutMinutes, unit: "min", width: 56)
                }
                LoreDivider()
                customMeetingAppsRows
            }
            if !settings.ignoredAppBundleIDs.isEmpty {
                LoreDivider()
                ignoredAppsRows
            }
            LoreDivider()
            // Current semantics kept honest (SET-21/Q4): hides the panel only;
            // transcription keeps running for notes.
            toggleRow(
                "Show live transcript",
                sub: "Hide the panel only \u{2014} transcription keeps running for notes",
                isOn: $settings.showLiveTranscript
            )
            LoreDivider()
            SettingsRow(name: "Microphone", sub: "Input device for recordings") {
                LoreMonoValueButton(title: currentMicName) {
                    showMicPicker.toggle()
                }
                .accessibilityIdentifier("settings.microphonePicker")
                .popover(isPresented: $showMicPicker, arrowEdge: .bottom) {
                    LorePickerPopover(
                        header: "Microphone",
                        items: micOptions,
                        width: 260,
                        isActive: { $0.id == settings.inputDeviceID },
                        onSelect: { option in
                            showMicPicker = false
                            settings.inputDeviceID = option.id
                        },
                        title: { $0.name }
                    )
                }
            }
            LoreDivider()
            toggleRow(
                "Save audio recording",
                sub: "Keep a local .m4a alongside each transcript",
                isOn: $settings.saveAudioRecording
            )
            LoreDivider()
            toggleRow(
                "Clean up transcript during recording",
                sub: "Removes fillers and fixes punctuation as you record",
                isOn: $settings.enableTranscriptRefinement
            )
            LoreDivider()
            toggleRow(
                "Enhance transcript after meeting",
                sub: "Re-transcribes the recording with full context in the background",
                isOn: $settings.enableBatchRefinement
            )
        }
    }

    private struct MicOption: Identifiable {
        let id: AudioDeviceID
        let name: String
    }

    private var micOptions: [MicOption] {
        [MicOption(id: 0, name: "System Default")]
            + inputDevices.map { MicOption(id: $0.id, name: $0.name) }
    }

    /// Honest current-device label: a persisted device that is not currently
    /// connected must not masquerade as "System Default". The stale ID stays
    /// stored and wins again when the device returns.
    private var currentMicName: String {
        if settings.inputDeviceID == 0 { return "System Default" }
        return micOptions.first { $0.id == settings.inputDeviceID }?.name ?? "Not connected"
    }

    @ViewBuilder
    private var ignoredAppsRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ignored apps")
                .font(LoreTheme.Typography.control)
                .foregroundStyle(LoreTheme.TextColor.primary)
            Text("These apps won't trigger meeting detection notifications")
                .font(.system(size: 12))
                .foregroundStyle(LoreTheme.TextColor.muted)
            ForEach(settings.ignoredAppBundleIDs, id: \.self) { bundleID in
                HStack {
                    Text(bundleID)
                        .font(LoreTheme.Typography.mono(12))
                        .foregroundStyle(LoreTheme.TextColor.primary)
                    Spacer()
                    Button {
                        settings.ignoredAppBundleIDs.removeAll { $0 == bundleID }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(LoreTheme.TextColor.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop ignoring \(bundleID)")
                    .help("Stop ignoring this app")
                }
            }
        }
        .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
    }

    private var autoDetectExplanationSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("How Meeting Detection Works")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                Label("\(LoreTheme.wordmark) watches for microphone activation by meeting apps (Zoom, Teams, FaceTime, etc.)", systemImage: "mic")
                Label("Only activation status is checked. No audio is captured or recorded until you accept.", systemImage: "lock.shield")
                Label("When a meeting is detected, you get a macOS notification to start transcribing.", systemImage: "bell")
                Label("You can always dismiss the notification or mark it as \"not a meeting\".", systemImage: "hand.raised")
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Cancel") {
                    showAutoDetectExplanation = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Enable Detection") {
                    settings.hasShownAutoDetectExplanation = true
                    settings.meetingAutoDetectEnabled = true
                    showAutoDetectExplanation = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    // MARK: - NOTES (SET-32/34/35/43/46)

    private var notesSection: some View {
        SettingsSection(label: "Notes") {
            SettingsRow(
                name: "Notes folder",
                sub: settings.notesFolderPath,
                subLineLimit: 1
            ) {
                LoreMonoValueButton(title: "Choose\u{2026}") {
                    chooseNotesFolder()
                }
            }
            LoreDivider()
            templatesRows
            LoreDivider()
            SettingsRow(
                name: "Granola import",
                sub: "API key from the Granola desktop app settings"
            ) {
                chipField("Granola API key", text: $settings.granolaApiKey, isSecure: true)
            }
            GranolaImportButton(apiKey: settings.granolaApiKey)
                .padding(EdgeInsets(top: 0, leading: 16, bottom: 13, trailing: 16))
        }
    }

    // MARK: - Templates (SET-46, expanding row)

    @ViewBuilder
    private var templatesRows: some View {
        ExpandableRow(
            name: "Meeting templates",
            sub: "\(templates.count) template\(templates.count == 1 ? "" : "s")",
            isExpanded: $isTemplatesExpanded
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(templates) { template in
                    HStack {
                        Image(systemName: template.icon)
                            .frame(width: 20)
                            .foregroundStyle(LoreTheme.TextColor.muted)
                        Text(template.name)
                            .font(.system(size: 12))
                            .foregroundStyle(LoreTheme.TextColor.primary)
                        Spacer()
                        if template.isBuiltIn {
                            Image(systemName: "lock")
                                .font(.system(size: 10))
                                .foregroundStyle(LoreTheme.TextColor.faint)
                            Button("Reset") {
                                resetTemplate(id: template.id)
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(LoreTheme.Accent.blue)
                        } else {
                            Button {
                                deleteTemplate(id: template.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(LoreTheme.Accent.red)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete \(template.name)")
                        }
                    }
                    .padding(.vertical, 5)
                }

                if isAddingTemplate {
                    newTemplateForm
                        .padding(.top, 8)
                } else {
                    Button("New Template") {
                        isAddingTemplate = true
                        Task { @MainActor in
                            focusedTemplateField = .name
                        }
                    }
                    .font(.system(size: 12))
                    .padding(.top, 8)
                }
            }
        }
    }

    private var newTemplateForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LoreTheme.TextColor.muted)
                TextField("e.g. Sprint Planning", text: $newTemplateName)
                    .font(.system(size: 12))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .focused($focusedTemplateField, equals: .name)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Icon")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LoreTheme.TextColor.muted)
                IconPickerGrid(selected: $newTemplateIcon)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Notes Prompt")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LoreTheme.TextColor.muted)
                Text("Instructions for how the AI should format notes for this meeting type.")
                    .font(.system(size: 10))
                    .foregroundStyle(LoreTheme.TextColor.faint)
                placeholderTextEditor(
                    "e.g. You are a meeting notes assistant. Given a transcript, produce structured notes with sections for...",
                    text: $newTemplatePrompt,
                    height: 100
                )
            }

            HStack {
                Button("Cancel") {
                    resetNewTemplateForm()
                }
                .buttonStyle(.plain)
                Button("Save") {
                    let template = MeetingTemplate(
                        id: UUID(),
                        name: trimmedTemplateName,
                        icon: newTemplateIcon,
                        systemPrompt: trimmedTemplatePrompt,
                        isBuiltIn: false
                    )
                    addTemplate(template)
                    resetNewTemplateForm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSaveNewTemplate)
            }
        }
    }

    // MARK: - ADVANCED (SET-30/33/36/42/44/45/48, DSET-08/18/19)

    private var advancedSection: some View {
        SettingsSection(label: "Advanced") {
            toggleRow(
                "Hide from screen sharing",
                sub: "The app is invisible during screen sharing and recording",
                isOn: $settings.hideFromScreenShare
            )
            LoreDivider()
            toggleRow(
                "Automatically check for updates",
                sub: nil,
                isOn: $automaticallyChecksForUpdates
            )
            LoreDivider()
            SettingsRow(name: "Check for updates", sub: nil) {
                LoreMonoValueButton(title: "Check Now") {
                    updater.checkForUpdates()
                }
                .disabled(!updatesViewModel.canCheckForUpdates)
                .opacity(updatesViewModel.canCheckForUpdates ? 1 : 0.4)
            }
            LoreDivider()
            SettingsRow(
                name: "Locale",
                sub: "Parakeet TDT v3 auto-detects speech language. Use this field to set your expected meeting language for metadata and export."
            ) {
                chipField("e.g. en-US", text: $settings.transcriptionLocale, width: 120)
            }
            LoreDivider()
            SettingsRow(
                name: "Report a problem",
                sub: "Send a diagnostic report — you'll see exactly what leaves your Mac"
            ) {
                LoreMonoValueButton(title: "Report\u{2026}") {
                    showProblemReport = true
                }
                .accessibilityIdentifier("settings.reportProblem")
            }
        }
    }

    /// Extra bundle IDs consumed by MeetingDetectionController. Lives in the
    /// MEETINGS auto-detect group (#54), shown only while auto-detect is on.
    private var customMeetingAppsRows: some View {
        ExpandableRow(
            name: "Custom meeting apps",
            sub: "Watch additional apps for meetings \u{2014} one bundle ID per line (e.g. com.example.voip)",
            isExpanded: $isCustomMeetingAppsExpanded
        ) {
            placeholderTextEditor(
                "One bundle ID per line, e.g. com.example.voip",
                text: customMeetingAppsText,
                height: 60
            )
        }
    }

    private var customMeetingAppsText: Binding<String> {
        Binding(
            get: { settings.customMeetingAppBundleIDs.joined(separator: "\n") },
            set: { text in
                settings.customMeetingAppBundleIDs = text
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    // MARK: - Row helpers

    private func toggleRow(
        _ name: String, sub: String?, isOn: Binding<Bool>
    ) -> some View {
        SettingsRow(name: name, sub: sub) {
            Toggle(name, isOn: isOn)
                .toggleStyle(LoreToggleStyle())
                .labelsHidden()
        }
    }

    /// Chip-styled text field (mono 12, `.06` fill); `isSecure` masks input
    /// for Keychain-backed keys.
    private func chipField(
        _ prompt: String,
        text: Binding<String>,
        isSecure: Bool = false,
        width: CGFloat = 260
    ) -> some View {
        Group {
            if isSecure {
                SecureField("", text: text, prompt: Text(prompt))
            } else {
                TextField("", text: text, prompt: Text(prompt))
            }
        }
        .font(LoreTheme.Typography.mono(12))
        .textFieldStyle(.plain)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(width: width)
        .background(
            Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: LoreTheme.Radius.chip)
        )
    }

    /// Chip-styled trailing-aligned integer field with a unit label — shared
    /// by the silence-timeout and Read Aloud max-length rows.
    private func numberField(value: Binding<Int>, unit: String, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number)
                .font(LoreTheme.Typography.mono(12))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(width: width)
                .background(
                    Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: LoreTheme.Radius.chip)
                )
            Text(unit)
                .font(.system(size: 12))
                .foregroundStyle(LoreTheme.TextColor.muted)
        }
    }

    /// Bordered TextEditor with a faint placeholder — shared by the template
    /// prompt and custom meeting apps editors.
    private func placeholderTextEditor(
        _ placeholder: String, text: Binding<String>, height: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11))
                    .foregroundStyle(LoreTheme.TextColor.faint)
                    .padding(.top, 6)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(LoreTheme.Typography.mono(11))
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .scrollContentBackground(.hidden)
        }
        .overlay(
            RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                .stroke(LoreTheme.Surface.line)
        )
    }

    // MARK: - State refresh & actions (unchanged logic)

    private func refreshViewState() {
        // Device enumeration is HAL IPC — it hops to the shared HAL queue (#64: never
        // on the main thread); the mic picker updates when the hop returns.
        Task { inputDevices = await AudioBus.availableInputDevices() }
        // Re-probe the key on every Settings activation (#50) — a key revoked
        // since the last visit must not keep showing a stale "Key OK".
        scheduleKeyProbe(debounce: false)
        refreshAudioDiskUsage()
        refreshSpeechifyVoices()
        Task { @MainActor in
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            templates = coordinator.templateStore.templates
        }
    }

    private func addTemplate(_ template: MeetingTemplate) {
        Task { @MainActor in
            coordinator.templateStore.add(template)
            templates = coordinator.templateStore.templates
        }
    }

    private func resetTemplate(id: UUID) {
        Task { @MainActor in
            coordinator.templateStore.resetBuiltIn(id: id)
            templates = coordinator.templateStore.templates
        }
    }

    private func deleteTemplate(id: UUID) {
        Task { @MainActor in
            coordinator.templateStore.delete(id: id)
            templates = coordinator.templateStore.templates
        }
    }

    private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save meeting transcripts"

        if panel.runModal() == .OK, let url = panel.url {
            settings.notesFolderPath = url.path
        }
    }

    private var trimmedTemplateName: String {
        newTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTemplatePrompt: String {
        newTemplatePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveNewTemplate: Bool {
        !trimmedTemplateName.isEmpty && !trimmedTemplatePrompt.isEmpty
    }

    private func resetNewTemplateForm() {
        isAddingTemplate = false
        newTemplateName = ""
        newTemplateIcon = "doc.text"
        newTemplatePrompt = ""
        focusedTemplateField = nil
    }
}

// MARK: - Section (SET-02: label + optional note + card, max-width 640)

private struct SettingsSection<Rows: View>: View {
    let label: String
    var note: String?
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoreSectionLabel(text: label, size: 11)
                .padding(.bottom, 9)
            if let note {
                Text(note)
                    .font(LoreTheme.Typography.secondary)
                    .foregroundStyle(LoreTheme.TextColor.muted)
                    .padding(.bottom, 9)
            }
            LoreCard { rows }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

// MARK: - Row (SET-02: 13px/600 name + 12px muted sub left, control right)

/// The one row layout: optional leading slot (key chip), name + sub, trailing
/// control. modifierRow and ExpandableRow's header compose this.
private struct SettingsRow<Leading: View, Trailing: View>: View {
    let name: String
    var sub: String?
    var subColor: Color
    var subLineLimit: Int?
    let leading: Leading
    let trailing: Trailing

    init(
        name: String,
        sub: String? = nil,
        subColor: Color = LoreTheme.TextColor.muted,
        subLineLimit: Int? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.name = name
        self.sub = sub
        self.subColor = subColor
        self.subLineLimit = subLineLimit
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 14) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(LoreTheme.Typography.control)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                if let sub, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(subColor)
                        .lineLimit(subLineLimit)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
    }
}

extension SettingsRow where Leading == EmptyView {
    init(
        name: String,
        sub: String? = nil,
        subColor: Color = LoreTheme.TextColor.muted,
        subLineLimit: Int? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            name: name,
            sub: sub,
            subColor: subColor,
            subLineLimit: subLineLimit,
            leading: { EmptyView() },
            trailing: trailing
        )
    }
}

// MARK: - Expandable row (Q6-approved pattern for complex controls)

/// Disclosure row for controls that don't fit the flat row vocabulary
/// (template editor, custom meeting apps editor). Expansion is instant — no
/// motion, so Reduce Motion needs no special-casing.
private struct ExpandableRow<Content: View>: View {
    let name: String
    var sub: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                SettingsRow(name: name, sub: sub) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LoreTheme.TextColor.muted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(isExpanded ? "expanded" : "collapsed")")

            if isExpanded {
                content
                    .padding(EdgeInsets(top: 0, leading: 16, bottom: 13, trailing: 16))
            }
        }
    }
}

// MARK: - Cycling helper (SET-04: value buttons cycle, no dropdown)

private func nextCase<T: CaseIterable & Equatable>(after value: T) -> T {
    let all = Array(T.allCases)
    guard let index = all.firstIndex(of: value) else { return all[0] }
    return all[(index + 1) % all.count]
}

// MARK: - Cleanup prompt copy chip (#146)

/// "Copy" chip in the default-preset prompt preview footer: writes the active
/// prompt to the pasteboard and flashes "✓ Copied" in green for 1.4s — chip
/// chrome over the shared `LoreCopyFlash` state machine. The hidden wider
/// label fixes the chip width so the swap causes no layout shift.
private struct CleanupPromptCopyChip: View {
    let text: String

    var body: some View {
        LoreCopyFlash {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } content: { copied, fire in
            Button(action: fire) {
                ZStack {
                    Text("✓ Copied").hidden()
                    Text(copied ? "✓ Copied" : "Copy")
                }
                .font(LoreTheme.Typography.mono(11, weight: .semibold))
                .foregroundStyle(copied ? LoreTheme.Accent.green : LoreTheme.TextColor.muted)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .loreChipChrome(fill: Color.white.opacity(0.06))
            }
            .buttonStyle(LorePressButtonStyle())
        }
    }
}

// MARK: - Icon Picker

private struct IconPickerGrid: View {
    @Binding var selected: String

    private static let icons = [
        "doc.text", "person.2", "person.3", "person.badge.plus",
        "calendar", "clock", "arrow.up.circle", "magnifyingglass",
        "lightbulb", "star", "flag", "bolt",
        "bubble.left.and.bubble.right", "phone", "video",
        "briefcase", "chart.bar", "list.bullet",
        "checkmark.circle", "gear", "globe", "book",
        "pencil", "megaphone",
    ]

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Self.icons, id: \.self) { icon in
                Button {
                    selected = icon
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected == icon ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selected == icon ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected == icon ? .primary : .secondary)
            }
        }
    }
}

// MARK: - Granola Import Button

private struct GranolaImportButton: View {
    @Environment(AppCoordinator.self) private var coordinator
    let apiKey: String
    @State private var importState: GranolaImportState = .idle
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch importState {
            case .idle:
                EmptyView()
            case .fetching(let progress):
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .importing(let current, let total):
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Importing \(current) of \(total)...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .completed(let imported, let skipped):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LoreTheme.Accent.green)
                        .font(.system(size: 12))
                    Text("Imported \(imported) meeting\(imported == 1 ? "" : "s")\(skipped > 0 ? ", \(skipped) already existed" : "")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .failed(let error):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(LoreTheme.Accent.red)
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(LoreTheme.Accent.red)
                }
            }

            Button("Import from Granola") {
                startImport()
            }
            .font(.system(size: 12))
            .disabled(isImporting)
        }
    }

    private func startImport() {
        guard !apiKey.isEmpty else {
            importState = .failed("Enter your Granola API key above.")
            return
        }

        isImporting = true
        importState = .fetching(progress: "Connecting to Granola...")

        let repo = coordinator.sessionRepository
        let importer = GranolaImporter()

        Task { @MainActor in
            do {
                let result = try await importer.importAll(
                    apiKey: apiKey,
                    sessionRepository: repo,
                    onProgress: { state in
                        Task { @MainActor in
                            self.importState = state
                        }
                    }
                )
                importState = .completed(imported: result.imported, skipped: result.skipped)
                isImporting = false
                await coordinator.loadHistory()
            } catch {
                importState = .failed(error.localizedDescription)
                isImporting = false
            }
        }
    }
}
