import SwiftUI
import WebKit

/// 文字颜色：默认跟随深浅色；red 是页边的红笔批注
enum RichTone: String {
    case normal = "", red
    /// 旧笔记：保持原来的换行方式（行内公式可以拆开），上面的笔迹才和文字对得上。字体也是原来的黑体
    case legacy
    /// 换成试卷字体之前就写画过的笔记：字体还用原来的黑体，换了字每行排的字数就变了，笔迹和文字对不上
    case sans
}

/// 显示 Markdown + LaTeX 公式（KaTeX 排版）。
/// 行内公式 $...$ 或 \(...\)，独立公式 $$...$$ 或 \[...\]，化学式 \ce{...}。
struct RichText: View {
    let text: String
    var scale: Double = 1
    var tone: RichTone = .normal
    /// 选中文字时回调（选中的文字；取消选中时为空）。笔记里用来选中提问
    var onSelect: ((String) -> Void)?
    /// 拿到显示文字的视图：笔记的涂鸦层把书写手势挂上去
    var host: InkHost?
    /// 临时荧光笔标出的一句话（看笔记时的重点）；找不到这句话就把整块淡淡地标一下
    var highlight: String?
    /// 网页把内容排好版（量出高度）时回调；内容变高变矮会再调。资料库的预览用它等排好了再截图
    var onRendered: (() -> Void)?
    /// 记不记量到的高度：流式生成、正在打字的文字每次都不一样，记下来只会把真正要用的挤掉
    var remember = true

    @State private var height: CGFloat
    /// 网页排好版了（公式也排好）
    @State private var shown = false
    /// 摆着几行灰条当加载中：排得快的不摆（免得一闪），过一会儿还没排好才摆
    @State private var waiting = false
    @State private var waitStart: Date?

    init(_ text: String, scale: Double = 1, tone: RichTone = .normal, onSelect: ((String) -> Void)? = nil,
         host: InkHost? = nil, highlight: String? = nil, onRendered: (() -> Void)? = nil, remember: Bool = true) {
        self.text = text
        self.scale = scale
        self.tone = tone
        self.onSelect = onSelect
        self.host = host
        self.highlight = highlight
        self.onRendered = onRendered
        self.remember = remember
        // 渲染完成前的高度：排过版的用上次量到的，没排过的估一个，减少跳动
        let lines = text.components(separatedBy: "\n").reduce(0) { $0 + max(1, $1.count / 45 + 1) }
        _height = State(initialValue: (remember ? Self.measured[HeightKey(text: text, scale: scale, tone: tone)] : nil)
                        ?? CGFloat(min(lines, 40)) * 26 * CGFloat(scale))
    }

