import AppKit
import XCTest
@testable import LoreKit

/// The talk key as a value (#226): what the recorder accepts, what it refuses
/// and why, what survives a launch, and which of the two event paths each key
/// rides.
@MainActor
final class HotkeyKeyTests: XCTestCase {

    // MARK: - The recorder's verdict

    /// Every test here presses with the F-row already set to standard function
    /// keys unless it is the media-row rule itself under test.
    private func record(_ keyCode: UInt16, fnRow: Bool = true) -> HotkeyKey.Recording {
        HotkeyKey.record(keyCode: keyCode, fnRowIsStandard: fnRow)
    }

    /// Pressing Fn or Right Option in the recorder is the same act as picking
    /// either from the list — it never produces a third, parallel encoding of a
    /// key the app already names.
    func testPressingTheTwoNamedKeysSelectsThoseOptions() {
        XCTAssertEqual(record(63), .chosen(.fn))
        XCTAssertEqual(record(61), .chosen(.rightOption))
    }

    /// The right-hand modifiers and the function keys: held for the length of a
    /// sentence they do nothing else, which is the whole requirement.
    func testTheAcceptedKeysAreTheOnesThatDoNothingElse() {
        for keyCode in [UInt16(54), 60, 62, 96, 122, 111, 90] {
            XCTAssertEqual(
                record(keyCode), .chosen(.custom(keyCode: keyCode)), "keyCode \(keyCode)"
            )
        }
    }

    /// Esc and Space already have a job inside a dictation, and each refusal
    /// names which — not one shared reason for both.
    func testEscAndSpaceAreRefusedByName() {
        XCTAssertEqual(record(53), .refused(.escPauses))
        XCTAssertEqual(record(HotkeyKey.spaceKeyCode), .refused(.spaceLocks))
    }

    /// A key that types must never become the talk key: it is held down for a
    /// second and a half, and whatever it does the rest of the time it would
    /// keep doing. Same for the keys that move the cursor.
    func testKeysThatDoSomethingWhileYouTypeAreRefused() {
        // a, 1, Return, Tab, Delete, and the four arrows.
        for keyCode in [UInt16(0), 18, 36, 48, 51, 123, 124, 125, 126] {
            XCTAssertEqual(record(keyCode), .refused(.itDoesSomethingElse), "keyCode \(keyCode)")
        }
    }

    /// The left-hand modifiers get their own reason, because the fix is a
    /// specific one: the same key on the other side of the keyboard.
    func testLeftHandModifiersAreRefusedWithTheirOwnReason() {
        for keyCode in [UInt16(55), 56, 58, 59] {
            XCTAssertEqual(record(keyCode), .refused(.shortcutsUseIt), "keyCode \(keyCode)")
        }
    }

    /// Caps Lock latches: pressing it once leaves the flag raised, so a
    /// recording started by it would never hear a release. Its own reason,
    /// rather than the one that claims the key types.
    func testCapsLockIsRefusedForWhatItActuallyDoes() {
        XCTAssertEqual(record(HotkeyKey.capsLockKeyCode), .refused(.capsLockLatches))
    }

    /// The dead end this issue exists to close, in its second form: with the
    /// F-row left as media keys — the macOS shipping default — a bare F5 sends
    /// a system-defined media event and never reaches an event tap at all, so
    /// a talk key set to it would simply never fire. The recorder refuses it
    /// with a reason instead of accepting a key that produces silence.
    func testTheMediaRowIsRefusedWhileMacOSOwnsIt() {
        for keyCode in HotkeyKey.mediaRowKeyCodes {
            XCTAssertEqual(record(keyCode, fnRow: false), .refused(.macOSKeepsTheMediaRow),
                           "keyCode \(keyCode)")
            XCTAssertEqual(record(keyCode, fnRow: true), .chosen(.custom(keyCode: keyCode)),
                           "keyCode \(keyCode) with the F-row set to function keys")
        }
    }

