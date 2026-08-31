import AppKit
import SwiftUI

/// The key recorder (#226): a button that becomes a prompt, takes the next key
/// the user presses, and says in one line when a key cannot be the one.
///
/// Shared by the Settings hotkey row and the onboarding step, so "pick a key"
/// is one control with one wording in both places. It listens with a *local*
/// monitor — the press has to happen in lore's own window, which is where the
/// user is looking — and it suspends hold-to-talk while it is up, so pressing
/// the key that is currently the talk key records it instead of starting a
/// dictation.
struct HotkeyRecorder: View {
    /// The key the user chose. Fn and Right Option arrive here too: pressing
    /// one is the same act as picking it from the list.
    let onPick: (HotkeyKey) -> Void
    /// Raised while the prompt is up, so the owner can quiet the talk key.
    let onListening: (Bool) -> Void

    @State private var listening = false
    @State private var refusal: HotkeyKey.Refusal?
    @State private var monitor: Any?

    var body: some View {
        Group {
            if listening {
                prompt
            } else {
                // Deliberately not the blue primary: wherever this stands, the
                // named keys beside it are the answer for almost everyone, and
                // three shouting buttons on one card is none of them shouting.
                Button { start() } label: {
                    Text(Self.buttonTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LoreTheme.TextColor.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .loreChipChrome(fill: Color.white.opacity(0.06))
                }
                .buttonStyle(LorePressButtonStyle())
            }
        }
        .onDisappear { stop() }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Press a key")
                    .font(LoreTheme.Typography.control)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                Button("Cancel") { stop() }
                    .buttonStyle(.plain)
                    .font(LoreTheme.Typography.secondary)
                    .foregroundStyle(LoreTheme.TextColor.muted)
            }
            // The exemplar is a key that works on every Mac whatever the
            // keyboard settings say. It is deliberately not an F-key: with the
            // F-row left as media keys — the shipping default — a bare F5 never
            // reaches lore at all, and a hint that recommends one would be the
            // same dead end this issue closes.
            Text(refusal?.message ?? "Something that doesn't type \u{2014} Right Command, or Right Shift.")
                .font(LoreTheme.Typography.meta)
                .foregroundStyle(refusal == nil ? LoreTheme.TextColor.faint : LoreTheme.Accent.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 300, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Listening

    private func start() {
        guard monitor == nil else { return }
        refusal = nil
        listening = true
        onListening(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            take(event)
            return nil  // nothing recorded here reaches the field behind it
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard listening else { return }
        listening = false
        refusal = nil
        onListening(false)
    }

    /// One event, classified. A modifier's press and its release are the same
    /// event type, told apart by whether the flag it raises is now set — a
    /// release would otherwise record the key a second time on the way up.
    private func take(_ event: NSEvent) {
        if event.type == .flagsChanged {
            guard let flag = HotkeyKey.modifierFlags[event.keyCode],
                  event.modifierFlags.contains(flag)
            else { return }
        }
        // Esc dismisses, here as everywhere. It is refused as a talk key too
        // (`HotkeyKey.record`), but a user pressing it here means "not this".
        guard event.keyCode != DictationEscape.keyCode else {
            stop()
            return
        }
        // The F-row's setting is read at the press, not cached: it is a System
        // Settings switch the user can flip while this prompt is open.
        switch HotkeyKey.record(
            keyCode: event.keyCode, fnRowIsStandard: HotkeyKey.functionKeyRowIsStandard
        ) {
        case .chosen(let key):
            stop()
            onPick(key)
        case .refused(let reason):
            refusal = reason  // still listening: the next key gets its verdict
        }
    }

    /// One name for this control, wherever it stands.
    static let buttonTitle = "Pick a key"
}
