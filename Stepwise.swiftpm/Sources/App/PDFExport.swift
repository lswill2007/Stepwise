import SwiftUI
import WebKit
#if os(iOS)
import UIKit
import PencilKit
#endif

/// 导出 PDF 时带上哪些内容
struct PDFExportOptions: Equatable {
    /// 参考答案和解析（没有参考答案时用 AI 给的完整答案）
    var answers = true
    /// 我的作答：手写（印上行号）和打字的部分，以及做题状态
    var myWork = true
    /// AI 的检查、提示和对话，笔记页边的问答
    var feedback = false
    /// 用识图模型（服务商的低档模型）把手写转写成文字，排在手写图片下面
    var transcribe = false
}

/// 把笔记和题集排成一份 PDF。
/// Swift 这边拼好 HTML 骨架，Markdown 和公式交给页面里的 md()（和 App 里显示的是同一套 KaTeX 排版），
/// 再用系统的打印排版分页，生成 A4（美国、加拿大用 Letter）的 PDF：文字是真正的文字（可以选中、搜索），字体嵌在文件里，不会乱码。
@MainActor
final class PDFExporter: ObservableObject {
    /// 正在做哪一步（显示给用户）；nil 表示没在导出
    @Published var phase: String?

    func export(sets: [QuestionSet], notes: [NoteDoc], store: AppStore, options: PDFExportOptions) async throws -> URL {
        defer { phase = nil }
        phase = L("正在整理内容…")
        await Task.yield()
        var doc = PDFDocumentBuilder(store: store, options: options)
        doc.build(sets: sets, notes: notes)

        // 手写转写：并行发给识图模型，最多同时 4 个；失败的只放图片
        if options.transcribe, !doc.inks.isEmpty, store.aiConsent == true, let reader = store.handwritingReader() {
            let images = doc.inks
            let total = images.count
            phase = String(localized: "AI 正在转写手写（0/\(total)）…")
            var done = 0
            var results: [Int: String] = [:]
            await withTaskGroup(of: (Int, String?).self) { group in
                var next = 0
                while next < min(4, total) {
                    let k = next, image = images[k]
                    group.addTask { (k, await PDFExporter.transcribe(image, with: reader)) }
                    next += 1
                }
                while let (k, text) = await group.next() {
                    // 点了“取消导出”：不再发新的转写
                    if Task.isCancelled { group.cancelAll(); break }
                    results[k] = text
                    done += 1
                    phase = String(localized: "AI 正在转写手写（\(done)/\(total)）…")
                    if next < total {
                        let k = next, image = images[k]
                        group.addTask { (k, await PDFExporter.transcribe(image, with: reader)) }
                        next += 1
                    }
                }
            }
            try Task.checkCancellation()
            doc.fillTranscripts(results)
        } else {
            doc.fillTranscripts([:])
        }

        try Task.checkCancellation()
        phase = L("正在排版…")
        let html = doc.page()
        #if os(iOS)
        let data = try await PDFRenderer.render(html: html, title: doc.title)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PDF", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.fileName(doc.title) + ".pdf")
        try data.write(to: url, options: .atomic)
        return url
        #else
        throw LLMError(message: L("这台设备不支持导出 PDF。"))
        #endif
    }

