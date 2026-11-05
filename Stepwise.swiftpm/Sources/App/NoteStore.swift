import Foundation

/// 正在进行的笔记 AI 任务：生成整篇笔记，或者回答选中文字的提问
struct NoteJob: Equatable {
    var label: String
    /// 正在写、还没写完的那一块笔记
    var partial = ""
    /// 提问时：显示在哪一块后面
    var afterBlock: UUID?
    var startedAt = Date()
}

extension AppStore {
    /// 左侧题集列表里的题集（不含笔记的练习题集）
    var questionSets: [QuestionSet] { sets.filter { $0.noteID == nil } }

    func note(_ id: UUID?) -> NoteDoc? {
        notes.first { $0.id == id }
    }

    func mutateNote(_ id: UUID, _ change: (inout NoteDoc) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
    }

    func selectNote(_ id: UUID?) {
        selectedNoteID = id
        if id != nil {
            selectedSetID = nil
            selectedQuestionID = nil
        }
    }

    /// 新建一篇空笔记（连同存放练习题的题集）
    @discardableResult
    func createNote(title: String, sourceName: String = "", prompt: String = "") -> UUID {
        let exerciseSet = QuestionSet(title: "笔记练习：\(title)", questions: [])
        var doc = NoteDoc(title: title, sourceName: sourceName, prompt: prompt, exerciseSetID: exerciseSet.id)
        doc.blocks = []
        var linked = exerciseSet
        linked.noteID = doc.id
        sets.append(linked)
        notes.insert(doc, at: 0)
        selectNote(doc.id)
        return doc.id
    }

    func renameNote(_ id: UUID, to title: String) {
        mutateNote(id) { $0.title = title }
    }

    func deleteNote(_ id: UUID) {
        stopNoteJob(id)
        if let doc = note(id) { deleteSet(doc.exerciseSetID) }
        notes.removeAll { $0.id == id }
        if selectedNoteID == id { selectedNoteID = nil }
    }

    // MARK: 块

    /// after 为 nil 时加在最后
    func insertBlock(_ block: NoteBlock, in docID: UUID, after: UUID?) {
        mutateNote(docID) { doc in
            if let after, let i = doc.blocks.firstIndex(where: { $0.id == after }) {
                doc.blocks.insert(block, at: i + 1)
            } else {
                doc.blocks.append(block)
            }
        }
    }

    func updateBlockText(_ docID: UUID, _ blockID: UUID, _ text: String) {
        mutateNote(docID) { doc in
            guard let i = doc.blocks.firstIndex(where: { $0.id == blockID }), doc.blocks[i].text != text else { return }
            doc.blocks[i].text = text
        }
    }

    func moveBlock(_ docID: UUID, _ blockID: UUID, by offset: Int) {
        mutateNote(docID) { doc in
            guard let i = doc.blocks.firstIndex(where: { $0.id == blockID }) else { return }
            let j = i + offset
            guard doc.blocks.indices.contains(j) else { return }
            doc.blocks.swapAt(i, j)
        }
        renumberExercises(docID)
    }

    /// 删除一块；练习题连同它的作答记录、手写和由它出的变式题一起删
    func deleteBlock(_ docID: UUID, _ blockID: UUID) {
        guard let doc = note(docID), let block = doc.blocks.first(where: { $0.id == blockID }) else { return }
        if block.kind == .exercise, let qID = block.questionID {
            for q in exerciseQuestions(docID, qID) {
                cancelReply(q.id)
                ImageStore.delete(q.imageIDs + q.messages.flatMap(\.imageIDs))
                DrawingStore.delete([q.id])
                if let si = sets.firstIndex(where: { $0.id == doc.exerciseSetID }) {
                    sets[si].questions.removeAll { $0.id == q.id }
                }
            }
        }
        mutateNote(docID) { $0.blocks.removeAll { $0.id == blockID } }
        renumberExercises(docID)
    }

    /// 练习题按在笔记里的先后编号（第 1、2、3 题），题集里的顺序也跟着排；做完后出的变式题（“2-新1”）跟着原题改号
    func renumberExercises(_ docID: UUID) {
        guard let doc = note(docID), let si = sets.firstIndex(where: { $0.id == doc.exerciseSetID }) else { return }
        // 先按旧题号把每道题和它的变式题分好组，再改号
        let groups = doc.blocks.compactMap { $0.questionID }.map { exerciseQuestions(docID, $0) }
        let grouped = Set(groups.flatMap { $0.map(\.id) })
        var ordered: [Question] = []
        for (n, group) in groups.enumerated() {
            guard let first = group.first else { continue }
            let old = first.label
            for var q in group {
                q.label = q.id == first.id ? "\(n + 1)" : "\(n + 1)" + q.label.dropFirst(old.count)
                ordered.append(q)
            }
        }
        // 不在任何一块里的题（理论上没有）放在最后，不丢
        ordered += sets[si].questions.filter { !grouped.contains($0.id) }
        if ordered != sets[si].questions { sets[si].questions = ordered }
    }

