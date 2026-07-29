import SwiftUI

struct SignInRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.showSSO, !model.logins.isEmpty {
            let now = Date()
            HStack(spacing: 6) {
                Image(systemName: icon(at: now))
                    .foregroundStyle(allSignedIn(at: now) ? Color.secondary : Color.orange)
                OverflowScroll {
                    Text(summary(at: now)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                control
            }
            if let err = model.signInError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var control: some View {
        if model.signingIn != nil {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("waiting for the browser…").font(.caption).foregroundStyle(.secondary)
            }
        } else if model.logins.count == 1 {
            Button("Sign in") { model.signIn(model.logins[0]) }
                .controlSize(.small)
                .help("Runs aws sso login for \(model.logins[0].label)")
        } else {
            Menu("Sign in") {
                ForEach(model.logins) { login in
                    Button(login.label) { model.signIn(login) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func allSignedIn(at now: Date) -> Bool {
        model.logins.allSatisfy { $0.signedIn(at: now) }
    }

    private func icon(at now: Date) -> String {
        allSignedIn(at: now) ? "person.badge.key" : "exclamationmark.lock"
    }

    private func summary(at now: Date) -> String {
        guard model.logins.count == 1 else {
            let live = model.logins.filter { $0.signedIn(at: now) }.count
            return "AWS SSO · \(live) of \(model.logins.count) signed in"
        }
        let login = model.logins[0]
        let covers = login.covers
        return covers.isEmpty
            ? "\(login.label) · \(login.status(at: now))"
            : "\(login.label) · \(login.status(at: now)) · \(covers)"
    }
}
