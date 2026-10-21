import Foundation

/// 所有提示词和模型输出解析集中在这里，方便调整。
/// 模型输出用 XML 风格标签而不是 JSON：LaTeX 里大量的反斜杠在 JSON 中极易被转义坏（如 \frac 里的 \f），标签可以原样保留公式。
enum Tutor {
    static let formatRule = """
    排版要求：
    - 使用中文。
    - 所有数学表达式一律用 LaTeX 书写：行内公式用 $...$，单独成行的公式用 $$...$$。哪怕只是一个变量或数字式子（如 $x$、$a_1$、$3\\times 4$）也放进 $ 里。
    - 多步推导用 $$\\begin{aligned} ... \\end{aligned}$$ 按等号对齐；方程组用 \\begin{cases}；分数用 \\frac，根号用 \\sqrt，向量用 \\vec，角用 \\angle。
    - 化学式和化学方程式用 $\\ce{...}$，如 $\\ce{2H2 + O2 -> 2H2O}$。
    - 不要用 Unicode 符号或纯文本拼凑公式（不要写 x^2、sqrt(2) 这种形式）。
    - 可以使用 Markdown 的 **粗体**、列表和表格。
    """

    // MARK: - 拆分题目

    static func splitSystem(requirement: String, hasImages: Bool, multiPart: Bool = false) -> String {
        var s = """
        你是题目整理助手。用户会提供一份题目文件的内容（文字或图片），请把其中每一道题目完整、准确地拆分出来。

        规则：
        1. 每道题保留完整题干、选项、小问和已知条件，内容逐字照录，不要改写，不要解答。
        2. 题号 label 使用原文的题号（如 1、二(3)），原文没有题号就按顺序编号。
        3. 如果原文附带该题的答案或解析，放进 <answer>，没有就省略 <answer>。答案部分本身不要当成题目。
        4. 默认一道大题和它的所有小问作为一道题；如果“拆分要求”另有说明，以拆分要求为准。
        5. 忽略页眉页脚、页码、试卷说明等不属于题目的内容。
        6. 题中所有公式都转写成标准 LaTeX（行内 $...$，独立成行 $$...$$，化学式 $\\ce{...}$），保证和原题完全一致；选项每个单独一行。
        7. 题目中的图形无法照录时，用一句话描述它在题中的作用，如“（见图：直角三角形 $ABC$，$\\angle C=90^\\circ$）”。
        """
        if hasImages {
            s += "\n8. 内容以图片给出，page 属性填写该题题干所在图片的序号（第一张图片为 1）；如果题目含有无法用文字完整表达的图形、表格或电路图，加上 figure=\"1\"。"
        }
        if multiPart {
            s += "\n9. 这只是文件的一部分，与相邻部分有一页重叠：只输出在本部分中能看到题干的题目；题目的答案或解析如果出现在本部分（包括题干后面的页），一并放进 <answer>。本部分没有任何题干时，只输出 <title></title>。"
        }
        if !requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += "\n\n拆分要求（优先遵守）：\(requirement)"
        }
        s += """


        严格按下面的格式输出，不要输出任何其他文字：
        <title>根据内容起一个简短的题集名称</title>
        <question label="1"\(hasImages ? " page=\"1\"" : "")>
        <content>
        完整题目
        </content>
        <answer>
        原文附带的答案（没有就省略整个 answer 标签）
        </answer>
        </question>
        <question label="2"\(hasImages ? " page=\"1\"" : "")>
        ……
        </question>
        """
        return s
    }

    struct SplitItem {
        var label: String
        var content: String
        var answer: String?
        var page: Int?
        var hasFigure = false
    }

    /// 题号归一化（“Problem 7”“第7题”“7.”都视为同一题），用于合并重叠页中的重复题目
    static func labelKey(_ label: String) -> String {
        var s = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["problem", "question", "exercise", "第"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        s = s.replacingOccurrences(of: "题", with: "")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .．、:："))
        return s
    }

    static func parseSplit(_ text: String) throws -> (title: String?, items: [SplitItem]) {
        let title = tag("title", in: text)
        var items: [SplitItem] = []
        for (index, block) in blocks("question", in: text).enumerated() {
            let content = (tag("content", in: block.body) ?? block.body).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            let label = displayLabel(block.attributes["label"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(index + 1)")
            let answer = tag("answer", in: block.body).flatMap { $0.isEmpty ? nil : $0 }
            items.append(SplitItem(label: label, content: stripLeadingLabel(content, label: label), answer: answer,
                                   page: block.attributes["page"].flatMap { Int($0) },
                                   hasFigure: block.attributes["figure"] == "1"))
        }
        if !items.isEmpty { return (title, items) }
        if text.contains("<title") && !text.contains("<question") { return (title, []) }

        // 兼容：模型仍然输出了 JSON
        if let json = extractJSON(text) {
            let object = json as? [String: Any]
            let list = (object?["questions"] as? [[String: Any]]) ?? (json as? [[String: Any]]) ?? []
            let jsonItems: [SplitItem] = list.enumerated().compactMap { index, q in
                guard let content = (q["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }
                let page = (q["page"] as? Int) ?? Int(stringValue(q["page"]) ?? "")
                let label = displayLabel(stringValue(q["label"]) ?? "\(index + 1)")
                return SplitItem(label: label, content: stripLeadingLabel(content, label: label),
                                 answer: (q["answer"] as? String).flatMap { $0.isEmpty ? nil : $0 }, page: page)
            }
            if !jsonItems.isEmpty { return (object?["title"] as? String ?? title, jsonItems) }
        }
        throw LLMError(message: "模型返回的内容无法解析成题目列表，请重试或换一个模型。\n\n模型返回：\(text.prefix(300))")
    }

    // MARK: - 辅导

    static func tutorSystem(for q: Question) -> String {
        let answerSection: String
        if let ref = q.referenceAnswer, !ref.isEmpty {
            answerSection = "【参考答案】（只供你判断对错，学生看不到。在学生请求完整答案之前不要泄露）\n\(ref)"
        } else {
            answerSection = "【参考答案】无。请你先自己认真求解并核对，再评判学生。"
        }
        return """
        你是一位耐心、严谨的学习辅导老师，正在一对一辅导学生做下面这道题。

        【题目】\(q.label)
        \(q.content)

        \(answerSection)

        辅导原则：鼓励学生独立思考；学生通过这道题（做对或已看过完整答案）之前，不要直接给出最终答案。

        当学生请你出一道新题时：先用一两句话说明这道题考查什么，然后按下面的格式给出新题（一次可以出多道，每道一组标签），新题的答案只写在 <answer> 里，不要写在标签外面：
        <new_question>
        <content>完整题干（含选项，每个选项单独一行）</content>
        <answer>参考答案和简要解析</answer>
        </new_question>

        \(formatRule)
        """
    }

    static let checkInstruction = """
    请批改我的作答（如果附有图片，那是我的手写作答）。
    第一行只输出 <verdict>correct</verdict> 或 <verdict>wrong</verdict>，从第二行开始写给我的反馈：
    - 结果和必要的过程都正确时判 correct，反馈简短肯定，并点出这道题的关键。
    - 有错误或不完整时判 wrong，具体指出哪里错了（哪一步、哪个概念或计算，可以引用我写的式子），可以提示检查方向，但不要给出正确答案或完整解法。
    - 如果题目要求写过程而我只写了结果，按不完整处理并说明。
    """

    static func hintInstruction(level: Int) -> String {
        """
        我需要进一步提示（这是第 \(level) 次提示）。请在之前提示的基础上再具体一步，引导我自己想出来，但仍然不要直接给出最终答案。简洁一些，控制在几句话以内。
        """
    }

    static let solutionInstruction = "请给出这道题的完整答案和详细的解题过程（推导写成对齐的公式），最后总结一下解题的关键点。"

    struct Verdict {
        var correct: Bool?
        var feedback: String
    }

    /// 解析批改结果；流式输出过程中也可以调用，correct 为 nil 表示还没判出来
    static func parseVerdict(_ text: String) -> Verdict {
        if let range = text.range(of: "<verdict>[\\s\\S]*?</verdict>", options: .regularExpression) {
            let value = text[range].replacingOccurrences(of: "<verdict>", with: "").replacingOccurrences(of: "</verdict>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let correct = value.hasPrefix("correct") || value.hasPrefix("正确") || value == "true"
            var feedback = text
            feedback.removeSubrange(range)
            return Verdict(correct: correct, feedback: feedback.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // 兼容：模型输出了 JSON
        if let obj = extractJSON(text) as? [String: Any], obj["correct"] != nil {
            let correct = (obj["correct"] as? Bool) ?? ((obj["correct"] as? String)?.lowercased() == "true")
            return Verdict(correct: correct, feedback: (obj["feedback"] as? String) ?? "")
        }
        // 流式输出时标签还没写完
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("<verdict") || "<verdict>".hasPrefix(t) { return Verdict(correct: nil, feedback: "") }
        return Verdict(correct: nil, feedback: text)
    }

    // MARK: - 对话中生成的新题

    struct NewQuestion {
        var content: String
        var answer: String?
    }

    /// 取出 <new_question> 里的新题，返回去掉标签后的显示文字。
    static func extractNewQuestions(_ text: String) -> (display: String, questions: [NewQuestion]) {
        var display = text
        var found: [NewQuestion] = []
        for block in blocks("new_question", in: text).reversed() {
            if let content = tag("content", in: block.body), !content.isEmpty {
                found.insert(NewQuestion(content: content, answer: tag("answer", in: block.body)), at: 0)
            } else if let obj = extractJSON(block.body) as? [String: Any], let content = obj["content"] as? String, !content.isEmpty {
                found.insert(NewQuestion(content: content, answer: obj["answer"] as? String), at: 0)
            } else {
                let plain = block.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !plain.isEmpty { found.insert(NewQuestion(content: plain, answer: nil), at: 0) }
            }
            display.replaceSubrange(block.range, with: "")
        }
        return (display.trimmingCharacters(in: .whitespacesAndNewlines), found)
    }

    /// 流式输出过程中隐藏还没写完的出题标签
    static func hideUnfinishedTags(_ text: String) -> String {
        let shown = extractNewQuestions(text).display
        if let r = shown.range(of: "<new_question") {
            return String(shown[..<r.lowerBound]) + "\n\n（正在出题…）"
        }
        return shown
    }

    /// 列表里的单行预览：去掉 LaTeX 标记，尽量可读
    static func plainPreview(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\\\\(begin|end)\\{[^}]*\\}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\", with: "；")
        let replacements: [(String, String)] = [
            ("^\\circ", "°"), ("^{\\circ}", "°"), ("^2", "²"), ("^{2}", "²"), ("^3", "³"), ("^{3}", "³"),
            ("\\left", ""), ("\\right", ""), ("\\cdot", "·"), ("\\times", "×"), ("\\div", "÷"),
            ("\\leqslant", "≤"), ("\\geqslant", "≥"), ("\\leq", "≤"), ("\\geq", "≥"), ("\\le", "≤"), ("\\ge", "≥"),
            ("\\neq", "≠"), ("\\ne", "≠"), ("\\pm", "±"), ("\\infty", "∞"), ("\\pi", "π"), ("\\alpha", "α"),
            ("\\beta", "β"), ("\\theta", "θ"), ("\\angle", "∠"), ("\\triangle", "△"), ("\\circ", "°"),
            ("\\sqrt", "√"), ("\\in", "∈"), ("\\rightarrow", "→"), ("\\to", "→"), ("\\quad", " "), ("\\,", " "),
            ("$$", " "), ("$", ""), ("\\(", ""), ("\\)", ""), ("\\[", ""), ("\\]", "")
        ]
        for (a, b) in replacements { s = s.replacingOccurrences(of: a, with: b) }
        s = s.replacingOccurrences(of: "\\\\[dt]?frac\\{([^{}]*)\\}\\{([^{}]*)\\}", with: "$1/$2", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\(ce|text|mathrm|mathbf|vec|overline|boldsymbol)\\{([^{}]*)\\}", with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\(sin|cos|tan|cot|log|ln|lg|lim|max|min)\\b", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\[a-zA-Z]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[{}]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\*\\*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&", with: " ")
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 标签解析

    struct TagBlock {
        var attributes: [String: String]
        var body: String
        var range: Range<String.Index>
    }

    /// 取第一个 <name>…</name> 的内容
    static func tag(_ name: String, in text: String) -> String? {
        blocks(name, in: text).first?.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 所有 <name attr="…">…</name> 块
    static func blocks(_ name: String, in text: String) -> [TagBlock] {
        let pattern = "<\(name)((?:\\s+[a-zA-Z_]+\\s*=\\s*\"[^\"]*\")*)\\s*>([\\s\\S]*?)</\(name)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            var attributes: [String: String] = [:]
            let attrText = ns.substring(with: match.range(at: 1))
            if let attrRegex = try? NSRegularExpression(pattern: "([a-zA-Z_]+)\\s*=\\s*\"([^\"]*)\"") {
                let attrNS = attrText as NSString
                for m in attrRegex.matches(in: attrText, range: NSRange(location: 0, length: attrNS.length)) {
                    attributes[attrNS.substring(with: m.range(at: 1))] = attrNS.substring(with: m.range(at: 2))
                }
            }
            return TagBlock(attributes: attributes, body: unescapeEntities(ns.substring(with: match.range(at: 2))), range: range)
        }
    }

    /// 模型有时会把 < > & 写成 &lt; &gt; &amp;（因为输出格式是标签），还原成原字符
    static func unescapeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 显示用题号：去掉 “Problem”“Question”“第…题” 等前缀，只保留编号
    static func displayLabel(_ label: String) -> String {
        let key = labelKey(label)
        return key.isEmpty ? label.trimmingCharacters(in: .whitespacesAndNewlines) : key
    }

    /// 题干开头如果单独一行重复题号（如 “Problem 7”），去掉这一行
    static func stripLeadingLabel(_ content: String, label: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty,
              first.count <= 20, labelKey(first) == labelKey(label) else { return content }
        lines.removeFirst()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JSON 兼容解析

    static func extractJSON(_ text: String) -> Any? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = s.range(of: "```") {
            var inner = String(s[fence.upperBound...])
            if let newline = inner.firstIndex(of: "\n") { inner = String(inner[inner.index(after: newline)...]) }
            if let end = inner.range(of: "```") { inner = String(inner[..<end.lowerBound]) }
            s = inner
        }
        for (open, close) in [(Character("{"), Character("}")), (Character("["), Character("]"))] {
            guard let start = s.firstIndex(of: open), let end = s.lastIndex(of: close), start < end else { continue }
            let slice = String(s[start...end])
            // 先用修复后的版本：\frac 里的 \f 是合法 JSON 转义，直接解析不会报错但会把公式弄坏
            let repaired = repairJSONStrings(slice)
            if let data = repaired.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) { return obj }
            if let data = slice.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) { return obj }
        }
        return nil
    }

    /// 和 JSON 转义（\\b \\f \\n \\r \\t \\u）同字母开头的常见 LaTeX 命令
    private static let latexCommands: [String] = [
        "frac", "forall", "flat", "frown",
        "neq", "ne", "nu", "nabla", "neg", "not", "notin", "ni", "nmid", "nleq", "ngeq", "newline", "nexists", "nsubseteq", "nparallel",
        "right", "rho", "rangle", "rceil", "rfloor", "rm", "rbrace", "rightarrow",
        "times", "theta", "tau", "tan", "tanh", "text", "textbf", "textrm", "tfrac", "to", "top", "triangle", "tilde", "therefore", "tbinom",
        "beta", "bar", "binom", "bmod", "boldsymbol", "big", "bigg", "begin", "because", "bot", "bullet", "backslash", "bigcup", "bigcap", "bf",
        "underline", "uparrow", "upsilon", "underbrace", "cup"
    ]

    /// 修复字符串里的裸换行，以及没有转义的 LaTeX 反斜杠
    private static func repairJSONStrings(_ s: String) -> String {
        var out = ""
        var inString = false
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inString && ch == "\\" && i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "\"" || next == "\\" || next == "/" {
                    out.append(ch); out.append(next); i += 2; continue
                }
                // 反斜杠后面的连续字母
                var j = i + 1
                while j < chars.count, chars[j].isASCIILetter { j += 1 }
                let word = String(chars[(i + 1)..<j])
                let isJSONEscape = "bfnrt".contains(next) || (next == "u" && j - i - 1 >= 1 && isUnicodeEscape(chars, at: i + 2))
                let isLatex = latexCommands.contains(word)
                if isJSONEscape && !isLatex {
                    out.append(ch); out.append(next); i += 2; continue
                }
                out += "\\\\"; i += 1; continue
            }
            if ch == "\"" { inString.toggle() }
            if inString && ch == "\n" { out += "\\n"; i += 1; continue }
            if inString && ch == "\t" { out += "\\t"; i += 1; continue }
            out.append(ch)
            i += 1
        }
        return out
    }

    private static func isUnicodeEscape(_ chars: [Character], at index: Int) -> Bool {
        guard index + 4 <= chars.count else { return false }
        return chars[index..<(index + 4)].allSatisfy { $0.isHexDigit }
    }

    private static func stringValue(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
}

private extension Character {
    var isASCIILetter: Bool { isASCII && isLetter }
}
