import Foundation
import CoreGraphics

// MARK: - AI 白板：数据操作、提示词和回复解析

extension Whiteboard {
    /// 画布的宽度（纸的坐标）；高度随写的内容往下加长
    static let canvasWidth: CGFloat = 2400
    /// 便签的宽度（屏幕上的点，不随缩放变）；拖右下角放大缩小以后乘上便签自己的倍数
    static let stickyWidth: CGFloat = 280
    /// 便签能拖到多小、多大（倍数）
    static let stickyScales: ClosedRange<CGFloat> = 0.75...2.5

    /// 框住一处后，便签放在哪里：右边放得下放右边，放不下放左边，再放不下放下面；和已有的便签叠在一起时往下挪。
    /// 便签按屏幕大小画，不随缩放变：zoom 是现在的缩放，heights 是量到的每张便签的高度（屏幕上的点）
    static func stickySpot(for region: CGRect, avoiding notes: [BoardNote] = [], zoom: CGFloat = 1,
                           heights: [UUID: CGFloat] = [:]) -> CGPoint {
        let z = max(zoom, 0.05)
        let gap: CGFloat = 28 / z
        let width = stickyWidth / z
        var spot: CGPoint
        if region.maxX + gap + width <= canvasWidth {
            spot = CGPoint(x: region.maxX + gap, y: region.minY)
        } else if region.minX - gap - width >= 0 {
            spot = CGPoint(x: region.minX - gap - width, y: region.minY)
        } else {
            spot = CGPoint(x: max(0, region.minX), y: region.maxY + gap)
        }
        // 收起的便签只是一个小标签
        let others = notes.map { note in
            let h = note.minimized ? 34 : (heights[note.id] ?? estimatedHeight(note))
            let w = note.minimized ? 70 : note.width
            return CGRect(x: note.x, y: note.y, width: Double(w / z), height: Double(h / z))
        }
        for _ in 0..<30 {
            let mine = CGRect(x: spot.x, y: spot.y, width: width, height: 160 / z)
            guard let hit = others.first(where: { $0.intersects(mine) }) else { break }
            spot.y = hit.maxY + 16 / z
        }
        return spot
    }

    /// 没量到时估一下便签有多高（屏幕上的点）：每段按一行 16 个字折行，段与段之间留空
    static func estimatedHeight(_ note: BoardNote) -> CGFloat {
        func height(_ text: String, perLine: Int, lineHeight: CGFloat) -> CGFloat {
            text.components(separatedBy: "\n").reduce(0) { sum, line in
                let n = line.trimmingCharacters(in: .whitespaces).count
                return sum + (n == 0 ? 6 : CGFloat((n + perLine - 1) / perLine) * lineHeight + 8)
            }
        }
        let body = height(note.text, perLine: 16, lineHeight: 23)
        let comments = note.comments.reduce(0) { $0 + height($1.note, perLine: 17, lineHeight: 20) + 6 }
        return 60 + max(body, 46) + comments
    }
}

extension BoardNote {
    var isCheck: Bool { question == nil }
    /// 拖右下角放大缩小的倍数
    var sizeScale: CGFloat { CGFloat(scale ?? 1) }
    /// 便签现在的宽度（屏幕上的点）
    var width: CGFloat { Whiteboard.stickyWidth * sizeScale }
}

extension AppStore {
    func board(_ id: UUID?) -> Whiteboard? {
        boards.first { $0.id == id }
    }

