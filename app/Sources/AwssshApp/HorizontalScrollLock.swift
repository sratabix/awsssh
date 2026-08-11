import AppKit
import SwiftUI

struct HorizontalScrollLock: NSViewRepresentable {
    static let slack: CGFloat = 0.01

    func makeNSView(context: Context) -> NSView { LockView() }

    func updateNSView(_ view: NSView, context: Context) {}

    final class LockView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard observer == nil, let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clip,
                queue: .main
            ) { [weak clip] _ in
                guard let clip else { return }
                LockView.pin(clip)
            }
        }

        static func pin(_ clip: NSClipView) {
            guard abs(clip.bounds.origin.x) > HorizontalScrollLock.slack else { return }
            clip.setBoundsOrigin(NSPoint(x: 0, y: clip.bounds.origin.y))
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