    private static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\n\r")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Stepwise" : String(cleaned.prefix(80))
    }

    /// 让识图模型把手写转写成可以排版的文字（Markdown + LaTeX）；失败、空白时返回 nil
    nonisolated static func transcribe(_ image: Data, with reader: LLMClient) async -> String? {
        let system = Tutor.pick("""
            你负责把学生的手写内容转写成文字，用来排版打印。
            - 按原来的顺序和换行逐行转写；不要加行号，不要改正、补充或解释。
            - 数学公式用 LaTeX：行内用 $...$，单独占一行的用 $$...$$；化学式用 \\ce{...}。
            - 认不出的字写 [?]；画的图写一句（图：……）。
            - 只输出转写的内容。图片里没有手写时只输出（空白）。
            """, """
            You transcribe a student's handwriting so it can be typeset and printed.
            - Transcribe line by line in the original order; no line numbers; do not correct, add or explain anything.
            - Write math in LaTeX: $...$ inline, $$...$$ for a formula on its own line; chemistry with \\ce{...}.
            - Write [?] for anything illegible; describe a drawing in one short phrase (Figure: ...).
            - Output only the transcription. If there is no handwriting, output only "(blank)".
            """)
        let blank = ["（空白）", "(空白)", "(blank)", "blank", "空白"]
        // 写得多时切成几段同时转写（见 ImageUtil.horizontalStrips），空白的段不要
        let parts = await AppStore.transcribeStrips(ImageUtil.horizontalStrips(image)) { strip in
            guard let text = try? await reader.complete(
                system: system,
                messages: [LLMMessage(role: .user, parts: [.image(strip), .text(Tutor.pick("请转写。", "Transcribe it."))])],
                // 识图模型卡住（VPN 断了、代理不回）时最多等一分钟，不让导出一直停在这里
                options: RequestOptions(fast: true, transcribing: true, responseTimeout: 60)) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return blank.contains(trimmed) ? "" : trimmed
        }
        guard let parts else { return nil }
        let trimmed = parts.filter { !$0.isEmpty }.joined(separator: "\n")
        if trimmed.isEmpty { return nil }
        // 只画了图、没写字（只有一句“（图：……）”）：转写没有用，只放图片
        let figureOnly = #"^[（(]\s*(图|圖|Figure)\s*[：:][^\n]*[)）]$"#
        if trimmed.range(of: figureOnly, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        return trimmed
    }
}

// MARK: - 拼 HTML

@MainActor
struct PDFDocumentBuilder {
    let store: AppStore
    let options: PDFExportOptions
    /// 整份 PDF 的标题（只有一篇时就是它的标题）
    var title = "Stepwise"
    /// 页面里 .md 元素的 Markdown 原文，按 data-k 取
    private(set) var sources: [String] = []
    /// 要转写的手写图片（JPEG），HTML 里在 \u{1}INK序号\u{1} 的位置放转写结果
    private(set) var inks: [Data] = []
    private var body = ""
    /// 上一道题共用题干的那一组：同一组的题干只印一次
    private var lastStemGroup: UUID?

    init(store: AppStore, options: PDFExportOptions) {
        self.store = store
        self.options = options
    }

    mutating func build(sets: [QuestionSet], notes: [NoteDoc]) {
        let count = sets.count + notes.count
        if count == 1 {
            title = notes.first?.title ?? sets.first?.title ?? "Stepwise"
        } else {
            title = String(localized: "Stepwise 导出 \(Self.date(Date()))")
        }
        // 不止一篇：第一页是封面和目录
        if count > 1 {
            var list = ""
            for n in notes { list += "<li><span class=\"kind\">\(Self.esc(L("笔记")))</span>\(Self.esc(n.title))</li>" }
            for s in sets { list += "<li><span class=\"kind\">\(Self.esc(L("题集")))</span>\(Self.esc(s.title))</li>" }
            body += """
                <section class="doc cover">
                <div class="cover-brand">Stepwise</div>
                <h1>\(Self.esc(L("学习资料")))</h1>
                <div class="meta">\(Self.esc(String(localized: "\(notes.count) 篇笔记、\(sets.count) 个题集 · 导出于 \(Self.date(Date()))")))</div>
                <h2 class="toc-title">\(Self.esc(L("目录")))</h2>
                <ol class="toc">\(list)</ol>
                </section>
                """
        }
        for n in notes { addNote(n) }
        for s in sets { addSet(s) }
    }

    // MARK: 笔记

