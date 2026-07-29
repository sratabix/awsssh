import AppKit
import SwiftUI

@MainActor
final class WindowHost: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private var window: NSWindow?

    func show<Content: View>(title: String, content: () -> Content) {
        let window = self.window ?? make(content())
        window.title = title
        window.layoutIfNeeded()
        centre(window)
        activate()
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func make(_ content: some View) -> NSWindow {
        let created = NSWindow(contentViewController: NSHostingController(rootView: content))
        created.styleMask = [.titled, .closable]
        created.isReleasedWhenClosed = false
        created.level = .floating
        created.delegate = self
        window = created
        return created
    }

    private func centre(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            window.center()
            return
        }
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(
            NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }

    private func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func windowWillClose(_: Notification) {
        Task { @MainActor in self.onClose?() }
    }
}
