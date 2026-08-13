import SwiftUI

struct FormView: View {
    @EnvironmentObject var model: AppModel
    @State var draft: Forward
    @State private var hexText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.isTemporary {
                Text("Runs until you stop it. Nothing is saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                field("Name", text: $draft.name, placeholder: "postgres (optional)")
                if !draft.isTemporary { groupField }
                profileField
                field("Region", text: $draft.region, placeholder: "eu-central-1 (optional)")
                field("Instance", text: $draft.instance, placeholder: "db-prod (Name tag or ID)")
                field("Local port", text: $draft.localPort, placeholder: "5432")
                field("Remote host", text: $draft.host, placeholder: "db.internal (optional)")
                field("Remote port", text: $draft.remotePort, placeholder: "5432")
                colorField
                if !draft.isTemporary { hotKeyField }
            }
            if let err = model.formError {
                note(err, tint: .red)
            }
            testLine
            Divider()
            HStack {
                Button("Cancel") { model.cancelForm() }
                    .keyboardShortcut(.cancelAction)
                Button("Test") { model.testForm(draft) }
                    .disabled(model.testing != nil)
                    .help("Check the profile, the instance and its SSM agent without connecting")
                if draft.isTemporary {
                    Button(action: paste) {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .help("Fill the form from JSON on the clipboard")
                }
                Spacer()
                Button(draft.isTemporary ? "Connect" : "Save") { model.saveForm(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { hexText = draft.color }
    }

    private func paste() {
        guard let merged = model.pasteIntoForm(draft) else { return }
        draft = merged
        hexText = merged.color
    }

    @ViewBuilder private var testLine: some View {
        if model.testing != nil {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let outcome = model.testOutcome {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: outcome.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(outcome.ok ? .green : .red)
                note(outcome.message, tint: outcome.ok ? .secondary : .red)
            }
        }
    }

    private func note(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private var hotKeyField: some View {
        GridRow {
            Text("Shortcut").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            HStack(spacing: 4) {
                HotKeyRecorder(hotKey: $draft.hotKey)
                if draft.hotKey != nil {
                    Button {
                        draft.hotKey = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
                }
            }
        }
    }

    private var groupField: some View {
        GridRow {
            Text("Group").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            HStack(spacing: 4) {
                TextField("databases (optional)", text: $draft.group)
                    .textFieldStyle(.roundedBorder)
                if !model.groupNames.isEmpty {
                    Menu {
                        ForEach(model.groupNames, id: \.self) { name in
                            Button(name) { draft.group = name }
                        }
                        Divider()
                        Button("No group") { draft.group = "" }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 18)
                    .help("Pick an existing group")
                }
            }
        }
    }

    private var colorField: some View {
        GridRow {
            Text("Color").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            HStack(spacing: 5) {
                swatch(hex: "", label: "No color")
                ForEach(ForwardColor.presets, id: \.hex) { preset in
                    swatch(hex: preset.hex, label: preset.name)
                }
                TextField("#RRGGBB", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .frame(width: 82)
                    .onChange(of: hexText) { draft.color = $0 }
            }
        }
    }

    private func swatch(hex: String, label: String) -> some View {
        let selected = ForwardColor.normalise(draft.color) == hex
        return Button {
            draft.color = hex
            hexText = hex
        } label: {
            Circle()
                .fill(ForwardColor.color(hex) ?? Color.secondary.opacity(0.12))
                .frame(width: 15, height: 15)
                .overlay {
                    if hex.isEmpty {
                        Image(systemName: "slash.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay(
                    Circle().strokeBorder(
                        selected ? Color.primary : Color.secondary.opacity(0.45),
                        lineWidth: selected ? 2 : 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var profileField: some View {
        GridRow {
            Text("Profile").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            HStack(spacing: 4) {
                TextField("prod (blank = default)", text: $draft.profile).textFieldStyle(.roundedBorder)
                if !model.profiles.isEmpty {
                    Menu {
                        ForEach(model.profiles, id: \.self) { p in
                            Button(p) { draft.profile = p }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 18)
                    .help("Pick from ~/.aws/config")
                }
            }
        }
    }
}
