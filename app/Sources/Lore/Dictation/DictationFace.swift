import Foundation

/// What the floating bubble says when a dictation could not be finished (#209).
///
/// One case per failure face on the board
/// (`docs/design/prototypes/dictation-bubble-states.html`, "every face after
/// release"), each carrying its own sentence and its own single action. One
/// value rather than a message string with a button kind beside it: those are
/// two fields that can disagree about which failure is on screen, and the
/// action can then be wrong about the sentence it stands under.
///
/// The working faces are not here — transcribing and downloading are states the
/// pipeline is in (`DictationState`), not things that went wrong.
enum DictationFace: Equatable, Sendable {
    /// F1 — every way the microphone can fail, said the same way: a denied
    /// grant, a stalled HAL, a device that delivered no frames. The sentence
    /// names the resolved device, so it is the one thing here that is not a
    /// constant. The raw driver string never reaches the row.
    case micUnavailable(String)
    /// F2 — the dictation transcribed to nothing: silence into the mic, or
    /// every chunk lost after its retries. One face, because the two are one
    /// experience (ui-language.md rule 5), and the app used to show a
    /// checkmark for both.
    case nothingCameThrough
    /// F4 — the speech model could not be fetched. Replaces two raw NSError
    /// descriptions, "Model loading failed: …" and "Backend prepare failed: …",
    /// which were the same thing to the person reading them.
    case modelDownloadFailed
    /// F5 — the synthetic Cmd+V could not even be created, which is the whole
    /// of what this path can observe (`TextInserter.postCommandChord`).
    case pasteFailed
    /// F6 — the words landed raw because the cleanup call failed (DIC-48's
    /// fallback, unchanged).
    case cleanupFailed
    case translateFailed

    /// The one line the person reads. Byte-identical to the board's copy table.
    var sentence: String {
        switch self {
        case .micUnavailable(let message): message
        case .nothingCameThrough: "Nothing came through."
        case .modelDownloadFailed: "Couldn't download the speech model. Check your connection."
        case .pasteFailed: "Couldn't paste."
        case .cleanupFailed: "Cleanup failed \u{2014} pasted raw text."
        case .translateFailed: "Translation failed \u{2014} pasted raw text."
        }
    }

    /// Secondary detail, present for whoever hovers and never load-bearing on
    /// the row (ui-language.md rule 3). The paste-failed face is the only one
    /// with something to add: the words are recoverable right now, without
    /// waiting on a permission grant.
    var detail: String? {
        switch self {
        case .pasteFailed: "Your text is on the clipboard \u{2014} press Cmd+V to paste it now."
        default: nil
        }
    }

    /// The one thing this face offers, or nothing. A face with no action is a
    /// face where there is nothing left for the person to decide: the raw text
    /// already landed, and history is where it gets fixed.
    var action: DictationFaceAction? {
        switch self {
        case .micUnavailable, .nothingCameThrough: .openLoreSettings
        case .modelDownloadFailed: .tryAgain
        case .pasteFailed: .openSettings(.accessibility)
        case .cleanupFailed, .translateFailed: nil
        }
    }

    /// P1, chosen 2026-08-30: this one face folds its action into the row past
    /// a hairline, in the rail's own keycap idiom. Every other face stands its
    /// action on its own line under the sentence, as the board draws them.
    var actionIsInline: Bool {
        self == .pasteFailed
    }
}

/// What a face's one button does — a *kind*, not a closure, and deliberately
/// the same three shapes `HealthRemedyAction` already has names for: the two
/// surfaces that offer the same door must say the same words, and borrowing the
/// label is how that stops being a promise and starts being a fact.
enum DictationFaceAction: Equatable, Sendable {
    /// A System Settings pane, opened the one way every surface opens one
    /// (`SettingsPane.open`).
    case openSettings(SettingsPane)
    /// lore's own Settings → Meetings, where the Microphone row already governs
    /// dictation's own capture (`DictationCoordinator.startMicCapture` resolves
    /// the same `settings.inputDeviceID`). Named for what it opens, not for this
    /// feature: no Audio section was built for it (owner, 2026-08-30).
    case openLoreSettings
    /// The model download the next dictation would attempt anyway, now — for
    /// whoever has just fixed their connection and does not want to wait for it.
    case tryAgain

    var label: String {
        switch self {
        case .openSettings(let pane): pane.buttonLabel
        case .openLoreSettings: HealthRemedyAction.openLoreSettings.buttonLabel
        case .tryAgain: "Try again"
        }
    }
}
