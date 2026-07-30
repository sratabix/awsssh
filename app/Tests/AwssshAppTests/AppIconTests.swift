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

        XCTAssertGreaterThan(
            badged.width - plain.width, 5,
            "widening by less than the badge means the knockout eats the glyph instead of sitting beside it")
        XCTAssertEqual(badged.height, plain.height, "the menubar sets the height; only width may grow")
    }

    func testNeitherVariantBakesABitmap() {
        for attention in [false, true] {
            for rep in AppIcon.menuBar(attention: attention).representations {
                XCTAssertEqual(
                    rep.pixelsWide, 0,
                    "attention: \(attention) — a baked rep pins the icon to one screen's scale factor")
                XCTAssertEqual(rep.pixelsHigh, 0, "attention: \(attention)")
            }
        }
    }

    func testBothVariantsFitTheMenuBar() {
        for attention in [false, true] {
            XCTAssertLessThan(
                AppIcon.menuBar(attention: attention).size.height, AppIcon.menuBarHeight + 0.001,
                "attention: \(attention) — anything taller is clipped top and bottom, not scaled down")
        }
    }

    func testTheHeightStaysInsideTheMenuBarsBudget() {
        XCTAssertLessThan(
            AppIcon.menuBarHeight, NSStatusBar.system.thickness - 3,
            "a 22pt bar pads roughly 3pt top and bottom; a taller glyph is sliced flat")
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
