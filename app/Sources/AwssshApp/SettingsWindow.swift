import Combine
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    static let width: CGFloat = 380
    static let indent: CGFloat = 20

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
                note(err, colour: .orange)
            }
            Divider()
            setting(
                "Show the AWS SSO sign-in",
                note: ssoNote,
                isOn: $model.showSSO
            )
            if model.showSSO {
                VStack(alignment: .leading, spacing: 10) {
                    setting(
                        "Sign in automatically",
                        note: "When the session expires, Awsssh signs in again in its own window. "
                            + "You only see it if it needs a click.",
                        isOn: $model.autoSignIn
                    )
                    if let nudge = refreshNote {
                        note(nudge, colour: .orange)
                    }
                }
                .padding(.leading, SettingsView.indent)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved forwards").font(.callout)
                note("forwards.json is the only file Awsssh writes.")
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

    private var refreshNote: String? {
        let labels = model.unscopedLogins.map(\.label)
        guard !labels.isEmpty else { return nil }
        return "\(labels.joined(separator: ", ")): add sso_registration_scopes = sso:account:access "
            + "to the [sso-session] block in ~/.aws/config and sign in once. The token then renews "
            + "on its own, so a sign-in is needed far less often."
    }

    private var ssoNote: String {
        model.logins.isEmpty
            ? "Nothing to sign in to — no SSO profiles were found in ~/.aws/config."
            : "A row that signs you in to AWS SSO. Turn it off if you use access keys."
    }

    private func setting(_ title: String, note text: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn).toggleStyle(.checkbox).font(.callout)
            note(text)
        }
    }

    private func note(_ text: String, colour: Color = .secondary) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