    /// 一道练习题，以及做完后由它出的变式题（“3-新1”接在“3”后面）
    func exerciseQuestions(_ docID: UUID, _ qID: UUID) -> [Question] {
        guard let doc = note(docID), let set = set(doc.exerciseSetID),
              let i = set.questions.firstIndex(where: { $0.id == qID }) else { return [] }
        let label = set.questions[i].label
        var result = [set.questions[i]]
        var j = i + 1
        while j < set.questions.count && set.questions[j].label.hasPrefix(label + "-新") {
            result.append(set.questions[j])
            j += 1
        }
        return result
    }

    /// 在笔记里加一道练习题，返回新块的 id
    @discardableResult
    func addExercise(to docID: UUID, after: UUID?, content: String, answer: String?) -> UUID? {
        guard let doc = note(docID), let si = sets.firstIndex(where: { $0.id == doc.exerciseSetID }) else { return nil }
        // 先给一个不会重复的临时题号，插进笔记后按位置重新编号
        let q = Question(label: "\(sets[si].questions.count + 1000)", content: content, referenceAnswer: answer)
        sets[si].questions.append(q)
        let block = NoteBlock(kind: .exercise, questionID: q.id)
        insertBlock(block, in: docID, after: after)
        renumberExercises(docID)
        return block.id
    }

    func stopNoteJob(_ docID: UUID) {
        noteTasks[docID]?.cancel()
        noteTasks[docID] = nil
        noteJobs[docID] = nil
    }

    // MARK: 生成笔记