    private mutating func addNote(_ doc: NoteDoc) {
        var meta: [String] = []
        if !doc.sourceName.isEmpty { meta.append(String(localized: "来源：\(doc.sourceName)")) }
        meta.append(Self.date(doc.createdAt))
        body += "<section class=\"doc\">" + header(kind: L("笔记"), title: doc.title, meta: meta)
        let exerciseSet = store.set(doc.exerciseSetID)
        var exerciseNumber = 0
        for block in doc.blocks {
            switch block.kind {
            case .text:
                body += md(block.text)
            case .answer:
                var box = "<div class=\"box qa\">"
                if let quote = block.quote, !quote.isEmpty { box += "<blockquote>\(Self.esc(quote))</blockquote>" }
                if let q = block.question, !q.isEmpty {
                    box += "<div class=\"ask\"><span class=\"tag\">\(Self.esc(L("问")))</span>\(Self.esc(q))</div>"
                }
                box += md(block.text) + "</div>"
                body += box
            case .exercise:
                exerciseNumber += 1
                guard let set = exerciseSet, let id = block.questionID, let q = set.questions.first(where: { $0.id == id }) else { continue }
                addQuestion(q, label: String(localized: "练习 \(exerciseNumber)"))
            case .canvas:
                #if os(iOS)
                if let data = DrawingStore.load(block.id), let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty,
                   let jpeg = Self.canvasImage(drawing, width: doc.paper) {
                    body += "<div class=\"ink canvas\">" + image(jpeg, width: doc.paper) + inkSlot(jpeg) + "</div>"
                }
                #endif
            }
        }
        if options.feedback, let comments = doc.comments?.filter({ !$0.answer.isEmpty }), !comments.isEmpty {
            body += "<h3 class=\"part\">\(Self.esc(L("页边问答")))</h3>"
            for c in comments {
                body += "<div class=\"box qa\"><div class=\"ask\"><span class=\"tag\">\(Self.esc(L("问")))</span>\(Self.esc(c.question))</div>"
                    + md(c.answer) + "</div>"
            }
        }
        body += "</section>"
    }

    // MARK: 题集

    private mutating func addSet(_ set: QuestionSet) {
        var meta = [String(localized: "\(set.questions.count) 道题")]
        if options.myWork { meta.append(String(localized: "已完成 \(set.doneCount)")) }
        meta.append(Self.date(set.createdAt))
        body += "<section class=\"doc\">" + header(kind: L("题集"), title: set.title, meta: meta)
        if set.questions.isEmpty {
            body += "<p class=\"empty\">\(Self.esc(L("这个题集里还没有题目。")))</p>"
        }
        for q in set.questions {
            addQuestion(q, label: Self.questionLabel(q.label))
        }
        body += "</section>"
    }