    func mutateBoard(_ id: UUID, _ change: (inout Whiteboard) -> Void) {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return }
        change(&boards[i])
    }

    func mutateBoardNote(_ boardID: UUID, _ noteID: UUID, _ change: (inout BoardNote) -> Void) {
        mutateBoard(boardID) { board in
            guard let i = board.notes.firstIndex(where: { $0.id == noteID }) else { return }
            change(&board.notes[i])
        }
    }

    func selectBoard(_ id: UUID?) {
        if id != nil {
            if activeNoteGuide != nil { activeNoteGuide = nil }
            selectedNoteID = nil
            selectedSetID = nil
            selectedQuestionID = nil
        }
        selectedBoardID = id
    }

    /// 新建一块白板并打开；纸用上次选的样式
    @discardableResult
    func createBoard() -> UUID {
        let count = boards.count + 1
        var board = Whiteboard(title: count == 1 ? L("白板") : String(localized: "白板 \(count)"))
        if let last = UserDefaults.standard.string(forKey: "boardPaper"), let style = PaperStyle(rawValue: last) {
            board.paper = style
        }
        boards.insert(board, at: 0)
        selectBoard(board.id)
        return board.id
    }

    func renameBoard(_ id: UUID, to title: String) {
        mutateBoard(id) { $0.title = title }
    }

    func setBoardPaper(_ id: UUID, _ style: PaperStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: "boardPaper")
        mutateBoard(id) { $0.paper = style }
    }

    func deleteBoard(_ id: UUID) {
        stopBoardJob(id)
        DrawingStore.delete([id])
        ReadingPosition.forget([id])
        boards.removeAll { $0.id == id }
        if selectedBoardID == id { selectedBoardID = nil }
    }

    func deleteBoardNote(_ boardID: UUID, _ noteID: UUID) {
        if boardJobs[boardID] == noteID { stopBoardJob(boardID) }
        mutateBoard(boardID) { $0.notes.removeAll { $0.id == noteID } }
    }

    func stopBoardJob(_ boardID: UUID) {
        boardTasks[boardID]?.cancel()
        boardTasks[boardID] = nil
        boardJobs[boardID] = nil
    }

    /// 框选一处发给 AI。image：框住的笔迹，左边印了行号；lines：每一行在画布上的位置（行号从 1 开始）；
    /// question 为 nil 时是检查。回复写在一张便签上，指出的问题按行号列在下面
    func askBoard(_ boardID: UUID, region: CGRect, lines: [CGRect], image: Data, question: String?,
                  zoom: CGFloat = 1, stickyHeights: [UUID: CGFloat] = [:]) {
        guard boardTasks[boardID] == nil, board(boardID) != nil else { return }
        let purpose: RequestPurpose = question == nil ? .check : .chat
        let client: LLMClient
        do { client = try makeClient(for: purpose) } catch {
            if !(error is ConsentRequired) { errorMessage = error.localizedDescription }
            return
        }
        let spot = Whiteboard.stickySpot(for: region, avoiding: board(boardID)?.notes ?? [], zoom: zoom, heights: stickyHeights)
        let note = BoardNote(region: InkRegion(region), x: spot.x, y: spot.y,
                             question: question?.trimmingCharacters(in: .whitespacesAndNewlines))
        mutateBoard(boardID) { board in
            board.notes.append(note)
            // 新的回复一定要看得到
            board.notesHidden = false
        }
        boardJobs[boardID] = note.id
        let system = Tutor.boardSystem()
        let instruction = question.map { Tutor.boardAskInstruction($0, lineCount: lines.count) }
            ?? Tutor.boardCheckInstruction(lineCount: lines.count)
        var messages = [LLMMessage(role: .user, parts: [.image(image), .text(instruction)])]
        let options = RequestOptions(fast: purpose.isGrading && quickGrading)
        let modelName = client.config.model
        // 检查：框选的手写先交给识图模型（Haiku）逐行转写，检查模型只看文字；转写失败时照旧发图片。
        // 提问不转写：问的可能是图形、示意图，文字表达不了
        let reader = question == nil ? handwritingReader() : nil

        boardTasks[boardID] = Task { [weak self] in
            var full = ""
            var lastFlush = Date.distantPast
            do {
                if let reader {
                    self?.mutateBoardNote(boardID, note.id) { $0.text = L("正在读手写…") }
                    let lines = await AppStore.transcribe(image, with: reader)
                    try Task.checkCancellation()
                    self?.mutateBoardNote(boardID, note.id) { $0.text = "" }
                    if let lines {
                        let text = Tutor.handwritingTranscript(lines, title: Tutor.pick("我框选的手写", "The handwriting I selected"))
                            + "\n\n" + Tutor.boardTranscriptNote + "\n\n" + instruction
                        messages = [LLMMessage(role: .user, parts: [.text(text)])]
                    }
                }
                for try await piece in client.stream(system: system, messages: messages, options: options) {
                    full += piece
                    if Date().timeIntervalSince(lastFlush) > 0.12 {
                        let shown = Tutor.parseBoardReply(full).text
                        self?.mutateBoardNote(boardID, note.id) { $0.text = shown }
                        lastFlush = Date()
                    }
                }
                try Task.checkCancellation()
                let reply = Tutor.parseBoardReply(full)
                if reply.text.isEmpty && reply.comments.isEmpty {
                    throw LLMError(message: L("模型没有返回内容，请重试。"))
                }
                self?.mutateBoardNote(boardID, note.id) { n in
                    n.text = reply.text
                    n.verdict = question == nil ? reply.verdict : nil
                    n.model = modelName
                    n.comments = reply.comments.map { c in
                        BoardComment(line: c.line, note: c.note,
                                     rect: lines.indices.contains(c.line - 1) ? InkRegion(lines[c.line - 1]) : nil)
                    }
                }
            } catch {
                if !(error is CancellationError) { self?.errorMessage = error.localizedDescription }
                // 没写出内容就撤掉这张便签
                let shown = Tutor.parseBoardReply(full).text
                if shown.isEmpty {
                    self?.mutateBoard(boardID) { $0.notes.removeAll { $0.id == note.id } }
                } else {
                    self?.mutateBoardNote(boardID, note.id) { $0.text = shown }
                }
            }
            // 停止后又马上问了下一处：不要把新的任务清掉
            if self?.boardJobs[boardID] == note.id {
                self?.boardJobs[boardID] = nil
                self?.boardTasks[boardID] = nil
            }
        }
    }
}

