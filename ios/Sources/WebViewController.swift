import UIKit
import WebKit

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    private var webView: WKWebView!
    private let pageURL: URL
    private let latestURL: URL?
    private let nativeBuild: Int

    private var loadedVersion: Int?
    private var lastBeat = Date.distantPast
    private var lastIdle = false
    private var checkTimer: Timer?
    private var toastLabel: UILabel?
    private var bannerShown = false
    private var forcedOnce = false

    private let bg = UIColor(red: 246/255, green: 245/255, blue: 242/255, alpha: 1)
    private let spinner = UIActivityIndicatorView(style: .large)

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        pageURL = URL(string: (info["GTPageURL"] as? String) ?? "https://workbuddy.link")!
        latestURL = (info["GTLatestURL"] as? String).flatMap { URL(string: $0) }
        nativeBuild = Int((info["GTNativeBuild"] as? String) ?? "") ?? 1
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bg

        // 云端自测专用：预置一份假密钥，验证「钥匙串 ←→ 页面」桥是否通。正式使用不会设置这些变量。
        let env = ProcessInfo.processInfo.environment
        if env["GT_DEBUG"] != nil, let fake = env["GT_FAKESEED"], !fake.isEmpty {
            KeyStore.set(Injected.keyName, fake)
            DebugLog.write("seeded fake key; readback=\(KeyStore.get(Injected.keyName) != nil)")
        }

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                      // 持久存储：不会因为退出 App 丢本机缓存
        cfg.allowsInlineMediaPlayback = true
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let seed = Injected.jsLiteral(KeyStore.get(Injected.keyName))
        let us = WKUserScript(source: Injected.script(seedJSON: seed),
                              injectionTime: .atDocumentStart,
                              forMainFrameOnly: false)       // 工作台在平台外壳的 iframe 里，必须注入所有 frame
        cfg.userContentController.addUserScript(us)
        cfg.userContentController.add(self, name: "gt")

        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = bg
        webView.scrollView.backgroundColor = bg
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: g.topAnchor),
            webView.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: g.trailingAnchor)
        ])

        spinner.color = .gray
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)

        load()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in self?.checkForUpdate() }
    }

    private var bgAt: Date?
    @objc private func didEnterBackground() { bgAt = Date() }
    @objc private func didBecomeActive() {
        // 回到前台：马上静默检查一次是否有新版本
        checkForUpdate()
        checkNative()
        // 后台超过 20 分钟才回来、而页面还是空白/失败状态，顺手重新载入
        if let t = bgAt, Date().timeIntervalSince(t) > 1200, webView.url == nil { load() }
        bgAt = nil
    }

    private func load() {
        spinner.startAnimating()
        var req = URLRequest(url: pageURL)
        req.cachePolicy = .reloadRevalidatingCacheData
        webView.load(req)
    }

    // MARK: - 静默更新（网页功能）

    /// 读平台外壳里的 publishVersion。工作台每次发布新版本，这个数字就 +1。
    private func fetchPublishVersion(_ done: @escaping (Int?) -> Void) {
        var req = URLRequest(url: pageURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var v: Int?
            if let d = data, let s = String(data: d, encoding: .utf8),
               let r = s.range(of: #"publishVersion"\s*:\s*(\d+)"#, options: .regularExpression) {
                let digits = s[r].filter { $0.isNumber }
                v = Int(digits)
            }
            DispatchQueue.main.async { done(v) }
        }.resume()
    }

    private func checkForUpdate() {
        guard let cur = loadedVersion else { return }
        fetchPublishVersion { [weak self] remote in
            guard let self = self, let remote = remote, remote != cur else { return }
            DebugLog.write("new version \(cur) -> \(remote)")
            // 只在「页面空闲」时才自动刷新：没有未保存的改动、没在打字、没开着弹窗
            let fresh = Date().timeIntervalSince(self.lastBeat) < 8
            if fresh && self.lastIdle {
                self.load()
                self.toast("已更新到最新版本")
            }
            // 否则这次先不动，下一次检查（90 秒后 / 回到前台）再试，绝不打断你正在做的事
        }
    }

    // MARK: - 原生壳版本提示（iOS 不允许应用静默替换自己，这里只做提示）

    private func checkNative() {
        guard !bannerShown, let url = latestURL else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let d = data,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let b = j["build"] as? Int, b > self.nativeBuild else { return }
            DispatchQueue.main.async {
                self.bannerShown = true
                self.toast("App 有新版本（第 \(b) 版），需要重新安装一次才能升级外壳；网页功能无需操作，已自动最新", seconds: 6)
            }
        }.resume()
    }

    // MARK: - 小提示

    private func toast(_ text: String, seconds: TimeInterval = 2.4) {
        toastLabel?.removeFromSuperview()
        let l = PaddedLabel()
        l.text = text
        l.numberOfLines = 0
        l.font = .systemFont(ofSize: 13.5)
        l.textColor = .white
        l.backgroundColor = UIColor(white: 0.12, alpha: 0.88)
        l.layer.cornerRadius = 12
        l.layer.masksToBounds = true
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -64),
            l.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48)
        ])
        toastLabel = l
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak l] in
            UIView.animate(withDuration: 0.3, animations: { l?.alpha = 0 }, completion: { _ in l?.removeFromSuperview() })
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let t = body["t"] as? String else { return }
        switch t {
        case "keySet":
            if let v = body["v"] as? String, !v.isEmpty {
                KeyStore.set(Injected.keyName, v)
                DebugLog.write("keySet len=\(v.count)")
            }
        case "keyDel":
            KeyStore.remove(Injected.keyName)
            DebugLog.write("keyDel")
        case "restored":
            DebugLog.write("restored from keychain")
        case "diag":
            if DebugLog.on, let d = body["d"] { DebugLog.write("diag \(d)") }
        case "beat":
            lastBeat = Date()
            lastIdle = (body["idle"] as? Bool) ?? false
            if DebugLog.on, (body["loaded"] as? Bool) == true { DebugLog.write("beat loaded idle=\(lastIdle)") }
        default: break
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "gtretry" { decisionHandler(.cancel); load(); return }
        if scheme == "about" || scheme == "blob" || scheme == "data" { decisionHandler(.allow); return }
        if scheme != "http" && scheme != "https" {
            // 自定义协议（例如平台想拉起 WorkBuddy App）一律拦下，避免被带出应用
            DebugLog.write("blocked scheme \(scheme)")
            decisionHandler(.cancel); return
        }
        let host = (url.host ?? "").lowercased()
        let inApp = host.hasSuffix("workbuddy.link") || host.hasSuffix("codebuddy.work") || host.hasSuffix("codebuddy.cn")
            || host.hasSuffix("workbuddy.cn") || host.hasSuffix("weixin.qq.com") || host.hasSuffix("qq.com")
        if navigationAction.targetFrame == nil || !inApp {
            // 新窗口 / 外部站点：交给系统浏览器，不在工作台窗口里打开
            if navigationAction.navigationType == .linkActivated && !inApp {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                decisionHandler(.cancel); return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            let host = (url.host ?? "").lowercased()
            if host.hasSuffix("workbuddy.link") || host.hasSuffix("codebuddy.work") { webView.load(navigationAction.request) }
            else { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spinner.stopAnimating()
        DebugLog.write("didFinish \(webView.url?.absoluteString ?? "-")")
        if let u = webView.url, (u.host ?? "").hasSuffix("workbuddy.link") {
            fetchPublishVersion { [weak self] v in
                guard let self = self, let v = v else { return }
                self.loadedVersion = v
                DebugLog.write("version \(v)")
                // 云端自测专用：假装自己是旧版本，验证「发现新版本 → 页面空闲 → 自动刷新」整条链路
                if DebugLog.on, ProcessInfo.processInfo.environment["GT_FORCE_OLD"] != nil, !self.forcedOnce {
                    self.forcedOnce = true
                    self.loadedVersion = 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.checkForUpdate() }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
        DebugLog.write("failProvisional \((error as NSError).code)")
        showOffline()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
        let c = (error as NSError).code
        if c == NSURLErrorCancelled { return }
        showOffline()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // 网页进程被系统回收（内存紧张）：自动重新载入，数据都在云端
        DebugLog.write("process terminated")
        load()
    }

    private func showOffline() {
        let html = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>body{margin:0;background:#F6F5F2;color:#2F2E2B;font-family:-apple-system,'PingFang SC',sans-serif;
        display:flex;align-items:center;justify-content:center;height:100vh;text-align:center}
        .c{padding:28px}h2{font-weight:500;font-size:19px;margin:0 0 10px}p{color:#6B6A65;font-size:14px;line-height:1.9;margin:0}
        a{display:inline-block;margin-top:18px;padding:11px 30px;border-radius:12px;background:#2F2E2B;color:#fff;
        text-decoration:none;font-size:15px}</style></head><body><div class="c"><h2>没连上网络</h2>
        <p>数据都在云端，不会丢。<br>连上网后点下面重试。</p><a href="gtretry://go">重试</a></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // 网页里的 alert / confirm（工作台里有「锁定本机」确认框等）
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a, animated: true)
    }
}

private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)))
    }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 28, height: s.height + 18)
    }
}
