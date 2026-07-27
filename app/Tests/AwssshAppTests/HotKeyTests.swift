import AppKit
import Carbon.HIToolbox
import XCTest
@testable import AwssshApp

final class HotKeyTests: XCTestCase {
    private func event(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func testRejectsBareKey() {
        XCTAssertNil(HotKey(event: event(keyCode: UInt16(kVK_ANSI_K), flags: [])))
    }

    func testRejectsShiftOnly() {
        XCTAssertNil(HotKey(event: event(keyCode: UInt16(kVK_ANSI_K), flags: [.shift])))
    }

    func testCapturesModifierCombo() {
        let hotKey = HotKey(event: event(keyCode: UInt16(kVK_ANSI_K), flags: [.command, .shift]))
        XCTAssertEqual(hotKey?.keyCode, UInt32(kVK_ANSI_K))
        XCTAssertEqual(hotKey?.displayString, "⇧⌘K")
    }

    func testDisplayStringOrdersModifiersLikeMacOS() {
        let all = HotKey(event: event(keyCode: UInt16(kVK_ANSI_A), flags: [.command, .option, .control, .shift]))
        XCTAssertEqual(all?.displayString, "⌃⌥⇧⌘A")
    }

    func testDisplayStringNamesSpecialKeys() {
        let space = HotKey(event: event(keyCode: UInt16(kVK_Space), flags: [.control]))
        XCTAssertEqual(space?.displayString, "⌃Space")

        let arrow = HotKey(event: event(keyCode: UInt16(kVK_UpArrow), flags: [.option]))
        XCTAssertEqual(arrow?.displayString, "⌥↑")
    }

    func testRoundTripsThroughJSON() throws {
        let original = HotKey(event: event(keyCode: UInt16(kVK_ANSI_J), flags: [.command, .control]))
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(HotKey?.self, from: data), original)
    }

    func testConflictFindsForwardSharingTheHotKey() {
        let hotKey = HotKey(event: event(keyCode: UInt16(kVK_ANSI_P), flags: [.command, .option]))!
        var mine = Forward(id: 1)
        mine.name = "mine"
        mine.hotKey = hotKey
        var other = Forward(id: 2)
        other.name = "other"
        other.hotKey = hotKey
        let unbound = Forward(id: 3)

        let forwards = [mine, other, unbound]
        XCTAssertEqual(HotKeyCenter.conflict(for: hotKey, in: forwards, excluding: 1)?.id, 2)
        XCTAssertNil(HotKeyCenter.conflict(for: hotKey, in: [mine, unbound], excluding: 1))
    }
}

extension HotKeyTests {
    func testIsUsableRequiresANonShiftModifier() {
        XCTAssertFalse(HotKey.isUsable(keyCode: 11, modifiers: 0))
        XCTAssertFalse(HotKey.isUsable(keyCode: 11, modifiers: UInt32(shiftKey)))
        XCTAssertTrue(HotKey.isUsable(keyCode: 11, modifiers: UInt32(cmdKey)))
        XCTAssertTrue(HotKey.isUsable(keyCode: 11, modifiers: UInt32(optionKey)))
        XCTAssertTrue(HotKey.isUsable(keyCode: 11, modifiers: UInt32(controlKey)))
        XCTAssertTrue(HotKey.isUsable(keyCode: 11, modifiers: UInt32(cmdKey | shiftKey)))
    }

    func testIsUsableRejectsUnknownModifierBits() {
        XCTAssertFalse(HotKey.isUsable(keyCode: 11, modifiers: 0xFFFF_FFFF))
        XCTAssertFalse(HotKey.isUsable(keyCode: 11, modifiers: UInt32(cmdKey) | 0x8000_0000))
    }

    func testIsUsableRejectsOutOfRangeKeyCodes() {
        XCTAssertTrue(HotKey.isUsable(keyCode: 0x7F, modifiers: UInt32(cmdKey)))
        XCTAssertFalse(HotKey.isUsable(keyCode: 0x80, modifiers: UInt32(cmdKey)))
        XCTAssertFalse(HotKey.isUsable(keyCode: 99999, modifiers: UInt32(cmdKey)))
    }

    func testMemberwiseInitRejectsUnusableCombinations() {
        XCTAssertNil(HotKey(keyCode: 11, carbonModifiers: 0))
        XCTAssertNotNil(HotKey(keyCode: 11, carbonModifiers: UInt32(cmdKey)))
    }