    private static func questionLabel(_ label: String) -> String {
        let t = label.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return L("题目") }
        // 题号本身已经是“例 1”“第 3 题”“Q2”这类就原样用
        if t.first?.isNumber == true { return String(localized: "第 \(t) 题") }
        return t
    }

    private mutating func addQuestion(_ q: Question, label: String) {
        var html = "<article class=\"q\"><div class=\"qhead\"><span class=\"qlabel\">\(Self.esc(label))</span>"
        if options.myWork {
            let (text, cls): (String, String) = {
                switch q.status {
                case .todo: return (L("未作答"), "todo")
                case .wrong: return (L("待订正"), "wrong")
                case .passed: return (L("已做对"), "passed")
                case .revealed: return (L("看过答案"), "revealed")
                }
            }()
            html += "<span class=\"status \(cls)\">\(Self.esc(text))</span>"
        }
        if q.isStarred { html += "<span class=\"star\">\(Self.esc(L("收藏")))</span>" }
        html += "</div>"
        body += html
        if let stem = q.stem, !stem.isEmpty, q.stemGroup == nil || q.stemGroup != lastStemGroup {
            body += md(stem)
        }
        lastStemGroup = q.stemGroup
        body += md(q.content)
        if let given = q.supplements, !given.isEmpty {
            body += md(L("补充的条件") + L("：") + given.joined(separator: L("；")))
        }
        for id in q.imageIDs {
            if let data = ImageStore.load(id) { body += "<div class=\"figure\">" + image(data, width: nil) + "</div>" }
        }

        if options.myWork { addWork(q) }

        // 参考答案：题目自带的，没有就用 AI 给的完整答案
        let solution = q.messages.last { $0.kind == .solution }
        if options.answers {
            if let ref = q.referenceAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
                body += section(L("参考答案"), cls: "answer") + md(ref) + "</div>"
            } else if let solution, !solution.text.isEmpty {
                body += section(L("完整答案（AI）"), cls: "answer") + md(solution.text) + "</div>"
            }
        }

        if options.feedback { addFeedback(q) }
        body += "</article>"
    }

    /// 我的作答：打字的部分和手写（手写区现在的笔迹；没有时用最后一次提交的手写图片）
    private mutating func addWork(_ q: Question) {
        let lastSubmission = q.messages.last { $0.kind == .submission }
        let typed = q.draftAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (lastSubmission?.text ?? "") : q.draftAnswer
        var inner = ""
        if !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { inner += md(typed) }
        var hasInk = false
        #if os(iOS)
        if let data = DrawingStore.load(q.id), let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty,
           let (jpeg, width) = Self.ruledImage(drawing) {
            inner += "<div class=\"ink\">" + image(jpeg, width: width) + inkSlot(jpeg) + "</div>"
            hasInk = true
        }
        #endif
        if !hasInk, let submission = lastSubmission {
            for id in submission.imageIDs {
                guard let data = ImageStore.load(id) else { continue }
                inner += "<div class=\"ink\">" + image(data, width: nil) + inkSlot(data) + "</div>"
            }
        }
        guard !inner.isEmpty else { return }
        body += section(L("我的作答"), cls: "work") + inner + "</div>"
    }

    /// AI 的检查、提示和对话（按先后）
    private mutating func addFeedback(_ q: Question) {
        var items = ""
        for m in q.messages {
            let title: String
            switch m.kind {
            case .verdictCorrect: title = L("检查：对了")
            case .verdictWrong: title = L("检查：找到要改的地方")
            case .hint: title = m.isStuckHelp ? L("卡住的地方") : m.isNextStep ? L("AI 写的下一步") : L("提示")
            case .chat: title = m.role == .user ? L("我问") : L("AI 回答")
            case .solution:
                // 答案已经放在“参考答案”里，或者选了不带答案
                continue
            case .submission, .hintRequest, .solutionRequest:
                continue
            }
            guard !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(m.marks ?? []).isEmpty else { continue }
            var item = "<div class=\"fb-item\"><div class=\"fb-title\">\(Self.esc(title))</div>" + md(m.text)
            if let marks = m.marks, !marks.isEmpty {
                let erased = Set(m.erasedMarks ?? [])
                let rows = marks.enumerated().filter { !erased.contains($0.offset) }.map { pair in
                    "<li><span class=\"line\">\(Self.esc(String(localized: "第 \(pair.element.line) 行")))</span>\(Self.esc(pair.element.note))</li>"
                }
                if !rows.isEmpty { item += "<ul class=\"marks\">" + rows.joined() + "</ul>" }
            }
            items += item + "</div>"
        }
        guard !items.isEmpty else { return }
        body += section(L("AI 检查和讲解"), cls: "feedback") + items + "</div>"
    }

    // MARK: 片段

    private func header(kind: String, title: String, meta: [String]) -> String {
        """
        <header class="doc-head"><div class="kind">\(Self.esc(kind))</div><h1>\(Self.esc(title))</h1>\
        <div class="meta">\(meta.map(Self.esc).joined(separator: " · "))</div></header>
        """
    }

    private func section(_ title: String, cls: String) -> String {
        "<div class=\"sec \(cls)\"><div class=\"sec-title\">\(Self.esc(title))</div>"
    }

    private mutating func md(_ text: String) -> String {
        sources.append(text)
        return "<div class=\"md\" data-k=\"\(sources.count - 1)\"></div>"
    }

    /// width：图片在纸上的宽度（点），超出版心时缩小
    private func image(_ data: Data, width: Double?) -> String {
        let mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        let style = width.map { " style=\"width:\(Int($0))px\"" } ?? ""
        return "<img src=\"data:\(mime);base64,\(data.base64EncodedString())\"\(style)>"
    }

    /// 手写转写结果的位置（选了 AI 转写时）
    private mutating func inkSlot(_ jpeg: Data) -> String {
        guard options.transcribe else { return "" }
        inks.append(jpeg)
        return "\u{1}INK\(inks.count - 1)\u{1}"
    }

    /// 一遍换完所有位置：正文里有所有图片的 base64，常常十几 MB，以前每张手写图都把整篇查找、复制一遍
    mutating func fillTranscripts(_ results: [Int: String]) {
        guard !inks.isEmpty else { return }
        let title = "<div class=\"transcript\"><div class=\"t-title\">\(Self.esc(L("文字转写（AI 识别，可能有误）")))</div>"
        var result = ""
        result.reserveCapacity(body.utf8.count)
        var rest = body[...]
        while let found = rest.range(of: "\u{1}INK") {
            result += rest[..<found.lowerBound]
            let after = rest[found.upperBound...]
            if let close = after.firstIndex(of: "\u{1}"), let k = Int(after[..<close]) {
                if let text = results[k] { result += title + md(text) + "</div>" }
                rest = after[after.index(after: close)...]
            } else {
                result += rest[found]
                rest = after
            }
        }
        result += rest
        body = result
    }

    // MARK: 手写图片

    #if os(iOS)
    /// 做题手写区的笔迹：印上横线和行号（和 AI 检查时看到的一样，“第 n 行”对得上）
    static func ruledImage(_ drawing: PKDrawing) -> (Data, Double)? {
        let spacing = RuledPaper.lineSpacing
        let content = drawing.bounds
        let firstRow = RuledPaper.row(at: content.minY)
        let lastRow = max(firstRow, RuledPaper.row(at: content.maxY))
        let top = RuledPaper.top(ofRow: firstRow)
        let left = max(0, content.minX - 16)
        let area = CGRect(x: left, y: top, width: content.maxX + 16 - left, height: CGFloat(lastRow - firstRow + 1) * spacing)
        var ink: UIImage!
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: area, scale: 2)
        }
        let gutter: CGFloat = 34
        let size = CGSize(width: area.width + gutter, height: area.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: UIColor(white: 0.55, alpha: 1)
            ]
            for row in firstRow...lastRow {
                let bottom = RuledPaper.top(ofRow: row) + spacing - top
                UIColor(red: 0.62, green: 0.72, blue: 0.86, alpha: 0.5).setFill()
                // fill(_:) 默认是 copy 混合，半透明颜色会变成很深的线；要 normal 才是浅色横线
                context.fill(CGRect(x: gutter, y: bottom - 0.5, width: area.width, height: 1), blendMode: .normal)
                let label = "\(row)" as NSString
                let labelSize = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: gutter - 8 - labelSize.width, y: bottom - spacing / 2 - labelSize.height / 2),
                           withAttributes: attributes)
            }
            ink.draw(in: CGRect(x: gutter, y: 0, width: area.width, height: area.height))
        }
        guard let cg = image.cgImage, let jpeg = ImageUtil.jpeg(cg, quality: 0.85) else { return nil }
        return (jpeg, Double(size.width))
    }

    /// 笔记手写块：按笔记的纸宽，只截有笔迹的那几行高度
    static func canvasImage(_ drawing: PKDrawing, width: Double) -> Data? {
        let b = drawing.bounds
        let area = CGRect(x: 0, y: max(0, b.minY - 10), width: max(CGFloat(width), b.maxX + 10), height: b.height + 20)
        var ink: UIImage!
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: area, scale: 2)
        }
        guard let cg = ink.cgImage else { return nil }
        return ImageUtil.jpeg(cg, quality: 0.85)
    }
    #endif

    // MARK: 整页

    func page() -> String {
        let sourcesJSON = (try? JSONSerialization.data(withJSONObject: sources)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // 在 <script> 里：避免原文里的 </script> 提前结束脚本
        let safeJSON = sourcesJSON.replacingOccurrences(of: "</", with: "<\\/")
        let cjk = UILanguage.isTraditional ? "\"PingFang HK\",\"PingFang TC\",\"PingFang SC\"" : "\"PingFang SC\",\"PingFang TC\""
        // 正文和 App 里一样用试卷字体（宋体 + Times New Roman）；字体没放进网页目录时照旧用系统字体
        let serif = MathAssets.pageURL != nil && MathAssets.serif
        let fontFaces = serif ? ExamFont.fontFaceCSS : ""
        let family = serif ? ExamFont.serifStack(cjk: cjk) : "-apple-system,\"Helvetica Neue\",\(cjk),sans-serif"
        let katexBase = MathAssets.pageURL == nil ? "https://cdn.jsdelivr.net/npm/katex@\(KatexAssets.version)/dist/" : ""
        return """
        <!doctype html>
        <html lang="\(UILanguage.isEnglish ? "en" : (UILanguage.isTraditional ? "zh-Hant" : "zh-Hans"))"><head>
        <meta charset="utf-8">
        <title>\(Self.esc(title))</title>
        <link rel="stylesheet" href="\(katexBase)katex.min.css">
        <style>
        :root{color-scheme:light}
        *{-webkit-print-color-adjust:exact;print-color-adjust:exact;box-sizing:border-box}
        html,body{margin:0;padding:0;background:#fff}
        \(fontFaces)
        body{font-family:\(family);font-size:10.5pt;line-height:1.7;color:#1d1d1f;
             overflow-wrap:anywhere;-webkit-text-size-adjust:100%;text-rendering:optimizeLegibility}
        .doc + .doc{break-before:page}
        .cover{padding-top:120px}
        .cover-brand{font-size:11pt;letter-spacing:.2em;text-transform:uppercase;color:#8e8e93;margin-bottom:10px}
        .cover h1{font-size:28pt;margin:0 0 8px;line-height:1.25}
        .toc-title{font-size:12pt;margin:48px 0 10px;padding-bottom:6px;border-bottom:1px solid #d1d1d6}
        .toc{margin:0;padding-left:1.6em}
        .toc li{margin:.45em 0}
        .toc .kind,.doc-head .kind{display:inline-block;font-size:8.5pt;color:#6e6e73;border:1px solid #c7c7cc;border-radius:3px;
             padding:0 5px;margin-right:8px;line-height:1.6;vertical-align:1px}
        .doc-head{margin:0 0 18px;padding-bottom:10px;border-bottom:1.5px solid #1d1d1f;break-after:avoid}
        .doc-head h1{font-size:18pt;line-height:1.3;margin:6px 0 4px}
        .meta{font-size:9pt;color:#6e6e73}
        .md>:first-child{margin-top:0}
        .md>:last-child{margin-bottom:0}
        .md{margin:0 0 .5em}
        p{margin:0 0 .55em}
        h4{font-size:12pt;line-height:1.4;margin:1.1em 0 .45em;padding-left:8px;border-left:3px solid #1d1d1f;break-after:avoid}
        h3.part{font-size:12pt;margin:1.6em 0 .6em;break-after:avoid}
        ul{margin:.2em 0 .55em;padding-left:1.4em}
        li{margin:.15em 0}
        strong{font-weight:600}
        code{font-family:ui-monospace,Menlo,monospace;font-size:.9em;background:#f2f2f4;padding:.05em .3em;border-radius:3px}
        pre{background:#f5f5f7;padding:.6em .8em;border-radius:4px;margin:.4em 0 .6em;white-space:pre-wrap;break-inside:avoid}
        pre code{background:none;padding:0}
        table{border-collapse:collapse;margin:.4em 0 .7em;max-width:100%}
        th,td{border:.75px solid #b8b8be;padding:.25em .6em;text-align:left;vertical-align:top}
        th{background:#f2f2f4;font-weight:600}
        tr{break-inside:avoid}
        hr{border:none;border-top:.75px solid #c7c7cc;margin:.9em 0}
        blockquote{margin:0 0 .5em;padding:.1em 0 .1em .8em;border-left:2px solid #c7c7cc;color:#48484a}
        .katex{font-size:1.1em}
        \(serif ? ".katex .cjk_fallback{font-family:ExamSong,ExamSongAlt,\(cjk),sans-serif}" : "")
        .katex-display{margin:.5em 0;padding:.1em 0;overflow:hidden;break-inside:avoid}
        .im{white-space:nowrap}
        .im.wrap{white-space:normal}
        table.nw th,table.nw td{white-space:nowrap}
        .tex{font-family:ui-monospace,Menlo,monospace;font-size:.92em;color:#6e6e73}
        img{max-width:100%;height:auto;display:block;break-inside:avoid}
        .figure{margin:.4em 0 .7em}
        .figure img{max-height:360px;width:auto;border:.75px solid #e5e5ea;border-radius:3px}
        .q{margin:0 0 20px;padding-top:12px;border-top:.75px solid #d1d1d6}
        .doc-head + .q{border-top:none;padding-top:0}
        .qhead{display:flex;align-items:baseline;gap:10px;margin-bottom:6px;break-after:avoid}
        .qlabel{font-weight:700;font-size:11pt}
        .status,.star{font-size:8.5pt;padding:0 6px;border-radius:3px;border:.75px solid currentColor;line-height:1.6}
        .status.todo{color:#8e8e93}.status.wrong{color:#c0392b}.status.passed{color:#2d7a46}.status.revealed{color:#2c5fa8}
        .star{color:#c0392b}
        .sec{margin:.7em 0 0;padding:.55em .8em .6em;border-radius:4px;border:.75px solid #e0e0e5}
        .sec-title{font-size:8.5pt;font-weight:600;color:#6e6e73;letter-spacing:.04em;margin-bottom:.35em;break-after:avoid}
        .sec.answer{background:#f4f7fb;border-color:#d6e1f0}
        .sec.feedback{background:#fbfaf6;border-color:#ebe5d3}
        .ink{margin:.3em 0}
        .ink img{border:.75px solid #e5e5ea;border-radius:3px}
        .canvas{margin:.6em 0}
        .transcript{margin:.45em 0 .2em;padding:.4em .7em;background:#f7f7f9;border-radius:3px}
        .t-title{font-size:8pt;color:#8e8e93;margin-bottom:.2em}
        .fb-item{margin:.2em 0 .7em}
        .fb-item:last-child{margin-bottom:.1em}
        .fb-title{font-weight:600;font-size:9.5pt;margin-bottom:.15em;break-after:avoid}
        .marks{margin:.3em 0 0;padding-left:1.2em}
        .marks .line{color:#c0392b;font-weight:600;margin-right:.5em}
        .box{margin:.5em 0 .8em;padding:.55em .8em;border-radius:4px;background:#f7f7f9;border:.75px solid #e5e5ea}
        .ask{font-weight:600;margin-bottom:.35em}
        .ask .tag{display:inline-block;font-size:8.5pt;font-weight:600;color:#fff;background:#6e6e73;border-radius:3px;padding:0 5px;margin-right:6px;vertical-align:1px}
        .empty{color:#8e8e93}
        </style>
        <script src="\(katexBase)katex.min.js"></script>
        <script src="\(katexBase)contrib/mhchem.min.js"></script>
        </head><body>
        \(body)
        <script>
        var READY = !!window.katex;
        \(MathTemplate.markdownJS)
        var SRC = \(safeJSON);
        document.querySelectorAll(".md").forEach(function (el) {
          try { el.innerHTML = md(SRC[+el.getAttribute("data-k")] || ""); }
          catch (e) { el.textContent = SRC[+el.getAttribute("data-k")] || ""; }
        });
        // 行内公式放得下就不拆行；表格放不下先缩小字；独立公式稍宽就缩小一点放进一行
        function fit() {
          document.querySelectorAll(".md").forEach(function (box) {
            var w = box.clientWidth;
            if (!w) return;
            box.querySelectorAll(".im").forEach(function (el) {
              el.classList.remove("wrap");
              if (el.getBoundingClientRect().width > w + 1) el.classList.add("wrap");
            });
            box.querySelectorAll("table").forEach(function (t) {
              t.style.fontSize = "";
              t.classList.add("nw");
              for (var k = 0; k < 3 && t.scrollWidth > w + 1; k++) {
                var cur = parseFloat(t.style.fontSize) || 1;
                var r = Math.max(0.65, Math.floor(cur * w / t.scrollWidth * 100) / 100);
                if (r >= cur) break;
                t.style.fontSize = r + "em";
              }
              if (t.scrollWidth > w + 1) t.classList.remove("nw");
            });
            box.querySelectorAll(".katex-display").forEach(function (d) {
              d.style.fontSize = "";
              var inner = d.firstElementChild;
              if (!inner) return;
              var need = inner.scrollWidth, have = d.clientWidth;
              if (need > have + 1) d.style.fontSize = Math.max(0.6, Math.floor(have / need * 100) / 100) + "em";
            });
          });
        }
        function finish() {
          fit();
          try { window.webkit.messageHandlers.done.postMessage(1); } catch (e) {}
        }
        var waits = [];
        if (document.fonts && document.fonts.ready) waits.push(document.fonts.ready);
        Array.prototype.forEach.call(document.images, function (img) {
          if (img.decode) waits.push(img.decode().catch(function () {}));
        });
        Promise.all(waits).then(finish, finish);
        </script>
        </body></html>
        """
    }

    // MARK: 工具

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: date)
    }
}

