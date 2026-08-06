import SwiftUI

struct SignInRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.showSSO, !model.logins.isEmpty {
            TimelineView(.periodic(from: Date(), by: SignInRow.tick)) { context in
                let now = context.date
                HStack(spacing: 6) {
                    Image(systemName: icon(at: now))
                        .foregroundStyle(allSignedIn(at: now) ? Color.secondary : Color.orange)
                    OverflowScroll {
                        Text(summary(at: now)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    control(at: now)
                }
            }
            if let err = model.signInError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    static let tick: TimeInterval = 30

    @ViewBuilder private func control(at now: Date) -> some View {
        if model.signingIn != nil {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(model.signInPending ? "waiting for your approval…" : "signing in…")
                    .font(.caption)
                    .foregroundStyle(model.signInPending ? Color.orange : Color.secondary)
            }
        } else {
            let needed = model.signedOutLogins(at: now)
            if needed.count == 1 {
                Button("Sign in") { model.signIn(needed[0]) }
                    .controlSize(.small)
                    .help("Runs aws sso login for \(needed[0].label)")
            } else if needed.count > 1 {
                Menu("Sign in") {
                    ForEach(needed) { login in
                        Button(login.label) { model.signIn(login) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func allSignedIn(at now: Date) -> Bool {
        model.signedOutLogins(at: now).isEmpty
    }

    private func icon(at now: Date) -> String {
        allSignedIn(at: now) ? "person.badge.key" : "exclamationmark.lock"
    }

    private func summary(at now: Date) -> String {
        guard model.logins.count == 1 else {
            let out = model.signedOutLogins(at: now).count
            return "AWS SSO · \(model.logins.count - out) of \(model.logins.count) signed in"
        }
        let login = model.logins[0]
        let status = login.status(at: now, check: model.check(for: login))
        let covers = login.covers
        return covers.isEmpty
            ? "\(login.label) · \(status)"
            : "\(login.label) · \(status) · \(covers)"
    }
}
