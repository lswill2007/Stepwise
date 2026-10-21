import Foundation
import SwiftUI

/// 正在进行中的模型请求（每道题最多一个）
struct PendingReply: Equatable {
    var kind: MessageKind
    var text: String = ""
}

@MainActor
final class AppStore: ObservableObject {
    // MARK: 题库
    @Published var sets: [QuestionSet] = [] { didSet { scheduleSave() } }
    @Published var selectedSetID: UUID?
    @Published var selectedQuestionID: UUID?
    /// 左侧两栏（题集、题目列表）是否显示；.detailOnly 为全屏做题
    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    var isFullScreen: Bool { columnVisibility == .detailOnly }

    func setFullScreen(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) {
            columnVisibility = on ? .detailOnly : .all
        }
    }

    // MARK: 服务商
    @Published var providers: [ProviderConfig] = [] { didSet { saveProviders() } }
    @Published var activeProviderID: String = "anthropic" { didSet { UserDefaults.standard.set(activeProviderID, forKey: "activeProvider") } }

    // MARK: 运行状态
    @Published var pending: [UUID: PendingReply] = [:]
    @Published var errorMessage: String?

    private var saveTask: Task<Void, Never>?
    private var replyTasks: [UUID: Task<Void, Never>] = [:]

    nonisolated private static let libraryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("library.json")

    init() {
        if let data = try? Data(contentsOf: Self.libraryURL),
           let decoded = try? JSONDecoder().decode([QuestionSet].self, from: data) {
            sets = decoded.map(Self.cleaned)
        }
        loadProviders()
        activeProviderID = UserDefaults.standard.string(forKey: "activeProvider") ?? "anthropic"
        // 打开 App 时直接回到最近的题集，停在第一道还没完成的题
        if let recent = sets.first {
            selectedSetID = recent.id
            selectedQuestionID = recent.questions.first(where: { !$0.status.isDone })?.id ?? recent.questions.first?.id
        }
    }

    // MARK: - 持久化

    /// 修正旧版本导入的数据：统一题号、还原转义字符、去掉题干里重复的题号行（可重复执行）
    private static func cleaned(_ set: QuestionSet) -> QuestionSet {
        var set = set
        for i in set.questions.indices where !set.questions[i].isGenerated {
            var q = set.questions[i]
            q.label = Tutor.displayLabel(q.label)
            q.content = Tutor.stripLeadingLabel(Tutor.unescapeEntities(q.content), label: q.label)
            q.referenceAnswer = q.referenceAnswer.map(Tutor.unescapeEntities)
            set.questions[i] = q
        }
        return set
    }

    /// 立即写盘（App 退到后台、切题时调用，避免最后几秒的改动丢失）
    func saveNow() {
        saveTask?.cancel()
        if let data = try? JSONEncoder().encode(sets) {
            try? data.write(to: Self.libraryURL, options: .atomic)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = sets
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.libraryURL, options: .atomic)
        }
    }

    private func loadProviders() {
        var saved: [ProviderConfig] = []
        if let data = UserDefaults.standard.data(forKey: "providers"),
           let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
            saved = decoded
        }
        // 用最新的预设补齐（升级后新增的服务商、新增的预设模型）
        var merged: [ProviderConfig] = ProviderCatalog.presets.map { preset in
            guard var old = saved.first(where: { $0.id == preset.id }) else { return preset }
            old.presetModels = preset.presetModels
            old.note = preset.note
            return old
        }
        merged += saved.filter { $0.isCustom }
        providers = merged
    }

    private func saveProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: "providers")
        }
    }

    // MARK: - 服务商

    var activeProvider: ProviderConfig? {
        providers.first { $0.id == activeProviderID }
    }

    func updateProvider(_ config: ProviderConfig) {
        if let i = providers.firstIndex(where: { $0.id == config.id }) {
            providers[i] = config
        } else {
            providers.append(config)
        }
    }

    func select(provider id: String, model: String) {
        guard let i = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[i].model = model
        activeProviderID = id
    }

    func deleteProvider(_ id: String) {
        Keychain.set("", for: id)
        providers.removeAll { $0.id == id }
        if activeProviderID == id { activeProviderID = "anthropic" }
    }

    func makeClient() throws -> LLMClient {
        guard let config = activeProvider else { throw LLMError(message: "请先在设置里选择一个模型服务商。") }
        return LLMClient(config: config, apiKey: config.apiKey)
    }

    // MARK: - 题库访问

    func set(_ id: UUID?) -> QuestionSet? {
        sets.first { $0.id == id }
    }

    func question(_ setID: UUID, _ qID: UUID) -> Question? {
        set(setID)?.questions.first { $0.id == qID }
    }

    func mutate(_ setID: UUID, _ qID: UUID, _ change: (inout Question) -> Void) {
        guard let si = sets.firstIndex(where: { $0.id == setID }),
              let qi = sets[si].questions.firstIndex(where: { $0.id == qID }) else { return }
        change(&sets[si].questions[qi])
    }

    func addSet(_ newSet: QuestionSet) {
        sets.insert(newSet, at: 0)
        selectedSetID = newSet.id
        selectedQuestionID = newSet.questions.first?.id
    }

    func deleteSet(_ id: UUID) {
        guard let s = set(id) else { return }
        for q in s.questions { cancelReply(q.id) }
        ImageStore.delete(s.questions.flatMap { q in q.imageIDs + q.messages.flatMap(\.imageIDs) })
        DrawingStore.delete(s.questions.map(\.id))
        sets.removeAll { $0.id == id }
        if selectedSetID == id {
            selectedSetID = nil
            selectedQuestionID = nil
        }
    }

    func renameSet(_ id: UUID, to title: String) {
        guard let i = sets.firstIndex(where: { $0.id == id }) else { return }
        sets[i].title = title
    }

    func resetQuestion(_ setID: UUID, _ qID: UUID) {
        cancelReply(qID)
        mutate(setID, qID) { q in
            ImageStore.delete(q.messages.flatMap(\.imageIDs))
            q.messages = []
            q.status = .todo
            q.hintCount = 0
            q.draftAnswer = ""
        }
        DrawingStore.delete([qID])
    }

    func neighbor(of qID: UUID, in setID: UUID, offset: Int) -> UUID? {
        guard let qs = set(setID)?.questions, let i = qs.firstIndex(where: { $0.id == qID }) else { return nil }
        let j = i + offset
        return qs.indices.contains(j) ? qs[j].id : nil
    }

    /// 下一道还没通过的题；没有就返回顺序上的下一题
    func nextQuestion(after qID: UUID, in setID: UUID) -> UUID? {
        guard let qs = set(setID)?.questions, let i = qs.firstIndex(where: { $0.id == qID }) else { return nil }
        let rest = qs[(i + 1)...]
        return rest.first(where: { !$0.status.isDone })?.id ?? rest.first?.id
    }

    // MARK: - 辅导操作

    func isBusy(_ qID: UUID) -> Bool { pending[qID] != nil }

    func cancelReply(_ qID: UUID) {
        replyTasks[qID]?.cancel()
        replyTasks[qID] = nil
        pending[qID] = nil
    }

    func check(_ setID: UUID, _ qID: UUID, answer: String, handwriting: Data?) {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty || handwriting != nil else { return }
        var prompt = "【我的作答】\n" + (answer.isEmpty ? "（见手写图片）" : answer)
        prompt += "\n\n" + Tutor.checkInstruction
        let imageIDs = handwriting.map { [ImageStore.save($0)] } ?? []
        let message = ChatMessage(role: .user, kind: .submission, text: answer, prompt: prompt, imageIDs: imageIDs)

        run(setID, qID, userMessage: message, replyKind: .verdictWrong) { [weak self] full in
            let verdict = Tutor.parseVerdict(full)
            // 没有按格式给出判定时按“未通过”处理，反馈原样显示
            let correct = verdict.correct ?? false
            self?.mutate(setID, qID) { q in
                let reply = ChatMessage(
                    role: .assistant, kind: correct ? .verdictCorrect : .verdictWrong,
                    text: verdict.feedback,
                    prompt: "<verdict>\(correct ? "correct" : "wrong")</verdict>\n\(verdict.feedback)")
                q.messages.append(reply)
                if correct {
                    if q.status != .revealed { q.status = .passed }
                    q.draftAnswer = ""
                } else if !q.status.isDone {
                    q.status = .wrong
                }
            }
        }
    }

    func requestHint(_ setID: UUID, _ qID: UUID) {
        guard let q = question(setID, qID) else { return }
        let level = q.hintCount + 1
        let message = ChatMessage(role: .user, kind: .hintRequest, text: "需要进一步提示（第 \(level) 次）",
                                  prompt: Tutor.hintInstruction(level: level))
        run(setID, qID, userMessage: message, replyKind: .hint) { [weak self] full in
            self?.mutate(setID, qID) { q in
                q.hintCount = level
                q.messages.append(ChatMessage(role: .assistant, kind: .hint, text: full))
            }
        }
    }

    func requestSolution(_ setID: UUID, _ qID: UUID) {
        let message = ChatMessage(role: .user, kind: .solutionRequest, text: "给出完整答案", prompt: Tutor.solutionInstruction)
        run(setID, qID, userMessage: message, replyKind: .solution) { [weak self] full in
            self?.mutate(setID, qID) { q in
                q.messages.append(ChatMessage(role: .assistant, kind: .solution, text: full))
                if q.status != .passed { q.status = .revealed }
            }
        }
    }

    func sendChat(_ setID: UUID, _ qID: UUID, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let message = ChatMessage(role: .user, kind: .chat, text: text)
        run(setID, qID, userMessage: message, replyKind: .chat) { [weak self] full in
            guard let self else { return }
            let (display, newOnes) = Tutor.extractNewQuestions(full)
            let created = self.insertGenerated(newOnes, after: qID, in: setID)
            self.mutate(setID, qID) { q in
                q.messages.append(ChatMessage(role: .assistant, kind: .chat, text: display.isEmpty && !created.isEmpty ? "新题来了：" : display,
                                              prompt: full, generatedQuestionIDs: created))
            }
        }
    }

    /// 把对话中出的新题插到当前题后面，返回新题 id
    private func insertGenerated(_ items: [Tutor.NewQuestion], after qID: UUID, in setID: UUID) -> [UUID] {
        guard !items.isEmpty,
              let si = sets.firstIndex(where: { $0.id == setID }),
              let qi = sets[si].questions.firstIndex(where: { $0.id == qID }) else { return [] }
        let baseLabel = sets[si].questions[qi].label
        let existing = sets[si].questions.filter { $0.label.hasPrefix(baseLabel + "-新") }.count
        var insertAt = qi + 1
        // 跳过之前已插入的变式题，保持顺序
        while insertAt < sets[si].questions.count && sets[si].questions[insertAt].label.hasPrefix(baseLabel + "-新") {
            insertAt += 1
        }
        var ids: [UUID] = []
        for (k, item) in items.enumerated() {
            let q = Question(label: "\(baseLabel)-新\(existing + k + 1)", content: item.content,
                             referenceAnswer: item.answer, isGenerated: true)
            sets[si].questions.insert(q, at: insertAt + k)
            ids.append(q.id)
        }
        return ids
    }

    /// 通用流程：追加用户消息 → 流式请求 → 完成后由 finish 写入回复
    private func run(_ setID: UUID, _ qID: UUID, userMessage: ChatMessage, replyKind: MessageKind,
                     finish: @escaping (String) -> Void) {
        guard !isBusy(qID) else { return }
        let client: LLMClient
        do { client = try makeClient() } catch {
            errorMessage = error.localizedDescription
            ImageStore.delete(userMessage.imageIDs)
            return
        }
        mutate(setID, qID) { $0.messages.append(userMessage) }
        guard let q = question(setID, qID) else { return }

        let system = Tutor.tutorSystem(for: q)
        let history = Self.history(for: q)
        pending[qID] = PendingReply(kind: replyKind)

        replyTasks[qID] = Task { [weak self] in
            var full = ""
            var lastFlush = Date.distantPast
            do {
                for try await chunk in client.stream(system: system, messages: history) {
                    full += chunk
                    // 限制刷新频率，长回答流式输出时界面不卡
                    if Date().timeIntervalSince(lastFlush) > 0.08 {
                        self?.pending[qID]?.text = full
                        lastFlush = Date()
                    }
                }
                try Task.checkCancellation()
                self?.pending[qID] = nil
                if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw LLMError(message: "模型没有返回内容，请重试。")
                }
                finish(full)
            } catch {
                guard let self else { return }
                self.pending[qID] = nil
                // 失败时撤回这次的提问，方便直接重试
                self.mutate(setID, qID) { q in q.messages.removeAll { $0.id == userMessage.id } }
                ImageStore.delete(userMessage.imageIDs)
                if !(error is CancellationError) {
                    self.errorMessage = error.localizedDescription
                }
            }
            self?.replyTasks[qID] = nil
        }
    }

    /// 发送给模型的对话历史。图片只带题目原图和最近两条带图消息，控制请求体积。
    static func history(for q: Question) -> [LLMMessage] {
        var result: [LLMMessage] = []
        let questionImages = q.imageIDs.compactMap(ImageStore.load).map(LLMContent.image)
        if !questionImages.isEmpty {
            result.append(LLMMessage(role: .user, parts: questionImages + [.text("（以上是题目原图，题目中的图形、表格以图片为准）")]))
        }
        let withImages = q.messages.indices.filter { !q.messages[$0].imageIDs.isEmpty }.suffix(2)
        for (i, m) in q.messages.enumerated() {
            var parts: [LLMContent] = []
            if withImages.contains(i) {
                parts += m.imageIDs.compactMap(ImageStore.load).map(LLMContent.image)
            }
            parts.append(.text(m.prompt ?? m.text))
            result.append(LLMMessage(role: m.role, parts: parts))
        }
        return result
    }

    // MARK: - 拆分题目

    func split(material: ImportedMaterial, requirement: String, title: String,
               progress: @escaping (Int, Int) -> Void) async throws -> QuestionSet {
        let client = try makeClient()
        let chunks = Importer.chunks(for: material)
        guard !chunks.isEmpty else { throw LLMError(message: "没有可以拆分的内容。") }

        var questions: [Question] = []
        var keys: [String] = []          // 与 questions 一一对应的题号，用于合并重叠页产生的重复题
        var suggestedTitle: String?
        var failedParts: [Int] = []
        var firstError: Error?

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(index + 1, chunks.count)
            var parts: [LLMContent] = chunk.images.map(LLMContent.image)
            var text = chunks.count > 1
                ? "以下是题目文件的第 \(index + 1)/\(chunks.count) 部分（与前后部分各有一页重叠）。"
                : "以下是题目文件的内容。"
            text += chunk.text.isEmpty ? "内容见上面的图片。" : "\n\n" + chunk.text
            parts.append(.text(text))

            let parsed: (title: String?, items: [Tutor.SplitItem])
            do {
                let output = try await client.complete(
                    system: Tutor.splitSystem(requirement: requirement, hasImages: !chunk.images.isEmpty, multiPart: chunks.count > 1),
                    messages: [LLMMessage(role: .user, parts: parts)])
                parsed = try Tutor.parseSplit(output)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 某一部分失败（比如只有封面）不影响其他部分
                failedParts.append(index + 1)
                if firstError == nil { firstError = error }
                continue
            }
            if suggestedTitle == nil { suggestedTitle = parsed.title }

            for item in parsed.items {
                let key = Tutor.labelKey(item.label)
                if let existing = keys.firstIndex(of: key) {
                    // 重叠页里的同一道题：补上缺失的答案，题干取更完整的那份
                    if questions[existing].referenceAnswer == nil, let answer = item.answer {
                        questions[existing].referenceAnswer = answer
                    } else if let answer = item.answer, answer.count > (questions[existing].referenceAnswer?.count ?? 0) {
                        questions[existing].referenceAnswer = answer
                    }
                    if item.content.count > questions[existing].content.count {
                        questions[existing].content = item.content
                    }
                    continue
                }
                var imageIDs: [String] = []
                if item.hasFigure, !chunk.images.isEmpty {
                    let page = item.page ?? (chunk.images.count == 1 ? 1 : nil)
                    if let page, chunk.images.indices.contains(page - 1) {
                        imageIDs = [ImageStore.save(chunk.images[page - 1])]
                    }
                }
                questions.append(Question(label: item.label, content: item.content,
                                          referenceAnswer: item.answer, imageIDs: imageIDs))
                keys.append(key)
            }
        }
        guard !questions.isEmpty else {
            throw firstError ?? LLMError(message: "没有识别出题目。可以调整拆分要求，或换一个能力更强的模型再试。")
        }
        if !failedParts.isEmpty {
            errorMessage = "共 \(chunks.count) 部分，其中第 \(failedParts.map(String.init).joined(separator: "、")) 部分没有识别成功，可能漏了题目。可以检查一下题目列表，必要时重新导入。"
        }

        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (suggestedTitle ?? material.name) : title
        return QuestionSet(title: finalTitle, requirement: requirement, questions: questions)
    }
}
