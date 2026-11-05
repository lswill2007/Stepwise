import Foundation

/// 做题卡住时找到的相关笔记：去看哪一篇、哪一块，临时荧光笔标哪句话，知识点的极简总结
struct NoteGuide: Equatable {
    var noteID: UUID
    var blockID: UUID
    var quote: String
    var summary: String
    /// 从哪道题过来的，看完可以回去
    var setID: UUID
    var questionID: UUID
}

// MARK: - 提示词

extension Tutor {
    struct NoteSection {
        let noteID: UUID
        let blockID: UUID
        let text: String
    }

    static func relatedNoteSystem() -> String {
        """
        学生在做一道题时做错了或者卡住了。下面给出这道题和学生自己笔记里的若干小节（每节有编号）。
        判断笔记里有没有和这道题关联度很高的知识点：看了这一节，学生就能想到这道题该怎么做。只有关联度确实很高时才选，否则宁可不选。

        只输出下面两种之一，不要输出别的：
        <match section="编号"><quote>从这一节原文里原样摘出最关键的一句（不超过 40 字，尽量不含公式）</quote><summary>这个知识点的极简总结，不超过 12 个字</summary></match>
        <none/>
        """
    }

    static func relatedNoteInstruction(question: Question, sections: [NoteSection], wrong: Bool) -> String {
        var s = "【题目】\n" + clip(question.content, 1500) + "\n\n【学生的情况】" + (wrong ? "刚才做错了。" : "不会做，想要提示。")
        s += "\n\n【学生的笔记】"
        for (i, section) in sections.enumerated() {
            s += "\n\n#\(i + 1)\n" + clip(section.text, 600)
        }
        return s
    }

    /// 解析 <match>；没有高度相关的、格式不对时为 nil
    static func parseRelatedNote(_ output: String, sections: [NoteSection]) -> (section: NoteSection, quote: String, summary: String)? {
        guard let block = blocks("match", in: output).first,
              let raw = block.attributes["section"], let n = Int(raw.trimmingCharacters(in: CharacterSet(charactersIn: "# "))),
              sections.indices.contains(n - 1) else { return nil }
        let quote = tag("quote", in: block.body) ?? ""
        let summary = tag("summary", in: block.body) ?? ""
        guard !summary.isEmpty else { return nil }
        return (sections[n - 1], clip(quote, 60), clip(summary, 20))
    }

