import Foundation

// MARK: - 笔记模式的提示词和输出解析

/// 生成笔记时出不出例题（练习题）
enum NoteExerciseLevel: String, CaseIterable, Identifiable {
    case off, needed, more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "不出"
        case .needed: return "必要时出"
        case .more: return "更多例题"
        }
    }

    var detail: String {
        switch self {
        case .off: return "只整理笔记，不加练习题。之后可以在任意小节下面点“出例题”。"
        case .needed: return "资料里没有例题的重要知识点后面，加一道练习题和手写批改区。"
        case .more: return "每个重要知识点后面都加 1–2 道练习题，由浅入深，适合复习时多练。"
        }
    }
}

/// 问答记到笔记里：原文不动，在提问的那一行后面插入一段解释
struct NoteInsertion: Equatable {
    /// 插入后的全文
    var text: String
    /// 原文里插入点之前的部分：量出它在纸上有多高，就知道插入点下面的笔迹要往下挪
    var prefix: String
    /// 插在了最后：后面没有原文，笔迹不用挪
    var atEnd: Bool
}

extension Tutor {
    /// 生成笔记时默认的要求
    static let defaultNotePrompt = "整理成预习和复习用的笔记：按小节列出核心概念、公式、方法和易错点"

    /// exercises：出不出练习题、出多少
    static func noteSystem(prompt: String, exercises: NoteExerciseLevel, hasImages: Bool, multiPart: Bool, first: Bool) -> String {
        var s = """
        你是一位擅长整理学习资料的老师。学生上传了一份学习资料（课件、讲义或教材），要用来预习和复习。请按学生的要求，把资料整理成一份结构清晰、讲得明白的学习笔记。

        【学生的要求】
        \(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultNotePrompt : prompt)

        输出格式：按顺序输出若干笔记块，每块用一组 <note> 标签包住，一块讲一个小节或一个知识点：
        <note>
        ## 小节标题
        正文（Markdown：列表、**加粗**、表格；公式用 LaTeX）
        </note>
        """
        let exerciseFormat = """
            <exercise>
            <content>完整题干（含选项，每个选项单独一行）</content>
            <answer>参考答案和简要解析</answer>
            </exercise>
            """
        switch exercises {
        case .off:
            s += "\n\n不要出练习题。"
        case .needed:
            s += "\n\n练习题：资料里已经有例题的知识点不要再出题。如果某个重要知识点在资料里没有配例题，就在讲这个知识点的 <note> 后面紧接着出一道练习题，检验学生是否真正理解；题目难度适中，能用几步写完：\n" + exerciseFormat
        case .more:
            s += "\n\n练习题：每个重要知识点讲完后，紧接着在它的 <note> 后面出 1–2 道练习题（每道一组标签），由浅入深，检验学生是否真正理解。资料里已有的例题不要照抄，可以出同类的变式；题目能用几步写完：\n" + exerciseFormat
        }
        if first {
            s += "\n\n在最前面用 <title>…</title> 给这份笔记起一个简短的标题（不超过 20 个字）。"
        }
        if multiPart {
            s += "\n\n资料很长，分几部分发给你。这次只整理收到的这一部分，接着前面的内容往下写，不要写开场白和总结；与前后部分各有一页重叠，重叠的内容只整理一次。"
        }
        if hasImages {
            s += "\n\n资料是图片，请仔细识别图中的文字、公式和图表。"
        }
        s += "\n\n标签外面不要写任何内容。\n\n" + formatRule
        return s
    }

    struct NoteItem: Equatable {
        enum Kind: Equatable { case note, exercise }
        var kind: Kind
        var text: String
        var answer: String?
    }

