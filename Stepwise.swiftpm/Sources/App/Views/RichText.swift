import SwiftUI
import WebKit

/// 显示 Markdown + LaTeX 公式（KaTeX 排版）。
/// 行内公式 $...$ 或 \(...\)，独立公式 $$...$$ 或 \[...\]，化学式 \ce{...}。
struct RichText: View {
    let text: String
    var scale: Double = 1

    @State private var height: CGFloat

    init(_ text: String, scale: Double = 1) {
        self.text = text
        self.scale = scale
        // 渲染完成前的估计高度，减少跳动
        let lines = text.components(separatedBy: "\n").reduce(0) { $0 + max(1, $1.count / 45 + 1) }
        _height = State(initialValue: CGFloat(min(lines, 40)) * 26 * CGFloat(scale))
    }

    var body: some View {
        MathWebView(text: text, scale: scale, height: $height)
            .frame(height: max(height, 18))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - WKWebView 包装

@MainActor
final class MathWebCoordinator: NSObject, WKNavigationDelegate {
    var height: Binding<CGFloat>
    weak var webView: WKWebView?
    private var loaded = false
    private var lastContent: String?
    private var lastScale: Double?

    init(height: Binding<CGFloat>) {
        self.height = height
    }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptHandler(self), name: "height")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        web.setValue(false, forKey: "drawsBackground")
        #endif
        webView = web
        if let page = MathAssets.pageURL {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            web.loadHTMLString(MathTemplate.html, baseURL: URL(string: "https://stepwise.app/"))
        }
        return web
    }

    func update(text: String, scale: Double) {
        guard text != lastContent || scale != lastScale else { return }
        lastContent = text
        lastScale = scale
        if loaded { push() }
    }

    private func push() {
        guard let text = lastContent,
              let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("setContent(\(json)[0], \(lastScale ?? 1))")
    }

    func receivedHeight(_ value: CGFloat) {
        if abs(height.wrappedValue - value) > 0.5 { height.wrappedValue = value }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loaded = true
            push()
        }
    }
}

/// 避免 WKUserContentController 强引用 coordinator 造成内存泄漏
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: MathWebCoordinator?
    init(_ target: MathWebCoordinator) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let number = message.body as? NSNumber else { return }
        let value = CGFloat(number.doubleValue)
        MainActor.assumeIsolated { target?.receivedHeight(value) }
    }
}

#if os(iOS)
struct MathWebView: UIViewRepresentable {
    let text: String
    let scale: Double
    @Binding var height: CGFloat

    func makeCoordinator() -> MathWebCoordinator { MathWebCoordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let web = context.coordinator.makeWebView()
        context.coordinator.update(text: text, scale: scale)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.update(text: text, scale: scale)
    }
}
#else
struct MathWebView: NSViewRepresentable {
    let text: String
    let scale: Double
    @Binding var height: CGFloat

    func makeCoordinator() -> MathWebCoordinator { MathWebCoordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let web = context.coordinator.makeWebView()
        context.coordinator.update(text: text, scale: scale)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.update(text: text, scale: scale)
    }
}
#endif

// MARK: - 本地 KaTeX

/// 首次使用时把内嵌的 KaTeX 写到本地目录，之后所有公式都离线排版。
enum MathAssets {
    /// 本地页面地址；写入失败时为 nil，页面改用 CDN 加载 KaTeX
    static let pageURL: URL? = {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return try? install(into: support.appendingPathComponent("katex-\(KatexAssets.version)", isDirectory: true))
    }()

    static func install(into dir: URL) throws -> URL {
        let fm = FileManager.default
        let marker = dir.appendingPathComponent(".complete")
        if !fm.fileExists(atPath: marker.path) {
            let fonts = dir.appendingPathComponent("fonts", isDirectory: true)
            let contrib = dir.appendingPathComponent("contrib", isDirectory: true)
            try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
            try fm.createDirectory(at: contrib, withIntermediateDirectories: true)
            try Data(KatexAssets.js.utf8).write(to: dir.appendingPathComponent("katex.min.js"), options: .atomic)
            try Data(KatexAssets.css.utf8).write(to: dir.appendingPathComponent("katex.min.css"), options: .atomic)
            try Data(KatexAssets.mhchem.utf8).write(to: contrib.appendingPathComponent("mhchem.min.js"), options: .atomic)
            for font in KatexAssets.fonts {
                guard let data = Data(base64Encoded: font.base64) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: fonts.appendingPathComponent(font.name), options: .atomic)
            }
            try Data().write(to: marker)
        }
        // 页面模板每次启动都检查一遍，App 更新后自动换成新模板
        let page = dir.appendingPathComponent("page.html")
        let html = Data(MathTemplate.html.utf8)
        if (try? Data(contentsOf: page)) != html {
            try html.write(to: page, options: .atomic)
        }
        return page
    }
}

