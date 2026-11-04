import WebKit

/// Renders a page offscreen and screenshots its top viewport, so a saved link comes with a
/// picture of what it looked like. The renderer has no browser login state — paywalls and
/// login walls simply return nil and the capture saves without a snapshot.
enum WebSnapshot {
    /// 1280×720 viewport PNG in a fresh temp folder, ready for the attachment copy. nil on failure.
    static func capture(_ url: URL, completion: @escaping (URL?) -> Void) {
        assert(Thread.isMainThread)
        let shot = Engine(url: url, completion: completion)
        live.append(shot)
        shot.onDone = { live.removeAll { $0 === shot } }
        shot.start()
    }

    /// Keeps each render alive until it finishes (the web view's delegate reference is weak).
    private static var live: [Engine] = []

    private final class Engine: NSObject, WKNavigationDelegate {
        private let web: WKWebView
        private let completion: (URL?) -> Void
        private var done = false
        private var timeout: DispatchWorkItem?
        var onDone: (() -> Void)?

        private init(url: URL, completion: @escaping (URL?) -> Void) {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            self.web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), configuration: config)
            self.completion = completion
        }

        func start() {
            timeout = DispatchWorkItem { [weak self] in self?.finish(nil) }
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
                        finish(nil)
                        return
                    }
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let f = DateFormatter()
                    f.dateFormat = "yyyyMMddHHmmss"
                    let file = dir.appendingPathComponent("网页快照 \(f.string(from: Date())).png")
                    do {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try data.write(to: file)
                        finish(file)
                    } catch {
                        finish(nil)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
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
