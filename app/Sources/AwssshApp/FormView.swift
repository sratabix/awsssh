import SwiftUI

struct FormView: View {
    @EnvironmentObject var model: AppModel
    @State var draft: Forward

    private var isEdit: Bool { model.forwards.contains { $0.id == draft.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isEdit ? "Edit forward" : "Add forward").font(.headline)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                field("Name", text: $draft.name, placeholder: "postgres (optional)")
                profileField
                field("Region", text: $draft.region, placeholder: "eu-central-1 (optional)")
                field("Instance", text: $draft.instance, placeholder: "db-prod (Name tag or ID)")
                field("Local port", text: $draft.localPort, placeholder: "5432")
                field("Remote host", text: $draft.host, placeholder: "db.internal (optional)")
                field("Remote port", text: $draft.remotePort, placeholder: "5432")
                hotKeyField
            }
            if let err = model.formError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Button("Cancel") { model.cancelForm() }
                Spacer()
                Button("Save") { model.saveForm(draft) }.keyboardShortcut(.defaultAction)
            }
        }
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
                    .frame(width: 26)
                }
            }
        }
    }
}
