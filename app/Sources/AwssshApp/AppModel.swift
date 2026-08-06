import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    static let reconnectCooldown: TimeInterval = 15
    static let loginPollInterval: TimeInterval = 60
    static let loginCheckInterval: TimeInterval = 300
    static let autoSignInBackoff: TimeInterval = 900

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
    @Published var expandedError: Int?
    @Published var importError: String?
    @Published var logins: [SSOLogin] = []
    @Published var checks: [String: LoginCheck] = [:]
    @Published var signingIn: String?
    @Published var signInError: String?
    @Published var signInPending = false
    @Published var showingSettings = false
    @Published var showingWhatsNew = false
    @Published var showingWebSignIn = false
    @Published private(set) var whatsNew: [ReleaseNotes.Section] = []
    @Published var showSSO = Preferences.showSSO {
        didSet {
            Preferences.showSSO = showSSO
            if !showSSO { autoSignIn = false }
        }
    }
    @Published var autoSignIn = Preferences.autoSignIn {
        didSet { Preferences.autoSignIn = autoSignIn }
    }
    @Published var collapsedGroups = Preferences.collapsedGroups {
        didSet { Preferences.collapsedGroups = collapsedGroups }
    }

    let updates = UpdateChecker()
    let installer = Installer()

    private let helper = Helper()
    private let forms = FormWindowPresenter()
    private let settings = SettingsWindowPresenter()
    private let news = WhatsNewWindowPresenter()
    private let webWindow = WebSignInWindowPresenter()
    private let attached: Bool
    private var nextID = 1
    private var stamp: Date?
    private var awaitingRestart: Set<Int> = []
    private var wakeObserver: NSObjectProtocol?
    let network = NetworkMonitor()
    let screen = ScreenLock()
    let presentation = Presentation()
    let webSignIn = WebSignIn()
    private var lastReconnect: Date?
    private var loginPoll: Timer?
    private var lastChecked: [String: Date] = [:]
    private var lastAutoSignIn: [String: Date] = [:]

    init(attached: Bool = true) {
        self.attached = attached

        let loaded = Store.load()
        forwards = loaded.forwards
        dataNotice = loaded.notice
        stamp = loaded.stamp
        nextID = (forwards.map(\.id).max() ?? 0) + 1

        guard attached else { return }

        forms.attach(to: self)
        settings.attach(to: self)
        news.attach(to: self)
        webWindow.attach(to: self)
        helper.onMessage = { [weak self] msg in self?.handle(msg) }
        helper.start()
        helper.send(HelperCommand(cmd: "profiles"))
        refreshLogins()

        HotKeyCenter.shared.onFire = { [weak self] id in
            guard let self, let forward = self.forwards.first(where: { $0.id == id }) else { return }
            self.toggle(forward)
        }
        HotKeyCenter.shared.sync(forwards)

        let checker = updates
        installer.fetchLatest = { await checker.fetchLatest() }
        installer.adopt = { checker.adopt($0) }
        installer.quit = { [weak self] in self?.quit() }
        updates.start()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLogins()
                self?.reconnectLiveForwards(reason: .sleep)
            }
        }

        network.onChange = { [weak self] in
            self?.reconnectLiveForwards(reason: .network)
            self?.maybeAutoSignIn()
        }
        network.start()

        screen.onUnlock = { [weak self] in
            self?.refreshLogins()
            self?.maybeAutoSignIn()
        }
        screen.start()

        announceUpdate()

        loginPoll = Timer.scheduledTimer(
            withTimeInterval: AppModel.loginPollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshLogins() }
        }
    }

    deinit {
        loginPoll?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func refreshLogins() {
        helper.send(HelperCommand(cmd: "logins"))
    }

    func checkLogins(now: Date = Date()) {
        for login in logins {
            if let last = lastChecked[login.label],
                now.timeIntervalSince(last) < Self.loginCheckInterval
            {
                continue
            }
            lastChecked[login.label] = now
            helper.send(HelperCommand(cmd: "checkLogin", login: login.label))
        }
    }

    func check(for login: SSOLogin) -> LoginCheck { checks[login.label] ?? .unknown }

    var unscopedLogins: [SSOLogin] { logins.filter { !$0.scoped && !$0.refreshable } }

    func signedOutLogins(at now: Date) -> [SSOLogin] {
        logins.filter { !$0.signedIn(at: now, check: check(for: $0)) }
    }

    var deferAutoSignIn: Bool {
        !network.reachable || screen.locked || presentation.active
    }

    func maybeAutoSignIn(now: Date = Date()) {
        var expired: [SSOLogin] = []
        for login in logins {
            if login.signedIn(at: now, check: check(for: login)) {
                lastAutoSignIn[login.label] = nil
            } else {
                expired.append(login)
            }
        }

        guard autoSignIn, showSSO, signingIn == nil, !deferAutoSignIn else { return }

        for login in expired {
            if let last = lastAutoSignIn[login.label],
                now.timeIntervalSince(last) < Self.autoSignInBackoff
            {
                continue
            }
            lastAutoSignIn[login.label] = now
            signIn(login, silent: true)
            return
        }
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

    var needsAttention: Bool {
        let live = Set(forwards.map(\.id))
        return states.contains { id, state in
            live.contains(id) && (state.run == .reconnecting || state.run == .error)
        }
    }

    func state(for forward: Forward) -> EntryState { states[forward.id] ?? EntryState() }

    func toggleErrorDetail(_ id: Int) {
        expandedError = expandedError == id ? nil : id
    }

    func dismissError(_ forward: Forward) {
        guard state(for: forward).run == .error else { return }
        update(forward.id) {
            $0.run = .stopped
            $0.detail = ""
            $0.error = ""
            $0.since = nil
        }
    }

    var errored: [Forward] { forwards.filter { state(for: $0).run == .error } }

    func dismissErrors(_ list: [Forward]) {
        for forward in list { dismissError(forward) }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func share(_ forward: Forward) {
        importError = nil
        copyToClipboard(Share.encode(forward))
    }

    func importFromClipboard() {
        importShared(NSPasteboard.general.string(forType: .string) ?? "")
    }

    func importShared(_ text: String) {
        do {
            let payload = try Share.decode(text)
            importError = nil
            pendingDelete = nil
            formError = nil
            editing = Share.forward(from: payload, id: nextID)
            showingForm = true
        } catch {
            importError = error.localizedDescription
        }
    }

    func openSettings() {
        showingSettings = true
    }

    func closeSettings() {
        showingSettings = false
    }

    func announceUpdate(current: String = AppInfo.version, notes: String = ReleaseNotes.bundled()) {
        let seen = Preferences.lastSeenVersion
        Preferences.lastSeenVersion = current
        guard !seen.isEmpty, seen != current else { return }

        let sections = ReleaseNotes.forUpdate(from: seen, to: current, in: notes)
        guard !sections.isEmpty else { return }
        whatsNew = sections
        showingWhatsNew = true
    }

    func openWhatsNew(current: String = AppInfo.version, notes: String = ReleaseNotes.bundled()) {
        whatsNew = ReleaseNotes.forCurrent(current, in: notes)
        showingWhatsNew = true
    }

    func closeWhatsNew() {
        showingWhatsNew = false
    }

    func revealStore() {
        let target = Store.revealTarget()
        if target.hasDirectoryPath {
            NSWorkspace.shared.open(target)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    func signIn(_ login: SSOLogin, silent: Bool = false) {
        guard signingIn == nil else { return }
        signInError = nil
        signingIn = login.label
        signInPending = false

        if attached {
            webSignIn.onFailure = { [weak self] message in self?.webSignInFailed(message) }
        }
        if !silent { showingWebSignIn = true }
        helper.send(HelperCommand(cmd: "ssoLogin", login: login.label))
    }

    private func revealWebSignIn() {
        guard signingIn != nil else { return }
        showingWebSignIn = true
    }

    private func webSignInFailed(_ message: String) {
        guard signingIn != nil else { return }
        signInError = "the sign-in window could not load: \(message)"
        revealWebSignIn()
    }

    func cancelWebSignIn() {
        showingWebSignIn = false
        webSignIn.reset()
    }

    private func endWebSignIn() {
        showingWebSignIn = false
        if attached { webSignIn.reset() }
    }

    var groups: [ForwardGroup] { ForwardGroup.build(from: forwards) }

    var groupNames: [String] { ForwardGroup.names(in: forwards) }

    func isCollapsed(_ group: ForwardGroup) -> Bool {
        collapsedGroups.contains(group.name)
    }

    func toggleCollapsed(_ group: ForwardGroup) {
        if collapsedGroups.contains(group.name) {
            collapsedGroups.remove(group.name)
        } else {
            collapsedGroups.insert(group.name)
        }
    }

    func anyLive(in list: [Forward]) -> Bool {
        list.contains { isLive(state(for: $0).run) }
    }

    func runningCount(in list: [Forward]) -> Int {
        list.filter { state(for: $0).run == .running }.count
    }

    func toggleAll(_ list: [Forward]) {
        anyLive(in: list) ? stopAll(list) : startAll(list)
    }

    func startAll(_ list: [Forward]) {
        for forward in list {
            guard !isLive(state(for: forward).run), forward.validate() == nil else { continue }
            guard liveForward(onLocalPort: forward.localPort, excluding: forward.id) == nil else {
                continue
            }
            toggle(forward)
        }
    }

    func stopAll(_ list: [Forward]) {
        for forward in list where isLive(state(for: forward).run) {
            toggle(forward)
        }
    }

    private func isLive(_ run: RunState) -> Bool {
        switch run {
        case .starting, .running, .reconnecting, .stopping: return true
        case .stopped, .error: return false
        }
    }

    func toggle(_ forward: Forward) {
        switch state(for: forward).run {
        case .running, .starting, .reconnecting:
            awaitingRestart.remove(forward.id)
            update(forward.id) {
                $0.run = .stopping
                $0.since = nil
            }
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
                $0.since = nil
            }
            sendStart(forward)
        }
    }

    private func sendStart(_ forward: Forward) {
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

    func reconnectLiveForwards(reason: ReconnectReason, now: Date = Date()) {
        if let lastReconnect, now.timeIntervalSince(lastReconnect) < Self.reconnectCooldown { return }

        let live = forwards.filter { state(for: $0).run == .running }
        guard !live.isEmpty else { return }
        lastReconnect = now

        for forward in live {
            awaitingRestart.insert(forward.id)
            update(forward.id) {
                $0.run = .reconnecting
                $0.detail = reason.rawValue
                $0.error = ""
                $0.since = nil
            }
            helper.send(HelperCommand(cmd: "stop", id: forward.id))
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

    func saveForm(_ draft: Forward) {
        var forward = draft
        forward.color = ForwardColor.normalise(forward.color)
        forward.group = forward.group.trimmingCharacters(in: .whitespaces)

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
        awaitingRestart.remove(forward.id)
        helper.send(HelperCommand(cmd: "stop", id: forward.id))
        forwards.removeAll { $0.id == forward.id }
        states[forward.id] = nil
        if expandedError == forward.id { expandedError = nil }
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
        refreshLogins()

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
            case .starting, .running, .reconnecting, .stopping: return true
            case .stopped, .error: return false
            }
        }
    }

    private func update(_ id: Int, _ mutate: (inout EntryState) -> Void) {
        var s = states[id] ?? EntryState()
        mutate(&s)
        states[id] = s
        if s.run != .error, expandedError == id { expandedError = nil }
    }

    func handle(_ msg: HelperMessage, now: Date = Date()) {
        switch msg.event {
        case "started":
            if let id = msg.id {
                awaitingRestart.remove(id)
                update(id) {
                    $0.run = .running
                    $0.detail = msg.detail ?? ""
                    $0.error = ""
                    $0.since = now
                }
            }
        case "exited":
            if let id = msg.id {
                if awaitingRestart.remove(id) != nil,
                    let forward = forwards.first(where: { $0.id == id })
                {
                    sendStart(forward)
                    return
                }
                let requested = states[id]?.run == .stopping
                if let e = msg.error, !e.isEmpty, !requested {
                    let ran = states[id]?.since.map {
                        "ran for \(EntryState.uptimeLabel(now.timeIntervalSince($0)))"
                    }
                    update(id) {
                        $0.run = .error
                        $0.error = e
                        $0.detail = ran ?? ""
                        $0.since = nil
                    }
                } else {
                    update(id) {
                        $0.run = .stopped
                        $0.detail = ""
                        $0.error = ""
                        $0.since = nil
                    }
                }
            }
        case "profiles":
            profiles = msg.profiles ?? []
        case "logins":
            logins = (msg.logins ?? []).map(SSOLogin.init)
            checkLogins(now: now)
            maybeAutoSignIn(now: now)
        case "loginCheck":
            if let label = msg.detail {
                checks[label] = LoginCheck(msg.state)
            }
            maybeAutoSignIn(now: now)
        case "authorizeURL":
            guard signingIn == msg.detail, attached,
                let raw = msg.url, let url = URL(string: raw)
            else { break }
            webSignIn.load(url)
        case "ssoLoginPending":
            guard signingIn != nil, signingIn == msg.detail else { break }
            signInPending = true
            revealWebSignIn()
        case "ssoLogin":
            if signingIn == nil || signingIn == msg.detail {
                signingIn = nil
                signInPending = false
                if signInError == nil || msg.error != nil { signInError = msg.error }
                endWebSignIn()
            }
            if msg.error == nil, let label = msg.detail {
                checks[label] = nil
                lastChecked[label] = nil
            }
        default:
            break
        }
    }
}
