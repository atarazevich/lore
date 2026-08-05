import AppKit
import DynamicNotchKit
import os
import SwiftUI

private let healthNotchLog = Logger(subsystem: "com.lore.app", category: "HealthNotch")

/// Raises the notch to summon the user when a critical health link fails (#83,
/// design §6) — "Keyboard shortcuts not working / Fix it" — rather than waiting for the
/// panel to be found. A deliberately simpler surface than the meeting prompt
/// (`NotchPromptPresenter`): a single alert with one action and an auto-timeout,
/// always expanded (no compact/hover island), so it does not reuse that
/// presenter's meeting-shaped content and callbacks.
@MainActor
final class HealthNotchPresenter {
    /// Fired when the user clicks "Fix it" — opens the health panel.
    var onFix: (() -> Void)?

    private let timeout: Duration
    private var notch: DynamicNotch<HealthNotchView, EmptyView, EmptyView>?
    private var timeoutTask: Task<Void, Never>?

    /// The summon on screen, or `nil`. Also the re-summon guard: one notch at a
    /// time, first come first served — **except** that a critical outage
    /// displaces a non-critical notice. The launch migration summon (#135) is
    /// non-critical and holds the notch for the full timeout, which is exactly
    /// the window in which an Accessibility or Input Monitoring failure surfaces
    /// (the user has just been told to remove Lore from both panes), and
    /// `SummonDebouncer` fires once per outage — so a summon dropped here is
    /// lost for the rest of the session, not merely delayed.
    private(set) var onScreen: HealthSummon?

    init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    func present(_ summon: HealthSummon) {
        if let onScreen {
            guard summon.probe.isCritical, !onScreen.probe.isCritical else { return }
            dismiss()
        }
        onScreen = summon

        let notch = DynamicNotch(hoverBehavior: [.increaseShadow]) {
            HealthNotchView(title: summon.title) { [weak self] in
                self?.fix()
            }
        } compactLeading: {
            EmptyView()
        } compactTrailing: {
            EmptyView()
        }
        notch.transitionConfiguration = .init(skipIntermediateHides: true)
        self.notch = notch

        Task {
            await notch.expand()
            notch.windowController?.window?.applyFullscreenAuxiliaryVisibility()
        }
        healthNotchLog.debug("health notch summoned: \(summon.probe.rawValue, privacy: .public)")

        timeoutTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func fix() {
        dismiss()
        onFix?()
    }

    func dismiss() {
        timeoutTask?.cancel()
        timeoutTask = nil
        onScreen = nil
        guard let notch else { return }
        self.notch = nil
        Task { await notch.hide() }
    }
}

/// The expanded alert content. Dark by design — notch content is always dark.
struct HealthNotchView: View {
    let title: String
    let onFix: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(XMOTheme.Accent.red)
            Text(title)
                .font(XMOTheme.Typography.control)
                .foregroundStyle(XMOTheme.TextColor.primary)
            Button("Fix it", action: onFix)
                .buttonStyle(HealthNotchButtonStyle())
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .fixedSize()
    }
}

private struct HealthNotchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(XMOTheme.Typography.secondary)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(XMOTheme.Accent.blue, in: RoundedRectangle(cornerRadius: XMOTheme.Radius.button))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