    var body: some View {
        MathWebView(text: text, scale: scale, tone: tone, highlight: highlight, onSelect: onSelect, host: host, height: $height,
                    shown: $shown, onRendered: onRendered)
            .opacity(shown && !waiting ? 1 : 0)
            .frame(height: max(height, 18))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if waiting { RichTextPlaceholder(height: max(height, 18), scale: scale).transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.2), value: shown && !waiting)
            .task(id: shown) { await placeholder() }
            // 记住量到的高度：页面滚动回收后重建时直接用，不会先按估计高度排再变，把页面顶得跳一下
            .onChange(of: height) {
                guard remember, shown else { return }
                // 满了只扔掉一半，不把正在看的几块的高度一起清掉
                if Self.measured.count > 400 {
                    for key in Self.measured.keys.shuffled().prefix(200) { Self.measured[key] = nil }
                }
                Self.measured[HeightKey(text: text, scale: scale, tone: tone)] = height
            }
    }

    /// 0.4 秒内排好的直接显示；没排好才摆灰条，摆了至少留 0.6 秒，不一闪而过。
    /// 网页那边万一一直没报排好（公式样式没载进来之类），3 秒后也照样显示出来。
    /// 跟着 shown 重新跑：排好时才醒来收灰条，不用每 50 毫秒看一次
    private func placeholder() async {
        if shown {
            guard waiting else { return }
            let held = Date().timeIntervalSince(waitStart ?? .distantPast)
            if held < 0.6 { try? await Task.sleep(nanoseconds: UInt64((0.6 - held) * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            waiting = false
            return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !shown, !Task.isCancelled else { return }
        waiting = true
        waitStart = Date()
        try? await Task.sleep(nanoseconds: 2_600_000_000)
        guard !shown, !Task.isCancelled else { return }
        shown = true   // 再跑一次上面那段：已经摆够 0.6 秒，马上收掉灰条
    }

    private struct HeightKey: Hashable {
        let text: String
        let scale: Double
        let tone: RichTone
    }
    @MainActor private static var measured: [HeightKey: CGFloat] = [:]
}

/// 排版中的占位：按这块的高度画几行灰条（最后一行短一点），轻轻地一明一暗
private struct RichTextPlaceholder: View {
    let height: CGFloat
    let scale: Double
    @State private var dim = false

    var body: some View {
        let line = 26 * CGFloat(scale)
        let count = max(1, min(Int(height / line), 14))
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: line * 0.45) {
                ForEach(0..<count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: line * 0.2)
                        .fill(Color.secondary.opacity(0.16))
                        .frame(width: geo.size.width * Self.widths[i % Self.widths.count] * (i == count - 1 && count > 1 ? 0.6 : 1),
                               height: line * 0.55)
                }
            }
            .padding(.top, line * 0.2)
        }
        .frame(height: height, alignment: .topLeading)
        .clipped()
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let widths: [CGFloat] = [1, 0.94, 0.97, 0.9, 1, 0.92]
}

// MARK: - WKWebView 包装

@MainActor
final class MathWebCoordinator: NSObject, WKNavigationDelegate {
    var height: Binding<CGFloat>
    var shown: Binding<Bool>
    var onSelect: ((String) -> Void)?
    var onRendered: (() -> Void)?
    weak var webView: WKWebView?
    private var loaded = false
    private var lastContent: String?
    private var lastScale: Double?
    private var lastTone: RichTone = .normal
    private var lastHighlight: String?

    init(height: Binding<CGFloat>, shown: Binding<Bool>) {
        self.height = height
        self.shown = shown
    }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptHandler(self), name: "height")
        config.userContentController.add(WeakScriptHandler(self), name: "selection")
        config.userContentController.add(WeakScriptHandler(self), name: "ready")
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
        MathAssets.load(web)
        return web
    }

    func update(text: String, scale: Double, tone: RichTone, highlight: String? = nil) {
        guard text != lastContent || scale != lastScale || tone != lastTone || highlight != lastHighlight else { return }
        lastContent = text
        lastScale = scale
        lastTone = tone
        lastHighlight = highlight
        if loaded { push() }
    }

    private func push() {
        guard let text = lastContent,
              let data = try? JSONSerialization.data(withJSONObject: [text, lastHighlight ?? ""]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("setContent(\(json)[0], \(lastScale ?? 1), '\(lastTone.rawValue)', \(json)[1])")
    }

    func receivedHeight(_ value: CGFloat) {
        if abs(height.wrappedValue - value) > 0.5 { height.wrappedValue = value }
        // 网页刚载入、内容还没放进去时也会报一次 0
        if value > 4 { onRendered?() }
    }

    /// 网页里内容连同公式都排好了
    func receivedReady() {
        if !shown.wrappedValue { shown.wrappedValue = true }
    }

    func receivedSelection(_ text: String) {
        onSelect?(text)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loaded = true
            push()
        }
    }

    /// 系统内存紧张时会结束网页的进程（常在 App 进后台时），网页就一直是空白：重新载入，载好后把内容再排一遍
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            loaded = false
            MathAssets.load(webView)
        }
    }
}

/// 避免 WKUserContentController 强引用 coordinator 造成内存泄漏
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: MathWebCoordinator?
    init(_ target: MathWebCoordinator) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "selection", let text = message.body as? String {
            MainActor.assumeIsolated { target?.receivedSelection(text) }
            return
        }
        if message.name == "ready" {
            MainActor.assumeIsolated { target?.receivedReady() }
            return
        }
        guard let number = message.body as? NSNumber else { return }
        let value = CGFloat(number.doubleValue)
        MainActor.assumeIsolated { target?.receivedHeight(value) }
    }
}

