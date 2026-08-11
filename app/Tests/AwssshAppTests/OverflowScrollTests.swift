import XCTest

@testable import AwssshApp

final class OverflowScrollTests: XCTestCase {
    private func metrics(_ content: CGFloat, scrolled: CGFloat = 0) -> OverflowMetrics {
        OverflowMetrics(content: content, viewport: 242, scrolled: scrolled)
    }

    func testTextThatFitsDoesNotScroll() {
        XCTAssertFalse(
            metrics(180).overflows,
            "a name with room to spare must pass the gesture to the list")
    }

    func testAnExactFitDoesNotScroll() {
        XCTAssertFalse(metrics(242).overflows)
    }

    func testSubPixelOverflowDoesNotScroll() {
        XCTAssertFalse(
            metrics(242.4).overflows,
            "rounding must not make a row that looks complete draggable")
    }

    func testTextWiderThanTheRowScrolls() {
        XCTAssertTrue(metrics(822).overflows)
    }

    func testTheChevronNeverPromisesAScrollThatCannotHappen() {
        for content in stride(from: 0.0, through: 400.0, by: 0.5) {
            for scrolled in stride(from: 0.0, through: 200.0, by: 0.5) {
                let m = metrics(content, scrolled: scrolled)
                if m.showsMore {
                    XCTAssertTrue(
                        m.overflows,
                        "content \(content) shows the chevron on a row that cannot scroll")
                }
            }
        }
    }

    func testScrollingToTheEndDoesNotDisableTheWayBack() {
        let m = metrics(400, scrolled: 158)
        XCTAssertFalse(m.showsMore, "nothing left to reveal")
        XCTAssertTrue(
            m.overflows,
            "the row must stay scrollable at the far end, or it cannot be scrolled back")
    }
}
