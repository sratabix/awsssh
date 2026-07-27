import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.showingForm, let editing = model.editing {
                FormView(draft: editing)
            } else {
                listView
            }
        }
        .frame(width: 380)
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
                "Launch at login",
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
            UpdateBadge(updates: model.updates)
            Divider()
            HStack {
                Button(action: { model.beginAdd() }) {
                    Label("Add forward", systemImage: "plus")
                }
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
        return HStack(spacing: 8) {
            Circle().fill(color(for: s.run)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
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
                statusLine(s)
            }
            Spacer()
            Button(action: { model.toggle(forward) }) {
                Image(systemName: buttonIcon(s.run))
            }
            .buttonStyle(.borderless)
            .help(buttonIcon(s.run) == "stop.circle" ? "Stop" : "Start")
            Button(action: { model.beginEdit(forward) }) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless).help("Edit")
            Button(action: { model.confirmDelete(forward) }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless).help("Delete")
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func statusLine(_ s: EntryState) -> some View {
        if s.run == .running, let since = s.since {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(status(s, at: context.date))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Text(status(s, at: Date()))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