#if os(iOS)
struct MathWebView: UIViewRepresentable {
    let text: String
    let scale: Double
    let tone: RichTone
    let highlight: String?
    let onSelect: ((String) -> Void)?
    let host: InkHost?
    @Binding var height: CGFloat
    @Binding var shown: Bool
    var onRendered: (() -> Void)?

    func makeCoordinator() -> MathWebCoordinator { MathWebCoordinator(height: $height, shown: $shown) }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.onSelect = onSelect
        context.coordinator.onRendered = onRendered
        let web = context.coordinator.makeWebView()
        context.coordinator.update(text: text, scale: scale, tone: tone, highlight: highlight)
        #if os(iOS)
        host?.view = web
        #endif
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.shown = $shown
        context.coordinator.onSelect = onSelect
        context.coordinator.onRendered = onRendered
        context.coordinator.update(text: text, scale: scale, tone: tone, highlight: highlight)
    }
}
#else
struct MathWebView: NSViewRepresentable {
    let text: String
    let scale: Double
    let tone: RichTone
    let highlight: String?
    let onSelect: ((String) -> Void)?
    let host: InkHost?
    @Binding var height: CGFloat
    @Binding var shown: Bool
    var onRendered: (() -> Void)?

    func makeCoordinator() -> MathWebCoordinator { MathWebCoordinator(height: $height, shown: $shown) }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.onSelect = onSelect
        context.coordinator.onRendered = onRendered
        let web = context.coordinator.makeWebView()
        context.coordinator.update(text: text, scale: scale, tone: tone, highlight: highlight)
        #if os(iOS)
        host?.view = web
        #endif
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.shown = $shown
        context.coordinator.onSelect = onSelect
        context.coordinator.onRendered = onRendered
        context.coordinator.update(text: text, scale: scale, tone: tone, highlight: highlight)
    }
}
#endif

// MARK: - 本地 KaTeX

/// 首次使用时把内嵌的 KaTeX 写到本地目录，之后所有公式都离线排版。
enum MathAssets {
    /// 本地页面地址；写入失败时为 nil，页面改用 CDN 加载 KaTeX
    static var pageURL: URL? { installed?.page }
    /// 正文的试卷字体（ExamFont）放进网页目录了；没放进去就照旧用系统字体
    static var serif: Bool { installed?.serif ?? false }

    private static let installed: (page: URL, serif: Bool)? = {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return try? install(into: support.appendingPathComponent("katex-\(KatexAssets.version)", isDirectory: true))
    }()

    /// 预热用的隐藏网页，题目显示出来之后就放掉
    @MainActor private static var warmView: WKWebView?

    /// 加载页画出来后调用（见 LaunchCover）：后台把 KaTeX 写到本地（第一次启动要解压字体，不能卡住界面），
    /// 再开一个隐藏网页先把 WebKit 进程和 KaTeX 加载起来，题目里的公式就不用从头等
    @MainActor static func prewarm() {
        guard warmView == nil else { return }
        Task.detached(priority: .userInitiated) {
            _ = pageURL
            await MainActor.run {
                let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
                load(web)
                warmView = web
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { warmView = nil }
            }
        }
    }

    /// 加载公式页面：本地 KaTeX 写入失败时用模板（从 CDN 加载 KaTeX）
    @MainActor static func load(_ web: WKWebView) {
        if let page = pageURL {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            web.loadHTMLString(MathTemplate.html(serif: false), baseURL: URL(string: "https://stepwise.app/"))
        }
    }

    static func install(into dir: URL) throws -> (page: URL, serif: Bool) {
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
        // 正文的试卷字体：每次启动检查一遍，缺了、换了就重放
        let serif = ExamFont.install(into: dir.appendingPathComponent("fonts", isDirectory: true))
        // 页面模板每次启动都检查一遍，App 更新后自动换成新模板
        let page = dir.appendingPathComponent("page.html")
        let html = Data(MathTemplate.html(serif: serif).utf8)
        if (try? Data(contentsOf: page)) != html {
            try html.write(to: page, options: .atomic)
        }
        return (page, serif)
    }
}

// MARK: - 页面模板

