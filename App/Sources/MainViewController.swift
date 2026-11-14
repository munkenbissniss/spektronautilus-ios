import UIKit
import WebKit

/// The whole app: one full-screen web view showing the bundled website, plus the bridge to the native plugins.
final class MainViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    private var web: WKWebView!
    private let bridge = Bridge()
    private let background = UIColor(red: 0.043, green: 0.051, blue: 0.118, alpha: 1)      // #0b0d1e, the dark theme of the pages
    private var downloadTarget: [ObjectIdentifier: URL] = [:]

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = background

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []          // loops start without a tap
        config.setURLSchemeHandler(WebAssetsHandler(), forURLScheme: "spektro")
        let ucc = WKUserContentController()
        ucc.addScriptMessageHandler(bridge, contentWorld: .page, name: "spk")
        config.userContentController = ucc

        web = WKWebView(frame: .zero, configuration: config)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.isOpaque = false
        web.backgroundColor = background
        web.scrollView.backgroundColor = background
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.uiDelegate = self
        web.navigationDelegate = self
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }       // Safari > Develop > your iPhone
        #endif
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])

        bridge.web = web
        bridge.register("app", AppPlugin(presenter: self))
        bridge.register("files", FilesPlugin(presenter: self))
        bridge.register("midi", MidiPlugin(bridge: bridge))
        bridge.register("transcode", TranscodePlugin(bridge: bridge))
        bridge.register("display", DisplayPlugin(bridge: bridge))
        bridge.register("upscale", UpscalePlugin(bridge: bridge))

        web.load(URLRequest(url: URL(string: "spektro://app/index.html")!))
    }

    // MARK: microphone and other permissions: the app asks iOS once, the page is then allowed without asking again
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.protocol == "spektro" ? .grant : .prompt)
    }

    // MARK: links: our own pages stay in the app, everything else opens in Safari
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { return decisionHandler(.download) }
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        if url.scheme == "spektro" || url.scheme == "blob" || url.scheme == "about" || url.scheme == "data" { return decisionHandler(.allow) }
        if ["http", "https", "mailto"].contains(url.scheme ?? "") {
            if navigationAction.targetFrame?.isMainFrame ?? true { UIApplication.shared.open(url) ; return decisionHandler(.cancel) }
            return decisionHandler(.allow)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType { return decisionHandler(.download) }
        if let r = navigationResponse.response as? HTTPURLResponse,
           (r.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment") { return decisionHandler(.download) }
        decisionHandler(.allow)
    }

    // window.open() for our own pages (the output window of the mixers) is not possible on a phone: show it in this web view instead
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { if u.scheme == "spektro" { webView.load(navigationAction.request) } else { UIApplication.shared.open(u) } }
        return nil
    }

    // alert(), confirm() and prompt() from the pages
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() }); present(a, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) }); present(a, animated: true)
    }

    // MARK: downloads: a finished video (a[download]) goes to the share sheet, where "Save to Files" or "Save Video" is one tap away
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let name = Files.clean(suggestedFilename) ?? "video.mp4"
        let target = Files.dir.appendingPathComponent("dl_" + String(UUID().uuidString.prefix(6)) + "_" + name)
        downloadTarget[ObjectIdentifier(download)] = target
        completionHandler(target)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let u = downloadTarget.removeValue(forKey: ObjectIdentifier(download)) else { return }
        FilesPlugin.share(u, from: self)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadTarget.removeValue(forKey: ObjectIdentifier(download))
        let a = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default)); present(a, animated: true)
    }

    // the page is gone (iOS can reclaim the web view's memory in the background): load it again
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
}
