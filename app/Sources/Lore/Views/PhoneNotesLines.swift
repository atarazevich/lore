import LoreCore
import LoreFormat
import SwiftUI

/// The lines under "Show notes from iPhone" (#309, phone-notes-on-mac.html
/// frames B and C): macOS refused iCloud Drive, or one note could not be
/// brought in. Both come from `PhoneNoteImporter`, live; with nothing wrong
/// the row stands alone.
struct PhoneNotesLines: View {
    let importer: PhoneNoteImporter

    var body: some View {
        if importer.accessRefused {
            HStack(alignment: .center, spacing: 12) {
                Text(PhoneNotesCopy.refused)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(PhoneNotesCopy.refusedTooltip)
                Button(SettingsPane.filesAndFolders.buttonLabel) { SettingsPane.filesAndFolders.open() }
                    .buttonStyle(HealthActionButtonStyle())
            }
            .modifier(ProblemLine())
        }
        ForEach(importer.reports, id: \.id) { report in
            HStack(alignment: .top, spacing: 12) {
                (Text(PhoneNotesCopy.failed(id: report.id))
                    .foregroundStyle(LoreTheme.TextColor.primary)
                    + Text(" " + PhoneNotesCopy.stillOnPhone)
                    .foregroundStyle(LoreTheme.TextColor.muted))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(PhoneNotesCopy.failedTooltip(report.record))
                LoreIconButton(systemName: "xmark", label: "Dismiss", size: 16, glyphSize: 8) {
                    importer.dismiss(report.id)
                }
            }
            .modifier(ProblemLine())
            .onAppear { importer.reportShown(report.id) }
        }
    }

    /// The board's `.problem`: 11 pt, tucked under its row.
    private struct ProblemLine: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.system(size: 11))
                .padding(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
        }
    }
}

/// The lines' words, the board's copy table (phone-notes-on-mac.html §04).
enum PhoneNotesCopy {
    static let refused = "\(LoreBrand.wordmark) can't read iCloud Drive."
    static let refusedTooltip = "Turn on iCloud Drive for \(LoreBrand.wordmark) in Privacy & Security \u{203A} "
        + "Files & Folders, so notes from iPhone can arrive."
    static let stillOnPhone = "It's still on your iPhone."

    /// `A note from 30 September 2026 · 21:14 couldn't be copied to this Mac.` —
    /// the note's start, from its id, in the meeting review's date form.
    static func failed(id: String) -> String {
        let start = MeetingFiles.startDate(fromSessionID: id).map { MeetingMeta.start($0, detail: true) } ?? []
        return "A note from \(start.joined(separator: " \u{00B7} ")) couldn't be copied to this Mac."
    }

    /// `lore tried 5 times over 2 days. Its audio file in iCloud Drive can't be read.`
    /// The second sentence names the file when the failure was reading one.
    static func failedTooltip(_ record: PhoneNoteImporter.FailureRecord) -> String {
        let span = record.lastFailure.timeIntervalSince(record.firstFailure)
        let days = max(1, Int((span / 86_400).rounded(.up)))
        let tries = "\(LoreBrand.wordmark) tried \(record.failures) times over \(days) day\(days == 1 ? "" : "s")."
        switch record.stage {
        case .audio: return tries + " Its audio file in iCloud Drive can't be read."
        case .transcript: return tries + " Its transcript in iCloud Drive can't be read."
        case .noteFile, .copy, .idInUse: return tries
        }
    }
}
