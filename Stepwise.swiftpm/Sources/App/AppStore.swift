import Foundation
import SwiftUI

/// 正在进行中的模型请求（每道题最多一个）
struct PendingReply: Equatable {
    var kind: MessageKind
    var text: String = ""
    var startedAt = Date()
    /// 圈出一步来提问：回答写在页边，不写在题目下面
    var inMargin = false
}

/// 错题复习的结果（只在本次打开 App 期间显示）
enum ReviewOutcome: Equatable {
    case mastered(rounds: Int)   // 2 轮内做对，已移出错题本
    case keep(rounds: Int)       // 用了 3 轮以上，留在错题本
    case revealed                // 看了完整答案，留在错题本
}

/// AI 请求的用途，决定用哪个模型、是否用快速模式
enum RequestPurpose {
    case check, hint, solution, chat, newQuestion, presolve, split
    /// 导入资料生成笔记：可以单独选一个整理长资料能力强的模型
    case note

    /// 批改和提示：可以用单独的批改模型和快速模式
    var isGrading: Bool { self == .check || self == .hint }
}

@MainActor
final class AppStore: ObservableObject {
    // MARK: 题库
    @Published var sets: [QuestionSet] = [] { didSet { scheduleSave() } }
    /// 左侧的分级文件夹，单独存在 folders.json
    @Published var folders: [Folder] = [] { didSet { saveFolders() } }
    @Published var selectedSetID: UUID?
    @Published var selectedQuestionID: UUID?
    /// 错题复习结果提示
    @Published var reviewOutcomes: [UUID: ReviewOutcome] = [:]

    // MARK: 笔记
    /// 笔记模式的文档，单独存在 notes.json
    @Published var notes: [NoteDoc] = [] { didSet { scheduleNotesSave() } }
    @Published var selectedNoteID: UUID?
    /// 正在生成或回答的笔记（每篇笔记同时只有一个）
    @Published var noteJobs: [UUID: NoteJob] = [:]
    /// 左侧笔记目录点了哪一块，笔记就滚到哪一块
    @Published var noteJump: UUID?
    var noteTasks: [UUID: Task<Void, Never>] = [:]
    private var notesSaveTask: Task<Void, Never>?

    /// 左侧“错题本”这一项的固定 id
    static let mistakeBookID = UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!
    /// 错题本里几轮内做对就移出
    static let masteryRounds = 2

    var isMistakeBook: Bool { selectedSetID == Self.mistakeBookID }
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

    // MARK: 数据发送同意
    /// 是否已同意把题目和作答发送给第三方 AI 服务商（nil 表示还没选择过）
    @Published private(set) var aiConsent: Bool? = {
        UserDefaults.standard.object(forKey: "aiConsent") as? Bool
    }()
    @Published var showConsent = false