enum MathTemplate {
    /// Markdown + 公式排版（md、math 等函数）：页面里的显示和导出 PDF 共用，排出来一模一样。
    /// 用到全局的 READY（KaTeX 已加载）和 katex
    static let markdownJS = #"""
    function esc(s) {
      return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    // 模型常把表格列格式里的竖线写成 \|（Markdown 表格里转义竖线的习惯），KaTeX 不认，整段会报错变红：改回 |
    function fixTex(tex) {
      return tex.replace(/\\begin\{(array|tabular)\}\{([^}]*)\}/g, function (m, env, spec) {
        return "\\begin{" + env + "}{" + spec.replace(/\\\|/g, "|") + "}";
      });
    }

    function math(tex, display) {
      if (READY && window.katex) {
        try {
          return katex.renderToString(fixTex(tex), { displayMode: display, throwOnError: false, strict: "ignore", output: "html" });
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
        .replace(/\u0002(\d+)\u0002([，。、；：！？）」』”’,.;:!?)\]]*)/g, function (m, k, p) {
          return '<span class="im">' + math(maths[k][0], false) + p + "</span>";
        })
        .replace(/\u0001(\d+)\u0001/g, function (m, k) { return "<pre><code>" + esc(codes[k]) + "</code></pre>"; });
    }

