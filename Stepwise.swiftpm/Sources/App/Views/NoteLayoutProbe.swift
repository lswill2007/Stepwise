import SwiftUI
import WebKit

/// 在看不见的地方按笔记的纸宽排版几段文字，量出各自的高度（纸上的坐标，和笔迹的坐标一致）。
/// 往一块笔记中间插内容时用：量出插入点在哪、多出来多高，才能把下面的笔迹跟着挪
@MainActor
enum NoteLayoutProbe {
    /// 排版不出来（KaTeX 没加载好等）时为 nil
    static func heights(of texts: [String], width: CGFloat, tone: RichTone) async -> [CGFloat]? {
        guard !texts.isEmpty else { return [] }
        let web = WKWebView(frame: CGRect(x: -width - 400, y: 0, width: width, height: 400))
        #if os(iOS)
        // 放进窗口（在屏幕外面），网页才会正常加载和排版
        web.isUserInteractionEnabled = false
        web.isOpaque = false
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        window?.addSubview(web)
        #endif
        defer { web.removeFromSuperview() }

        if let page = MathAssets.pageURL {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            web.loadHTMLString(MathTemplate.html, baseURL: URL(string: "https://stepwise.app/"))
        }

        // 等 KaTeX 和它的样式表加载好，否则公式的高度不对
        var ready = false
        for _ in 0..<80 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return nil }
            if await isTrue(web, "typeof READY !== 'undefined' && READY && window.CSS_OK === true") {
                ready = true
                break
            }
        }
        guard ready else { return nil }

        // 先排一遍最长的那段，等用到的字体都加载完再逐段量
        let script = """
        setContent(texts[texts.length - 1], 1, tone, "");
        await document.fonts.ready;
        var out = [];
        for (var i = 0; i < texts.length; i++) {
          setContent(texts[i], 1, tone, "");
          out.push(box.getBoundingClientRect().height);
        }
        return out;
        """
        let value = await withCheckedContinuation { (done: CheckedContinuation<[Double]?, Never>) in
            web.callAsyncJavaScript(script, arguments: ["texts": texts, "tone": tone.rawValue],
                                    in: nil, in: .page) { result in
                guard case .success(let value) = result, let numbers = value as? [NSNumber] else {
                    done.resume(returning: nil)
                    return
                }
                done.resume(returning: numbers.map(\.doubleValue))
            }
        }
        guard let value, value.count == texts.count else { return nil }
        // 页面上每一块的高度是向上取整的（见 RichText 的 post()）
        return value.map { CGFloat($0.rounded(.up)) }
    }

    private static func isTrue(_ web: WKWebView, _ js: String) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            web.evaluateJavaScript(js) { value, _ in done.resume(returning: value as? Bool == true) }
        }
    }
}