    /// 荧光笔在排版后的页面上找这句话：去掉公式，取最长的一段文字
    static func highlightKey(_ quote: String) -> String {
        let plain = quote.replacingOccurrences(of: #"\$[^$]*\$"#, with: "|", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
        let pieces = plain.components(separatedBy: CharacterSet(charactersIn: "|，。；：,.;:!?！？()（）\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return pieces.max { $0.count < $1.count } ?? ""
    }

    /// “详细记录 xxx”：把一个知识点详细整理成一块笔记
    static func detailNoteInstruction(topic: String, block: String) -> String {
        """
        【笔记里相关的一段】
        \(clip(block, 2000))

        请把「\(topic)」这个知识点详细整理成一块笔记，补在这一段后面：用 ### 小标题开头，写清定义或结论、为什么成立、怎么用（配一个简短的例子）、常见易错点。不要重复上面已经写过的内容，不要开场白。
        """
    }
}

// MARK: - 找相关笔记、记录详细笔记

extension AppStore {
    /// 题集所在的“最小文件夹”里的笔记；笔记里的练习题，就找这篇笔记所在文件夹的笔记
    func notesNear(setID: UUID) -> [NoteDoc] {
        guard let set = set(setID) else { return [] }
        let folderID: UUID?
        if let noteID = set.noteID { folderID = note(noteID)?.folderID } else { folderID = set.folderID }
        let actual = folder(folderID) == nil ? nil : folderID
        return notes.filter { (folder($0.folderID) == nil ? nil : $0.folderID) == actual }
    }

    /// 做错或者要提示时：在同一个文件夹的笔记里找关联度很高的知识点，找到了就在题目下面引导去看
    func findRelatedNote(_ setID: UUID, _ qID: UUID, wrong: Bool) {
        guard aiConsent == true, noteGuideTasks[qID] == nil, noteGuides[qID] == nil,
              let q = question(setID, qID) else { return }
        // 每篇最多 8 节，一共最多 24 节：请求小，回得快
        var sections: [Tutor.NoteSection] = []
        for doc in notesNear(setID: setID).prefix(4) {
            for block in doc.blocks where block.kind == .text && !block.text.isEmpty {
                sections.append(Tutor.NoteSection(noteID: doc.id, blockID: block.id, text: block.text))
            }
        }
        sections = Array(sections.prefix(24))
        guard !sections.isEmpty, let client = try? makeClient(for: .check) else { return }
        let system = Tutor.relatedNoteSystem()
        let messages = [LLMMessage(role: .user, parts: [.text(Tutor.relatedNoteInstruction(question: q, sections: sections, wrong: wrong))])]
        noteGuideTasks[qID] = Task { [weak self] in
            let output = try? await client.complete(system: system, messages: messages, options: RequestOptions(fast: true))
            guard let self else { return }
            self.noteGuideTasks[qID] = nil
            guard let output, let match = Tutor.parseRelatedNote(output, sections: sections) else { return }
            self.noteGuides[qID] = NoteGuide(noteID: match.section.noteID, blockID: match.section.blockID,
                                             quote: match.quote, summary: match.summary, setID: setID, questionID: qID)
        }
    }

    /// 去看笔记：打开那篇笔记，翻到那一块，临时荧光笔标出重点
    func openNoteGuide(_ guide: NoteGuide) {
        activeNoteGuide = guide
        selectNote(guide.noteID)
        // 等笔记页排好版再翻过去
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.noteJump = guide.blockID }
    }

    /// 看完回到题目
    func returnFromNoteGuide() {
        guard let guide = activeNoteGuide else { return }
        activeNoteGuide = nil
        selectedNoteID = nil
        selectedSetID = set(guide.setID)?.noteID == nil ? guide.setID : nil
        if let noteID = set(guide.setID)?.noteID {
            // 笔记里的练习题：回到那篇笔记
            selectNote(noteID)
        }
        selectedQuestionID = guide.questionID
    }

    /// “详细记录 xxx”：AI 把这个知识点详细写成一块笔记，插在那一块后面
    func recordDetail(_ guide: NoteGuide) {
        let docID = guide.noteID
        guard noteTasks[docID] == nil, let doc = note(docID),
              let block = doc.blocks.first(where: { $0.id == guide.blockID }) else { return }
        let client: LLMClient
        do { client = try makeClient(for: .chat) } catch {
            if !(error is ConsentRequired) { errorMessage = error.localizedDescription }
            return
        }
        let newBlock = NoteBlock(kind: .text)
        insertBlock(newBlock, in: docID, after: guide.blockID)
        let system = Tutor.noteAskSystem(doc: doc)
        let messages = [LLMMessage(role: .user, parts: [.text(Tutor.detailNoteInstruction(topic: guide.summary, block: block.text))])]
        noteJobs[docID] = NoteJob(label: "正在记录…", afterBlock: newBlock.id)
        noteTasks[docID] = Task { [weak self] in
            var full = ""
            var lastFlush = Date.distantPast
            do {
                for try await piece in client.stream(system: system, messages: messages) {
                    full += piece
                    if Date().timeIntervalSince(lastFlush) > 0.15 {
                        self?.updateBlockText(docID, newBlock.id, full)
                        lastFlush = Date()
                    }
                }
                try Task.checkCancellation()
                self?.updateBlockText(docID, newBlock.id, full.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                if !(error is CancellationError) { self?.errorMessage = error.localizedDescription }
                if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self?.deleteBlock(docID, newBlock.id) }
            }
            self?.noteJobs[docID] = nil
            self?.noteTasks[docID] = nil
        }
        // 记过了就不再提示
        if activeNoteGuide?.blockID == guide.blockID { activeNoteGuide?.summary = "" }
    }
}