    /// F13 and up carry no media job, so the keyboard setting cannot take them
    /// away — which is why the recorder can accept one either way.
    func testTheKeysPastF12AreTakenWhateverTheFRowSettingSays() {
        for keyCode in [UInt16(105), 107, 113, 106, 64, 79, 80, 90] {
            XCTAssertFalse(HotkeyKey.mediaRowKeyCodes.contains(keyCode), "keyCode \(keyCode)")
            for fnRow in [true, false] {
                XCTAssertEqual(record(keyCode, fnRow: fnRow), .chosen(.custom(keyCode: keyCode)),
                               "keyCode \(keyCode), fnRow \(fnRow)")
            }
        }
    }

    /// Every refusal is one sentence the user can act on — the recorder shows it
    /// where a hint would be, and a paragraph there is a wall. Each also points
    /// at a key that works, and never at an F-key: with the F-row as media keys
    /// that would be the very dead end being refused.
    func testEveryRefusalIsOneShortSentenceThatNamesAWorkingKey() {
        for refusal in HotkeyKey.Refusal.allCases {
            let message = refusal.message
            XCTAssertLessThan(message.count, 90, "\(refusal): \(message)")
            XCTAssertTrue(message.hasSuffix("."), "\(refusal): \(message)")
            XCTAssertFalse(message.contains("F5"), "\(refusal) recommends a media-row key")
        }
        // And no two of them read the same, or one of the six is decoration.
        let messages = Set(HotkeyKey.Refusal.allCases.map(\.message))
        XCTAssertEqual(messages.count, HotkeyKey.Refusal.allCases.count)
    }

    /// Every refusal case is reachable from a real keycode — an unreachable one
    /// is copy nobody can ever be shown.
    func testEveryRefusalIsReachable() {
        var seen = Set<HotkeyKey.Refusal>()
        for keyCode in UInt16(0)...127 {
            for fnRow in [true, false] {
                if case .refused(let reason) = record(keyCode, fnRow: fnRow) { seen.insert(reason) }
            }
        }
        XCTAssertEqual(seen, Set(HotkeyKey.Refusal.allCases))
    }

    // MARK: - Storage

    /// A recorded key survives a launch: the keycode goes into the defaults and
    /// comes back as the same key, so nothing has to be re-recorded.
    func testEveryKeyRoundTripsThroughStorage() {
        for key in [HotkeyKey.fn, .rightOption, .custom(keyCode: 96), .custom(keyCode: 54)] {
            XCTAssertEqual(HotkeyKey(storage: key.storageValue), key, key.displayName)
        }
    }

    /// Anything the defaults hold that this build cannot honour reads as
    /// nothing, and the store's `?? .fn` then lands on the key everybody has —
    /// never on a talk key nobody can press.
    func testGarbageAndUnacceptableKeycodesReadAsNothing() {
        for stored in ["", "option", "custom:", "custom:abc", "custom:53", "custom:49", "custom:0"] {
            XCTAssertNil(HotkeyKey(storage: stored), stored)
        }
    }

    /// Storage reads against the static set, not the live keyboard setting:
    /// turning the F-row back into media keys after choosing F5 leaves Settings
    /// showing F5 for the user to change, rather than swapping the talk key
    /// under them at the next launch.
    func testAStoredMediaRowKeySurvivesTheKeyboardSettingChanging() {
        XCTAssertEqual(HotkeyKey(storage: "custom:96"), .custom(keyCode: 96))
        XCTAssertEqual(record(96, fnRow: false), .refused(.macOSKeepsTheMediaRow),
                       "the recorder still refuses to *choose* it")
    }

    /// The whole point of the storage change: a settings store handed a
    /// recorded key gives it back after a fresh read of the same defaults.
    func testTheSettingsStoreKeepsARecordedKey() {
        let suiteName = "HotkeyKeyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = isolatedSettings("HotkeyKeyTests", defaults: defaults)
        settings.hotkeyKey = .custom(keyCode: 96)

        let reopened = isolatedSettings("HotkeyKeyTests", defaults: defaults)
        XCTAssertEqual(reopened.hotkeyKey, .custom(keyCode: 96))

        defaults.set("something else entirely", forKey: "hotkeyKey")
        XCTAssertEqual(isolatedSettings("HotkeyKeyTests", defaults: defaults).hotkeyKey, .fn)
    }

