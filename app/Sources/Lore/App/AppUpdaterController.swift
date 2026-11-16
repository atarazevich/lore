import AppKit
import LoreCore
import Sparkle

@MainActor
final class AppUpdaterController {
    let updater: SPUUpdater
    private let userDriver: LoreUserDriver
    private let delegateProxy: AppUpdaterDelegateProxy
    private var shouldRestoreAccessoryModeAfterUpdateCycle = false

    private var didStart = false

    init() {
        let hostBundle = Bundle.main
        delegateProxy = AppUpdaterDelegateProxy()
        userDriver = LoreUserDriver(hostBundle: hostBundle, delegate: nil)
        updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: delegateProxy
        )
        delegateProxy.owner = self
    }

    /// Begin update checks. Called from the boot gate, never from `init` (#150):
    /// during setup no Sparkle prompt may appear over the onboarding window, and
    /// on a configured machine this runs at the same moment as every other
    /// subsystem. Idempotent — `SPUUpdater.start()` throws on a second call.
    func start() {
        guard !didStart else { return }
        didStart = true

        do {
            try updater.start()
        } catch {
            presentStartupError()
            return
        }

        // Force an update check near launch so the app checks soon rather than
        // waiting a full interval (#91). This is the SILENT path: unlike
        // `checkForUpdatesFromMenuBar`, it does NOT flip activation policy to
        // .regular or call NSApp.activate, so an accessory-mode launch is never
        // yanked to the foreground. SPUStandardUserDriver surfaces UI only if an
        // update is actually found (gentle reminder); a background check shows no
        // "you're up to date" dialog. Guarded on `automaticallyChecksForUpdates`
        // (default true via Info.plist SUEnableAutomaticChecks, overridable by the
        // user) so a user who turned updates off gets no launch check either.
        // The header recommends calling this only immediately after `start()`.
        // Scheduled interval lives in Info.plist (SUScheduledCheckInterval) — the
        // API-preferred place — so we never clobber the setting on launch.
        if updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }
    }

    private func presentStartupError() {
        let alert = NSAlert()
        alert.messageText = "Unable to Check For Updates"
        alert.informativeText = "The updater failed to start. Please verify you have the latest version of \(LoreBrand.wordmark) and contact the developer if the issue persists."
        alert.runModal()
    }

    func checkForUpdatesFromMenuBar() {
        let launchedFromAccessoryMode = NSApp.activationPolicy() == .accessory
        shouldRestoreAccessoryModeAfterUpdateCycle = launchedFromAccessoryMode

        if launchedFromAccessoryMode {
            NSApp.setActivationPolicy(.regular)
        }

        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }

    fileprivate func handleUpdateCycleFinished() {
        guard shouldRestoreAccessoryModeAfterUpdateCycle else { return }
        shouldRestoreAccessoryModeAfterUpdateCycle = false

        let hasVisibleWindows = NSApp.windows.contains { window in
            window.isVisible && !window.isMiniaturized
        }

        if !hasVisibleWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

@MainActor
final class LoreUserDriver: SPUStandardUserDriver {
    private nonisolated static let sparkleErrorDomain = DiagEvent.ErrorDomain.sparkleDomainName
    private nonisolated static let installationErrorCode = 4005
    private nonisolated static let installationWriteNoPermissionErrorCode = 4012

    /// lore's own guidance replaces Sparkle's alert only when macOS confirmably
    /// refused the write (#359). Every other failure, an installer that exited
    /// early included, gets Sparkle's own message: the cause is unknown, and
    /// sending the user to App Management on a guess is a false alarm.
    override func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let writeRefused = Self.isWritePermissionFailure(error as NSError)
        let guidance = writeRefused ? Self.installedBundleGuidance() : .none
        DiagStore.record(.updateFailed(error: error, guidance: guidance))

        guard let content = alertContent(for: guidance) else {
            super.showUpdaterError(error, acknowledgement: acknowledgement)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = content.title
        alert.informativeText = content.message
        alert.addButton(withTitle: "OK")
        alert.runModal()

        acknowledgement()
    }

    /// Reads the installed bundle's owner and writability, only after a
    /// confirmed write refusal. Unreadable attributes count as not proven.
    private static func installedBundleGuidance() -> DiagEvent.UpdateGuidance {
        let bundle = Bundle.main.bundleURL
        let files = FileManager.default
        let owner = (try? files.attributesOfItem(atPath: bundle.path))?[.ownerAccountID] as? NSNumber
        return writeRefusedGuidance(
            ownerID: owner?.uint32Value,
            userID: getuid(),
            bundleWritable: files.isWritableFile(atPath: bundle.path)
        )
    }

    /// After macOS refused the write: a bundle another account owns, or one
    /// this user cannot write, is fixed by reinstalling; otherwise App
    /// Management is what stands in the way. The folder it sits in is not
    /// read: a non-admin user never can write /Applications, and reinstalling
    /// would not change that. A missing owner (attributes unreadable) is not
    /// evidence of another account.
    nonisolated static func writeRefusedGuidance(
        ownerID: UInt32?, userID: UInt32, bundleWritable: Bool
    ) -> DiagEvent.UpdateGuidance {
        let ownedByAnother = ownerID.map { $0 != userID } ?? false
        return ownedByAnother || !bundleWritable ? .notOwned : .appManagement
    }

    /// A write refusal as Sparkle shapes it (SPUInstallerDriver.m): its own
    /// no-permission code anywhere in the chain, or Cocoa's write-no-permission
    /// directly beneath its installation error. A 513 anywhere else (the delta
    /// patcher's temporary files) is not a refusal to replace the app.
    nonisolated static func isWritePermissionFailure(_ error: NSError) -> Bool {
        let chain = error.underlyingChain
        if chain.contains(where: { $0.domain == sparkleErrorDomain && $0.code == installationWriteNoPermissionErrorCode }) {
            return true
        }
        return zip(chain, chain.dropFirst()).contains { parent, child in
            parent.domain == sparkleErrorDomain && parent.code == installationErrorCode
                && child.domain == NSCocoaErrorDomain && child.code == NSFileWriteNoPermissionError
        }
    }

    private func alertContent(for guidance: DiagEvent.UpdateGuidance) -> (title: String, message: String)? {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "This app"

        switch guidance {
        case .none, .unknown:
            return nil
        case .notOwned:
            return ("\(appName) can't update itself", """
            \(appName) was installed by another account or with administrator rights, so it can't replace itself. \
            Drag \(appName) from Applications to the Trash, then install it again from the download. Updates will work from then on.
            """)
        case .appManagement:
            return ("Allow \(appName) to Install Updates", """
            macOS didn't let \(appName) replace the installed app.

            To allow updates:
            1. Open System Settings > Privacy & Security > App Management
            2. Enable \(appName)
            3. Approve the password prompt
            4. Quit \(appName), open it and try the update again
            """)
        }
    }
}

private final class AppUpdaterDelegateProxy: NSObject, SPUUpdaterDelegate {
    weak var owner: AppUpdaterController?

    /// Updates between releases sit on the feed's `beta` channel; a Mac takes them only
    /// after `defaults write com.lore.app updateChannel beta`. Hidden, no UI.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.string(forKey: "updateChannel") == "beta" ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        owner?.handleUpdateCycleFinished()
    }
}
