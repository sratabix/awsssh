import AppKit
import XCTest

@testable import AwssshIcon

final class AppIconTests: XCTestCase {
    func testTheSymbolResolves() {
        XCTAssertNotNil(
            NSImage(systemSymbolName: AppIcon.symbolName, accessibilityDescription: nil),
            "\(AppIcon.symbolName) must exist or both the menubar and the .icns fall back to nothing")
    }

    func testBothMenuBarVariantsAreTemplates() {
        XCTAssertTrue(
            AppIcon.menuBar(attention: false).isTemplate,
            "a non-template menubar image ignores the light/dark menubar")
        XCTAssertTrue(AppIcon.menuBar(attention: true).isTemplate)
    }

    func testTheBadgeMakesRoomForItself() {
        let plain = AppIcon.menuBar(attention: false).size
        let badged = AppIcon.menuBar(attention: true).size

        XCTAssertGreaterThan(badged.width, plain.width, "the badge must not be drawn over the glyph")
        XCTAssertEqual(badged.height, plain.height, "the menubar sets the height; only width may grow")
    }

    func testBothVariantsHaveARealSize() {
        for attention in [false, true] {
            let size = AppIcon.menuBar(attention: attention).size
            XCTAssertGreaterThan(size.width, 0, "attention: \(attention)")
            XCTAssertGreaterThan(size.height, 0, "attention: \(attention)")
        }
    }

    func testTheIconStillRenders() {
        XCTAssertNotNil(AppIcon.png(size: 512), "make app turns this into Awsssh.icns")
    }
}