    // MARK: - Which event path a key rides

    /// A modifier is a flag on an event; a function key is a key-down and a
    /// key-up. Every key is on exactly one of the two paths, because a key on
    /// both would start a recording twice.
    func testEachKeyRidesExactlyOnePath() {
        for key in [HotkeyKey.fn, .rightOption, .custom(keyCode: 54), .custom(keyCode: 96)] {
            XCTAssertEqual(key.isModifier, key.tapKeyCode == nil, key.displayName)
        }
        XCTAssertEqual(HotkeyKey.custom(keyCode: 96).tapKeyCode, 96)
        XCTAssertNil(HotkeyKey.fn.tapKeyCode)
        XCTAssertNil(HotkeyKey.rightOption.tapKeyCode)
    }

    /// A recorded modifier is matched the way Right Option always was: the flag
    /// it raises *and* the keycode of the key that changed, so its left-hand
    /// twin cannot stand in for it.
    func testARecordedModifierMatchesItsOwnKeyAndNoOther() {
        let key = HotkeyKey.custom(keyCode: 54)  // Right Command
        XCTAssertTrue(key.matchesPress(flagsChanged(keyCode: 54, flags: [.command])))
        XCTAssertFalse(key.matchesPress(flagsChanged(keyCode: 55, flags: [.command])),
                       "Left Command is a different key")
        XCTAssertFalse(key.matchesPress(flagsChanged(keyCode: 54, flags: [])),
                       "the release is the same event with the flag gone")
    }

    /// The two shipped keys keep their exact behaviour — #226 added a case
    /// beside them, it did not re-decide them.
    func testTheShippedKeysMatchExactlyAsBefore() {
        XCTAssertTrue(HotkeyKey.fn.matchesPress(flagsChanged(keyCode: 63, flags: [.function])))
        XCTAssertFalse(HotkeyKey.fn.matchesPress(flagsChanged(keyCode: 63, flags: [])))
        XCTAssertTrue(HotkeyKey.rightOption.matchesPress(flagsChanged(keyCode: 61, flags: [.option])))
        XCTAssertFalse(HotkeyKey.rightOption.matchesPress(flagsChanged(keyCode: 58, flags: [.option])))
    }

    /// A function key never arrives as a flag, so it must never claim to match
    /// one — a `true` here would start a recording on somebody else's Shift.
    func testAFunctionKeyNeverMatchesAFlagChange() {
        let key = HotkeyKey.custom(keyCode: 96)
        for flags in [NSEvent.ModifierFlags.function, .option, .command, []] {
            XCTAssertFalse(key.matchesPress(flagsChanged(keyCode: 96, flags: flags)))
        }
    }

    // MARK: - Names

    /// Every key the recorder can produce says its own name — a row reading
    /// "Key 96" is the app failing to describe what the user just pressed.
    func testEveryAcceptableKeyHasAHumanName() {
        for keyCode in UInt16(0)...127 {
            guard case .chosen(let key) = record(keyCode) else { continue }
            XCTAssertFalse(key.displayName.hasPrefix("Key "), "keyCode \(keyCode)")
            XCTAssertFalse(key.shortName.isEmpty, "keyCode \(keyCode)")
        }
        XCTAssertEqual(HotkeyKey.custom(keyCode: 96).displayName, "F5")
        XCTAssertEqual(HotkeyKey.custom(keyCode: 54).displayName, "Right Command (\u{2318})")
        XCTAssertEqual(HotkeyKey.custom(keyCode: 54).shortName, "R\u{2318}")
        XCTAssertEqual(HotkeyKey.fn.shortName, "Fn")
        XCTAssertEqual(HotkeyKey.rightOption.shortName, "R\u{2325}")
    }
}
