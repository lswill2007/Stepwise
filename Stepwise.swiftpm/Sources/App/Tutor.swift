import Foundation

/// 所有提示词和模型输出解析集中在这里，方便调整。
/// 模型输出用 XML 风格标签而不是 JSON：LaTeX 里大量的反斜杠在 JSON 中极易被转义坏（如 \frac 里的 \f），标签可以原样保留公式。
enum Tutor {
    static let formatRuleZH = """
    排版要求：
    - 使用中文。简体还是繁体跟着题目（或资料）原文：原文是繁体字，就全部用繁体字写；否则用简体字。
    - 开门见山，直接进入正题。不要写“我来系统地解答这道题”“好的”之类的开场白，也不要客套。
    - 所有数学表达式一律用 LaTeX 书写：行内公式用 $...$，单独成行的公式用 $$...$$。哪怕只是一个变量或数字式子（如 $x$、$a_1$、$3\\times 4$）也放进 $ 里。
    - 多步推导用 $$\\begin{aligned} ... \\end{aligned}$$ 按等号对齐；方程组用 \\begin{cases}；分数用 \\frac，根号用 \\sqrt，向量用 \\vec，角用 \\angle。
    - 化学式和化学方程式用 $\\ce{...}$，如 $\\ce{2H2 + O2 -> 2H2O}$。
    - 不要用 Unicode 符号或纯文本拼凑公式（不要写 x^2、sqrt(2) 这种形式）。
    - 可以使用 Markdown 的 **粗体**、列表和表格。
    """

    // MARK: - 拆分题目