    """#

    /// 正文字体的样式。serif：试卷字体（ExamFont）可用。写画过的旧笔记（.sans / .legacy）一直用原来的黑体。
    /// 公式里的中文（\text{…}）KaTeX 自己不带字，跟着正文走
    static func fontCSS(serif: Bool) -> String {
        guard serif else { return "body{font-family:\(ExamFont.sansStack)}" }
        return """
        \(ExamFont.fontFaceCSS)
        body{font-family:\(ExamFont.serifStack())}
        body.sans,body.legacy{font-family:\(ExamFont.sansStack)}
        body:not(.sans):not(.legacy) .katex .cjk_fallback{font-family:ExamSong,ExamSongAlt,"PingFang SC",sans-serif}
        """
    }

    /// 优先加载同目录下的本地 KaTeX；本地失败时依次尝试国内外 CDN 镜像。
    static func html(serif: Bool) -> String {
        template.replacingOccurrences(of: "/*FONTS*/", with: fontCSS(serif: serif))
    }

    private static let template = #"""
    <!doctype html>
    <html><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <style>
    :root{color-scheme:light dark;--scale:1}
    html{font:-apple-system-body}
    html,body{margin:0;padding:0;background:transparent}
    /*FONTS*/
    body{font-size:calc(1em * var(--scale));line-height:1.7;color:#1c1c1e;overflow-wrap:anywhere;-webkit-text-size-adjust:100%;-webkit-user-select:text;-webkit-touch-callout:default}
    @media (prefers-color-scheme: dark){body{color:#f2f2f7}}
    body.red{color:#bd291f}
    @media (prefers-color-scheme: dark){body.red{color:#f5786b}}
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
    /* 行内公式连同后面的标点不拆行；整个公式比一行还宽时才允许拆（.wrap） */
    .im{white-space:nowrap}
    body.legacy .im{white-space:normal}
    .im.wrap{white-space:normal}
    /* 表格尽量不换行，放不下时恢复换行 */
    table.nw th,table.nw td{white-space:nowrap}
    .tex{font-family:ui-monospace,Menlo,monospace;font-size:.92em;opacity:.75}
    mark.hl{background:rgba(255,214,0,.5);color:inherit;border-radius:3px;padding:0 1px}
    #c.hl-all{background:rgba(255,214,0,.16);border-radius:6px}
    </style>
    </head><body><div id="c"></div>
    <script>
    var SRC = "", READY = false, FAILED = false, GOT = false;
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

    // 选中文字：停顿一下再告诉 App（笔记里选中提问）
    var selTimer = null;
    document.addEventListener("selectionchange", function () {
      clearTimeout(selTimer);
      selTimer = setTimeout(function () {
        var s = String(window.getSelection() || "").trim();
        try { window.webkit.messageHandlers.selection.postMessage(s); } catch (e) {}
      }, 300);
    });

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
        if (k >= MIRRORS.length) { FAILED = true; draw(); return; }
        var base = MIRRORS[k];
        loadScript(base + "katex.min.js", function () {
          window.KATEX_BASE = base || "local";
          var link = document.createElement("link");
          link.rel = "stylesheet";
          link.href = base + "katex.min.css";
          link.onload = function () { window.CSS_OK = true; draw(); };
          document.head.appendChild(link);
          READY = true;
          draw();
          loadScript(base + "contrib/mhchem.min.js", draw, function () {});
        }, function () { attempt(k + 1); });
      })(0);
    }

    """# + markdownJS + #"""
    var HL = "";
    // 临时荧光笔：在排版后的文字里找到这句话包上 <mark>；找不到就把整块淡淡地标一下
    function applyHL() {
      box.classList.remove("hl-all");
      if (!HL) return;
      var walker = document.createTreeWalker(box, NodeFilter.SHOW_TEXT), node;
      while ((node = walker.nextNode())) {
        var i = node.nodeValue.indexOf(HL);
        if (i < 0) continue;
        var range = document.createRange();
        range.setStart(node, i);
        range.setEnd(node, i + HL.length);
        var mark = document.createElement("mark");
        mark.className = "hl";
        range.surroundContents(mark);
        return;
      }
      box.classList.add("hl-all");
    }

    // 排版后检查：行内公式、表格放得下就不换行；独立公式稍微超宽就缩小一点放进一行
    function fit() {
      if (document.body.classList.contains("legacy")) return;
      var w = box.clientWidth;
      if (!w) return;
      box.querySelectorAll(".im").forEach(function (el) {
        el.classList.remove("wrap");
        if (el.getBoundingClientRect().width > w + 1) el.classList.add("wrap");
      });
      // 表格：先不换行；放不下就整张表的字缩小到刚好放下，缩到 0.6 还放不下才换行
      box.querySelectorAll("table").forEach(function (t) {
        t.style.fontSize = "";
        t.classList.add("nw");
        for (var k = 0; k < 3 && t.scrollWidth > t.clientWidth + 1; k++) {
          var cur = parseFloat(t.style.fontSize) || 1;
          var r = Math.max(0.6, Math.floor(cur * t.clientWidth / t.scrollWidth * 100) / 100);
          if (r >= cur) break;
          t.style.fontSize = r + "em";
        }
        if (t.scrollWidth > t.clientWidth + 1) t.classList.remove("nw");
      });
      box.querySelectorAll(".katex-display").forEach(function (d) {
        d.style.fontSize = "";
        var inner = d.firstElementChild;
        if (!inner) return;
        var need = inner.scrollWidth, have = d.clientWidth;
        if (need > have + 1) {
          var r = have / need;
          if (r >= 0.72) d.style.fontSize = (Math.floor(r * 100) / 100) + "em";
        }
      });
    }
    var lastWidth = 0;
    window.addEventListener("resize", function () {
      if (box.clientWidth !== lastWidth) { lastWidth = box.clientWidth; fit(); post(); }
    });

    // 排好了告诉 App（去掉加载中的灰条）：没有公式的马上算好；有公式的等 KaTeX 和它的样式都载好，或者载不到了
    function ready() {
      if (!GOT || !FONTS) return;
      if (!(FAILED || (READY && window.CSS_OK) || !/\$|\\[(\[]|\\begin\{/.test(SRC))) return;
      try { window.webkit.messageHandlers.ready.postMessage(1); } catch (e) {}
    }

    // 这次排版用到的字体（正文的宋体、公式字体）都载好了。没载好之前字是空的，量出来的高度也不准：载好再告诉 App 排好了
    var FONTS = false, DRAWN = 0;
    function draw() {
      box.innerHTML = md(SRC); applyHL(); fit(); lastWidth = box.clientWidth; post();
      var seq = ++DRAWN;
      FONTS = false;
      // 字体加载完宽度会变：再量一次，表格、公式按真正的宽度缩放
      var loaded = function () {
        if (seq !== DRAWN || FONTS) return;
        FONTS = true; fit(); post(); ready();
      };
      if (document.fonts && document.fonts.ready) document.fonts.ready.then(loaded); else loaded();
      // 字体一直载不到也不一直等
      setTimeout(loaded, 1200);
    }

    function setContent(s, scale, tone, hl) {
      SRC = s;
      GOT = true;
      HL = hl || "";
      document.body.className = tone || "";
      document.documentElement.style.setProperty("--scale", scale || 1);
      draw();
    }

    loadKatex();
    </script>
    </body></html>
    """#
}
