import SwiftUI
import WebKit

/// Mail gövdesini güvenli gösterir: JavaScript kapalı, uzak kaynaklar varsayılan olarak engelli,
/// linkler varsayılan tarayıcıda açılır. Yükseklik içeriğe göre ayarlanır, kaydırma üst ScrollView'a geçer.
struct MailBodyView: View {
    let html: String
    let allowRemote: Bool
    /// Ölçüm gelene kadar düz metinden tahmin edilen yükseklik; yüklenirken düzen zıplamasın
    var estimatedHeight: CGFloat = 24
    @State private var measuredHeight: CGFloat?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SettingsKey.darkMailStyle) private var darkMailStyle = DarkMailStyle.lightCard.rawValue

    /// Kendi renkleri olan (tasarlanmış) mailler koyu temada okunmaz; açık kartta ya da ters çevrilerek gösterilir
    private var mode: MailHTML.Mode {
        guard colorScheme == .dark, MailHTML.isDesigned(html) else { return .adaptive }
        return DarkMailStyle(rawValue: darkMailStyle) == .inverted ? .inverted : .light
    }

    var body: some View {
        let mode = self.mode
        MailWebView(html: html, allowRemote: allowRemote, mode: mode, height: $measuredHeight)
            .frame(height: measuredHeight ?? estimatedHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(mode == .light ? 18 : 0)
            .background {
                if mode == .light {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white)
                }
            }
            .opacity(measuredHeight == nil ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: measuredHeight == nil)
    }

    static func estimate(for text: String, hasImages: Bool) -> CGFloat {
        let paragraphs = text.split(separator: "\n")
        let lines = paragraphs.reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 95))) }
        return CGFloat(lines) * 22 + CGFloat(max(0, paragraphs.count - 1)) * 10 + (hasImages ? 220 : 0)
    }
}

private struct MailWebView: NSViewRepresentable {
    let html: String
    let allowRemote: Bool
    let mode: MailHTML.Mode
    @Binding var height: CGFloat?

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PassthroughWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        let webView = PassthroughWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.onWidthChange = { [weak coordinator = context.coordinator, weak webView] in
            guard let webView else { return }
            coordinator?.measure(webView)
        }
        context.coordinator.load(html: html, allowRemote: allowRemote, mode: mode, into: webView)
        return webView
    }

    func updateNSView(_ webView: PassthroughWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.load(html: html, allowRemote: allowRemote, mode: mode, into: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat?>
        private var loaded: (html: String, allowRemote: Bool, mode: MailHTML.Mode)?

        init(height: Binding<CGFloat?>) { self.height = height }

        func load(html: String, allowRemote: Bool, mode: MailHTML.Mode, into webView: WKWebView) {
            if let loaded, loaded.html == html, loaded.allowRemote == allowRemote, loaded.mode == mode { return }
            loaded = (html, allowRemote, mode)
            // Açık kartta sayfa açık temada çizilir; tasarımcının renkleri olduğu gibi görünür
            webView.appearance = mode == .light ? NSAppearance(named: .aqua) : nil
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            var content = html
            if !allowRemote {
                // İki katman: kaynak adresleri HTML'den silinir, derlenmiş kural hazırsa o da eklenir
                content = RemoteContentBlocker.stripRemoteSources(html)
                if let rules = RemoteContentBlocker.cached { controller.add(rules) }
            }
            webView.loadHTMLString(MailHTML.document(content, mode: mode), baseURL: nil)
        }

        func measure(_ webView: WKWebView) {
            let script = "document.getElementById('posta-root').getBoundingClientRect().height"
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self, let value = (result as? NSNumber)?.doubleValue else { return }
                let newHeight = max(20, ceil(value) + 4)
                if abs(newHeight - (self.height.wrappedValue ?? 0)) > 1 {
                    self.height.wrappedValue = newHeight
                }
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let loaded else { return }
            self.loaded = nil
            load(html: loaded.html, allowRemote: loaded.allowRemote, mode: loaded.mode, into: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            // Görseller yüklendikçe yükseklik değişebilir
            Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(for: .milliseconds(400))
                if let webView { self?.measure(webView) }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                return .cancel
            }
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            return scheme == "about" || scheme == nil ? .allow : .cancel
        }
    }
}

