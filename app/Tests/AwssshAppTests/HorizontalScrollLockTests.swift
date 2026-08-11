import AppKit
import XCTest

@testable import AwssshApp

final class HorizontalScrollLockTests: XCTestCase {
    private func clip(x: CGFloat, y: CGFloat) -> NSClipView {
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 465, height: 420))
        clip.setBoundsOrigin(NSPoint(x: x, y: y))
        return clip
    }

    @MainActor func testASidewaysOffsetIsPinnedBack() {
        let view = clip(x: 120, y: 0)
        HorizontalScrollLock.LockView.pin(view)
        XCTAssertEqual(view.bounds.origin.x, 0, "the list has nothing to reveal sideways")
    }

    @MainActor func testTheVerticalOffsetIsLeftAlone() {
        let view = clip(x: 120, y: 240)
        HorizontalScrollLock.LockView.pin(view)
        XCTAssertEqual(view.bounds.origin.y, 240, "pinning the wrong axis would fight the list")
    }

    @MainActor func testAnUnscrolledClipViewIsNotTouched() {
        let view = clip(x: 0, y: 100)
        HorizontalScrollLock.LockView.pin(view)
        XCTAssertEqual(view.bounds.origin.x, 0)
        XCTAssertEqual(view.bounds.origin.y, 100)
    }

    @MainActor func testSubPixelDriftIsNotWorthAWriteBack() {
        let view = clip(x: HorizontalScrollLock.slack / 2, y: 0)
        HorizontalScrollLock.LockView.pin(view)
        XCTAssertEqual(
            view.bounds.origin.x, HorizontalScrollLock.slack / 2,
            "writing on every bounds change would re-enter the notification forever")
    }

    @MainActor func testANegativeOffsetIsPinnedToo() {
        let view = clip(x: -60, y: 0)
        HorizontalScrollLock.LockView.pin(view)
        XCTAssertEqual(view.bounds.origin.x, 0, "dragging the other way is the same bug")
    }
}
