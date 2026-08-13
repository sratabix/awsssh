import SwiftUI

struct ContentView: View {
    static let minWidth: CGFloat = 380
    static let maxWidth: CGFloat = 560
    static let listMaxHeight: CGFloat = 420

    static func erroredLabel(_ count: Int) -> String {
        count == 1 ? "1 forward errored" : "\(count) forwards errored"
    }

    @EnvironmentObject var model: AppModel

    var body: some View {
        listView
            .frame(minWidth: ContentView.minWidth, maxWidth: ContentView.maxWidth)
            .padding(12)
            .onAppear { model.refreshIfChanged() }
    }

    private var listView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Port forwards").font(.headline)
                Button(action: { model.openWhatsNew() }) {
                    HStack(spacing: 4) {
                        Text(AppInfo.displayVersion)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        if model.whatsNewUnread {
                            Text("New")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.tint, in: Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(
                    model.whatsNewUnread
                        ? "See what changed in \(AppInfo.displayVersion)"
                        : "What's new in \(AppInfo.displayVersion)")
                Spacer()
                Text("\(model.forwards.count) saved · \(model.runningCount) running")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if model.entries.isEmpty {
                Text("No forwards yet — add one below.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                let groups = model.groups
                ScrollingList(maxHeight: ContentView.listMaxHeight) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(groups) { group in
                            GroupHeader(group: group, soleGroup: groups.count == 1)
                            if !model.isCollapsed(group) {
                                ForEach(group.forwards) { forward in
                                    ForwardRow(forward: forward)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            SignInRow()
            if let err = model.launchAtLoginError {
                NoticeText(err)
            }
            if let notice = model.dataNotice {
                NoticeText(notice)
            }
            if let err = model.importError {
                NoticeText(err)
            }
            let errored = model.errored
            if !errored.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(ContentView.erroredLabel(errored.count)).font(.caption)
                    Spacer()
                    Button(errored.count == 1 ? "Dismiss" : "Dismiss all") {
                        model.dismissErrors(errored)
                    }
                    .controlSize(.small)
                    .help("Clear every error and the menubar badge")
                }
            }
            UpdateBadge(updates: model.updates, installer: model.installer, running: model.runningCount)
            Divider()
            HStack {
                Button(action: { model.beginAdd() }) {
                    Label("Add forward", systemImage: "plus")
                }
                Button(action: { model.importFromClipboard() }) {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Add a forward from JSON on the clipboard")
                Button(action: { model.beginQuickConnect() }) {
                    Image(systemName: "bolt")
                }
                .help("Quick connect — start a forward without saving it")
                Spacer()
                Button(action: { model.openSettings() }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                Button("Quit") { model.quit() }
            }
        }
    }
}

struct NoticeText: View {
    static let lines = 4

    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(NoticeText.lines)
            .fixedSize(horizontal: false, vertical: true)
            .frame(idealWidth: 1, maxWidth: .infinity, alignment: .leading)
    }
}

struct UpdateBadge: View {
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var installer: Installer
    let running: Int

    @State private var confirming = false

    var body: some View {
        if let release = updates.available {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue)
                    Text("Update available · \(release.version)").font(.caption)
                    Spacer()
                    controls(release)
                }
                if let status {
                    Text(status.text)
                        .font(.caption2)
                        .foregroundStyle(status.warning ? Color.orange : Color.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(idealWidth: 1, maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private func controls(_ release: Release) -> some View {
        if installer.busy {
            ProgressView().controlSize(.small)
        } else if confirming {
            Button("Stop & update") {
                confirming = false; installer.install(release)
            }
            .controlSize(.small)
            Button("Cancel") { confirming = false }
                .controlSize(.small)
        } else if release.asset != nil {
            if status?.warning == true {
                Button("Dismiss") { installer.dismiss() }
                    .controlSize(.small)
            }
            Button(status?.warning == true ? "Retry" : "Update") {
                if running > 0 {
                    confirming = true
                } else {
                    installer.install(release)
                }
            }
            .controlSize(.small)
            .help("Download \(release.version), verify it, and relaunch")
        } else {
            Text("brew upgrade --cask awsssh")
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }

    private var status: (text: String, warning: Bool)? {
        switch installer.phase {
        case .idle:
            guard confirming else { return nil }
            return ("\(running) running forward\(running == 1 ? "" : "s") will stop.", true)
        case .resolving:
            return ("Checking for the newest release…", false)
        case .downloading(let version):
            return ("Downloading \(version)…", false)
        case .verifying:
            return ("Verifying checksum and signature…", false)
        case .installing:
            return ("Replacing Awsssh and relaunching…", false)
        case .failed(let message), .blocked(let message):
            return (message, true)
        }
    }
}

struct GroupHeader: View {
    @EnvironmentObject var model: AppModel
    let group: ForwardGroup
    let soleGroup: Bool

    var body: some View {
        let live = model.anyLive(in: group.forwards)
        let collapsed = model.isCollapsed(group)
        HStack(spacing: 6) {
            Button(action: { model.toggleCollapsed(group) }) {
                HStack(spacing: 4) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 9)
                    Text(group.title(soleGroup: soleGroup))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(model.runningCount(in: group.forwards))/\(group.forwards.count)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show this group" : "Hide this group")
            Spacer()
            Button(action: { model.toggleAll(group.forwards) }) {
                Image(systemName: live ? "stop.circle" : "play.circle")
            }
            .buttonStyle(.borderless)
            .help(live ? "Stop this group" : "Start this group")
        }
        .padding(.top, 2)
    }
}

struct RowTint: ViewModifier {
    let color: Color?

    private static let cornerRadius: CGFloat = 6
    private static let fillOpacity: Double = 0.18
    private static let borderOpacity: Double = 0.4

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: RowTint.cornerRadius)
                    .fill((color ?? .clear).opacity(RowTint.fillOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: RowTint.cornerRadius)
                    .strokeBorder((color ?? .clear).opacity(RowTint.borderOpacity), lineWidth: 1)
            )
    }
}

struct ForwardRow: View {
    @EnvironmentObject var model: AppModel
    let forward: Forward

    var body: some View {
        if model.pendingDelete?.id == forward.id {
            deleteConfirmation
        } else {
            row
        }
    }

    private var deleteConfirmation: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text("Delete “\(forward.title)”?").fontWeight(.medium)
                Text(forward.route).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Cancel") { model.cancelDelete() }
                .controlSize(.small)
            Button("Delete") { model.delete(forward) }
                .controlSize(.small)
                .tint(.red)
        }
        .modifier(RowTint(color: forward.tint))
    }

    private var row: some View {
        let s = model.state(for: forward)
        return VStack(alignment: .leading, spacing: 5) {
            header(s)
            if s.run == .error, model.expandedError == forward.id {
                errorDetail(s)
            }
        }
        .modifier(RowTint(color: forward.tint))
    }

    private func header(_ s: EntryState) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(for: s.run)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                OverflowScroll {
                    HStack(spacing: 6) {
                        Text(forward.title).fontWeight(.medium)
                        Text(forward.profileLabel).font(.caption).foregroundStyle(.purple)
                        if let hotKey = forward.hotKey {
                            Text(hotKey.displayString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .lineLimit(1)
                }
                statusLine(s)
            }
            Spacer()
            Button(action: { model.toggle(forward) }) {
                Image(systemName: buttonIcon(s.run))
            }
            .buttonStyle(.borderless)
            .help(buttonIcon(s.run) == "stop.circle" ? "Stop" : "Start")
            Button(action: { model.share(forward) }) {
                Image(systemName: "square.on.square")
            }
            .buttonStyle(.borderless).help("Copy as JSON to share")
            if !forward.isTemporary {
                Button(action: { model.beginEdit(forward) }) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless).help("Edit")
            }
            Button(action: { model.confirmDelete(forward) }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless).help("Delete")
        }
    }

    private func errorDetail(_ s: EntryState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !s.detail.isEmpty {
                Text(s.detail).font(.caption2).foregroundStyle(.secondary)
            }
            Text(s.error)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(idealWidth: 1, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Spacer()
                Button("Copy") { model.copyToClipboard(s.error) }
                    .controlSize(.small)
                Button("Dismiss") { model.dismissError(forward) }
                    .controlSize(.small)
                    .help("Clear the error and the menubar badge")
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder private func statusLine(_ s: EntryState) -> some View {
        if s.run == .error {
            Button(action: { model.toggleErrorDetail(forward.id) }) {
                HStack(spacing: 3) {
                    Text(s.error)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .frame(idealWidth: 1, maxWidth: .infinity, alignment: .leading)
                    Image(
                        systemName: model.expandedError == forward.id
                            ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Show the full message")
        } else if s.run == .running, let since = s.since {
            OverflowScroll {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(status(s, at: context.date))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            OverflowScroll {
                Text(status(s, at: Date())).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func color(for run: RunState) -> Color {
        switch run {
        case .running: return .green
        case .starting, .stopping: return .yellow
        case .reconnecting: return .orange
        case .error: return .red
        case .stopped: return .secondary
        }
    }

    private func buttonIcon(_ run: RunState) -> String {
        switch run {
        case .running, .starting, .reconnecting: return "stop.circle"
        default: return "play.circle"
        }
    }

    private func status(_ s: EntryState, at now: Date) -> String {
        switch s.run {
        case .running:
            return
                ["running", s.detail, s.uptime(at: now).map { "up \($0)" }]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case .starting: return "starting…"
        case .reconnecting:
            return s.detail.isEmpty ? "reconnecting…" : "reconnecting \(s.detail)…"
        case .stopping: return "stopping…"
        case .error: return s.error
        case .stopped: return forward.route
        }
    }
}
