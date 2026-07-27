import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var forwards: [Forward] = []
    @Published var states: [Int: EntryState] = [:]
    @Published var profiles: [String] = []
    @Published var editing: Forward?
    @Published var showingForm = false
    @Published var formError: String?
    @Published var pendingDelete: Forward?
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
    @Published var launchAtLoginError: String?
    @Published var dataNotice: String?

    let updates = UpdateChecker()

    private let helper = Helper()
    private let attached: Bool
    private var nextID = 1
    private var stamp: Date?

    init(attached: Bool = true) {
        self.attached = attached

        let loaded = Store.load()
        forwards = loaded.forwards
        dataNotice = loaded.notice
        stamp = loaded.stamp
        nextID = (forwards.map(\.id).max() ?? 0) + 1

        guard attached else { return }

        helper.onMessage = { [weak self] msg in self?.handle(msg) }
        helper.start()
        helper.send(HelperCommand(cmd: "profiles"))

        HotKeyCenter.shared.onFire = { [weak self] id in
            guard let self, let forward = self.forwards.first(where: { $0.id == id }) else { return }
            self.toggle(forward)
        }
        HotKeyCenter.shared.sync(forwards)
        updates.start()
    }

    private func syncHotKeys() {
        guard attached else { return }
        HotKeyCenter.shared.sync(forwards)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = LaunchAtLogin.set(enabled)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    var runningCount: Int { states.values.filter { $0.run == .running }.count }

    func state(for forward: Forward) -> EntryState { states[forward.id] ?? EntryState() }

    func toggle(_ forward: Forward) {
        switch state(for: forward).run {
        case .running, .starting:
            update(forward.id) { $0.run = .stopping }
            helper.send(HelperCommand(cmd: "stop", id: forward.id))
        case .stopping:
            break
        default:
            if let invalid = forward.validate() {
                update(forward.id) {
                    $0.run = .error
                    $0.error = invalid
                }
                return
            }
            if let other = liveForward(onLocalPort: forward.localPort, excluding: forward.id) {
                update(forward.id) {
                    $0.run = .error
                    $0.error = "local port \(forward.localPort) is already in use by “\(other.title)”"
                }
                return
            }
            update(forward.id) {
                $0.run = .starting
                $0.error = ""
            }
            helper.send(
                HelperCommand(
                    cmd: "start",
                    id: forward.id,
                    forward: HelperForward(
                        profile: forward.profile,
                        region: forward.region,
                        instance: forward.instance,
                        local: forward.localPort,
                        host: forward.host,
                        remote: forward.remotePort
                    )
                ))
        }
    }

    func beginAdd() {
        pendingDelete = nil
        editing = Forward(id: nextID)
        formError = nil
        showingForm = true
    }

    func beginEdit(_ forward: Forward) {
        pendingDelete = nil
        editing = forward
        formError = nil
        showingForm = true
    }

    func saveForm(_ forward: Forward) {
        if let err = forward.validate() {
            formError = err
            return
        }
        if let hotKey = forward.hotKey,
            let clash = HotKeyCenter.conflict(for: hotKey, in: forwards, excluding: forward.id)
        {
            formError = "\(hotKey.displayString) is already used by “\(clash.title)”."
            return
        }
        if let idx = forwards.firstIndex(where: { $0.id == forward.id }) {
            forwards[idx] = forward
        } else {
            forwards.append(forward)
            nextID = max(nextID, forward.id + 1)
        }
        persist()
        syncHotKeys()
        showingForm = false
        editing = nil
    }

    func cancelForm() {
        showingForm = false
        editing = nil
        formError = nil
    }

    func confirmDelete(_ forward: Forward) {
        pendingDelete = forward
    }

    func cancelDelete() {
        pendingDelete = nil
    }

    func delete(_ forward: Forward) {
        helper.send(HelperCommand(cmd: "stop", id: forward.id))
        forwards.removeAll { $0.id == forward.id }
        states[forward.id] = nil
        persist()
        syncHotKeys()
        pendingDelete = nil
    }

    func quit() {
        if attached {
            HotKeyCenter.shared.unregisterAll()
        }
        helper.shutdown()
        NSApp.terminate(nil)
    }

    func refreshIfChanged() {
        helper.send(HelperCommand(cmd: "profiles"))

        guard !showingForm, pendingDelete == nil else { return }
        guard let onDisk = Store.stamp(), onDisk != stamp else { return }

        let loaded = Store.load()
        let running = Set(states.filter { $0.value.run != .stopped }.keys)
        guard running.isSubset(of: Set(loaded.forwards.map(\.id))) else {
            dataNotice = "forwards.json changed on disk; not reloading while forwards are running."
            return
        }

        forwards = loaded.forwards
        dataNotice = loaded.notice
        stamp = loaded.stamp
        nextID = (forwards.map(\.id).max() ?? 0) + 1
        syncHotKeys()
    }

    private func persist() {
        stamp = Store.save(forwards, expecting: stamp)
    }

    func liveForward(onLocalPort localPort: String, excluding id: Int) -> Forward? {
        forwards.first { f in
            guard f.id != id, f.localPort == localPort else { return false }
            switch state(for: f).run {
            case .starting, .running, .stopping: return true
            case .stopped, .error: return false
            }
        }
    }

    private func update(_ id: Int, _ mutate: (inout EntryState) -> Void) {
        var s = states[id] ?? EntryState()
        mutate(&s)
        states[id] = s
    }

    func handle(_ msg: HelperMessage) {
        switch msg.event {
        case "started":
            if let id = msg.id {
                update(id) {
                    $0.run = .running
                    $0.detail = msg.detail ?? ""
                    $0.error = ""
                }
            }
        case "exited":
            if let id = msg.id {
                if let e = msg.error, !e.isEmpty {
                    update(id) {
                        $0.run = .error
                        $0.error = e
                    }
                } else {
                    update(id) {
                        $0.run = .stopped
                        $0.detail = ""
                    }
                }
            }
        case "profiles":
            profiles = msg.profiles ?? []
        default:
            break
        }
    }
}