    /// 解析笔记输出：按出现顺序取出完整的 <note> 和 <exercise>；流式输出时没写完的块不算
    static func parseNote(_ output: String) -> (title: String?, items: [NoteItem]) {
        let title = tag("title", in: output)
        guard let regex = try? NSRegularExpression(pattern: "<(note|exercise)>([\\s\\S]*?)</\\1>") else { return (title, []) }
        let ns = output as NSString
        var items: [NoteItem] = []
        for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: match.range(at: 2))
            if ns.substring(with: match.range(at: 1)) == "note" {
                let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { items.append(NoteItem(kind: .note, text: text)) }
            } else if let content = tag("content", in: body), !content.isEmpty {
                items.append(NoteItem(kind: .exercise, text: content, answer: tag("answer", in: body)))
            }
        }
        return (title, items)
    }

    /// 流式输出时正在写、还没写完的那一块笔记（用来实时显示）
    static func unfinishedNote(_ output: String) -> String? {
        guard let open = output.range(of: "<note>", options: .backwards) else { return nil }
        let rest = output[open.upperBound...]
        if rest.contains("</note>") { return nil }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 模型完全没按格式输出时，把整段当成一块笔记，不至于什么都没有
    static func looseNote(_ output: String) -> String {
        var s = output
        if let range = s.range(of: "<title>[\\s\\S]*?</title>", options: .regularExpression) { s.removeSubrange(range) }
        return s.replacingOccurrences(of: "</?note>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 选中文字提问

    /// 笔记选中文字后的固定选项
    struct NoteAskOption: Identifiable {
        var id: String { title }
        let title: String
        let prompt: String
        var makesExercise = false
    }

    static let noteAskOptions: [NoteAskOption] = [
        NoteAskOption(title: "解释一下", prompt: "请用更容易懂的话解释我选中的这部分，必要时补充推导或直观理解。"),
        NoteAskOption(title: "举个例子", prompt: "请针对我选中的这部分举一个具体的例子，并讲清楚。"),
        NoteAskOption(title: "出一道练习题", prompt: "请针对我选中的这部分出一道练习题。", makesExercise: true)
    ]

    static func noteAskSystem(doc: NoteDoc) -> String {
        let body = doc.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n")
        return """
        你是一位耐心的学习辅导老师。学生正在用下面这份笔记预习或复习，会选中笔记里的一段向你提问。回答要紧扣选中的内容，简洁清楚，必要时写出推导。

        【笔记：\(doc.title)】
        \(clip(body, 8000))

        \(formatRule)
        """
    }

    /// 用笔圈出来问：圈住的地方截了图，问题写在后面
    static func noteCircleInstruction(block: String, question: String, hasImage: Bool) -> String {
        """
        \(hasImage ? "【我圈出的部分】见图片（笔记里圈住的一小段，可能带着我的笔迹）。\n\n" : "")【这段所在的笔记原文】
        \(clip(block, 3000))

        【我的问题】\(question)

        像老师写在页边的小字批注一样回答：紧扣圈住的内容，几句话说清楚，必要时写出关键推导；公式用 $...$。不要开场白。
        """
    }

    /// 问答之后记到笔记里：不照抄回答，结合原文在提问的地方补一段解释
    static func noteIntegrateSystem(doc: NoteDoc) -> String {
        let body = doc.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n")
        return """
        你在帮学生完善自己的学习笔记。学生刚才就笔记里的一处提了问题、得到了回答，现在要把这次问答的收获补进笔记，就补在提问的地方。下面是整份笔记，补的内容要和它融为一体。

        【笔记：\(doc.title)】
        \(clip(body, 8000))

        \(formatRule)
        """
    }

    /// section：提问的那一块笔记原文，带上行号发过去，让 AI 说出插在哪一行后面
    static func noteIntegrateInstruction(section: String, quote: String?, question: String, answer: String) -> String {
        var s = "【提问的那一节（笔记原文，每行开头方括号里是行号，只用来定位，不是笔记内容）】\n\(numberedLines(section))\n\n"
        if let quote, !quote.isEmpty {
            s += "【学生选中提问的内容】\(clip(quote, 600))\n\n"
        }
        s += """
        【学生的问题】\(question)

        【当时的回答】
        \(clip(answer, 3000))

        请把这次问答里学到的东西补进这一节，就补在提问的地方：
        - 原文一个字都不改，只在某一行后面插入一段解释。选学生提问的那一处所在的行；如果这一行后面紧跟着属于它的公式、列表或表格，就选它们的最后一行；不要选标题行；
        - 结合原文来写：顺着这一行往下讲，沿用原文里的符号、例子和说法，可以用“也就是说”“这是因为”“比如”这样的话自然接上，读起来像笔记本来就有的一段，不要另起炉灶从头讲；
        - 只写原文里还没有的内容，已经写过的不要重复；回答里和这个知识点无关的话不要；
        - 写成笔记，不要写成问答：不要出现“你问”“回答”“这个问题”之类的说法，不要开场白，也不要结尾总结；
        - 简洁：几句话或几条要点，必要时一个公式或很短的例子；不要加标题。

        按下面的格式输出，标签外面不要写任何内容：
        <after>行号</after>
        <insert>要插入的解释</insert>
        """
        return s
    }

    /// 给原文每个非空行标上行号（从 1 开始，空行不标但占号），让 AI 说出插在哪一行后面
    static func numberedLines(_ text: String) -> String {
        var out: [String] = []
        var total = 0
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // 太长的块只发前面一部分
            total += line.count
            if total > 6000 { out.append("……"); break }
            out.append("[\(i + 1)] \(line)")
        }
        return out.joined(separator: "\n")
    }

    /// 解析 AI 的输出：插在第几行后面、插入什么。没按格式输出时整段当作要插入的内容
    static func parseIntegrate(_ output: String) -> (line: Int?, insert: String) {
        func tag(_ name: String) -> String? {
            guard let open = output.range(of: "<\(name)>") else { return nil }
            let rest = output[open.upperBound...]
            // 还没写完（或者漏了结束标签）：到目前为止的都算
            let body = rest.range(of: "</\(name)>").map { rest[..<$0.lowerBound] } ?? rest
            return String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let line = tag("after").flatMap { Int($0.filter { $0.isASCII && $0.isNumber }) }
        if let insert = tag("insert") { return (line, insert) }
        // 还在写 <after> 或者 <insert> 的开头
        if output.contains("<after") || output.contains("<insert") { return (line, "") }
        return (line, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 在原文第 line 行（从 1 开始）后面插入一段，原文不动。行号不对时按选中的文字找，再找不到就加在最后。
    /// 插入点会避开公式、代码、表格的中间，标题行后面也不插（往后挪到下一段的末尾）
    static func insertNote(_ insert: String, into text: String, afterLine line: Int?, quote: String?) -> NoteInsertion {
        let insert = insert.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        func isBlank(_ i: Int) -> Bool { lines[i].trimmingCharacters(in: .whitespaces).isEmpty }

        var index: Int?
        if let line, lines.indices.contains(line - 1) {
            // 说的是空行：算它上面那一行
            index = (0...(line - 1)).last { !isBlank($0) }
        }
        if index == nil, let quote {
            // 选中的文字是从排版后的页面复制的，公式会不一样：先整段找，找不到用开头的一小段
            let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            for key in [q, String(q.prefix(12)), String(q.suffix(12))] where key.count >= 4 {
                if let i = lines.indices.last(where: { lines[$0].contains(key) }) { index = i; break }
            }
        }
        guard var i = index else {
            let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return NoteInsertion(text: head.isEmpty ? insert : head + "\n\n" + insert, prefix: head, atEnd: true)
        }

        // 标题行：挪到它下面那一段的末尾
        if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            var j = i + 1
            while j < lines.count, isBlank(j) { j += 1 }
            while j + 1 < lines.count, !isBlank(j + 1) { j += 1 }
            if j < lines.count { i = j }
        }
        i = unsplittableEnd(lines, from: i)

        let head = lines[...i].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty {
            return NoteInsertion(text: head + "\n\n" + insert, prefix: head, atEnd: true)
        }
        return NoteInsertion(text: head + "\n\n" + insert + "\n\n" + tail, prefix: head, atEnd: false)
    }

    /// 第 i 行如果在独立公式、代码块、表格中间，返回这一整段的最后一行；否则就是第 i 行
    private static func unsplittableEnd(_ lines: [String], from target: Int) -> Int {
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            var end = i
            func until(_ match: (String) -> Bool) -> Int {
                ((i + 1)..<lines.count).first { match(lines[$0].trimmingCharacters(in: .whitespaces)) } ?? lines.count - 1
            }
            func count(_ s: String, _ key: String) -> Int { s.components(separatedBy: key).count - 1 }
            if t.hasPrefix("```") {
                end = until { $0.hasPrefix("```") }
            } else if count(t, "$$") % 2 == 1 {
                end = until { count($0, "$$") % 2 == 1 }
            } else if count(t, "\\[") > count(t, "\\]") {
                end = until { $0.contains("\\]") }
            } else if count(t, "\\begin{") > count(t, "\\end{") {
                var depth = count(t, "\\begin{") - count(t, "\\end{")
                var j = i
                while depth > 0, j + 1 < lines.count {
                    j += 1
                    depth += count(lines[j], "\\begin{") - count(lines[j], "\\end{")
                }
                end = j
            } else if t.hasPrefix("|") {
                while end + 1 < lines.count, lines[end + 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") { end += 1 }
            }
            if target <= end { return end }
            i = end + 1
        }
        return target
    }

    /// selection：从排版后的页面选中的文字（公式可能显示不全），block：选中的文字所在的笔记块原文
    /// exerciseCount：出几道练习题；0 表示不是出题，是回答问题
    static func noteAskInstruction(selection: String, block: String, question: String, exerciseCount: Int = 0) -> String {
        var s = """
        【我选中的内容】（从排版后的页面复制，公式可能不完整）
        \(clip(selection, 1500))

        【这段内容所在的笔记原文】
        \(clip(block, 3000))

        \(question)
        """
        if exerciseCount > 0 {
            s += """

            \(exerciseCount > 1 ? "一共出 \(exerciseCount) 道，由浅入深，题目之间不要重复，每道题一组标签。" : "")题目难度适中，能用几步写完。按下面的格式输出，标签外面不要写任何内容：
            <exercise>
            <content>完整题干（含选项，每个选项单独一行）</content>
            <answer>参考答案和简要解析</answer>
            </exercise>
            """
        }
        return s
    }
}
