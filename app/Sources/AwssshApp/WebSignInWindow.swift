import Combine
import SwiftUI
import WebKit

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct WebSignInView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            WebViewHost(webView: model.webSignIn.webView)
                .frame(width: WebSignIn.size.width, height: WebSignIn.size.height)
            Divider()
            HStack {
                Text("Signing in to AWS").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelWebSignIn() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
    }
}

@MainActor
final class WebSignInWindowPresenter {
    private weak var model: AppModel?
    private let host = WindowHost()
    private var watch: AnyCancellable?

    func attach(to model: AppModel) {
        self.model = model
        host.onClose = { [weak model] in model?.cancelWebSignIn() }
        watch =
            model.$showingWebSignIn
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
        host.show(title: "AWS SSO sign-in") {
            WebSignInView().environmentObject(model)
        }
    }
}