// MARK: - 页面模板

enum MathTemplate {
    /// 优先加载同目录下的本地 KaTeX；本地失败时依次尝试国内外 CDN 镜像。
    static let html = #"""
    <!doctype html>
    <html><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <style>
    :root{color-scheme:light dark;--scale:1}
    html{font:-apple-system-body}
    html,body{margin:0;padding:0;background:transparent}
    body{font-family:-apple-system,"PingFang SC","Hiragino Sans GB","Helvetica Neue",sans-serif;font-size:calc(1em * var(--scale));line-height:1.7;color:#1c1c1e;overflow-wrap:anywhere;-webkit-text-size-adjust:100%;-webkit-user-select:text;-webkit-touch-callout:default}
    @media (prefers-color-scheme: dark){body{color:#f2f2f7}}
    #c{display:flow-root}
    #c>:first-child{margin-top:0}
    #c>:last-child{margin-bottom:0}
    p{margin:0 0 .6em}
    h4{font-size:1.06em;margin:.7em 0 .35em}
    ul{margin:.2em 0 .6em;padding-left:1.3em}
    li{margin:.2em 0}
    strong{font-weight:600}
    code{font-family:ui-monospace,Menlo,monospace;font-size:.88em;background:rgba(127,127,127,.15);padding:.1em .35em;border-radius:4px}
    pre{background:rgba(127,127,127,.12);padding:.6em .8em;border-radius:8px;overflow-x:auto;margin:.4em 0 .6em}
    pre code{background:none;padding:0}
    table{border-collapse:collapse;margin:.4em 0 .7em;display:block;overflow-x:auto;max-width:100%}
    th,td{border:1px solid rgba(127,127,127,.35);padding:.3em .65em;text-align:left}
    th{background:rgba(127,127,127,.1);font-weight:600}
    hr{border:none;border-top:1px solid rgba(127,127,127,.3);margin:.9em 0}
    .katex{font-size:1.12em}
    .katex .base{margin:.2em 0}
    .katex-display{margin:.5em 0;overflow-x:auto;overflow-y:hidden;padding:.2em 0}
    .tex{font-family:ui-monospace,Menlo,monospace;font-size:.92em;opacity:.75}
    </style>
    </head><body><div id="c"></div>
    <script>
    var SRC = "", READY = false;
    var MIRRORS = [
      "",
      "https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/",
      "https://cdn.bootcdn.net/ajax/libs/KaTeX/0.16.9/",
      "https://cdn.staticfile.net/KaTeX/0.16.9/",
      "https://unpkg.com/katex@0.16.9/dist/",
      "https://cdnjs.cloudflare.com/ajax/libs/KaTeX/0.16.9/"
    ];
    var box = document.getElementById("c");

    function post() {
      var h = Math.ceil(box.getBoundingClientRect().height);
      try { window.webkit.messageHandlers.height.postMessage(h); } catch (e) {}
    }
    new ResizeObserver(post).observe(box);

    function loadScript(url, ok, fail) {
      var s = document.createElement("script"), done = false;
      var timer = setTimeout(function () { if (!done) { done = true; fail(); } }, 5000);
      s.onload = function () { if (!done) { done = true; clearTimeout(timer); ok(); } };
      s.onerror = function () { if (!done) { done = true; clearTimeout(timer); fail(); } };
      s.src = url;
      document.head.appendChild(s);
    }

    function loadKatex() {
      (function attempt(k) {
        if (k >= MIRRORS.length) return;
        var base = MIRRORS[k];
        loadScript(base + "katex.min.js", function () {
          window.KATEX_BASE = base || "local";
          var link = document.createElement("link");
          link.rel = "stylesheet";
          link.href = base + "katex.min.css";
          link.onload = function () { draw(); };
          document.head.appendChild(link);
          READY = true;
          draw();
          loadScript(base + "contrib/mhchem.min.js", draw, function () {});
        }, function () { attempt(k + 1); });
      })(0);
    }

    function esc(s) {
      return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function math(tex, display) {
      if (READY && window.katex) {
        try {
          return katex.renderToString(tex, { displayMode: display, throwOnError: false, strict: "ignore", output: "html" });
        } catch (e) {}
      }
      return '<span class="tex">' + esc(display ? "$$" + tex + "$$" : "$" + tex + "$") + "</span>";
    }

    function inline(s) {
      return s
        .replace(/`([^`\n]+)`/g, "<code>$1</code>")
        .replace(/\*\*([^*\n]+?)\*\*/g, "<strong>$1</strong>");
    }

    function md(src) {
      var codes = [], maths = [];
      src = String(src).replace(/\r\n?/g, "\n");
      src = src.replace(/```[^\n]*\n?([\s\S]*?)```/g, function (m, c) {
        codes.push(c); return "\n\u0001" + (codes.length - 1) + "\u0001\n";
      });
      // 行内公式用 \u0002 标记，独立公式用 \u0003 标记（独立公式两侧不再额外换行）
      function put(t, d) { maths.push([t, d]); var k = d ? "\u0003" : "\u0002"; return k + (maths.length - 1) + k; }
      src = src
        .replace(/\$\$([\s\S]+?)\$\$/g, function (m, t) { return put(t, true); })
        .replace(/\\\[([\s\S]+?)\\\]/g, function (m, t) { return put(t, true); })
        .replace(/\\\(([\s\S]+?)\\\)/g, function (m, t) { return put(t, false); })
        .replace(/\$([^$\n]+?)\$/g, function (m, t) { return put(t, false); })
        // 最后处理没有包在 $ 里的 \begin{...}\end{...}（行内公式里的矩阵等已在上一步取走）
        .replace(/\\begin\{([a-zA-Z*]+)\}[\s\S]*?\\end\{\1\}/g, function (m) { return put(m, true); });
      src = esc(src);

      var lines = src.split("\n"), out = [], para = [], list = null;
      function flushPara() { if (para.length) { out.push("<p>" + para.map(inline).join("<br>") + "</p>"); para = []; } }
      function flushList() { if (list) { out.push("<ul>" + list.map(function (x) { return "<li>" + inline(x) + "</li>"; }).join("") + "</ul>"); list = null; } }
      function cells(row) { return row.replace(/^\||\|$/g, "").split("|").map(function (c) { return inline(c.trim()); }); }

      for (var i = 0; i < lines.length; i++) {
        var line = lines[i], t = line.trim(), m;
        if (!t) { flushPara(); flushList(); continue; }
        if (/^\u0001\d+\u0001$/.test(t)) { flushPara(); flushList(); out.push(t); continue; }
        if ((m = t.match(/^#{1,6}\s+(.*)$/))) { flushPara(); flushList(); out.push("<h4>" + inline(m[1]) + "</h4>"); continue; }
        if (/^(-{3,}|\*{3,})$/.test(t)) { flushPara(); flushList(); out.push("<hr>"); continue; }
        if (t.charAt(0) === "|" && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
          flushPara(); flushList();
          var head = cells(t), body = [];
          i += 2;
          while (i < lines.length && lines[i].trim().charAt(0) === "|") { body.push(cells(lines[i].trim())); i++; }
          i--;
          var h = "<table><tr>" + head.map(function (c) { return "<th>" + c + "</th>"; }).join("") + "</tr>";
          body.forEach(function (r) { h += "<tr>" + r.map(function (c) { return "<td>" + c + "</td>"; }).join("") + "</tr>"; });
          out.push(h + "</table>");
          continue;
        }
        if ((m = line.match(/^\s*[-*•]\s+(.*)$/))) { flushPara(); (list = list || []).push(m[1]); continue; }
        flushList();
        para.push(t);
      }
      flushPara(); flushList();

      return out.join("")
        .replace(/(?:<br>)?\u0003(\d+)\u0003(?:<br>)?/g, function (m, k) { return math(maths[k][0], true); })
        .replace(/\u0002(\d+)\u0002/g, function (m, k) { return math(maths[k][0], false); })
        .replace(/\u0001(\d+)\u0001/g, function (m, k) { return "<pre><code>" + esc(codes[k]) + "</code></pre>"; });
    }

    function draw() { box.innerHTML = md(SRC); post(); }

    function setContent(s, scale) {
      SRC = s;
      document.documentElement.style.setProperty("--scale", scale || 1);
      draw();
    }

    loadKatex();
    </script>
    </body></html>
    """#
}