    /// 导入资料后开始生成笔记：先建好空笔记并打开，AI 写完一块就加一块
    func startNoteGeneration(material: ImportedMaterial, prompt: String, exercises: NoteExerciseLevel, title: String) throws {
        let client = try makeClient(for: .note)
        let chunks = Importer.chunks(for: material)
        guard !chunks.isEmpty else { throw LLMError(message: "没有可以整理的内容。") }
        let givenTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let docID = createNote(title: givenTitle.isEmpty ? material.name : givenTitle,
                               sourceName: material.name, prompt: prompt)
        noteJobs[docID] = NoteJob(label: "正在生成笔记…")

        noteTasks[docID] = Task { [weak self] in
            var failedParts: [Int] = []
            var firstError: Error?
            for (index, chunk) in chunks.enumerated() {
                guard let self, !Task.isCancelled else { break }
                self.noteJobs[docID]?.label = chunks.count > 1 ? "正在生成 第 \(index + 1)/\(chunks.count) 部分…" : "正在生成笔记…"
                self.noteJobs[docID]?.partial = ""

                var parts: [LLMContent] = chunk.images.map(LLMContent.image)
                var text = chunks.count > 1
                    ? "以下是学习资料的第 \(index + 1)/\(chunks.count) 部分。"
                    : "以下是学习资料的内容。"
                text += chunk.text.isEmpty ? "内容见上面的图片。" : "\n\n" + chunk.text
                parts.append(.text(text))
                let system = Tutor.noteSystem(prompt: prompt, exercises: exercises, hasImages: !chunk.images.isEmpty,
                                              multiPart: chunks.count > 1, first: index == 0)

                var full = ""
                var added = 0
                var lastFlush = Date.distantPast
                // 把已经写完的块加进笔记，没写完的那块实时显示
                @MainActor func flush() {
                    let parsed = Tutor.parseNote(full)
                    if index == 0, givenTitle.isEmpty, let t = parsed.title, !t.isEmpty,
                       self.note(docID)?.title == material.name {
                        self.renameNote(docID, to: t)
                    }
                    for item in parsed.items.dropFirst(added) {
                        switch item.kind {
                        case .note: self.insertBlock(NoteBlock(kind: .text, text: item.text), in: docID, after: nil)
                        case .exercise: self.addExercise(to: docID, after: nil, content: item.text, answer: item.answer)
                        }
                    }
                    added = max(added, parsed.items.count)
                    self.noteJobs[docID]?.partial = Tutor.unfinishedNote(full) ?? ""
                }
                do {
                    for try await piece in client.stream(system: system, messages: [LLMMessage(role: .user, parts: parts)]) {
                        full += piece
                        if Date().timeIntervalSince(lastFlush) > 0.2 {
                            flush()
                            lastFlush = Date()
                        }
                    }
                    try Task.checkCancellation()
                    flush()
                    // 完全没按格式输出：整段当成一块笔记
                    if added == 0 {
                        let loose = Tutor.looseNote(full)
                        if !loose.isEmpty { self.insertBlock(NoteBlock(kind: .text, text: loose), in: docID, after: nil) }
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled { break }
                    // 某一部分失败不影响其他部分
                    failedParts.append(index + 1)
                    if firstError == nil { firstError = error }
                }
            }
            guard let self else { return }
            let cancelled = Task.isCancelled
            self.noteJobs[docID] = nil
            self.noteTasks[docID] = nil
            guard !cancelled else { return }
            if self.note(docID)?.blocks.isEmpty == true, let firstError {
                // 一块都没写出来：不留空笔记，直接报错
                self.deleteNote(docID)
                self.errorMessage = firstError.localizedDescription
            } else if !failedParts.isEmpty {
                self.errorMessage = "共 \(chunks.count) 部分，其中第 \(failedParts.map(String.init).joined(separator: "、")) 部分没有生成成功，笔记可能不完整。"
            }
        }
    }

    // MARK: 选中文字提问

    /// 选中笔记里的一段提问。回答写成一块新笔记，插在选中的那一块后面；
    /// exerciseCount 大于 0 时是出练习题，依次插在那一块后面
    func askNote(_ docID: UUID, blockID: UUID, selection: String, title: String, prompt: String, exerciseCount: Int = 0) {
        let makesExercise = exerciseCount > 0
        guard noteTasks[docID] == nil, let doc = note(docID),
              let block = doc.blocks.first(where: { $0.id == blockID }) else { return }
        let client: LLMClient
        do { client = try makeClient(for: makesExercise ? .newQuestion : .chat) } catch {
            if !(error is ConsentRequired) { errorMessage = error.localizedDescription }
            return
        }
        var source = block.text
        if block.kind == .exercise, let qID = block.questionID, let q = question(doc.exerciseSetID, qID) {
            source = q.content
        }
        let system = Tutor.noteAskSystem(doc: doc)
        let messages = [LLMMessage(role: .user, parts: [.text(Tutor.noteAskInstruction(
            selection: selection, block: source, question: prompt, exerciseCount: exerciseCount))])]

        if makesExercise {
            noteJobs[docID] = NoteJob(label: exerciseCount > 1 ? "正在出 \(exerciseCount) 道题…" : "正在出题…", afterBlock: blockID)
            noteTasks[docID] = Task { [weak self] in
                do {
                    let output = try await client.complete(system: system, messages: messages)
                    try Task.checkCancellation()
                    guard let self else { return }
                    let items = Tutor.parseNote(output).items.filter { $0.kind == .exercise }.prefix(exerciseCount)
                    if !items.isEmpty {
                        // 按顺序一道接一道插在这一块后面
                        var after = blockID
                        for item in items {
                            if let id = self.addExercise(to: docID, after: after, content: item.text, answer: item.answer) { after = id }
                        }
                    } else {
                        self.errorMessage = "AI 没有按格式出题，请再试一次。"
                    }
                } catch {
                    if !(error is CancellationError) { self?.errorMessage = error.localizedDescription }
                }
                self?.noteJobs[docID] = nil
                self?.noteTasks[docID] = nil
            }
            return
        }

        let answer = NoteBlock(kind: .answer, quote: selection, question: title)
        insertBlock(answer, in: docID, after: blockID)
        noteJobs[docID] = NoteJob(label: "正在回答…", afterBlock: answer.id)
        noteTasks[docID] = Task { [weak self] in
            var full = ""
            var lastFlush = Date.distantPast
            do {
                for try await piece in client.stream(system: system, messages: messages) {
                    full += piece
                    if Date().timeIntervalSince(lastFlush) > 0.15 {
                        self?.updateBlockText(docID, answer.id, full)
                        lastFlush = Date()
                    }
                }
                try Task.checkCancellation()
                self?.updateBlockText(docID, answer.id, full.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                if !(error is CancellationError) { self?.errorMessage = error.localizedDescription }
                // 没写出内容就撤掉这一块
                if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self?.deleteBlock(docID, answer.id) }
            }
            self?.noteJobs[docID] = nil
            self?.noteTasks[docID] = nil
        }
    }
}