// MARK: - 提示词

extension Tutor {
    static func boardSystem() -> String {
        pick("""
        你是一位耐心、严谨的学习辅导老师。学生在一块白板上手写题目和自己的解答，会框选其中一部分（图片）发给你，请你检查或回答问题。你的回复会写在白板上的一张便签里，所以要简短、直接。

        \(formatRule)
        """, """
        You are a patient, careful tutor. The student writes questions and their own working by hand on a whiteboard, and sends you a part of it they selected (an image) to check or ask about. Your reply goes on a sticky note on the whiteboard, so keep it short and to the point.

        \(formatRule)
        """)
    }

    static func boardCheckInstruction(lineCount: Int) -> String {
        let lines = lineCount > 0
        return pick("""
        图片是我在白板上框选的手写内容，可能有题目，也可能有我的解答。\(lines ? "图片左边的灰色数字是行号，只给你定位用，我在白板上看不到，回答里不要说“第几行”。" : "")
        请像老师坐在旁边一样帮我检查：
        - 先认清题目和我写的每一步。看不清的地方直接说哪里看不清（引用附近写的内容），不要猜。
        - 第一行只输出 <verdict>correct</verdict>、<verdict>wrong</verdict> 或 <verdict>unsure</verdict>（只给程序用，我看不到）：结果和必要的过程都对判 correct；有错判 wrong；只有题目还没开始做、没写完、或者看不清没法判断，判 unsure。
        - 然后在 <reply>…</reply> 里写给我的反馈，2–5 句：做对的步骤一句带过；出问题的地方说清是哪一步、为什么不对、该从哪里检查，不要直接给出这一步的正确结果，也不要给完整解法。只有题目时，给一个思路方向的提示，不要解出来；没写完时，确认已经写的对不对，再提示下一步往哪个方向想。
        - 语气平和，不要用“错了”开头，不要说教。
        \(lines ? "- 判 wrong 时，在 </reply> 后面为每一处需要改的地方单独写一行 <comment line=\"行号\">一句话说清这一行哪里要再看、为什么</comment>，行号是图片左边的数字，按从上到下的顺序写，最多 4 处；不要给出正确答案。判 correct 时不写 comment。这些地方会在白板上用红色波浪线标出，按 comment 的先后标上 ①②③④；<reply> 里提到它们时直接用 ①②③④ 指代，或者引用我写的式子，不要说“第几行”，comment 里也一样。\n" : "")标签外面不要写其他内容。
        """, """
        The image is handwriting I selected on my whiteboard. It may contain a question, my working, or both.\(lines ? " The gray numbers on the left of the image are line numbers, only for you to locate things; I can't see them on my whiteboard, so don't mention them." : "")
        Please check it like a teacher sitting next to me:
        - First read the question and each step I wrote. If something is unreadable, say which part you can't read (quote what's nearby); don't guess.
        - On the first line, output only <verdict>correct</verdict>, <verdict>wrong</verdict> or <verdict>unsure</verdict> (for the app; I won't see it): correct when the result and the necessary working are right; wrong when something is wrong; unsure when there is only a question with no working yet, the working is unfinished, or it can't be read.
        - Then write your feedback to me inside <reply>…</reply>, 2–5 sentences: confirm correct steps briefly; for the step that goes wrong, say which step it is, why it doesn't work and where to look again, without giving the correct result of that step or the full solution. If there is only a question, give a hint about which direction to think in, without solving it; if the working is unfinished, confirm whether what's there is right, then hint at the direction for the next step.
        - Keep the tone calm; don't open with "wrong" and don't lecture.
        \(lines ? "- When the verdict is wrong, after </reply> write one separate line for each place that needs fixing: <comment line=\"line number\">one sentence on what to look at again in this line and why</comment>, using the numbers on the left of the image, in order from top to bottom, at most 4; don't give the correct answer. No comment when the verdict is correct. These places get a red wavy underline on the whiteboard, labeled ①②③④ in the order of the comments; in <reply>, refer to them as ①②③④ or quote what I wrote, never as \"line 3\", and the same in the comments.\n" : "")Write nothing outside the tags.
        """)
    }