    func testDecodingRejectsAnUnusableHotKey() {
        let bare = Data(#"{"keyCode":11,"modifiers":0}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(HotKey.self, from: bare))

        let good = Data(#"{"keyCode":11,"modifiers":256}"#.utf8)
        XCTAssertNotNil(try? JSONDecoder().decode(HotKey.self, from: good))
    }

    func testDecodingRequiresBothFields() {
        XCTAssertThrowsError(try JSONDecoder().decode(HotKey.self, from: Data(#"{"keyCode":11}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(HotKey.self, from: Data(#"{"modifiers":256}"#.utf8)))
    }

    func testEqualAndHashableAgree() {
        let a = HotKey(keyCode: 11, carbonModifiers: UInt32(cmdKey))!
        let b = HotKey(keyCode: 11, carbonModifiers: UInt32(cmdKey))!
        let c = HotKey(keyCode: 12, carbonModifiers: UInt32(cmdKey))!

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertEqual(Set([a, c]).count, 2)
    }

    func testDisplayStringNamesFunctionKeys() {
        for (code, name) in [(kVK_F1, "F1"), (kVK_F5, "F5"), (kVK_F12, "F12")] {
            let hotKey = HotKey(keyCode: UInt32(code), carbonModifiers: UInt32(cmdKey))
            XCTAssertEqual(hotKey?.displayString, "⌘" + name)
        }
    }

    func testDisplayStringNamesPunctuation() {
        let pairs: [(Int, String)] = [
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_Slash, "/"),
            (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Semicolon, ";"),
        ]
        for (code, name) in pairs {
            let hotKey = HotKey(keyCode: UInt32(code), carbonModifiers: UInt32(controlKey))
            XCTAssertEqual(hotKey?.displayString, "⌃" + name)
        }
    }

    func testDisplayStringNamesDigits() {
        for (code, name) in [(kVK_ANSI_0, "0"), (kVK_ANSI_5, "5"), (kVK_ANSI_9, "9")] {
            let hotKey = HotKey(keyCode: UInt32(code), carbonModifiers: UInt32(cmdKey))
            XCTAssertEqual(hotKey?.displayString, "⌘" + name)
        }
    }

    func testDisplayStringFallsBackForUnmappedKeys() {
        let hotKey = HotKey(keyCode: 0x6E, carbonModifiers: UInt32(cmdKey))
        XCTAssertTrue(hotKey?.displayString.hasPrefix("⌘") == true)
        XCTAssertFalse(hotKey?.displayString.isEmpty == true)
    }

    func testDisplayStringNamesEveryNavigationKey() {
        let pairs: [(Int, String)] = [
            (kVK_Return, "↩"), (kVK_Tab, "⇥"), (kVK_Delete, "⌫"), (kVK_Escape, "⎋"),
            (kVK_ForwardDelete, "⌦"), (kVK_Home, "↖"), (kVK_End, "↘"),
            (kVK_PageUp, "⇞"), (kVK_PageDown, "⇟"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_DownArrow, "↓"),
        ]
        for (code, name) in pairs {
            let hotKey = HotKey(keyCode: UInt32(code), carbonModifiers: UInt32(optionKey))
            XCTAssertEqual(hotKey?.displayString, "⌥" + name)
        }
    }

    func testConflictIgnoresForwardsWithoutAShortcut() {
        let hotKey = HotKey(keyCode: 11, carbonModifiers: UInt32(cmdKey))!
        var bound = Forward(id: 1)
        bound.hotKey = hotKey
        let unbound = Forward(id: 2)

        XCTAssertNil(HotKeyCenter.conflict(for: hotKey, in: [unbound], excluding: 1))
        XCTAssertEqual(HotKeyCenter.conflict(for: hotKey, in: [bound, unbound], excluding: 2)?.id, 1)
    }

    func testConflictReturnsTheFirstClash() {
        let hotKey = HotKey(keyCode: 11, carbonModifiers: UInt32(cmdKey))!
        var a = Forward(id: 1)
        a.hotKey = hotKey
        var b = Forward(id: 2)
        b.hotKey = hotKey

        XCTAssertEqual(HotKeyCenter.conflict(for: hotKey, in: [a, b], excluding: 3)?.id, 1)
    }

    func testConflictOnAnEmptyListIsNil() {
        let hotKey = HotKey(keyCode: 11, carbonModifiers: UInt32(cmdKey))!
        XCTAssertNil(HotKeyCenter.conflict(for: hotKey, in: [], excluding: 1))
    }
}
