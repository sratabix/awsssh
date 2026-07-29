import Combine
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            setting(
                "Launch app at login",
                note: "Awsssh starts with macOS and waits in the menubar.",
                isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                )
            )
            if let err = model.launchAtLoginError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
            Divider()
            setting(
                "Show the AWS SSO sign-in",
                note: ssoNote,
                isOn: $model.showSSO
            )
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved forwards").font(.callout)
                Text("forwards.json is the only file Awsssh writes.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show in Finder") { model.revealStore() }
                    .controlSize(.small)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.closeSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: SettingsView.width)
    }

    private var ssoNote: String {
        model.logins.isEmpty
            ? "Nothing to sign in to — no SSO profiles were found in ~/.aws/config."
            : "A row that runs aws sso login for you. Turn it off if you use access keys."
    }

    private func setting(_ title: String, note: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn).toggleStyle(.checkbox).font(.callout)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class SettingsWindowPresenter {
    private weak var model: AppModel?
    private let host = WindowHost()
    private var watch: AnyCancellable?

    func attach(to model: AppModel) {
        self.model = model
        host.onClose = { [weak model] in model?.closeSettings() }
        watch =
            model.$showingSettings
            .removeDuplicates()
            .sink { [weak self] showing in
                Task { @MainActor in
                    guard let self else { return }
                    showing ? self.show() : self.host.hide()
                }
            }
    }

    private func show() {
        guard let model else { return }
        host.show(title: "Settings") {
            SettingsView().environmentObject(model)
        }
    }
}