final class PassthroughWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            onWidthChange?()
        }
    }
}

enum MailHTML {
    enum Mode: Equatable {
        /// Temaya uyar: şeffaf zemin, sistem metin rengi (düz metin ve yazışmalar)
        case adaptive
        /// Koyu temada tasarlanmış mail: açık temada, beyaz kartın üzerinde
        case light
        /// Koyu temada tasarlanmış mail: renkler ters çevrilir, görseller korunur
        case inverted
    }

    /// Kendi renk ve zeminini tanımlayan mail (bülten, bildirim, fatura…)
    static func isDesigned(_ html: String) -> Bool {
        html.range(of: #"(?i)(bgcolor\s*=|background(-color)?\s*:|<table|[^-]color\s*:\s*(#|rgb|black|white))"#, options: .regularExpression) != nil
    }

    static func document(_ body: String, mode: Mode = .adaptive) -> String {
        let scheme = mode == .adaptive ? "light dark" : "light"
        let modeStyle: String
        switch mode {
        case .adaptive:
            modeStyle = ""
        case .light:
            modeStyle = "body { color: #1d1d1f; }"
        case .inverted:
            // Sayfa ters çevrilir, görseller ikinci kez çevrilerek aslına döner
            modeStyle = """
            html { filter: invert(1) hue-rotate(180deg); background: #e8e8e8 !important; }
            img, video, picture, svg, [style*="background-image"], [background] { filter: invert(1) hue-rotate(180deg); }
            body { color: #1d1d1f; }
            """
        }
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="\(scheme)">
        <style>
        :root { color-scheme: \(scheme); }
        html, body { margin: 0; padding: 0; background: transparent; }
        body {
          font: 14px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          color: CanvasText;
          -webkit-font-smoothing: antialiased;
          overflow-wrap: anywhere;
        }
        #posta-root { display: flow-root; }
        p { margin: 0 0 10px; }
        p:last-child { margin-bottom: 0; }
        a { color: LinkText; color: -apple-system-blue; text-decoration: none; }
        a:hover { text-decoration: underline; }
        img { max-width: 100%; height: auto; }
        ul, ol { padding-left: 22px; margin: 6px 0 10px; }
        blockquote { margin: 8px 0; padding: 2px 0 2px 12px; border-left: 3px solid rgba(127,127,127,.35); color: GrayText; }
        code { font: 12.5px ui-monospace, "SF Mono", monospace; padding: 1px 4px; border-radius: 4px; background: rgba(127,127,127,.14); }
        pre { font: 12px ui-monospace, "SF Mono", monospace; white-space: pre-wrap; }
        table { max-width: 100%; }
        h1, h2, h3 { line-height: 1.25; }
        \(modeStyle)
        </style>
        </head><body><div id="posta-root">\(body)</div></body></html>
        """
    }
}

/// Uzak görsel, stil ve fontları engelleyen içerik kuralı. Takip pikselleri böylece çalışmaz.
enum RemoteContentBlocker {
    private(set) static var cached: WKContentRuleList?

    /// Uygulama açılışında bir kez derlenir; mail yüklemesi bunu beklemez.
    static func prepare() {
        guard cached == nil else { return }
        // WebKit içerik kuralları regex'te | desteklemiyor; her şema ayrı kural
        let types = #"["image","style-sheet","script","font","raw","svg-document","media","popup"]"#
        let json = "[" + ["^https?://", "^wss?://", "^ftp://"]
            .map { #"{"trigger":{"url-filter":"\#($0)","resource-type":\#(types)},"action":{"type":"block"}}"# }
            .joined(separator: ",") + "]"
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "posta.block-remote",
            encodedContentRuleList: json
        ) { list, _ in
            DispatchQueue.main.async { cached = list }
        }
    }

    static func stripRemoteSources(_ html: String) -> String {
        html
            .replacingOccurrences(
                of: #"(src|background|srcset|poster)\s*=\s*(["'])\s*(https?:)?//[^"']*\2"#,
                with: "$1=\"\"",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"url\(\s*(["']?)\s*(https?:)?//[^)]*\)"#,
                with: "none",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"<link\b[^>]*>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
    }
}