    // MARK: 批改速度
    /// 检查答案和提示时让模型少思考
    @Published var quickGrading: Bool = UserDefaults.standard.object(forKey: "quickGrading") as? Bool ?? true {
        didSet { UserDefaults.standard.set(quickGrading, forKey: "quickGrading") }
    }
    /// 单独的批改与提示模型；为 nil 时跟随当前模型
    @Published var gradingProviderID: String? = UserDefaults.standard.string(forKey: "gradingProvider") {
        didSet { UserDefaults.standard.set(gradingProviderID, forKey: "gradingProvider") }
    }
    @Published var gradingModel: String = UserDefaults.standard.string(forKey: "gradingModel") ?? "" {
        didSet { UserDefaults.standard.set(gradingModel, forKey: "gradingModel") }
    }
    /// 在 AI 回复旁显示用时
    @Published var showTiming: Bool = UserDefaults.standard.object(forKey: "showTiming") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showTiming, forKey: "showTiming") }
    }

    // MARK: 作答与出题
    /// 允许键盘作答；默认只用 Apple Pencil 手写
    @Published var keyboardAnswer: Bool = UserDefaults.standard.bool(forKey: "keyboardAnswer") {
        didSet { UserDefaults.standard.set(keyboardAnswer, forKey: "keyboardAnswer") }
    }
    /// 做完一道题之后的快捷操作
    @Published var followUps: [FollowUpAction] = {
        guard let data = UserDefaults.standard.data(forKey: "followUps"),
              let saved = try? JSONDecoder().decode([FollowUpAction].self, from: data) else { return FollowUpAction.defaults }
        return saved
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(followUps) { UserDefaults.standard.set(data, forKey: "followUps") }
        }
    }
    /// 单独的出新题模型（一般选推理能力强的）；为 nil 时跟随当前模型
    @Published var questionProviderID: String? = UserDefaults.standard.string(forKey: "questionProvider") {
        didSet { UserDefaults.standard.set(questionProviderID, forKey: "questionProvider") }
    }
    @Published var questionModel: String = UserDefaults.standard.string(forKey: "questionModel") ?? "" {
        didSet { UserDefaults.standard.set(questionModel, forKey: "questionModel") }
    }

    /// 单独的整理笔记模型（导入资料生成笔记时用，一般选上下文长、能力强的）；为 nil 时跟随当前模型
    @Published var noteProviderID: String? = UserDefaults.standard.string(forKey: "noteProvider") {
        didSet { UserDefaults.standard.set(noteProviderID, forKey: "noteProvider") }
    }
    @Published var noteModel: String = UserDefaults.standard.string(forKey: "noteModel") ?? "" {
        didSet { UserDefaults.standard.set(noteModel, forKey: "noteModel") }
    }

    /// 导入后在后台预先求解没有参考答案的题
    @Published var presolveAnswers: Bool = UserDefaults.standard.object(forKey: "presolveAnswers") as? Bool ?? true {
        didSet { UserDefaults.standard.set(presolveAnswers, forKey: "presolveAnswers") }
    }
    /// 正在后台求解的题
    private var presolving: Set<UUID> = []

    /// 实际用于批改和提示的服务商（已填 Key 且选了模型才生效）
    var gradingProvider: ProviderConfig? { overrideProvider(id: gradingProviderID, model: gradingModel) }
    /// 实际用于出新题的服务商
    var questionProvider: ProviderConfig? { overrideProvider(id: questionProviderID, model: questionModel) }
    /// 实际用于生成笔记的服务商
    var noteProvider: ProviderConfig? { overrideProvider(id: noteProviderID, model: noteModel) }

    private func overrideProvider(id: String?, model: String) -> ProviderConfig? {
        guard let id, var config = providers.first(where: { $0.id == id }), config.hasKey else { return nil }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        config.model = model
        return config
    }

    func setAIConsent(_ value: Bool) {
        aiConsent = value
        UserDefaults.standard.set(value, forKey: "aiConsent")
    }

    private var saveTask: Task<Void, Never>?
    private var replyTasks: [UUID: Task<Void, Never>] = [:]

    nonisolated private static let libraryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("library.json")
    private static let foldersURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("folders.json")
    nonisolated private static let notesURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("notes.json")

    init() {
        if let data = try? Data(contentsOf: Self.libraryURL) {
            if let decoded = try? JSONDecoder().decode([QuestionSet].self, from: data) {
                sets = decoded.map(Self.cleaned)
            } else {
                // 读不出来时先把原文件备份，绝不能让之后的保存把题库覆盖掉
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let backup = Self.libraryURL.deletingLastPathComponent().appendingPathComponent("library-backup-\(stamp).json")
                try? data.write(to: backup)
            }
        }
        if let data = try? Data(contentsOf: Self.notesURL),
           let decoded = try? JSONDecoder().decode([NoteDoc].self, from: data) {
            notes = decoded
        }
        if let data = try? Data(contentsOf: Self.foldersURL),
           let decoded = try? JSONDecoder().decode([Folder].self, from: data) {
            folders = decoded
            repairFolders()
        }
        loadProviders()
        activeProviderID = UserDefaults.standard.string(forKey: "activeProvider") ?? "anthropic"
        // 打开 App 时直接回到最近的题集，停在第一道还没完成的题
        if let recent = questionSets.first {
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
        notesSaveTask?.cancel()
        if let data = try? JSONEncoder().encode(notes) {
            try? data.write(to: Self.notesURL, options: .atomic)
        }
    }

    /// 笔记在流式生成时变化很频繁，停一会儿再写盘
    private func scheduleNotesSave() {
        notesSaveTask?.cancel()
        let snapshot = notes
        notesSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.notesURL, options: .atomic)
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

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(folders) {
            try? data.write(to: Self.foldersURL, options: .atomic)
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

    func makeClient(for purpose: RequestPurpose = .chat) throws -> LLMClient {
        // 没有同意数据发送说明之前，不向任何 AI 服务商发送内容
        guard aiConsent == true else {
            showConsent = true
            throw ConsentRequired()
        }
        if purpose.isGrading, let grading = gradingProvider {
            return LLMClient(config: grading, apiKey: grading.apiKey)
        }
        if purpose == .newQuestion || purpose == .presolve, let question = questionProvider {
            return LLMClient(config: question, apiKey: question.apiKey)
        }
        if purpose == .note, let note = noteProvider {
            return LLMClient(config: note, apiKey: note.apiKey)
        }
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
        presolve(newSet.id, newSet.questions.map(\.id))
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
            q.reviewRounds = nil
        }
        reviewOutcomes[qID] = nil
        DrawingStore.delete([qID])
    }

    // MARK: - 错题本

    /// 错题本里的所有题，按加入时间从新到旧
    var starredEntries: [(setID: UUID, question: Question)] {
        sets.flatMap { set in set.questions.filter(\.isStarred).map { (set.id, $0) } }
            .sorted { ($0.question.starredAt ?? .distantPast) > ($1.question.starredAt ?? .distantPast) }
    }

    /// 某道题属于哪个题集
    func setID(containing qID: UUID) -> UUID? {
        sets.first { $0.questions.contains { $0.id == qID } }?.id
    }

    func toggleStar(_ setID: UUID, _ qID: UUID) {
        mutate(setID, qID) { q in
            if q.isStarred {
                q.starredAt = nil
                q.reviewRounds = nil
            } else {
                q.starredAt = Date()
            }
        }
        reviewOutcomes[qID] = nil
    }

    /// 从错题本打开一道还没做完的题：从现在开始计轮数
    func beginReviewIfNeeded(_ setID: UUID, _ qID: UUID) {
        guard let q = question(setID, qID), q.isStarred, !q.status.isDone, q.reviewRounds == nil else { return }
        mutate(setID, qID) { $0.reviewRounds = 0 }
    }

    /// 已经做完的错题重新练一遍：之前的作答记录折叠保存，题目恢复成未作答
    func startReview(_ setID: UUID, _ qID: UUID) {
        cancelReply(qID)
        mutate(setID, qID) { q in
            if !q.messages.isEmpty {
                q.previousAttempts = (q.previousAttempts ?? []) + [q.messages]
            }
            q.messages = []
            q.status = .todo
            q.hintCount = 0
            q.draftAnswer = ""
            q.reviewRounds = 0
        }
        reviewOutcomes[qID] = nil
        DrawingStore.delete([qID])
    }

    /// 复习中每完成一次检查或提示调用一次，返回已用轮数
    private func countReviewRound(_ q: inout Question) -> Int? {
        guard let r = q.reviewRounds else { return nil }
        q.reviewRounds = r + 1
        return r + 1
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

    // MARK: - 预先求解

    /// 在后台为没有参考答案的题求解答案，之后批改只需对答案。
    /// 两题一组并行；没同意数据发送、没开这个设置、出错时都静默跳过，不打扰做题。
    func presolve(_ setID: UUID, _ ids: [UUID]) {
        guard presolveAnswers, aiConsent == true else { return }
        let todo = ids.filter { id in
            guard let q = question(setID, id), !presolving.contains(id) else { return false }
            return (q.referenceAnswer ?? "").isEmpty && q.aiAnswer == nil
        }
        guard !todo.isEmpty, let client = try? makeClient(for: .presolve) else { return }
        presolving.formUnion(todo)
        // 在主线程先把题目和图片准备好
        let jobs: [(UUID, String, [LLMMessage])] = todo.compactMap { id in
            guard let q = question(setID, id) else { return nil }
            let images = q.imageIDs.compactMap(ImageStore.load).map(LLMContent.image)
            return (id, Tutor.presolveSystem(for: q), [LLMMessage(role: .user, parts: images + [.text(Tutor.presolveInstruction)])])
        }
        Task { [weak self] in
            for start in stride(from: 0, to: jobs.count, by: 2) {
                let batch = jobs[start..<min(start + 2, jobs.count)]
                await withTaskGroup(of: (UUID, String?).self) { group in
                    for (id, system, messages) in batch {
                        group.addTask {
                            let answer = try? await client.complete(system: system, messages: messages)
                            return (id, answer?.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                    for await (id, answer) in group {
                        guard let self else { continue }
                        self.presolving.remove(id)
                        if let answer, !answer.isEmpty {
                            self.mutate(setID, id) { $0.aiAnswer = answer }
                        }
                    }
                }
            }
        }
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
        // 手写图片左边印着行号，AI 可以指出错在哪一行
        prompt += "\n\n" + Tutor.checkInstruction(lineNumbers: handwriting != nil)
        let imageIDs = handwriting.map { [ImageStore.save($0)] } ?? []
        let message = ChatMessage(role: .user, kind: .submission, text: answer, prompt: prompt, imageIDs: imageIDs)

        run(setID, qID, userMessage: message, replyKind: .verdictWrong, purpose: .check) { [weak self] full in
            let verdict = Tutor.parseVerdict(full)
            // 没有按格式给出判定时按“未通过”处理，反馈原样显示
            let correct = verdict.correct ?? false
            let (feedback, marks) = Tutor.extractMarks(verdict.feedback)
            self?.mutate(setID, qID) { q in
                var reply = ChatMessage(
                    role: .assistant, kind: correct ? .verdictCorrect : .verdictWrong,
                    text: feedback,
                    prompt: "<verdict>\(correct ? "correct" : "wrong")</verdict>\n\(feedback)")
                if !correct && !marks.isEmpty { reply.marks = marks }
                q.messages.append(reply)
                let rounds = self?.countReviewRound(&q)
                if correct {
                    let revealedBefore = q.status == .revealed
                    if q.status != .revealed { q.status = .passed }
                    if let rounds {
                        q.reviewRounds = nil
                        if rounds <= AppStore.masteryRounds && !revealedBefore {
                            // 错题本里 2 轮内做对：说明掌握了，移出错题本
                            q.starredAt = nil
                            self?.reviewOutcomes[qID] = .mastered(rounds: rounds)
                        } else {
                            self?.reviewOutcomes[qID] = revealedBefore ? .revealed : .keep(rounds: rounds)
                        }
                    }
                } else if !q.status.isDone {
                    q.status = .wrong
                }
            }
        }
    }

    /// note：学生补充的文字说明（卡在哪里），可以为空
    func requestHint(_ setID: UUID, _ qID: UUID, note: String? = nil) {
        guard let q = question(setID, qID) else { return }
        let level = q.hintCount + 1
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = ChatMessage(role: .user, kind: .hintRequest, text: "需要进一步提示（第 \(level) 次）",
                                  prompt: Tutor.hintInstruction(level: level, note: note))
        message.note = note?.isEmpty == false ? note : nil
        run(setID, qID, userMessage: message, replyKind: .hint, purpose: .hint) { [weak self] full in
            self?.mutate(setID, qID) { q in
                q.hintCount = level
                var hint = ChatMessage(role: .assistant, kind: .hint, text: full)
                hint.hintLevel = level
                q.messages.append(hint)
                _ = self?.countReviewRound(&q)
            }
        }
    }

    func requestSolution(_ setID: UUID, _ qID: UUID) {
        let message = ChatMessage(role: .user, kind: .solutionRequest, text: "给出完整答案", prompt: Tutor.solutionInstruction)
        run(setID, qID, userMessage: message, replyKind: .solution, purpose: .solution) { [weak self] full in
            self?.mutate(setID, qID) { q in
                q.messages.append(ChatMessage(role: .assistant, kind: .solution, text: full))
                if q.status != .passed { q.status = .revealed }
                // 复习中看了完整答案：这轮复习结束，题目留在错题本
                if q.reviewRounds != nil {
                    q.reviewRounds = nil
                    self?.reviewOutcomes[qID] = .revealed
                }
            }
        }
    }

    /// makesQuestion：这句话是让 AI 出新题，用出新题模型
    func sendChat(_ setID: UUID, _ qID: UUID, text: String, makesQuestion: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let message = ChatMessage(role: .user, kind: .chat, text: text)
        let purpose: RequestPurpose = makesQuestion || Tutor.asksForNewQuestion(text) ? .newQuestion : .chat
        run(setID, qID, userMessage: message, replyKind: .chat, purpose: purpose) { [weak self] full in
            guard let self else { return }
            let (display, newOnes) = Tutor.extractNewQuestions(full)
            let created = self.insertGenerated(newOnes, after: qID, in: setID)
            self.mutate(setID, qID) { q in
                q.messages.append(ChatMessage(role: .assistant, kind: .chat, text: display.isEmpty && !created.isEmpty ? "出了一道新题：" : display,
                                              prompt: full, generatedQuestionIDs: created))
            }
        }
    }

    /// 用笔圈出一步来提问。image：整块手写，圈住的地方画了蓝框；回答贴在页边
    func askAboutStep(_ setID: UUID, _ qID: UUID, text: String, image: Data?, region: InkRegion) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let q = question(setID, qID) else { return }
        let imageIDs = image.map { [ImageStore.save($0)] } ?? []
        var message = ChatMessage(role: .user, kind: .chat, text: text,
                                  prompt: Tutor.stepQuestion(text, done: q.status.isDone), imageIDs: imageIDs)
        message.region = region
        run(setID, qID, userMessage: message, replyKind: .chat, purpose: .chat, inMargin: true) { [weak self] full in
            self?.mutate(setID, qID) { q in
                var reply = ChatMessage(role: .assistant, kind: .chat, text: full)
                reply.region = region
                q.messages.append(reply)
            }
        }
    }

    /// 把对话中出的新题插到当前题后面，返回新题 id
    private func insertGenerated(_ items: [Tutor.NewQuestion], after qID: UUID, in setID: UUID) -> [UUID] {
        guard !items.isEmpty,
              let si = sets.firstIndex(where: { $0.id == setID }),
              let qi = sets[si].questions.firstIndex(where: { $0.id == qID }) else { return [] }
        let baseLabel = sets[si].questions[qi].label
        let origin = Tutor.originNote(for: sets[si].questions[qi])
        let existing = sets[si].questions.filter { $0.label.hasPrefix(baseLabel + "-新") }.count
        var insertAt = qi + 1
        // 跳过之前已插入的变式题，保持顺序
        while insertAt < sets[si].questions.count && sets[si].questions[insertAt].label.hasPrefix(baseLabel + "-新") {
            insertAt += 1
        }
        var ids: [UUID] = []
        for (k, item) in items.enumerated() {
            var q = Question(label: "\(baseLabel)-新\(existing + k + 1)", content: item.content,
                             referenceAnswer: item.answer, isGenerated: true)
            q.originNote = origin
            sets[si].questions.insert(q, at: insertAt + k)
            ids.append(q.id)
        }
        return ids
    }

    /// 通用流程：追加用户消息 → 流式请求 → 完成后由 finish 写入回复
    private func run(_ setID: UUID, _ qID: UUID, userMessage: ChatMessage, replyKind: MessageKind,
                     purpose: RequestPurpose, inMargin: Bool = false, finish: @escaping (String) -> Void) {
        guard !isBusy(qID) else { return }
        let client: LLMClient
        do { client = try makeClient(for: purpose) } catch {
            if !(error is ConsentRequired) { errorMessage = error.localizedDescription }
            ImageStore.delete(userMessage.imageIDs)
            return
        }
        mutate(setID, qID) { $0.messages.append(userMessage) }
        guard let q = question(setID, qID) else { return }

        let system = Tutor.tutorSystem(for: q, origin: q.originNote ?? legacyOrigin(of: q, in: setID))
        let history = Self.context(for: q, current: userMessage, purpose: purpose)
        let options = RequestOptions(fast: purpose.isGrading && quickGrading)
        let modelName = client.config.model
        pending[qID] = PendingReply(kind: replyKind, inMargin: inMargin)
        let started = Date()

        replyTasks[qID] = Task { [weak self] in
            var full = ""
            var lastFlush = Date.distantPast
            do {
                for try await chunk in client.stream(system: system, messages: history, options: options) {
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
                // 记下用时和模型，显示在回复旁边
                let elapsed = Date().timeIntervalSince(started)
                self?.mutate(setID, qID) { q in
                    if let i = q.messages.lastIndex(where: { $0.role == .assistant }) {
                        q.messages[i].duration = elapsed
                        q.messages[i].model = modelName
                    }
                }
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

    /// 旧版本出的新题没有保存原题记忆：按题号（“3-新1”的原题是“3”）找到原题现场生成
    private func legacyOrigin(of q: Question, in setID: UUID) -> String? {
        guard q.isGenerated, let range = q.label.range(of: "-新", options: .backwards) else { return nil }
        let base = String(q.label[..<range.lowerBound])
        guard let source = set(setID)?.questions.first(where: { $0.label == base }) else { return nil }
        return Tutor.originNote(for: source)
    }

    /// 发送给模型的上下文。不发完整对话（越来越长，回复越来越慢）：
    /// 之前的批改和提示压缩成一段摘要，再附上这次请求真正需要的内容。
    /// - 检查答案：摘要 + 这次的作答，以这次作答为准重新批改
    /// - 提示：摘要 + 最近一次作答（含手写图片）
    /// - 完整答案：摘要
    /// - 继续对话：摘要 + 完整答案 + 最近几轮对话
    static func context(for q: Question, current: ChatMessage, purpose: RequestPurpose) -> [LLMMessage] {
        let earlier = q.messages.filter { $0.id != current.id }
        let summary = Tutor.progressSummary(earlier)
        func images(_ m: ChatMessage) -> [LLMContent] { m.imageIDs.compactMap(ImageStore.load).map(LLMContent.image) }

        var result: [LLMMessage] = []
        let questionImages = q.imageIDs.compactMap(ImageStore.load).map(LLMContent.image)
        if !questionImages.isEmpty {
            result.append(LLMMessage(role: .user, parts: questionImages + [.text("（以上是题目原图，题目中的图形、表格以图片为准）")]))
        }

        switch purpose {
        case .check:
            let blocks = [summary, summary == nil ? nil : Tutor.regradeNote, current.prompt ?? current.text]
            result.append(LLMMessage(role: .user, parts: images(current) + [.text(blocks.compactMap { $0 }.joined(separator: "\n\n"))]))
        case .hint, .solution, .presolve, .split, .note:
            var blocks = [summary]
            var parts: [LLMContent] = []
            if purpose == .hint, let last = earlier.last(where: { $0.kind == .submission }) {
                parts = images(last)
                blocks.append("【我最近一次的作答】\n" + (last.text.isEmpty ? "（见手写图片）" : Tutor.clip(last.text, 1500)))
            }
            blocks.append(current.prompt ?? current.text)
            result.append(LLMMessage(role: .user, parts: parts + [.text(blocks.compactMap { $0 }.joined(separator: "\n\n"))]))
        case .chat, .newQuestion:
            var background = [summary]
            if let solution = earlier.last(where: { $0.kind == .solution }) {
                background.append("【完整答案和解题过程】\n" + Tutor.clip(solution.text, 3000))
            }
            // 只带最近几轮对话，从学生的一句话开始
            var recent = Array(earlier.filter { $0.kind == .chat }.suffix(6)) + [current]
            while recent.first?.role == .assistant { recent.removeFirst() }
            for (i, m) in recent.enumerated() {
                var text = m.prompt ?? m.text
                let notes = background.compactMap { $0 }
                if i == 0 && !notes.isEmpty {
                    text = "【这道题之前的批改和讲解】（背景信息）\n" + notes.joined(separator: "\n\n") + "\n\n" + text
                }
                // 这次提问带的图片（圈出一步来问时的手写）
                let attached = m.id == current.id ? images(m) : []
                result.append(LLMMessage(role: m.role, parts: attached + [.text(text)]))
            }
        }
        return mergingSameRole(result)
    }

    /// 合并相邻的同角色消息，部分接口要求用户和助手交替出现
    private static func mergingSameRole(_ list: [LLMMessage]) -> [LLMMessage] {
        list.reduce(into: []) { out, m in
            if let last = out.last, last.role == m.role {
                out[out.count - 1].parts += m.parts
            } else {
                out.append(m)
            }
        }
    }

    // MARK: - 拆分题目

    func split(material: ImportedMaterial, requirement: String, title: String,
               progress: @escaping (Int, Int) -> Void) async throws -> QuestionSet {
        let client = try makeClient(for: .split)
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

            var parsed: (title: String?, items: [Tutor.SplitItem])
            let system = Tutor.splitSystem(requirement: requirement, hasImages: !chunk.images.isEmpty, multiPart: chunks.count > 1)
            do {
                let output = try await client.complete(system: system, messages: [LLMMessage(role: .user, parts: parts)])
                parsed = try Tutor.parseSplit(output)

                // 选择题漏了选项：把这几道题指出来，让模型对照原文重新输出
                let missing = parsed.items.filter { Tutor.looksLikeMissingOptions($0.content) }.map(\.label)
                if !missing.isEmpty {
                    progress(index + 1, chunks.count)
                    let followUp: [LLMMessage] = [
                        LLMMessage(role: .user, parts: parts),
                        LLMMessage(role: .assistant, parts: [.text(output)]),
                        LLMMessage(role: .user, parts: [.text(Tutor.missingOptionsFollowUp(labels: missing))])
                    ]
                    if let repairedText = try? await client.complete(system: system, messages: followUp),
                       let repaired = try? Tutor.parseSplit(repairedText) {
                        for fixed in repaired.items where Tutor.optionLetterCount(fixed.content) >= 2 {
                            let key = Tutor.labelKey(fixed.label)
                            guard let i = parsed.items.firstIndex(where: { Tutor.labelKey($0.label) == key }) else { continue }
                            parsed.items[i].content = fixed.content
                            if parsed.items[i].answer == nil { parsed.items[i].answer = fixed.answer }
                        }
                    }
                }
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

/// 需要先同意数据发送说明（会弹出说明页，不显示错误提示）
struct ConsentRequired: LocalizedError {
    var errorDescription: String? { "需要先同意数据发送说明才能使用 AI 功能。" }
}

// MARK: - 文件夹

extension AppStore {
    func folder(_ id: UUID?) -> Folder? {
        id.flatMap { id in folders.first { $0.id == id } }
    }

    /// 某个文件夹（nil 为最外层）直接包含的文件夹和题集
    func childFolders(of parent: UUID?) -> [Folder] {
        folders.filter { $0.parentID == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func sets(in folderID: UUID?) -> [QuestionSet] {
        // 指向已经不存在的文件夹的题集放到最外层，不会丢
        questionSets.filter { set in
            let actual = folder(set.folderID) == nil ? nil : set.folderID
            return actual == folderID
        }
    }

    /// 文件夹里（包括子文件夹）一共多少个题集
    func setCount(inTree id: UUID) -> Int {
        sets(in: id).count + childFolders(of: id).reduce(0) { $0 + setCount(inTree: $1.id) }
    }

    /// “数学 / 函数 / 二次函数”
    func folderPath(_ id: UUID?) -> String {
        var names: [String] = []
        var current = folder(id)
        var guardCount = 0
        while let f = current, guardCount < 50 {
            names.insert(f.name, at: 0)
            current = folder(f.parentID)
            guardCount += 1
        }
        return names.joined(separator: " / ")
    }

    /// 所有文件夹，按层级排好（用于“移到…”菜单）
    func folderTree() -> [(folder: Folder, depth: Int)] {
        func walk(_ parent: UUID?, _ depth: Int) -> [(Folder, Int)] {
            childFolders(of: parent).flatMap { [($0, depth)] + walk($0.id, depth + 1) }
        }
        return walk(nil, 0)
    }

    /// id 是不是 ancestor 本身或它的子孙（防止把文件夹移到自己里面）
    func isInside(_ id: UUID?, _ ancestor: UUID) -> Bool {
        var current = id
        var guardCount = 0
        while let c = current, guardCount < 50 {
            if c == ancestor { return true }
            current = folder(c)?.parentID
            guardCount += 1
        }
        return false
    }

    @discardableResult
    func addFolder(name: String, parent: UUID?) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = Folder(name: trimmed.isEmpty ? "新文件夹" : trimmed, parentID: parent)
        folders.append(new)
        // 在文件夹里新建时，把上一级展开
        if let parent, let i = folders.firstIndex(where: { $0.id == parent }) { folders[i].collapsed = false }
        return new.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = trimmed
    }

    func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        guard let i = folders.firstIndex(where: { $0.id == id }), folders[i].collapsed != collapsed else { return }
        folders[i].collapsed = collapsed
    }

    /// 删除文件夹：里面的题集和子文件夹移到上一级，不会删除任何题目
    func deleteFolder(_ id: UUID) {
        guard let f = folder(id) else { return }
        for i in folders.indices where folders[i].parentID == id { folders[i].parentID = f.parentID }
        for i in sets.indices where sets[i].folderID == id { sets[i].folderID = f.parentID }
        folders.removeAll { $0.id == id }
    }

    /// 上级文件夹不存在、或者互相嵌套成环的文件夹（只可能来自损坏的备份）放回最外层，里面的题集不会看不见
    func repairFolders() {
        let ids = Set(folders.map(\.id))
        for i in folders.indices {
            var seen: Set<UUID> = [folders[i].id]
            var current = folders[i].parentID
            while let c = current {
                if !ids.contains(c) || seen.contains(c) {
                    folders[i].parentID = nil
                    break
                }
                seen.insert(c)
                current = folder(c)?.parentID
            }
        }
    }

    func moveSet(_ setID: UUID, to folderID: UUID?) {
        guard let i = sets.firstIndex(where: { $0.id == setID }), sets[i].folderID != folderID else { return }
        sets[i].folderID = folderID
        if let folderID { setCollapsed(folderID, false) }
    }

    func moveFolder(_ id: UUID, to parent: UUID?) {
        // 不能移到自己或自己的子文件夹里
        if let parent, isInside(parent, id) { return }
        guard let i = folders.firstIndex(where: { $0.id == id }), folders[i].parentID != parent else { return }
        folders[i].parentID = parent
        if let parent { setCollapsed(parent, false) }
    }
}
