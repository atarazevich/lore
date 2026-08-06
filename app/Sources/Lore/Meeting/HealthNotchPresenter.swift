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
    /// One `DynamicNotch` for the presenter's whole life — the full #141
    /// rationale for both notch surfaces (`DynamicNotchPromptWindow` points
    /// here): the library's init spawns an unstructured Task iterating
    /// screen-parameter notifications forever with a strong `self` capture, so
    /// no DynamicNotch ever deallocates. Per-present construction therefore
    /// accumulated an instance per summon, each rebuilding a ghost panel
    /// (`initializeWindow` + `orderFrontRegardless`) on every display change.
    /// Created lazily on the first summon; per-summon content flows through
    /// `model` instead. Accepted residual: the observer re-creates and fronts
    /// the one panel on display changes even while hidden — a steady count of
    /// one per surface (#141's criterion), not growth.
    private var notch: DynamicNotch<HealthNotchView, EmptyView, EmptyView>?
    private let model = HealthNotchModel()
    private var timeoutTask: Task<Void, Never>?
    /// Serializes expand/hide — see `NotchOpQueue` for the stranded
    /// continuation this prevents.
    private let windowOps = NotchOpQueue()

    /// The summon on screen, or `nil`. Also the re-summon guard: one notch at a
    /// time, first come first served — **except** that a critical outage
    /// displaces a non-critical notice. The launch migration summon (#135) is
    /// non-critical and holds the notch for the full timeout, which is exactly
    /// the window in which an Accessibility or Input Monitoring failure surfaces
    /// (the user has just been told to remove Lore from both panes) — so a
    /// summon dropped here could go unseen for the rest of the outage.
    private(set) var onScreen: HealthSummon?

    init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    func present(_ summon: HealthSummon) {
        if let onScreen {
            guard summon.probe.isCritical, !onScreen.probe.isCritical else { return }
        }
        let alreadyUp = onScreen != nil
        onScreen = summon
        model.title = summon.title

        timeoutTask?.cancel()
        let notch = ensureNotch()
        // Displacement is a pure content swap: the notch is already expanded,
        // so only a hidden notch needs the raise.
        if !alreadyUp {
            windowOps.enqueue { [weak self] in
                await notch.expand()
                // Dismissed mid-animation: don't re-front a panel the library
                // is about to close.
                guard self?.onScreen != nil else { return }
                notch.windowController?.window?.applyFullscreenAuxiliaryVisibility()
            }
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
        guard onScreen != nil else { return }
        onScreen = nil
        guard let notch else { return }
        // The reference is deliberately kept (see `notch`): `hide()` closes the
        // library's panel only at the end of its animation, so the presenter
        // must not forget the window before that completes.
        windowOps.enqueue { await notch.hide() }
    }

    private func ensureNotch() -> DynamicNotch<HealthNotchView, EmptyView, EmptyView> {
        if let notch { return notch }
        let notch = DynamicNotch(hoverBehavior: [.increaseShadow]) { [model] in
            HealthNotchView(model: model) { [weak self] in
                self?.fix()
            }
        } compactLeading: {
            EmptyView()
        } compactTrailing: {
            EmptyView()
        }
        notch.transitionConfiguration = .init(skipIntermediateHides: true)
        self.notch = notch
        return notch
    }
}

/// The reusable notch's one mutable input (#141): DynamicNotchKit captures its
/// content view once at init, so per-summon content has to flow through an
/// observed model rather than a freshly built view.
@MainActor
final class HealthNotchModel: ObservableObject {
    @Published var title = ""
}

/// The expanded alert content. Dark by design — notch content is always dark.
struct HealthNotchView: View {
    @ObservedObject var model: HealthNotchModel
    let onFix: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LoreTheme.Accent.red)
            Text(model.title)
                .font(LoreTheme.Typography.control)
                .foregroundStyle(LoreTheme.TextColor.primary)
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
            .font(LoreTheme.Typography.secondary)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(LoreTheme.Accent.blue, in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