    static func boardAskInstruction(_ question: String, lineCount: Int) -> String {
        let lines = lineCount > 0
        let (question, detailed) = AskPreset.resolve(question, in: .board)
        return pick("""
        图片是我在白板上框选的手写内容。\(lines ? "图片左边的灰色数字是行号，只给你定位用，我在白板上看不到，回答里不要说“第几行”。" : "")

        【我的问题】\(question)

        在 <reply>…</reply> 里回答，像老师写在便签上的话：紧扣我框住的内容，\(detailed ? detailedAnswerRule : "几句话说清楚，必要时写出关键推导。")\(lines ? "要指出某一行时，可以在 </reply> 后面单独写 <comment line=\"行号\">一句话</comment>，最多 3 处，<reply> 里按先后用 ①②③ 指代它们。" : "")标签外面不要写其他内容。
        """, """
        The image is handwriting I selected on my whiteboard.\(lines ? " The gray numbers on the left of the image are line numbers, only for you to locate things; I can't see them, so don't mention them." : "")

        [My question] \(question)

        Answer inside <reply>…</reply>, like a teacher's words on a sticky note: stick to what I selected. \(detailed ? detailedAnswerRule : "A few sentences, with the key derivation if needed.")\(lines ? " To point at a particular line, after </reply> you may write <comment line=\"line number\">one sentence</comment> on its own line, at most 3, and refer to them in <reply> as ①②③ in that order." : "") Write nothing outside the tags.
        """)
    }

    struct BoardReply: Equatable {
        /// correct / wrong / unsure；还没判出来是 nil
        var verdict: String?
        var text: String
        var comments: [InkMark]
    }

    /// 解析白板便签的回复；流式输出时也能调用：text 是到目前为止写好的反馈，没写完的标签不显示
    static func parseBoardReply(_ output: String) -> BoardReply {
        var verdict: String?
        if let v = tag("verdict", in: output)?.lowercased() {
            if v.hasPrefix("correct") || v.hasPrefix("正确") || v == "true" {
                verdict = "correct"
            } else if v.hasPrefix("wrong") || v.hasPrefix("错") || v == "false" {
                verdict = "wrong"
            } else {
                verdict = "unsure"
            }
        }
        let pattern = #"<comment\s+line\s*=\s*["'“”]?\s*(\d+)\s*["'“”]?\s*>([\s\S]*?)</comment>"#
        var comments: [InkMark] = []
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = output as NSString
            for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length)) {
                guard let line = Int(ns.substring(with: match.range(at: 1))), line > 0 else { continue }
                let note = unescapeEntities(ns.substring(with: match.range(at: 2))).trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty { comments.append(InkMark(line: line, note: note)) }
            }
        }

        var text: String
        if let open = output.range(of: "<reply>") {
            let rest = output[open.upperBound...]
            text = String(rest.range(of: "</reply>").map { rest[..<$0.lowerBound] } ?? rest)
        } else if output.contains("<reply") || (output.contains("<verdict") && !output.contains("</verdict>")) {
            // 还在写 <reply>、<verdict> 这个标签
            text = ""
        } else {
            // 没按格式写：标签外面的都算
            text = textOutsideTags(["verdict", "comment"], in: output)
        }
        // 写在反馈里的 comment、还没写完的标签不显示
        text = text.replacingOccurrences(of: #"<comment[\s\S]*?(</comment>|$)"#, with: "", options: .regularExpression)
        if let r = text.range(of: "<[^>]*$", options: .regularExpression) { text.removeSubrange(r) }
        text = text.replacingOccurrences(of: "</?(verdict|reply)>", with: "", options: .regularExpression)
        return BoardReply(verdict: verdict, text: unescapeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines),
                          comments: Array(comments.prefix(6)))
    }
}
