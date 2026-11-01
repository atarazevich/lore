import Carbon.HIToolbox
import LoreCore
import os

/// One key lore claims during a recording, as the system's hot key registry
/// knows it (#342): a keycode and the Carbon modifiers that must be down with
/// it (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`, `kEventKeyModifierFnMask`;
/// 0 for the bare key). Matching is exact, Fn included.
///
/// Why hot keys at all: while another app holds Secure Event Input, the CGEvent
/// tap receives no key-downs, so Space, Esc and the letters died mid-recording.
/// A Carbon hot key is still delivered then — measured, down and up, in
/// `experiments/secure-input-key-probe` — and lore receives only the keys it
/// registered, so nothing else is read.
struct ControlHotKey: Hashable, Sendable {
    let keyCode: UInt16
    let modifiers: UInt32

    /// The key's kind for the event stream — never a keycode.
    var diagKey: ControlKey {
        switch keyCode {
        case HotkeyKey.spaceKeyCode: .space
        case DictationEscape.keyCode: .escape
        default: .letter
        }
    }

    /// The hot key's id is the key itself: the keycode in the low byte, the
    /// Carbon modifiers (bits 8–17, Fn's the highest) shifted above it — bit
    /// 25 at most, inside 32. So an event decodes to its key with no table to
    /// search.
    var id: UInt32 { modifiers << 8 | UInt32(keyCode & 0xFF) }

    /// The key as Settings prints it ("fn R", "esc"), for the health row
    /// that names a refused key (#346).
    var displayName: String {
        if modifiers == UInt32(controlKey | cmdKey), keyCode == 9 { return "Control-Command-V" }
        let named: [(UInt32, String)] = [(UInt32(kEventKeyModifierFnMask), "fn"), (UInt32(controlKey), "control"),
                                         (UInt32(optionKey), "option"), (UInt32(cmdKey), "command"),
                                         (UInt32(shiftKey), "shift")]
        let base = Self.keyNames[keyCode] ?? "key \(keyCode)"
        return (named.filter { modifiers & $0.0 != 0 }.map(\.1) + [base]).joined(separator: " ")
    }

    /// Every key lore registers, by keycode.
    private static let keyNames: [UInt16: String] = [
        49: "space", 53: "esc", 9: "V", 17: "T", 1: "S", 40: "K",
        15: "R", 12: "Q", 33: "[", 30: "]", 38: "J", 46: "M",
    ]

    init(keyCode: UInt16, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(id: UInt32) {
        self.init(keyCode: UInt16(id & 0xFF), modifiers: id >> 8)
    }
}

/// The system side of hot keys. A protocol so tests never register a real one —
/// a test that did would swallow the owner's Space system-wide while it ran.
@MainActor
protocol HotKeyRegistering: AnyObject {
    /// A registered key went down (`pressed`) or up.
    var onEvent: ((ControlHotKey, _ pressed: Bool) -> Void)? { get set }
    /// `noErr`, or the system's reason (another app holds the same key, or the
    /// handler that would receive it could not be installed).
    func register(_ key: ControlHotKey) -> OSStatus
    func unregister(_ key: ControlHotKey)
}

/// The registrar for tests and for a manager built without one: registers
/// nothing, delivers nothing.
@MainActor
final class InertHotKeys: HotKeyRegistering {
    var onEvent: ((ControlHotKey, Bool) -> Void)?
    func register(_ key: ControlHotKey) -> OSStatus { noErr }
    func unregister(_ key: ControlHotKey) {}
}

/// The live registrar: `RegisterEventHotKey` on the application event target.
/// The handler runs on the main run loop, which is the main actor's thread. A
/// process's hot keys are released by the system when it exits or crashes.
@MainActor
final class CarbonHotKeys: HotKeyRegistering {
    var onEvent: ((ControlHotKey, Bool) -> Void)?
    private var refs: [ControlHotKey: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    /// Installs the event handler; injected only by the test that proves no key
    /// is taken without one.
    private let installHandler: @MainActor (CarbonHotKeys) -> (OSStatus, EventHandlerRef?)
    /// "LrHK" — tells our hot keys from anyone else's on the same target.
    private static let signature: OSType = 0x4C72_484B

    init(installHandler: @escaping @MainActor (CarbonHotKeys) -> (OSStatus, EventHandlerRef?) = CarbonHotKeys.liveInstall) {
        self.installHandler = installHandler
    }

    func register(_ key: ControlHotKey) -> OSStatus {
        guard refs[key] == nil else { return noErr }
        // Never take a key nobody would receive: with no handler, a hot key
        // would swallow the press and nothing would act on it.
        if handler == nil {
            let (status, installed) = installHandler(self)
            guard status == noErr, let installed else {
                return status == noErr ? OSStatus(eventInternalErr) : status
            }
            handler = installed
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(key.keyCode), key.modifiers,
            EventHotKeyID(signature: Self.signature, id: key.id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return status == noErr ? OSStatus(eventInternalErr) : status }
        refs[key] = ref
        return noErr
    }

    func unregister(_ key: ControlHotKey) {
        guard let ref = refs.removeValue(forKey: key) else { return }
        UnregisterEventHotKey(ref)
    }

    private static func liveInstall(_ registrar: CarbonHotKeys) -> (OSStatus, EventHandlerRef?) {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var handler: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard read == noErr, id.signature == CarbonHotKeys.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let key = ControlHotKey(id: id.id)
            // The application target's handlers run on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<CarbonHotKeys>.fromOpaque(userData).takeUnretainedValue().onEvent?(key, pressed)
            }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(registrar).toOpaque(), &handler)
        return (status, handler)
    }
}

/// The hot keys registered right now, kept equal to a wanted set (#342).
///
/// `apply` is the only way in: the manager derives the set from the tap's own
/// decisions on every state change and hands it here, so registration follows
/// state by construction. An empty set unregisters everything.
@MainActor
final class RecordingHotKeys {
    private static let log = Logger(subsystem: "com.lore.app", category: "Hotkey")
    let registrar: HotKeyRegistering
    /// What is registered — a key the system refused is not in here.
    private(set) var registered: Set<ControlHotKey> = []
    /// Keys the system refused while wanted: retried on every apply, traced
    /// only the first time, until they leave the wanted set.
    private(set) var refused: Set<ControlHotKey> = []
    /// Keys whose press arrived and whose release has not: a second press
    /// before the release is the same key held down (auto-repeat).
    private var down: Set<ControlHotKey> = []
    /// Which channel last acted on a keycode, and when.
    private var lastActed: [UInt16: (channel: PressChannel, at: TimeInterval)] = [:]
    /// One physical press reaching two channels is one press: the second
    /// arrives within milliseconds. Which channel sees a press first with
    /// secure input off is unverified, so the guard is symmetric — and it only
    /// ever drops the *other* channel's copy: two genuine presses on one
    /// channel (Fn+K Fn+K, Esc Esc) both act; a channel's own repeats are its
    /// own business (the tap's autorepeat field, `takePress`).
    static let samePressWindow: TimeInterval = 0.2

