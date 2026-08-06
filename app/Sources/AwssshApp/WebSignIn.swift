import Foundation
import OSLog
import WebKit

@MainActor
final class WebSignIn: NSObject {
    static let size = CGSize(width: 480, height: 620)
    static let log = Logger(subsystem: "com.github.sratabix.awsssh", category: "signin")

    var onFailure: ((String) -> Void)?

    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: CGRect(origin: .zero, size: WebSignIn.size), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        return view
    }()

    static func trace(_ url: URL?) -> String {
        guard let url else { return "nil" }
        var trimmed = URLComponents(url: url, resolvingAgainstBaseURL: false)
        trimmed?.query = url.query == nil ? nil : "<redacted>"
        return trimmed?.string ?? url.scheme ?? "?"
    }

    func load(_ url: URL) {
        WebSignIn.log.info("load \(WebSignIn.trace(url), privacy: .public)")
        webView.load(URLRequest(url: url))
    }

    func reset() {
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }
}

extension WebSignIn: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        WebSignIn.log.info("retargeting \(WebSignIn.trace(url), privacy: .public) into the main frame")
        decisionHandler(.cancel)
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        WebSignIn.log.info("finished \(WebSignIn.trace(webView.url), privacy: .public)")
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        report(error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        report(error)
    }

    private func report(_ error: Error) {
        let code = (error as NSError).code
        WebSignIn.log.error("navigation failed code=\(code) \(error.localizedDescription, privacy: .public)")
        guard code != NSURLErrorCancelled else { return }
        onFailure?(error.localizedDescription)
    }
}

extension WebSignIn: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            WebSignIn.log.info("popup \(WebSignIn.trace(url), privacy: .public) kept in the same view")
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
