import XCTest

@testable import AwssshApp

final class ForwardColorTests: XCTestCase {
    func testASixDigitHexIsNormalised() {
        XCTAssertEqual(ForwardColor.normalise("#ff453a"), "#FF453A")
        XCTAssertEqual(ForwardColor.normalise("ff453a"), "#FF453A")
        XCTAssertEqual(ForwardColor.normalise("  #FF453A  "), "#FF453A")
    }

    func testAThreeDigitHexIsExpanded() {
        XCTAssertEqual(ForwardColor.normalise("#f00"), "#FF0000")
        XCTAssertEqual(ForwardColor.normalise("abc"), "#AABBCC")
    }

    func testRubbishBecomesNoColor() {
        for value in ["", "   ", "#", "red", "#12", "#1234", "#GGGGGG", "#FF453A11", "0x11FF00"] {
            XCTAssertEqual(ForwardColor.normalise(value), "", "\(value) is not a hex color")
        }
    }

    func testFullWidthDigitsAreNotHex() {
        XCTAssertEqual(
            ForwardColor.normalise("\u{FF10}\u{FF10}\u{FF10}"), "",
            "isHexDigit accepts these, UInt32(radix:) does not")
    }

    func testEveryPresetParses() {
        for preset in ForwardColor.presets {
            XCTAssertEqual(ForwardColor.normalise(preset.hex), preset.hex, preset.name)
            XCTAssertNotNil(ForwardColor.color(preset.hex), preset.name)
        }
    }

    func testPresetHexesAreUnique() {
        let hexes = Set(ForwardColor.presets.map(\.hex))
        XCTAssertEqual(hexes.count, ForwardColor.presets.count)
    }

    func testAnUnsetColorHasNoTint() {
        XCTAssertNil(ForwardColor.color(""))
        var forward = Forward(id: 1)
        XCTAssertNil(forward.tint)
        forward.color = "#FF453A"
        XCTAssertNotNil(forward.tint)
    }

    func testAStoredColorIsNormalisedOnLoad() throws {
        let data = Data(#"{"id":1,"instance":"db","color":"ff453a"}"#.utf8)
        let forward = try JSONDecoder().decode(Forward.self, from: data)
        XCTAssertEqual(forward.color, "#FF453A", "a hand-edited file must not keep a raw value")
    }

    func testAnUnusableStoredColorIsDroppedButKeepsTheForward() throws {
        let data = Data(#"{"id":1,"instance":"db","color":"chartreuse"}"#.utf8)
        let forward = try JSONDecoder().decode(Forward.self, from: data)
        XCTAssertEqual(forward.instance, "db")
        XCTAssertEqual(forward.color, "")
    }

    func testTheColorSurvivesACodableRoundTrip() throws {
        var forward = Forward(id: 1)
        forward.instance = "db"
        forward.color = "#0A84FF"

        let data = try JSONEncoder().encode(forward)
        XCTAssertEqual(try JSONDecoder().decode(Forward.self, from: data), forward)
    }

    func testAColorIsNotRequiredToValidate() {
        var forward = Forward(id: 1)
        forward.instance = "db"
        forward.localPort = "5432"
        forward.remotePort = "5432"
        forward.color = "not a color"
        XCTAssertNil(forward.validate(), "a bad color is normalised away, never a save error")
    }
}
