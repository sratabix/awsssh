import SwiftUI

struct FormView: View {
    @EnvironmentObject var model: AppModel
    @State var draft: Forward
    @State private var hexText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                field("Name", text: $draft.name, placeholder: "postgres (optional)")
                profileField
                field("Region", text: $draft.region, placeholder: "eu-central-1 (optional)")
                field("Instance", text: $draft.instance, placeholder: "db-prod (Name tag or ID)")
                field("Local port", text: $draft.localPort, placeholder: "5432")
                field("Remote host", text: $draft.host, placeholder: "db.internal (optional)")
                field("Remote port", text: $draft.remotePort, placeholder: "5432")
                colorField
                hotKeyField
            }
            if let err = model.formError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Button("Cancel") { model.cancelForm() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { model.saveForm(draft) }.keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { hexText = draft.color }
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
