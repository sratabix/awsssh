import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotKeyRecorder: View {
    @EnvironmentObject var model: AppModel
    @Binding var hotKey: HotKey?

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(label)
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .foregroundStyle(recording ? .secondary : .primary)
        .help(recording ? "Press a shortcut, or Esc to cancel" : "Click, then press a shortcut")
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording { return "Press a shortcut…" }
        return hotKey?.displayString ?? "Click to record"
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        guard !recording else { return }
        recording = true
        HotKeyCenter.shared.unregisterAll()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop()
                return nil
            }
            if let captured = HotKey(event: event) {
                hotKey = captured
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if recording {
            recording = false
            HotKeyCenter.shared.sync(model.forwards)
        }
    }
}