// MARK: - 排版成 PDF

#if os(iOS)
@MainActor
enum PDFRenderer {
    /// 纸张：美国、加拿大用 Letter，其他地方用 A4
    static var paper: CGRect {
        let region = Locale.current.region?.identifier
        return region == "US" || region == "CA" ? CGRect(x: 0, y: 0, width: 612, height: 792) : CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    }
    nonisolated static let marginX: CGFloat = 56
    nonisolated static let marginY: CGFloat = 40
    static let headerHeight: CGFloat = 30
    static let footerHeight: CGFloat = 30

    static func render(html: String, title: String) async throws -> Data {
        let paper = paper
        let printable = paper.insetBy(dx: marginX, dy: marginY)
        let contentWidth = printable.width

        let config = WKWebViewConfiguration()
        let waiter = LoadWaiter()
        config.userContentController.add(waiter, name: "done")
        let web = WKWebView(frame: CGRect(x: -contentWidth * 3, y: 0, width: contentWidth, height: 900), configuration: config)
        web.overrideUserInterfaceStyle = .light
        web.navigationDelegate = waiter
        // 打印排版要在窗口里的网页上做；放在屏幕外，用户看不到
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.addSubview(web)
        // 写出来给网页读的 export.html 里有整份导出的手写图片（常常几十 MB）：排完就删，不一直留在 App 的资料里
        var tempFile: URL?
        defer {
            web.removeFromSuperview()
            config.userContentController.removeScriptMessageHandler(forName: "done")
            if let tempFile { try? FileManager.default.removeItem(at: tempFile) }
        }

        if let page = MathAssets.pageURL {
            // 和 KaTeX 放在同一个目录，公式字体用本地的
            let dir = page.deletingLastPathComponent()
            let file = dir.appendingPathComponent("export.html")
            try Data(html.utf8).write(to: file, options: .atomic)
            web.loadFileURL(file, allowingReadAccessTo: dir)
            tempFile = file
        } else {
            web.loadHTMLString(html, baseURL: URL(string: "https://stepwise.app/"))
        }
        try await waiter.wait(timeout: 45)

        let renderer = PageRenderer(title: title)
        renderer.headerHeight = headerHeight
        renderer.footerHeight = footerHeight
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")
        renderer.addPrintFormatter(web.viewPrintFormatter(), startingAtPageAt: 0)

        let data = NSMutableData()
        let info: [String: Any] = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Stepwise"]
        UIGraphicsBeginPDFContextToData(data, paper, info)
        let pages = renderer.numberOfPages
        renderer.pageCount = pages
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        let bounds = UIGraphicsGetPDFContextBounds()
        for i in 0..<pages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: bounds)
        }
        UIGraphicsEndPDFContext()
        guard pages > 0, data.length > 0 else { throw LLMError(message: L("没能生成 PDF，请再试一次。")) }
        // 复制、搜索出来的字要对：把文字对照表里的康熙部首改回常用字（见 PDFTextFix）。
        // 要把整份 PDF 扫好几遍，放到后台做，转圈的动画不停
        let pdf = data as Data
        return await Task.detached(priority: .userInitiated) { PDFTextFix.fix(pdf) }.value
    }

    /// 每页页眉（标题）和页脚（页码）
    final class PageRenderer: UIPrintPageRenderer {
        let title: String
        var pageCount = 0
        init(title: String) {
            self.title = title
            super.init()
        }

        private var small: [NSAttributedString.Key: Any] {
            [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor(white: 0.5, alpha: 1)]
        }

        // 页眉、页脚按纸的位置画在版心上下的页边里（左右和正文对齐）
        override func drawHeaderForPage(at pageIndex: Int, in headerRect: CGRect) {
            // 封面（第一页）不画页眉
            guard pageIndex > 0 else { return }
            let x = PDFRenderer.marginX, width = paperRect.width - 2 * x
            let text = title as NSString
            let height = text.size(withAttributes: small).height
            let y = PDFRenderer.marginY - height - 8
            text.draw(with: CGRect(x: x, y: y, width: width, height: height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: small, context: nil)
            UIColor(white: 0.82, alpha: 1).setFill()
            UIRectFill(CGRect(x: x, y: PDFRenderer.marginY - 4, width: width, height: 0.5))
        }

        override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
            let text = "\(pageIndex + 1) / \(pageCount)" as NSString
            let size = text.size(withAttributes: small)
            text.draw(at: CGPoint(x: paperRect.midX - size.width / 2, y: paperRect.height - PDFRenderer.marginY + 10), withAttributes: small)
        }
    }

    /// 等页面排完（公式、字体、图片都好了）
    @MainActor
    final class LoadWaiter: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false

        func wait(timeout: Double) async throws {
            if finished { return }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    // 超时也照样排：最多是个别公式字体还没加载完
                    self?.resume(nil)
                }
            }
        }

        private func resume(_ error: Error?) {
            finished = true
            guard let c = continuation else { return }
            continuation = nil
            if let error { c.resume(throwing: error) } else { c.resume() }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            resume(nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            resume(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            resume(error)
        }
    }
}
#endif
