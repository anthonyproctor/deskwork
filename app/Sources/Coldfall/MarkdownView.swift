// A rendered markdown page inside a reader tab.
//
// WebKit rather than an attributed string, because the files that matter most
// here are full of GFM tables — Apple's own markdown parser follows CommonMark,
// which has no tables at all, and a desk list rendered as a paragraph of pipes
// is the exact complaint this replaces.
//
// Three things it has to get right that a naive web view would not:
//
//  * It REUSES itself when an agent rewrites the file, and keeps your scroll
//    position. Agents write while you read; a page that jumped to the top on
//    every save would be unusable, and replacing the whole view flickers.
//
//  * JavaScript from the page is disabled. This renders files the user may not
//    have written — a cloned repo, an agent's output — and MarkdownHTML escapes
//    everything as well, so a stray <script> is inert twice over. Scroll
//    restoration runs in the app's own isolated script world, which content
//    settings do not reach.
//
//  * Links do not navigate the reader away. A web link opens in the browser;
//    a relative link to another file opens that file in a reader tab.

import AppKit
import WebKit
import ColdfallCore

final class MarkdownView: NSView, WKNavigationDelegate {

    private let web: WKWebView
    private var baseURL: URL
    private var pendingScroll: Double?
    /// Called for a relative link to another local file.
    var onOpenFile: ((URL) -> Void)?

    init(markdown: String, fileURL: URL) {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: .zero, configuration: cfg)
        baseURL = fileURL.deletingLastPathComponent()
        super.init(frame: .zero)

        web.translatesAutoresizingMaskIntoConstraints = false
        web.navigationDelegate = self
        // The web view paints white before the page arrives, which flashes on
        // a dark theme. Paint the theme's editor colour underneath instead.
        web.underPageBackgroundColor = Theme.ui.editor
        wantsLayer = true
        layer?.backgroundColor = Theme.ui.editor.cgColor

        addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: topAnchor),
            web.bottomAnchor.constraint(equalTo: bottomAnchor),
            web.leadingAnchor.constraint(equalTo: leadingAnchor),
            web.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        load(markdown)
    }
    required init?(coder: NSCoder) { nil }

    private func load(_ md: String) {
        let ui = Theme.ui
        let html = MarkdownHTML.page(
            md,
            bg: ui.editor.hexString, text: ui.text.hexString, dim: ui.dimText.hexString,
            border: ui.border.hexString, accent: ui.accent.hexString,
            codeBg: ui.hover.hexString)
        web.loadHTMLString(html, baseURL: baseURL)
    }

    /// Re-render after the file changed on disk, keeping the reader's place.
    func reload(markdown: String) {
        web.evaluateJavaScript("window.scrollY", in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            if case .success(let v) = result { self.pendingScroll = (v as? NSNumber)?.doubleValue }
            self.load(markdown)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let y = pendingScroll, y > 0 else { return }
        pendingScroll = nil
        webView.evaluateJavaScript("window.scrollTo(0, \(y))", in: nil, in: .defaultClient) { _ in }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Our own page load is allowed; anything the user clicks is not.
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        if url.isFileURL {
            // A link to a heading in this same file, or to another file.
            let path = url.path
            if FileManager.default.fileExists(atPath: path) { onOpenFile?(url) }
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension NSColor {
    /// `#rrggbb`, for handing theme colours to a stylesheet.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02x%02x%02x",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
