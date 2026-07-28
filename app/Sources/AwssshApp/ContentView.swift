import SwiftUI

struct ContentView: View {
    static let minWidth: CGFloat = 380
    static let maxWidth: CGFloat = 560

    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.showingForm, let editing = model.editing {
                FormView(draft: editing)
            } else {
                listView
            }
        }
        .frame(minWidth: ContentView.minWidth, maxWidth: ContentView.maxWidth)
        .padding(12)
        .onAppear { model.refreshIfChanged() }
    }

    private var listView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Port forwards").font(.headline)
                Text(AppInfo.displayVersion)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                Spacer()
                Text("\(model.forwards.count) saved · \(model.runningCount) running")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if model.forwards.isEmpty {
                Text("No forwards yet — add one below.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(model.forwards) { forward in
                    ForwardRow(forward: forward)
                }
            }
            Divider()
            Toggle(
                "Launch app at login",
                isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.callout)
            if let err = model.launchAtLoginError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
            if let notice = model.dataNotice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            if let err = model.importError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
            UpdateBadge(updates: model.updates)
            Divider()
            HStack {
                Button(action: { model.beginAdd() }) {
                    Label("Add forward", systemImage: "plus")
                }
                Button(action: { model.importFromClipboard() }) {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Add a forward from JSON on the clipboard")
                Spacer()
                Button("Quit") { model.quit() }
            }
        }
    }
}

struct UpdateBadge: View {
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        if let latest = updates.latestVersion {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue)
                Text("Update available · \(latest)").font(.caption)
                Spacer()
                Text("brew upgrade --cask awsssh")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
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
        .padding(.vertical, 3)
    }

    private var row: some View {
        let s = model.state(for: forward)
        return VStack(alignment: .leading, spacing: 5) {
            header(s)
            if s.run == .error, model.expandedError == forward.id {
                errorDetail(s)
            }
        }
        .padding(.vertical, 3)
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
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless).help("Copy as JSON to share")
            Button(action: { model.beginEdit(forward) }) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless).help("Edit")
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
