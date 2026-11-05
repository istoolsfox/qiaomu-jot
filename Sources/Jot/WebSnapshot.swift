import WebKit

/// Renders a page offscreen and screenshots its top viewport, so a saved link comes with a
/// picture of what it looked like. The renderer has no browser login state — paywalls and
/// login walls simply return nil and the capture saves without a snapshot. Ad, tracker and
/// analytics networks are blocked and common ad containers hidden, so the picture shows the
/// page, not its commercials.
enum WebSnapshot {
    /// Ad, tracker and analytics hosts, as regex fragments matched inside the request URL.
    private static let blockedHosts = [
        "doubleclick\\.net", "googlesyndication\\.com", "googleadservices\\.com",
        "google-analytics\\.com", "analytics\\.google\\.com", "adservice\\.google\\.[a-z.]+",
        "adnxs\\.com", "adsrvr\\.org", "criteo\\.(?:com|net)", "rubiconproject\\.com",
        "pubmatic\\.com", "openx\\.net", "smartadserver\\.com", "taboola\\.com",
        "outbrain\\.com", "amazon-adsystem\\.com", "moatads\\.com", "scorecardresearch\\.com",
        "quantserve\\.com", "connect\\.facebook\\.net", "analytics\\.tiktok\\.com",
        "ads-twitter\\.com", "analytics\\.twitter\\.com", "hotjar\\.com", "clarity\\.ms",
        "bat\\.bing\\.com", "pos\\.baidu\\.com", "hm\\.baidu\\.com", "tanx\\.com",
        "mediav\\.com", "miaozhen\\.com", "ipinyou\\.(?:com|net)", "admaster\\.com\\.cn",
        "cnzz\\.com", "umeng\\.(?:co|com)", "growingio\\.com",
    ]
    /// Ad containers hidden from layout, so blocked slots don't leave grey boxes behind.
    private static let hiddenSelectors = "ins.adsbygoogle, .adsbygoogle, .ad-banner, .advert, " +
        ".advertisement, .ad-slot, [id^=\"ad_\"], [id^=\"ads_\"], [id^=\"google_ads\"], " +
        "iframe[src*=\"doubleclick\"], iframe[src*=\"googlesyndication\"], iframe[src*=\"taboola\"]"

    /// The content rule list built from the lists above (the store caches it by identifier).
    private static func blockList(then: @escaping (WKContentRuleList?) -> Void) {
        var rules: [[String: Any]] = blockedHosts.map { host in
            ["trigger": ["url-filter": "https?://[^/]*\(host)"],
             "action": ["type": "block"]]
        }
        rules.append(["trigger": ["url-filter": ".*"],
                      "action": ["type": "css-display-none"], "selector": hiddenSelectors])
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let source = String(data: data, encoding: .utf8) else { then(nil); return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "jot-adblock", encodedContentRuleList: source) { list, _ in
            DispatchQueue.main.async { then(list) }
        }
    }

    /// 1280×720 viewport PNG in a fresh temp folder, ready for the attachment copy. nil on failure.
    static func capture(_ url: URL, completion: @escaping (URL?) -> Void) {
        assert(Thread.isMainThread)
        blockList { list in
            let shot = Engine(url: url, completion: completion)
            shot.use(list)
            live.append(shot)
            shot.onDone = { live.removeAll { $0 === shot } }
            shot.start()
        }
    }

    /// Keeps each render alive until it finishes (the web view's delegate reference is weak).
    private static var live: [Engine] = []

    private final class Engine: NSObject, WKNavigationDelegate {
        private let url: URL
        private let web: WKWebView
        private let completion: (URL?) -> Void
        private var done = false
        private var timeout: DispatchWorkItem?
        var onDone: (() -> Void)?

        init(url: URL, completion: @escaping (URL?) -> Void) {
            self.url = url
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            self.web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), configuration: config)
            self.completion = completion
        }

        /// Installs the content rule list before the first load.
        func use(_ list: WKContentRuleList?) {
            if let list { web.configuration.userContentController.add(list) }
        }

        func start() {
            web.navigationDelegate = self
            let target = url.absoluteString
            timeout = DispatchWorkItem { [weak self] in
                print("snapshot timed out: \(target)")
                self?.finish(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout!)
            web.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            timeout?.cancel()
            // Let fonts and late layout settle before grabbing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                webView.takeSnapshot(with: nil) { image, _ in
                    guard let self, let image, let tiff = image.tiffRepresentation,
                          let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                        self?.finish(nil)
                        return
                    }
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let f = DateFormatter()
                    f.dateFormat = "yyyyMMddHHmmss"
                    let file = dir.appendingPathComponent("网页快照 \(f.string(from: Date())).png")
                    do {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try data.write(to: file)
                        self.finish(file)
                    } catch {
                        self.finish(nil)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("webview error: \(url.absoluteString) — \(error.localizedDescription)")
            finish(nil)
        }

        private func finish(_ file: URL?) {
            guard !done else { return }
            done = true
            timeout?.cancel()
            web.stopLoading()
            onDone?()
            completion(file)
        }
    }
}