    init(registrar: HotKeyRegistering) {
        self.registrar = registrar
    }

    func apply(_ wanted: Set<ControlHotKey>) {
        for key in registered.subtracting(wanted) {
            registrar.unregister(key)
            registered.remove(key)
            down.remove(key)
        }
        refused.formIntersection(wanted)
        for key in wanted.subtracting(registered) {
            let status = registrar.register(key)
            if status == noErr {
                registered.insert(key)
                refused.remove(key)
            } else if refused.insert(key).inserted {
                DiagStore.record(.hotKeyRegisterFailed(key: key.diagKey, osStatus: status))
                Self.log.error("[HK] hot key \(key.keyCode, privacy: .public)/\(key.modifiers, privacy: .public) refused: \(status, privacy: .public)")
            }
        }
    }

    /// A press or release arrived. True for a fresh press of a key still
    /// registered: not a release, not auto-repeat.
    func takePress(_ key: ControlHotKey, pressed: Bool) -> Bool {
        guard pressed else { down.remove(key); return false }
        return registered.contains(key) && down.insert(key).inserted
    }

    /// This key-down is another channel's press seen again: swallow it,
    /// before deciding anything, so it is neither acted on twice nor passed on.
    func isDuplicate(_ keyCode: UInt16, on channel: PressChannel, now: TimeInterval) -> Bool {
        guard let last = lastActed[keyCode] else { return false }
        return last.channel != channel && now - last.at < Self.samePressWindow
    }

    /// A channel acted on this keycode.
    func noteActed(_ keyCode: UInt16, on channel: PressChannel, now: TimeInterval) {
        lastActed[keyCode] = (channel, now)
    }
}

/// The paths a key-down can reach lore by (#342).
enum PressChannel: Sendable {
    case tap
    case localMonitor
    /// Control-Command-V only, the one key it reads (#95).
    case globalMonitor
    case hotKey
}

extension HotkeyKey {
    /// The Carbon modifier this talk key adds to a key pressed while it is
    /// held, so the hot key for "Space with the talk key" matches the press:
    /// Carbon matches modifiers exactly, Fn's bit included (measured live,
    /// #342). 0 for a recorded key that is not a modifier.
    var carbonModifier: UInt32 {
        let keyCode: UInt16
        switch self {
        case .fn: return UInt32(kEventKeyModifierFnMask)
        case .rightOption: keyCode = Self.rightOptionKeyCode
        case .custom(let code): keyCode = code
        }
        switch Self.modifierFlags[keyCode] {
        case .command?: return UInt32(cmdKey)
        case .option?: return UInt32(optionKey)
        case .control?: return UInt32(controlKey)
        case .shift?: return UInt32(shiftKey)
        case .function?: return UInt32(kEventKeyModifierFnMask)
        default: return 0
        }
    }
}
