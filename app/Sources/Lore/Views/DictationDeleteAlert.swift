import AppKit
import LoreCore

/// The words for deleting dictations (#243): `dictation-delete.html` §06, the
/// copy table, which is the contract. One noun, "dictations", everywhere.
enum DictationDeleteCopy {
    /// "1 dictation", "2,954 dictations": the history strip and Settings.
    static func count(_ n: Int) -> String {
        "\(DictationActivityFormat.groupedNumber(n)) \(n == 1 ? "dictation" : "dictations")"
    }

    /// Settings → History, the Dictation history row's line.
    static func historyLine(_ n: Int) -> String {
        n == 0 ? "No dictations on this Mac" : "\(count(n)) on this Mac"
    }

    /// The select bar's button and the alert's for chosen rows.
    static func deleteChosen(_ n: Int) -> String {
        n == 1 ? "Delete Dictation" : "Delete \(DictationActivityFormat.groupedNumber(n)) Dictations"
    }

    /// The alert's destructive button; its title is this with a question mark.
    static func action(count n: Int, all: Bool) -> String {
        all && n > 1 ? "Delete All \(DictationActivityFormat.groupedNumber(n)) Dictations" : deleteChosen(n)
    }

    /// The alert's line: exactly what goes, and where to. Screenshots are
    /// named only when there are any.
    static func message(count n: Int, screenshots: Bool) -> String {
        switch (n == 1, screenshots) {
        case (true, false): "The audio and its text move to the Trash."
        case (true, true): "The audio, screenshots and text move to the Trash."
        case (false, false): "Their audio and text move to the Trash."
        case (false, true): "Their audio, screenshots and text move to the Trash."
        }
    }

    /// After a delete that left some in history because a file of theirs could
    /// not be moved to the Trash: what happened, and what is left.
    static func failureTitle(kept n: Int) -> String {
        n == 1 ? "Couldn't Delete Dictation" : "Couldn't Delete \(DictationActivityFormat.groupedNumber(n)) Dictations"
    }

    /// `incomplete`: some of them are in history without a file that went to
    /// the Trash and could not be put back, so "still in history" alone would
    /// claim they are whole.
    static func failureMessage(kept n: Int, incomplete: Bool = false) -> String {
        switch (n == 1, incomplete) {
        case (true, false): "It is still in history."
        case (false, false): "They are still in history."
        case (true, true): "It is still in history. Some of its files are in the Trash."
        case (false, true): "They are still in history. Some of their files are in the Trash."
        }
    }
}

/// One confirmation, fixed when it is asked (#243): the dictations it names
/// are the ones it deletes, so one that lands while the alert is up is not
/// taken with them.
struct DictationDeleteRequest {
    let ids: Set<UUID>
    let all: Bool
    let screenshots: Bool

    /// Nil when none of `ids` may be deleted now — in flight, or gone.
    @MainActor
    init?(_ ids: Set<UUID>, all: Bool = false, in history: DictationHistory) {
        let ids = history.deletable(ids)
        guard !ids.isEmpty else { return nil }
        self.ids = ids
        self.all = all
        self.screenshots = history.collectedScreenshots(ids)
    }

    var action: String { DictationDeleteCopy.action(count: ids.count, all: all) }
    var title: String { action + "?" }
    var message: String { DictationDeleteCopy.message(count: ids.count, screenshots: screenshots) }
}

/// The Mac's own alert for a delete (`dictation-delete.html` §04), and the
/// one that follows when something could not be deleted — both as sheets on
/// lore's window, as SwiftUI shows "Delete Meeting?". A sheet keeps the main
/// queue running, so a dictation started with Fn while one is up goes ahead.
///
/// AppKit's `NSAlert`, not SwiftUI's `.alert`: Apple asks for Cancel as the
/// default of a destructive alert, and only here is that certain. The red
/// button is on top and answers to no key; Cancel is filled, and Return and
/// Escape both press it.
@MainActor
enum DictationDeleteConfirmation {
    /// Ask, and delete when the answer is the red button. `onConfirm` runs at
    /// that moment, before the files go.
    static func ask(
        _ request: DictationDeleteRequest?, history: DictationHistory, onConfirm: @escaping () -> Void = {}
    ) {
        guard let request else { return }
        guard let window = shellWindow() else {
            DiagStore.record(.dictationDeleteAlertUnshown(afterDelete: false))
            return
        }
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = request.message
        let delete = alert.addButton(withTitle: request.action)
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        // Escape presses Cancel while the sheet is up: Cancel's key equivalent
        // is Return here, and a button holds only one.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window == alert.window else { return event }
            cancel.performClick(nil)
            return nil
        }
        alert.beginSheetModal(for: window) { response in
            escape.map(NSEvent.removeMonitor)
            guard response == .alertFirstButtonReturn else { return }
            onConfirm()
            Task { @MainActor in
                let result = await history.delete(request.ids, all: request.all)
                reportWhatStayed(result)
            }
        }
    }

    /// Nothing to say when everything went.
    private static func reportWhatStayed(_ result: DictationDeletion) {
        let stayed = result.kept + result.incomplete
        guard stayed > 0 else { return }
        // The window may have closed while the files moved: brought back, so
        // the user always learns what stayed.
        guard let window = shellWindow() else {
            DiagStore.record(.dictationDeleteAlertUnshown(afterDelete: true))
            return
        }
        let failure = NSAlert()
        failure.messageText = DictationDeleteCopy.failureTitle(kept: stayed)
        failure.informativeText = DictationDeleteCopy.failureMessage(kept: stayed, incomplete: result.incomplete > 0)
        failure.addButton(withTitle: "OK")
        failure.beginSheetModal(for: window, completionHandler: nil)
    }

    /// lore's one window, in front, for a sheet: every delete starts there,
    /// and a closed window is only ordered out, so it can be brought back.
    /// Nil only when AppKit never made it.
    private static func shellWindow() -> NSWindow? {
        guard let window = LoreRootApp.mainWindow else { return nil }
        if !window.isVisible {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        return window
    }
}