    static func splitSystemZH(requirement: String, hasImages: Bool, multiPart: Bool = false) -> String {
        var s = """
        你是题目整理助手。用户会提供一份题目文件的内容（文字或图片），请把其中每一道题目完整、准确地拆分出来。

        规则：
        1. 每道题保留完整题干、全部选项、小问和已知条件，内容逐字照录，不要改写，不要解答。
        1a. 【选项绝对不能漏】选择题的选项是题目的一部分：A、B、C、D（以及 E、F 等更多选项）必须全部放进 <content>，紧跟在题干后面，每个选项单独一行，例如“A. $x>0$”。原文选项横排、两列排或排成表格时，也要拆成每行一个。不要省略选项，不要合并选项，也不要把选项放进 <answer>。
        2. 题号 label 使用原文的题号（如 1、二(3)），原文没有题号就按顺序编号。
        3. 如果原文附带该题的答案或解析，放进 <answer>，没有就省略 <answer>。答案部分本身不要当成题目。
        4. 默认一道大题和它的所有小问作为一道题；如果“拆分要求”另有说明，以拆分要求为准。
        4a. 【共用题干】几道题连在一起、共用同一段题干时——原文写着“根据以下材料回答第 5–7 题”“第 3、4 题共用题干”这类说明，或者后一题要用前一题题干里的条件、数据、图表才能做，或者按拆分要求把一道大题的各个小问分开成几道题——共用的那段题干只写一次，放进 <stem id="S1">…</stem>（和 <question> 并列，写在这几道题前面；第二组用 S2，依此类推），这几道题都加上 stem="S1"，各自的 <content> 里只写这一题（这一小问）自己的内容，不要重复题干。共用题干不能丢，也不能只放进第一道题里。共用题干带图时，这几道题每一道都要标出图。不共用题干的题不要写 stem。
        5. 忽略页眉页脚、页码、试卷说明等不属于题目的内容。
        6. 题中所有公式都转写成标准 LaTeX（行内 $...$，独立成行 $$...$$，化学式 $\\ce{...}$），保证和原题完全一致。
        7. 题目中的图形无法照录时，用一句话描述它在题中的作用，如“（见图：直角三角形 $ABC$，$\\angle C=90^\\circ$）”。
        """
        if hasImages {
            s += "\n8. 内容以图片给出，page 属性填写该题题干所在图片的序号（第一张图片为 1）。如果题目含有无法用文字完整表达的图形、表格或电路图，加上 figure 属性标出图在图片上的位置：figure=\"左,上,右,下\"，四个数依次是图形外框的左边、上边、右边、下边在图片上的位置，用占图片宽、高的百分比表示（0–100，图片左上角为 0,0），框住整个图形连同图上的字母和标注，不要框进题干文字。图不在题干那张图片上时，前面加图片序号和冒号，如 figure=\"2:10,5,60,40\"；一道题有几个图就用分号隔开，如 figure=\"55,20,95,45;10,60,50,85\"。选项是图形的，把所有选项图一起框进去。"
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
        完整题干
        A. 选项一
        B. 选项二
        C. 选项三
        D. 选项四
        （不是选择题就没有选项行）
        </content>
        <answer>
        原文附带的答案（没有就省略整个 answer 标签）
        </answer>
        </question>
        <question label="2"\(hasImages ? " page=\"1\"" : "")>
        ……
        </question>
        （只有几道题共用题干时才这样写：）
        <stem id="S1">
        这几道题共用的题干
        </stem>
        <question label="3(1)" stem="S1"\(hasImages ? " page=\"1\"" : "")>
        <content>
        这一小问自己的内容
        </content>
        </question>
        <question label="3(2)" stem="S1"\(hasImages ? " page=\"1\"" : "")>
        ……
        </question>
        """
        return s
    }

    struct SplitItem {
        var label: String
        var content: String
        var answer: String?
        /// 和相邻几道题共用的题干；stemID 是模型给这段题干起的编号（只在这一次输出里有意义）
        var stem: String?
        var stemID: String?
        var page: Int?
        var hasFigure = false
        /// 图形在页面上的大致位置；只写了 figure="1" 时为空，附上整页
        var figures: [FigureBox] = []
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
        // 几道题共用的题干：<stem id="S1">…</stem> 写在题目外面，题目用 stem="S1" 指过来
        var stems: [String: String] = [:]
        for block in blocks("stem", in: text) {
            let body = block.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = block.attributes["id"], !id.isEmpty, !body.isEmpty { stems[id] = body }
        }
        var items: [SplitItem] = []
        for (index, block) in blocks("question", in: text).enumerated() {
            let hasContentTag = tag("content", in: block.body) != nil
            var content = (tag("content", in: block.body) ?? block.body).trimmingCharacters(in: .whitespacesAndNewlines)
            // 模型有时把选项放在 <content> 外面（比如自己加一个 <options> 标签），拼回题干，不能丢
            if hasContentTag {
                let extra = textOutsideTags(["content", "answer", "stem"], in: block.body)
                if !extra.isEmpty { content += "\n" + extra }
            }
            guard !content.isEmpty else { continue }
            let label = displayLabel(block.attributes["label"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(index + 1)")
            let answer = tag("answer", in: block.body).flatMap { $0.isEmpty ? nil : $0 }
            let figure = FigureCrop.parse(block.attributes["figure"])
            var item = SplitItem(label: label, content: stripLeadingLabel(content, label: label), answer: answer,
                                 page: block.attributes["page"].flatMap { Int($0.filter(\.isNumber)) },
                                 hasFigure: figure.hasFigure, figures: figure.boxes)
            // 共用题干：按编号去找；模型把题干直接写在题目里面（<stem>…</stem>）也认
            if let id = block.attributes["stem"], let stem = stems[id] {
                item.stem = stem
                item.stemID = id
            } else if hasContentTag, let inline = tag("stem", in: block.body)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !inline.isEmpty {
                item.stem = inline
                item.stemID = "inline:" + inline
            }
            items.append(item)
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
        throw LLMError(message: String(localized: "模型返回的内容无法解析成题目列表，请重试或换一个模型。\n\n模型返回：\(String(text.prefix(300)))"))
    }

    // MARK: - 辅导

    /// 发给 AI 的题目全文：共用题干、这一题自己的内容、同一题干下的其他题、学生补充的条件。
    /// siblings：和这道题共用题干的其他题（按题集里的顺序）
    static func problemStatement(for q: Question, siblings: [Question] = []) -> String {
        let english = AILanguage.isEnglish
        var s: String
        if let stem = q.stem, !stem.isEmpty {
            s = english
                ? "[Shared stem] (this question and the neighboring ones share the stem below; it is part of this question's given information)\n"
                : "【共用题干】（这道题和相邻的几道题共用下面这段题干，是本题已知条件的一部分）\n"
            s += stem + "\n\n"
            s += english
                ? "[This question: \(q.label)] (tutor and grade this part only; the student only needs to answer this part here)\n"
                : "【本题：第 \(q.label) 题】（只辅导、只批改这一问；学生在这里只需要回答这一问）\n"
            s += q.content
            if !siblings.isEmpty {
                s += english
                    ? "\n\n[Other questions under the same stem] (only so you know how the parts relate, e.g. \"using the result of (a)\". Do not grade them, do not ask the student to answer them here, and do not give away their answers.)"
                    : "\n\n【同一题干下的其他题】（只用来了解前后关系，比如“由(1)可知”。不要批改它们，不要要求学生在这里回答它们，也不要泄露它们的答案）"
                for other in siblings {
                    s += (english ? "\nQuestion \(other.label): " : "\n第 \(other.label) 题：") + clip(other.content, 400)
                }
            }
        } else {
            s = (english ? "[Question] " : "【题目】") + q.label + "\n" + q.content
        }
        let given = (q.supplements ?? []).filter { !$0.isEmpty }
        if !given.isEmpty {
            s += english
                ? "\n\n[Information added by the student] (data or conditions the question text above leaves out; the student supplied them from the original paper. Treat them as given, and do not say the question doesn't provide them.)"
                : "\n\n【学生补充的题目信息】（上面的题目原文没有写全，学生对照原卷补上的数据或条件。当作本题的已知条件，不要再说题目没有给出）"
            for item in given { s += "\n- " + item }
        }
        return s
    }

    /// origin：这道题是 AI 出的新题时，原题的内容和作答记录
    static func tutorSystemZH(for q: Question, origin: String? = nil, siblings: [Question] = []) -> String {
        var answerSection: String
        if let ref = q.referenceAnswer, !ref.isEmpty {
            answerSection = "【参考答案】（只供你判断对错，学生看不到。在学生请求完整答案之前不要泄露）\n\(ref)"
        } else if let solved = q.aiAnswer, !solved.isEmpty {
            answerSection = "【参考答案】（AI 预先求解的，只供你判断对错，学生看不到，在学生请求完整答案之前不要泄露。一般可靠；如果和学生的作答不一致，先快速验算一下参考答案本身）\n\(solved)"
        } else {
            answerSection = "【参考答案】无。请你先自己认真求解并核对，再评判学生。"
        }
        if let origin, !origin.isEmpty {
            answerSection += """


            【原题的记忆】这道题是根据学生做过的一道原题出的新题。学生在原题上出过的错很可能再犯：批改和提示时请特别留意，发现同类问题时直接点明“和原题一样……”。
            \(origin)
            """
        }
        return """
        你是一位耐心、严谨的学习辅导老师，正在一对一辅导学生做下面这道题。

        \(problemStatement(for: q, siblings: siblings))

        \(answerSection)

        辅导原则：鼓励学生独立思考；学生通过这道题（做对或已看过完整答案）之前，不要直接给出最终答案。\(unlearnedRule)

        当学生请你出一道新题时：参考学生在这道题上的作答记录，让新题能检验他之前出错的地方。先用一两句话说明这道题考查什么，然后按下面的格式给出新题（一次可以出多道，每道一组标签），新题的答案只写在 <answer> 里，不要写在标签外面：
        <new_question>
        <content>完整题干（含选项，每个选项单独一行）</content>
        <answer>参考答案和简要解析</answer>
        </new_question>

        \(formatRule)\(traditionalRule(for: q.fullText))
        """
    }

    /// 题目原文是繁体字（香港、台湾的题）：中文提示词整套是简体写的，模型容易跟着用简体，这里单独点明
    static func traditionalRule(for text: String) -> String {
        guard isTraditional(text) else { return "" }
        return "\n\n【用字】这道题的原文是繁体字：你的所有回答都必须用繁体中文书写，不要出现简体字。"
    }

    /// 每次请求最后附上的一句提醒：开门见山；繁体题用繁体回答
    static func replyReminder(for q: Question) -> String {
        if AILanguage.isEnglish { return "(Get straight to the point: no greeting or opening line.)" }
        if AILanguage.isCantonese || isTraditional(q.fullText) {
            return "（直接講重點，不要打招呼、不要開場白。全部用繁體字。）"
        }
        return "（直接说重点，不要打招呼、不要开场白。）"
    }

    /// 文字里有不少只在繁体里才这样写的字（转成简体后会变）
    static func isTraditional(_ text: String) -> Bool {
        guard let simplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) else { return false }
        let changed = zip(text, simplified).filter { $0 != $1 }.count
        return changed >= 3
    }

    /// lineNumbers：手写图片左边印了行号，可以要求模型指出错在哪一行
    static func checkInstructionZH(lineNumbers: Bool) -> String {
        var s = """
        请帮我检查作答（如果附有图片，那是我的手写作答）。像老师坐在旁边陪我看一样，从第一步开始按我写的顺序一步一步往下看。
        第一行只输出 <verdict>correct</verdict> 或 <verdict>wrong</verdict>（只给程序用，我看不到），从第二行开始写给我的反馈：
        - 按顺序看每一步：做对的步骤简短确认（例如“前两行的求导没问题”），看到第一处出问题的地方停下来细说。
        - 出问题的那一步：说清是哪一步（引用我写的式子）、问题出在哪个概念或计算、为什么这样不行，再提示我该从哪里检查。不要直接给出这一步的正确结果，也不要给完整解法。
        - 后面的步骤如果只是被前面那一步连带算错，不用逐个挑，说一句“这一步改好后，后面跟着重新算一下”即可；后面如果还有另外的问题，也一并指出。
        - 语气平和、就事论事，像在一起讲题。不要用“不对”“错了”“答案错误”这样的结论开头，也不要说教；可以先说做得好的地方。
        - 结果和必要的过程都正确时判 correct：简短肯定，点出这道题的关键。
        - 题目要求写过程而我只写了结果时判 wrong，说明还需要补上哪些过程。
        - 简洁：做对的步骤一句带过，篇幅留给出问题的那一步，整体控制在 3–6 句。
        """
        if lineNumbers {
            s += """

            - 手写图片左边的灰色数字是行号，只给程序定位用，我在页面上看不到。判 wrong 时，在反馈的最后为每一处需要改的地方单独写一行 <mark line="行号">一句话说清这里哪里需要再看、为什么</mark>，行号是出错的那一行左边的数字，按从上到下的顺序写，最多 3 处；说明里的公式用 $...$ 包住，但不要直接给出正确答案；判 correct 时不要写 mark。
            - 这些地方会在我的手写上用红色波浪线标出，按 mark 的先后依次标上 ①②③。反馈里提到它们时直接用 ①②③ 指代（例如“① 这里的符号再看看”），也可以引用我写的式子；不要说“第几行”，也不要提行号，mark 的说明里也一样。
            """
        }
        return s
    }

    /// 识图模型转写手写作答：逐行照抄，带上图片左边的行号，不改错、不解题
    static var transcribeSystem: String {
        pick("""
        你是手写识别助手。图片是学生的手写数学作答，左边的灰色数字是行号。
        把手写内容逐行照抄成文字，每行开头写上它左边的行号和冒号，例如 “3: $f'(x)=3x^2-3$”。
        - 数学式子用 LaTeX，包在 $...$ 里；文字照原样写。
        - 只照抄，写错的也照抄，不要改正、不要补步骤、不要解题、不要评价。
        - 看不清的字写成 [?]；划掉的内容写成 ~~划掉的内容~~。
        - 同一行左边没有行号时，接在上一行后面。
        - 只输出转写结果，不要任何其他说明。如果图片里没有手写内容，只输出“（空白）”。
        """, """
        You transcribe handwriting. The image is a student's handwritten math answer; the gray numbers on the left are line numbers.
        Copy the handwriting line by line as text, starting each line with the line number to its left and a colon, e.g. "3: $f'(x)=3x^2-3$".
        - Write math in LaTeX inside $...$; copy words as they are.
        - Copy only. Copy mistakes as written; don't correct them, add steps, solve or comment.
        - Write anything illegible as [?]; write crossed-out content as ~~crossed out~~.
        - If a line has no line number on its left, append it to the previous line.
        - Output only the transcription, nothing else. If there is no handwriting, output only "(blank)".
        """)
    }

    /// 提示、卡了、白板用：手写转写成的文字，个别字可能认错
    static func handwritingTranscript(_ text: String, title: String? = nil) -> String {
        pick("""
        【\(title ?? "我的手写")】（由识字程序逐行转写，每行开头是行号；个别字符可能认错，[?] 表示看不清，遇到像是认错的地方按最合理的理解来看）
        \(text)
        """, """
        [\(title ?? "My handwriting")] (transcribed line by line by a text-recognition step; each line starts with its line number; a character may be misread and [?] means illegible, so read anything that looks misread in the most sensible way)
        \(text)
        """)
    }

    /// 白板：框选的内容已经转写成文字，指令里说的“图片”就是这份转写
    static var boardTranscriptNote: String {
        pick("（我框选的手写已经逐行转写成上面的文字，下面说的“图片”就是指这份转写，行号是每行开头的数字。）",
             "(The handwriting I selected has been transcribed line by line above; where the instructions below say \"image\", they mean this transcription, and the line numbers are the numbers at the start of each line.)")
    }

    /// 检查时附在作答前面：说明下面是转写，个别字可能认错
    static func transcribedAnswer(_ text: String) -> String {
        pick("""
        【我的手写作答】（由识字程序逐行转写，每行开头是手写图片左边的行号；个别字符可能认错，[?] 表示看不清）
        \(text)

        如果某处更像是转写认错（例如 [?]、字形相近的 1/l、x/×、2/z 混淆）而不是我写错，不要因此判错；真看不清会影响判断时，在反馈里请我把那一处写清楚。
        """, """
        [My handwritten answer] (transcribed line by line by a text-recognition step; each line starts with the line number to the left of the handwriting; a character may be misread, and [?] means illegible)
        \(text)

        If something looks more like a transcription misread (e.g. [?], or look-alikes such as 1/l, x/×, 2/z) than my own mistake, don't judge wrong because of it; if it truly can't be read and that matters, ask me in the feedback to write that part more clearly.
        """)
    }

    /// 提示分三档，一档比一档具体
    static var hintLevels: [String] { [L("思路方向"), L("关键一步"), L("下一步写什么")] }

    static func hintLevelName(_ level: Int) -> String {
        hintLevels[min(max(level, 1), hintLevels.count) - 1]
    }

    /// 按钮和小标签上用的短名字
    static func hintLevelShortName(_ level: Int) -> String {
        [L("思路"), L("关键一步"), L("下一步")][min(max(level, 1), hintLevels.count) - 1]
    }

    /// level：第几次提示，决定这次提示的档次；note：学生补充的文字说明
    static func hintInstructionZH(level: Int, note: String? = nil) -> String {
        let detail: String
        switch level {
        case 1:
            detail = "这次是「思路方向」：只点出该往哪个方向想、用到哪个知识点或方法，不要涉及具体步骤和式子。"
        case 2:
            detail = "这次是「关键一步」：指出这道题最关键的一步是什么（可以写出关键的关系式），但不要往下算。"
        default:
            detail = "这次是「下一步写什么」：结合我已经写的作答，具体告诉我下一步该写什么（可以给出下一步的式子），但不要给出最终答案。"
        }
        var s = """
        我需要提示（这是第 \(level) 次提示）。\(detail)
        每次提示都在之前提示的基础上更具体一步，引导我自己想出来，简洁一些，控制在几句话以内。
        """
        if let note, !note.isEmpty {
            s += "\n\n【我的补充说明】\(note)\n请针对我说的卡住的地方给提示。"
        }
        return s
    }

    /// 点“卡了”：把现在写到哪里一起发过去，让 AI 自己找出卡在哪一步
    /// hasImage：附了手写图片（左边印着行号）；typed：打字写的部分
    static func stuckInstructionZH(hasImage: Bool, typed: String) -> String {
        var s = "我卡住了，写不下去。"
        if hasImage {
            s += "我到目前为止的手写也附上了（行号只给你定位用）。"
        }
        if !typed.isEmpty {
            s += "\n【我打的字】\n\(clip(typed, 1500))"
        }
        if !hasImage && typed.isEmpty {
            s += "我还没写什么，不知道从哪里开始。"
        }
        s += """

        请你：
        1. 按顺序快速看一遍我已经写的步骤，找出我卡在哪里：通常是我写到的最后一步，也可能是前面某一步出了问题，后面才推不下去。
        2. 第一句话直接说出我卡在哪里（例如“你卡在把 $f'(x)=0$ 解出来这一步”，引用我写的式子；行号只给你定位用，我看不到，不要说“第几行”）。
        3. 如果是前面某一步出了问题导致卡住，说清是哪一步、为什么，让我回去改。
        4. 如果前面都没问题，就针对我停下来的地方点拨：这一步该用哪个条件或方法、往哪个方向变形。可以写出关键的关系式，但不要替我往下算，也不要给出最终答案。
        5. 语气平和，像老师坐在旁边陪我看；简洁，控制在 3–5 句。
        """
        return s
    }

    /// 点“下一步”：卡了太久写不下去，让 AI 接着已经写的直接写出一步（只写一步）
    static func nextStepInstructionZH(hasImage: Bool, typed: String) -> String {
        var s = "我卡在这里很久了，写不出下一步。"
        if hasImage {
            s += "我到目前为止的手写也附上了（行号只给你定位用）。"
        }
        if !typed.isEmpty {
            s += "\n【我打的字】\n\(clip(typed, 1500))"
        }
        if !hasImage && typed.isEmpty {
            s += "我还没写什么，不知道从哪里开始。"
        }
        s += """

        请直接替我写出紧接着的下一步，只写一步：
        1. 先按顺序看一遍我已经写的。如果前面有一步写错了，才导致写不下去：第一句话指出是哪一步（引用我写的式子）、错在哪，然后写出改正后的那一步，不要再往下写。
        2. 前面都没问题：第一句话说接在哪里往下写（引用我写的最后一个式子）；我还没写什么，就写出第一步。
        3. 把这一步的式子单独成行写成 $$...$$，写成我能直接抄到纸上的样子；一步就是一行，或者紧密相连、一起写出来的两三行。
        4. 最后用一两句话说明这一步为什么这样写：用了哪个条件、公式或方法。
        5. 只写这一步，不要往下算，也不要写出最终答案（除非这一步本身就是最后一步）。
        6. 行号只给你定位用，我看不到，不要说“第几行”。整体简洁，像老师在我纸上补写一行。
        """
        return s
    }

    // MARK: - 追问一条回复

    /// 学生标记过“还没学”的知识点：检查、提示、下一步、答案都不用
    static var unlearnedTopics: [String] {
        (UserDefaults.standard.stringArray(forKey: unlearnedTopicsKey) ?? []).filter { !$0.isEmpty }
    }
    static let unlearnedTopicsKey = "unlearnedTopics"

    /// 附在系统提示词“辅导原则”后面；没有标记过时为空
    static var unlearnedRule: String {
        let topics = unlearnedTopics
        guard !topics.isEmpty else { return "" }
        return pick("""


        【学生还没学过的知识点】\(topics.joined(separator: "、"))
        讲解、提示、写下一步、给完整答案时都不要用这些知识点，改用学生学过的更基础的方法。题目确实绕不开时，先用一句话说明，再用最直观的方式把用到的那一点讲明白。学生自己的作答用了这些知识点并且用对了，照常认可。
        """, """


        [Topics the student hasn't learned yet] \(topics.joined(separator: ", "))
        When explaining, giving hints, writing the next step or giving the full solution, don't use these topics; use more basic methods the student has learned. If the question really can't be done without one, say so in one sentence, then explain the bit that's needed in the most intuitive way. If the student's own work uses one of these topics correctly, accept it as usual.
        """)
    }

    /// 被追问的那条回复是什么（检查反馈、提示、下一步……）
    static func replyTitle(_ m: ChatMessage) -> String {
        switch m.kind {
        case .verdictCorrect, .verdictWrong: return pick("检查反馈", "checking feedback")
        case .hint:
            if m.isNextStep { return pick("替我写出的下一步", "the next step you wrote for me") }
            if m.isStuckHelp { return pick("卡住时的点拨", "your help when I was stuck") }
            return pick("提示", "hint")
        case .solution: return pick("完整答案", "full solution")
        default: return pick("回答", "answer")
        }
    }

    static func quotedReply(_ m: ChatMessage) -> String {
        var text = m.text
        if let marks = m.marks, !marks.isEmpty {
            text += "\n" + marks.enumerated().map { "\(circled($0.offset + 1)) \($0.element.note)" }.joined(separator: "\n")
        }
        return pick("【你之前的这条回复】（\(replyTitle(m))）\n", "[Your earlier reply] (\(replyTitle(m)))\n") + clip(text, 2500)
    }

    static func circled(_ n: Int) -> String {
        let digits = Array("①②③④⑤⑥⑦⑧⑨")
        return (1...digits.count).contains(n) ? String(digits[n - 1]) : "(\(n))"
    }

    /// 有疑问：学生直接写下哪里不明白
    static func doubtInstructionZH(about m: ChatMessage, question: String, done: Bool) -> String {
        var s = quotedReply(m) + "\n\n【我对这条回复的疑问】\(question)\n\n"
        s += "请针对我的疑问回答：先直接回应我问的那一处（是我哪里理解错了，还是你之前没讲清楚；如果确实是你之前讲错了，直接承认并改正），再把那一处讲明白，需要式子就写出来。"
        if !done && m.kind != .solution {
            s += "这道题我还没做完：不要借机给出最终答案或完整解法。"
        }
        return s + "简洁，控制在几句话以内。\n\n" + supplementRuleZH
    }

    /// “有疑问”里可以补充题目原文没有的数据：AI 当作已知条件，并用 <given> 记下来，之后批改都按它来
    static let supplementRuleZH = "如果我的疑问里补充了题目原文没有写出来的数据或条件（比如图上的数值、导入时漏掉的已知条件、别的小问或共用题干里的内容），就把它当作本题的已知条件：按它重新判断你这条回复，之前因为缺这个条件而判错、讲错或讲不下去的地方直接改正，并明确告诉我按补充的条件我原来的作答对不对（批改结果需要更新时，提醒我再点一次“检查”）；然后在回复的最后另起一行，把我补充的条件整理成一句完整、单独看也能看懂的话，写进 <given>…</given>（补充了几条就写几个标签，公式用 LaTeX，标签里不要加别的话）。我没有补充题目条件时不要写 <given>。"

    /// 取出回复里的 <given>…</given>（学生补充的题目条件），返回去掉标签的正文和这些条件
    static func extractGiven(_ text: String) -> (text: String, given: [String]) {
        var rest = text
        var given: [String] = []
        while let start = rest.range(of: "<given>"),
              let end = rest.range(of: "</given>", range: start.upperBound..<rest.endIndex) {
            let item = rest[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty { given.append(item) }
            rest.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), given)
    }

    /// 没学过：换成学过的方法重讲这条回复。topic 为空：学生说不出名字，让 AI 判断
    static func unlearnedInstructionZH(about m: ChatMessage, topic: String, done: Bool) -> String {
        var s = quotedReply(m) + "\n\n这条回复里用到了我还没学过的知识点"
        s += topic.isEmpty ? "（我说不出名字，请你判断是哪一个，通常是超出我目前程度的定理、公式或方法）。" : "：\(topic)。"
        s += """

        请不用这个知识点，改用更基础、我学过的方法，重新讲这条回复的内容：
        - 第一句话说明换成了什么方法。
        - 这道题确实绕不开这个知识点时，说明这一点，再用最直观的方式把需要的那一点讲明白，不要展开成整套理论。
        """
        if m.kind == .solution || done {
            s += "\n- 原来是完整答案，就用新方法写出完整过程和最终答案。"
        } else {
            s += "\n- 保持原来那条回复的分寸：原来是提示就只给提示，原来是下一步就只写一步。这道题我还没做完，不要给出最终答案。"
        }
        s += "\n- 最后单独一行写 <topic>这个知识点的简短名字</topic>（只给程序记下来用，我看不到），例如 <topic>洛必达法则</topic>。"
        return s
    }

    /// 取出回复最后的 <topic>…</topic>，返回去掉标签的正文和知识点名字
    static func extractTopic(_ text: String) -> (text: String, topic: String?) {
        guard let start = text.range(of: "<topic>"),
              let end = text.range(of: "</topic>", range: start.upperBound..<text.endIndex) else {
            return (text, nil)
        }
        let topic = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = text
        rest.removeSubrange(start.lowerBound..<end.upperBound)
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), topic.isEmpty ? nil : topic)
    }

    /// 用笔圈出一步来提问
    static func stepQuestionZH(_ text: String, done: Bool) -> String {
        // 点的是常用问题：换成具体的问法；“详细过程”这类不限几句话
        let (question, detailed) = AskPreset.resolve(text, in: .step)
        var s = "【我圈出的这一步】见手写图片里蓝框圈住的部分（左边的灰色数字是行号，只给你定位用，我看不到，回答里不要说“第几行”）。\n" + question
        if !done {
            s += "\n（这道题我还没做完：请只针对我圈出的这一步回答，可以指出问题、提示方向，不要直接给出最终答案。）"
        }
        return s + "\n" + (detailed ? detailedAnswerRule : "请简洁回答，控制在几句话以内。")
    }

    static let solutionInstructionZH = "我已经决定看完整答案了：请把这道题的每一小问都完整解出来，写出最终答案和详细的解题过程（推导写成对齐的公式），不要只给提示，也不要让我自己先试；最后总结一下解题的关键点。"

    // MARK: - 预先求解

    static func presolveSystemZH(for q: Question, siblings: [Question] = []) -> String {
        """
        你是严谨的解题老师。请认真求解下面这道题，结果用于之后批改学生的作答，学生看不到。\(q.stem?.isEmpty == false ? "只求解【本题】这一问。" : "")

        \(problemStatement(for: q, siblings: siblings))

        要求：
        - 先在心里仔细验算，再输出。
        - 只输出最终答案和关键步骤，简洁，不超过 12 行；选择题写明正确选项的字母；有多个小问时逐问给出答案。
        - 不要寒暄，不要解释你在做什么。

        \(formatRule)\(traditionalRule(for: q.fullText))
        """
    }

    static let presolveInstructionZH = "请求解这道题。"

    // MARK: - 精简上下文

    /// 之前的作答记录摘要：每次判定和反馈、每次提示、是否看过答案。
    /// 代替完整对话发给模型，对话变长后回复也不会越来越慢。
    static func progressSummaryZH(_ messages: [ChatMessage]) -> String? {
        var lines: [String] = []
        var attempts = 0, hints = 0
        for m in messages {
            switch m.kind {
            case .verdictWrong, .verdictCorrect:
                attempts += 1
                let result = m.kind == .verdictCorrect ? "正确" : "错误"
                lines.append("- 第 \(attempts) 次作答：判为\(result)。当时的反馈：\(clip(m.text, 300))")
            case .hintRequest:
                if let note = m.note, !note.isEmpty {
                    lines.append("- 学生请求提示时补充说：\(clip(note, 200))")
                }
            case .hint where m.isNextStep:
                lines.append("- 学生卡住时，AI 替学生写出了下一步：\(clip(m.text, 300))")
            case .hint:
                hints += 1
                lines.append("- 第 \(hints) 次提示：\(clip(m.text, 300))")
            case .solution:
                lines.append("- 学生已经看过完整答案。")
            default:
                break
            }
        }
        guard !lines.isEmpty else { return nil }
        // 记录很多时只留最近几条，最早的反馈对现在帮助不大
        let kept = lines.suffix(8)
        var s = "【之前的作答记录】共作答 \(attempts) 次，提示 \(hints) 次"
        if kept.count < lines.count { s += "（只列出最近 \(kept.count) 条）" }
        return s + "\n" + kept.joined(separator: "\n")
    }

    /// 检查答案时附在作答记录后面：以这次作答为准重新批改
    static let regradeNoteZH = "以上记录只用来了解我的进展。请只根据下面这次的作答重新批改，不要因为之前错过就判错；之前指出过的错误如果还在，简单点明即可，不要重复整段反馈。"

    /// 出的新题要记住的原题内容：题干和作答记录（包括收藏里重新练习之前的记录）
    static func originNoteZH(for source: Question) -> String {
        let history = (source.previousAttempts ?? []).flatMap { $0 } + source.messages
        var s = "原题（第 \(source.label) 题）：\n" + clip(source.fullText, 800) + "\n\n"
        s += progressSummary(history) ?? "学生在原题上没有错误记录。"
        // 新题再出新题时，最早那道原题的记录也带上
        if let earlier = source.originNote {
            s += "\n\n更早的原题：\n" + clip(earlier, 800)
        }
        return s
    }

    /// 对话里直接打字让 AI 出题时，也用出新题模型
    static func asksForNewQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["出一道", "出两道", "出三道", "出几道", "再出", "出道题", "出个题", "新题",
                "new question", "another question", "similar question", "harder question", "practice question",
                "new problem", "another problem", "similar problem", "harder problem", "practice problem"].contains { lower.contains($0) }
    }

    static func clip(_ s: String, _ limit: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit)) + "……" : t
    }

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

    /// 取出批改里的 <mark line="3">短评</mark>，返回去掉标签后的反馈
    static func extractMarks(_ text: String) -> (text: String, marks: [InkMark]) {
        let pattern = #"<mark\s+line\s*=\s*["'“”]?\s*(\d+)\s*["'“”]?\s*>([\s\S]*?)</mark>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, []) }
        let ns = text as NSString
        var marks: [InkMark] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let line = Int(ns.substring(with: match.range(at: 1))), line > 0 else { continue }
            let note = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            // 短评里可以有公式，太长才截断，免得把公式截成两半
            marks.append(InkMark(line: line, note: note.count > 80 ? clip(note, 80) : note))
        }
        let stripped = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), Array(marks.prefix(3)))
    }

    /// 流式输出过程中隐藏还没写完的出题标签和批改标记
    static func hideUnfinishedTags(_ text: String) -> String {
        var shown = extractMarks(extractNewQuestions(text).display).text
        if let r = shown.range(of: "<mark") { shown = String(shown[..<r.lowerBound]) }
        if let r = shown.range(of: "<topic") { shown = String(shown[..<r.lowerBound]) }
        if let r = shown.range(of: "<given") { shown = String(shown[..<r.lowerBound]) }
        if let r = shown.range(of: "<new_question") {
            return String(shown[..<r.lowerBound]) + "\n\n" + L("（正在出题…）")
        }
        return shown
    }

    private static let previewCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2000
        return cache
    }()

    /// 列表里的单行预览：去掉 LaTeX 标记，尽量可读。
    /// 题目列表、笔记目录每次刷新都要算一遍（十几个正则、几十次替换），算过的记下来
    static func plainPreview(_ text: String) -> String {
        if let cached = previewCache.object(forKey: text as NSString) { return cached as String }
        let result = makePlainPreview(text)
        previewCache.setObject(result as NSString, forKey: text as NSString)
        return result
    }

    private static func makePlainPreview(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\\\\(begin|end)\\{[^}]*\\}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\", with: "；")
        // 集合、数列的花括号 \{ \} 要留着（先换成占位符，免得和分组用的 {} 一起被去掉）；\% \_ 这些只去掉反斜杠
        s = s.replacingOccurrences(of: "\\{", with: "\u{1}").replacingOccurrences(of: "\\}", with: "\u{2}")
        s = s.replacingOccurrences(of: "\\\\([%_#&$ ])", with: "$1", options: .regularExpression)
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
        s = s.replacingOccurrences(of: "\\\\[dt]?frac(\\d)(\\d)", with: "$1/$2", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\(ce|text|mathrm|mathbf|vec|overline|boldsymbol)\\{([^{}]*)\\}", with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\(sin|cos|tan|cot|sec|csc|log|ln|lg|lim|max|min|exp)(?![A-Za-z])", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\\\[a-zA-Z]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[{}]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\*\\*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&", with: " ")
        s = s.replacingOccurrences(of: "\u{1}", with: "{").replacingOccurrences(of: "\u{2}", with: "}")
        s = s.replacingOccurrences(of: "\\", with: "")
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 选择题检查

    /// 题干里出现了几个不同的大写选项字母（A. / B、/ (C) / D： 等）。小写 (a)(b) 是小问，不算。
    static func optionLetterCount(_ content: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: "(?:^|[\\s（(])[（(]?([A-H])[\\.．、:：\\)）]") else { return 0 }
        let ns = content as NSString
        let letters = regex.matches(in: content, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        return Set(letters).count
    }

    /// 看起来是选择题但题干里没有选项（用于自动补全）
    static func looksLikeMissingOptions(_ content: String) -> Bool {
        guard optionLetterCount(content) < 2 else { return false }
        let lower = content.lowercased()
        let cues = ["（ ）", "（  ）", "（   ）", "（）", "( )", "(  )", "()",
                    "下列", "以下哪", "哪一个", "哪一项", "哪个选项", "哪些", "选出", "选择正确", "正确的是", "错误的是", "不正确的是",
                    "单选", "多选", "选择题",
                    "which of the following", "which one", "choose the", "select the", "multiple choice", "all of the following"]
        return cues.contains { lower.contains($0) }
    }

    /// 补全选项时追加的要求
    static func missingOptionsFollowUpZH(labels: [String]) -> String {
        let list = labels.map { "第 \($0) 题" }.joined(separator: "、")
        return """
        检查发现 \(list) 看起来是选择题，但你输出的题干里没有选项。请对照原文，只重新输出这几道题，必须包含全部选项（A、B、C、D……每个选项单独一行，放在 <content> 里）。格式和之前一样（<question label="…"><content>…</content><answer>…</answer></question>），不要输出其他题目，也不要输出 <title>。如果原文中这道题确实没有选项，就原样输出它。
        """
    }

    // MARK: - 标签解析

    /// 去掉指定标签块之后剩下的文字（再去掉残留的标签符号）
    static func textOutsideTags(_ names: [String], in text: String) -> String {
        var rest = text
        for name in names {
            for block in blocks(name, in: rest).reversed() {
                rest.replaceSubrange(block.range, with: "")
            }
        }
        rest = rest.replacingOccurrences(of: "</?[a-zA-Z_]+[^>]*>", with: "", options: .regularExpression)
        return unescapeEntities(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }


    struct TagBlock {
        var attributes: [String: String]
        var body: String
        var range: Range<String.Index>
    }

    /// 取第一个 <name>…</name> 的内容
    static func tag(_ name: String, in text: String) -> String? {
        blocks(name, in: text).first?.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 属性值：模型多半写 "3"，有时写 '3'、“3”，或者干脆不加引号；都认，不然整道题被悄悄丢掉
    private static let attributeValue = #"(?:"[^"]*"|'[^']*'|“[^”]*”|[^\s>"'“”]+)"#
    private static let attributeRegex = try? NSRegularExpression(
        pattern: #"([a-zA-Z_]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|“([^”]*)”|([^\s>"'“”]+))"#)

    /// 所有 <name attr="…">…</name> 块
    static func blocks(_ name: String, in text: String) -> [TagBlock] {
        let pattern = "<\(name)((?:\\s+[a-zA-Z_]+\\s*=\\s*\(attributeValue))*)\\s*>([\\s\\S]*?)</\(name)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            var attributes: [String: String] = [:]
            let attrText = ns.substring(with: match.range(at: 1))
            if let attrRegex = attributeRegex {
                let attrNS = attrText as NSString
                for m in attrRegex.matches(in: attrText, range: NSRange(location: 0, length: attrNS.length)) {
                    guard let value = (2...5).lazy.map({ m.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { continue }
                    attributes[attrNS.substring(with: m.range(at: 1))] = attrNS.substring(with: value)
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
