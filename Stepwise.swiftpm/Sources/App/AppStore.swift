import Foundation
import SwiftUI

/// 正在进行中的模型请求（每道题最多一个）
struct PendingReply: Equatable {
    var kind: MessageKind
    var text: String = ""
    var startedAt = Date()
    /// 圈出一步来提问：回答写在页边，不写在题目下面
    var inMargin = false
    /// 等待时显示的文字；nil 时按种类显示
    var label: String?
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
    /// 选了题集（或错题本）、笔记就不再显示白板
    @Published var selectedSetID: UUID? { didSet { if selectedSetID != nil, selectedBoardID != nil { selectedBoardID = nil } } }
    @Published var selectedQuestionID: UUID?
    /// 错题复习结果提示
    @Published var reviewOutcomes: [UUID: ReviewOutcome] = [:]

    // MARK: 笔记
    /// 笔记模式的文档，单独存在 notes.json
    @Published var notes: [NoteDoc] = [] { didSet { scheduleNotesSave() } }
    @Published var selectedNoteID: UUID? { didSet { if selectedNoteID != nil, selectedBoardID != nil { selectedBoardID = nil } } }

    // MARK: 白板
    /// AI 白板，单独存在 boards.json
    @Published var boards: [Whiteboard] = [] { didSet { scheduleBoardsSave() } }
    @Published var selectedBoardID: UUID?
    /// 正在回复的便签（白板 id → 便签 id）；每块白板同时只问一处
    @Published var boardJobs: [UUID: UUID] = [:]
    var boardTasks: [UUID: Task<Void, Never>] = [:]
    /// 左边便签列表点了哪一张，白板就滚到哪里
    @Published var boardJump: UUID?
    private var boardsSaveTask: Task<Void, Never>?
    /// 正在生成或回答的笔记（每篇笔记同时只有一个）
    @Published var noteJobs: [UUID: NoteJob] = [:]
    /// 左侧笔记目录点了哪一块，笔记就滚到哪一块
    @Published var noteJump: UUID?
    var noteTasks: [UUID: Task<Void, Never>] = [:]
    /// 做题卡住时找到的相关笔记（题目 id → 引导）；正在找的任务
    @Published var noteGuides: [UUID: NoteGuide] = [:]
    var noteGuideTasks: [UUID: Task<Void, Never>] = [:]
    /// 正在看的引导：笔记页上临时荧光笔标出重点，页边有“详细记录”
    @Published var activeNoteGuide: NoteGuide?
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
    @Published var providers: [ProviderConfig] = [] { didSet { saveProviders(); saveSettingsFile() } }
    @Published var activeProviderID: String = "anthropic" {
        didSet { UserDefaults.standard.set(activeProviderID, forKey: "activeProvider"); saveSettingsFile() }
    }

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
        didSet { UserDefaults.standard.set(quickGrading, forKey: "quickGrading"); saveSettingsFile() }
    }
    /// 单独的批改与提示模型；为 nil 时跟随当前模型
    @Published var gradingProviderID: String? = UserDefaults.standard.string(forKey: "gradingProvider") {
        didSet { UserDefaults.standard.set(gradingProviderID, forKey: "gradingProvider"); saveSettingsFile() }
    }
    @Published var gradingModel: String = UserDefaults.standard.string(forKey: "gradingModel") ?? "" {
        didSet { UserDefaults.standard.set(gradingModel, forKey: "gradingModel"); saveSettingsFile() }
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
        didSet { UserDefaults.standard.set(questionProviderID, forKey: "questionProvider"); saveSettingsFile() }
    }
    @Published var questionModel: String = UserDefaults.standard.string(forKey: "questionModel") ?? "" {
        didSet { UserDefaults.standard.set(questionModel, forKey: "questionModel"); saveSettingsFile() }
    }

    /// 单独的整理笔记模型（导入资料生成笔记时用，一般选上下文长、能力强的）；为 nil 时跟随当前模型
    @Published var noteProviderID: String? = UserDefaults.standard.string(forKey: "noteProvider") {
        didSet { UserDefaults.standard.set(noteProviderID, forKey: "noteProvider"); saveSettingsFile() }
    }
    @Published var noteModel: String = UserDefaults.standard.string(forKey: "noteModel") ?? "" {
        didSet { UserDefaults.standard.set(noteModel, forKey: "noteModel"); saveSettingsFile() }
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
    /// 模型设置文件（settings.json）停一会儿再写，填 API Key 时不用每个字都写一次
    private var settingsSaveTask: Task<Void, Never>?
    /// 正在套用设置文件：这期间的赋值不写回文件
    private var applyingSettings = false
    /// 储存位置里的 settings.json 存在但读不出来：不写，免得把里面的 API Key 覆盖掉
    private var settingsFileBlocked = false
    private var replyTasks: [UUID: Task<Void, Never>] = [:]

    /// 数据文件都在数据根目录下（默认 App 内的 Documents，也可以在设置里换成用户选的文件夹）
    nonisolated private static var libraryURL: URL { DataLocation.url(DataLocation.libraryFile) }
    nonisolated private static var foldersURL: URL { DataLocation.url(DataLocation.foldersFile) }
    nonisolated private static var notesURL: URL { DataLocation.url(DataLocation.notesFile) }
    nonisolated private static var boardsURL: URL { DataLocation.url(DataLocation.boardsFile) }

    /// 储存位置里有数据文件但读不出来（例如 iCloud 还没下载完）：这时不写盘，免得把原来的数据覆盖成空的
    @Published private(set) var writesBlocked = false
    /// 正在从磁盘读数据：这期间的赋值不触发保存
    private var loading = false

    /// 启动时的数据还在后台读：读完之前界面只显示空白页，也不保存任何东西
    @Published private(set) var isLoaded = false

    init() {
        // 题库、笔记和储存文件夹里的设置都在后台读（iCloud 文件可能要等下载），界面不用等
        loading = true
        settingsFileBlocked = true
        applyingSettings = true
        loadProviders()
        activeProviderID = UserDefaults.standard.string(forKey: "activeProvider") ?? "anthropic"
        applyingSettings = false
        // 任何设置变了（时钟、笔、学习时间……）都写一份进储存文件夹
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.saveSettingsFile() }
        }
        Task { await loadAtLaunch() }
    }

    private func loadAtLaunch() async {
        let snapshot = await Task.detached(priority: .userInitiated) {
            DataLocation.bootstrap()
            return AppStore.readDisk()
        }.value
        apply(snapshot)
        // 用了储存文件夹：以文件夹里的 API Key 和设置为准（重装 App 后也能恢复）
        applyingSettings = true
        let hasSettingsFile = applySettings(snapshot.settings)
        applyingSettings = false
        if DataLocation.isCustom && !hasSettingsFile { writeSettingsFile() }
        selectRecent()
        isLoaded = true
        if let problem = DataLocation.launchProblem { errorMessage = problem }
    }

    /// 打开 App 时直接回到最近的题集，停在第一道还没完成的题
    private func selectRecent() {
        if let recent = questionSets.first {
            selectedSetID = recent.id
            selectedQuestionID = recent.questions.first(where: { !$0.status.isDone })?.id ?? recent.questions.first?.id
        }
    }

    /// 从磁盘读出来、还没交给界面的数据
    private struct DiskSnapshot {
        var sets: [QuestionSet] = []
        var notes: [NoteDoc] = []
        var boards: [Whiteboard] = []
        var folders: [Folder] = []
        /// 存在但读不出来的文件
        var unreadable: [String] = []
        var settings: SettingsRead = .missing
    }

    private enum SettingsRead {
        case missing, unreadable
        case file(SettingsFile)
    }

    /// 在后台读当前储存位置的题库、笔记、文件夹和 settings.json（启动时、换了储存位置之后）
    nonisolated private static func readDisk() -> DiskSnapshot {
        var snapshot = DiskSnapshot()
        func load(_ url: URL) -> Data? {
            guard DataLocation.exists(url) else { return nil }
            do {
                return try DataLocation.read(url)
            } catch {
                snapshot.unreadable.append(url.lastPathComponent)
                return nil
            }
        }
        if let data = load(libraryURL) {
            if let decoded = try? JSONDecoder().decode([QuestionSet].self, from: data) {
                snapshot.sets = decoded.map(cleaned)
            } else {
                // 读不出来时先把原文件备份，绝不能让之后的保存把题库覆盖掉
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let backup = libraryURL.deletingLastPathComponent().appendingPathComponent("library-backup-\(stamp).json")
                try? DataLocation.write(data, to: backup)
            }
        }
        if let data = load(notesURL), let decoded = try? JSONDecoder().decode([NoteDoc].self, from: data) {
            snapshot.notes = decoded
        }
        if let data = load(boardsURL), let decoded = try? JSONDecoder().decode([Whiteboard].self, from: data) {
            snapshot.boards = decoded
        }
        if let data = load(foldersURL), let decoded = try? JSONDecoder().decode([Folder].self, from: data) {
            snapshot.folders = decoded
        }
        if DataLocation.isCustom {
            let url = DataLocation.url(DataLocation.settingsFile)
            if DataLocation.exists(url) {
                if let data = try? DataLocation.read(url), let file = try? JSONDecoder().decode(SettingsFile.self, from: data) {
                    snapshot.settings = .file(file)
                } else {
                    snapshot.settings = .unreadable
                }
            }
        }
        return snapshot
    }

    /// 把读好的数据交给界面
    private func apply(_ snapshot: DiskSnapshot) {
        loading = true
        defer { loading = false }
        writesBlocked = !snapshot.unreadable.isEmpty
        if writesBlocked {
            errorMessage = String(localized: "读不到储存位置里的 \(snapshot.unreadable.joined(separator: L("、")))（可能还没从 iCloud 下载完）。为了不覆盖原来的数据，现在的改动不会保存。请确认网络和 iCloud 正常后重新打开 App。")
        }
        sets = snapshot.sets
        notes = snapshot.notes
        boards = snapshot.boards
        folders = snapshot.folders
        repairFolders()
    }

    // MARK: - 持久化

    /// 修正旧版本导入的数据：统一题号、还原转义字符、去掉题干里重复的题号行（可重复执行）
    nonisolated private static func cleaned(_ set: QuestionSet) -> QuestionSet {
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
        // 数据还没读完（启动时、换储存位置时）：这时保存会把空的或旧的数据写进去
        guard isLoaded, !loading else { return }
        writeSettingsFile()
        saveTask?.cancel()
        notesSaveTask?.cancel()
        boardsSaveTask?.cancel()
        guard !writesBlocked else { return }
        if let data = try? JSONEncoder().encode(sets) {
            try? DataLocation.write(data, to: Self.libraryURL)
        }
        if let data = try? JSONEncoder().encode(notes) {
            try? DataLocation.write(data, to: Self.notesURL)
        }
        if let data = try? JSONEncoder().encode(boards) {
            try? DataLocation.write(data, to: Self.boardsURL)
        }
    }

    /// 便签在流式回复、拖动时变化很频繁，停一会儿再写盘
    private func scheduleBoardsSave() {
        guard !loading, !writesBlocked else { return }
        boardsSaveTask?.cancel()
        let snapshot = boards
        let url = Self.boardsURL
        boardsSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? DataLocation.write(data, to: url)
        }
    }

    /// 笔记在流式生成时变化很频繁，停一会儿再写盘
    private func scheduleNotesSave() {
        guard !loading, !writesBlocked else { return }
        notesSaveTask?.cancel()
        let snapshot = notes
        // 地址在这里先定下来：等待期间换了储存位置，也不会写到新位置去
        let url = Self.notesURL
        notesSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? DataLocation.write(data, to: url)
        }
    }

    private func scheduleSave() {
        guard !loading, !writesBlocked else { return }
        saveTask?.cancel()
        let snapshot = sets
        let url = Self.libraryURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? DataLocation.write(data, to: url)
        }
    }

    private func saveFolders() {
        guard !loading, !writesBlocked else { return }
        if let data = try? JSONEncoder().encode(folders) {
            try? DataLocation.write(data, to: Self.foldersURL)
        }
    }

    // MARK: - 储存位置

    /// AI 正在回复、生成笔记或在后台求解（这时不能换储存位置）
    var hasBackgroundWork: Bool { !pending.isEmpty || !noteJobs.isEmpty || !presolving.isEmpty || !boardJobs.isEmpty }

    enum LocationChange {
        /// 目标是空的：把当前数据复制过去
        case copyCurrent
        /// 目标里已经有 Stepwise 数据：改用那份
        case useExisting
    }

    /// 换储存位置；folder 为 nil 表示改回 App 内默认位置。
    /// 两种方式都只复制或改读，不删除、不覆盖原来位置的数据，改回去就能看到。
    func changeDataLocation(to folder: URL?, mode: LocationChange) async throws {
        guard !hasBackgroundWork else {
            throw LocationError(message: L("AI 正在回复或生成笔记，等它完成后再换储存位置。"))
        }
        let source = DataLocation.root
        let target = folder ?? DataLocation.defaultRoot
        guard !DataLocation.isSame(source, target) else { return }
        // 先把最近的改动写进原来的位置
        saveNow()
        if mode == .copyCurrent {
            guard !writesBlocked else {
                throw LocationError(message: L("当前位置的数据没有完整读出来，不能复制。请先确认原来的数据能正常打开。"))
            }
            try await Task.detached(priority: .userInitiated) {
                try DataLocation.copyData(from: source, to: target)
            }.value
        }
        // 从换位置到新数据读完，什么都不写，免得把旧数据写进新位置
        loading = true
        do {
            if let folder {
                try DataLocation.adopt(folder)
            } else {
                DataLocation.resetToDefault()
            }
        } catch {
            loading = false
            throw error
        }
        ImageStore.clearCache()
        let snapshot = await Task.detached(priority: .userInitiated) { AppStore.readDisk() }.value
        apply(snapshot)
        // API Key 和设置：改用已有数据时套用文件夹里的；复制过去（或文件夹里还没有）时写一份进去
        if folder != nil {
            if mode == .copyCurrent || !applySettings(snapshot.settings) { writeSettingsFile() }
        } else {
            settingsFileBlocked = false
        }
        // 换了一份数据：原来选中的题集、笔记可能已经不在了
        selectedNoteID = nil
        selectedSetID = nil
        selectedQuestionID = nil
        reviewOutcomes = [:]
        noteGuides = [:]
        activeNoteGuide = nil
        selectRecent()
    }

    private func loadProviders() {
        var saved: [ProviderConfig] = []
        if let data = UserDefaults.standard.data(forKey: "providers"),
           let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
            saved = decoded
        }
        providers = Self.mergedWithPresets(saved)
    }

    /// 用最新的预设补齐（升级后新增的服务商、新增的预设模型）
    private static func mergedWithPresets(_ saved: [ProviderConfig]) -> [ProviderConfig] {
        var merged: [ProviderConfig] = ProviderCatalog.presets.map { preset in
            guard var old = saved.first(where: { $0.id == preset.id }) else { return preset }
            old.presetModels = preset.presetModels
            // 名称和说明跟着预设（界面语言换了，名称跟着换）
            old.name = preset.name
            old.note = preset.note
            return old
        }
        merged += saved.filter { $0.isCustom }
        return merged
    }

    // MARK: - 模型设置文件

    /// 选了储存文件夹时，把服务商（含选的模型、常用模型）、API Key、各用途的模型写进文件夹里的 settings.json
    func saveSettingsFile() {
        guard DataLocation.isCustom, !loading, !applyingSettings, !settingsFileBlocked else { return }
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.writeSettingsFile()
        }
    }

    /// 立即写 settings.json（换储存位置、退到后台时）
    func writeSettingsFile() {
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        guard DataLocation.isCustom, !loading, !settingsFileBlocked else { return }
        var keys: [String: String] = [:]
        for p in providers where p.hasKey { keys[p.id] = p.apiKey }
        let file = SettingsFile(providers: providers, apiKeys: keys, activeProviderID: activeProviderID,
                                gradingProviderID: gradingProviderID, gradingModel: gradingModel,
                                questionProviderID: questionProviderID, questionModel: questionModel,
                                noteProviderID: noteProviderID, noteModel: noteModel, quickGrading: quickGrading,
                                preferences: Self.preferenceSnapshot())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(file) {
            try? DataLocation.write(data, to: DataLocation.url(DataLocation.settingsFile))
        }
    }

    /// 套用储存文件夹里的 settings.json（已经在后台读好）；没有这个文件时返回 false
    @discardableResult
    private func applySettings(_ read: SettingsRead) -> Bool {
        settingsFileBlocked = false
        guard DataLocation.isCustom else { return false }
        let file: SettingsFile
        switch read {
        case .missing: return false
        case .unreadable:
            // 读不出来就不写，免得把里面的 API Key 覆盖掉
            settingsFileBlocked = true
            return true
        case .file(let f): file = f
        }
        let wasApplying = applyingSettings
        applyingSettings = true
        defer { applyingSettings = wasApplying }
        // 本机有、文件里没有的自定义服务商也留着
        let localCustom = providers.filter { p in p.isCustom && !file.providers.contains { $0.id == p.id } }
        providers = Self.mergedWithPresets(file.providers + localCustom)
        // 文件里有 Key 的以文件为准；文件里没有的保留本机钥匙串里的
        for (id, key) in file.apiKeys where !key.isEmpty && Keychain.get(id) != key {
            Keychain.set(key, for: id)
        }
        // 触发界面刷新（Key 存在钥匙串里，providers 本身没变时界面不知道）
        objectWillChange.send()
        activeProviderID = file.activeProviderID
        gradingProviderID = file.gradingProviderID
        gradingModel = file.gradingModel
        questionProviderID = file.questionProviderID
        questionModel = file.questionModel
        noteProviderID = file.noteProviderID
        noteModel = file.noteModel
        if let quick = file.quickGrading { quickGrading = quick }
        if let data = file.preferences { restorePreferences(data) }
        return true
    }

    // MARK: - 其他设置和学习时间

    /// 上面单独存过的模型设置、储存位置本身不放进 preferences
    private static let excludedPreferenceKeys: Set<String> = [
        DataLocation.bookmarkKey, "providers", "activeProvider", "gradingProvider", "gradingModel",
        "questionProvider", "questionModel", "noteProvider", "noteModel", "quickGrading"
    ]

    /// App 自己的设置键都是小写字母开头；系统框架写的（NS…、Apple…、com.apple…）不要
    private static func isAppPreferenceKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return !key.hasPrefix("com.") && !excludedPreferenceKeys.contains(key)
    }

    /// 本 App 的 UserDefaults（时钟、笔、快捷操作、学习时间和周报……）打包成二进制 plist
    private static func preferenceSnapshot() -> Data? {
        guard let id = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: id) else { return nil }
        let prefs = domain.filter { isAppPreferenceKey($0.key) }
        return try? PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0)
    }

    /// 把文件夹里的设置写回 UserDefaults。学习时间按天取较大的值、周报合并，本机多出来的不丢
    private func restorePreferences(_ data: Data) {
        guard let prefs = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        let d = UserDefaults.standard
        for (key, value) in prefs where Self.isAppPreferenceKey(key) {
            switch key {
            case "studyDaily":
                var merged = d.dictionary(forKey: key) as? [String: Double] ?? [:]
                merged.merge(value as? [String: Double] ?? [:]) { max($0, $1) }
                d.set(merged, forKey: key)
            case "studyWeeklyReports":
                var merged = d.dictionary(forKey: key) as? [String: String] ?? [:]
                merged.merge(value as? [String: String] ?? [:]) { $1 }
                d.set(merged, forKey: key)
            case "tokenUsage":
                // 用量按天、按模型取请求次数多的那份，本机多出来的不丢
                typealias Days = [String: [String: UsageTotals]]
                let local = d.data(forKey: key).flatMap { try? JSONDecoder().decode(Days.self, from: $0) } ?? [:]
                let saved = (value as? Data).flatMap { try? JSONDecoder().decode(Days.self, from: $0) } ?? [:]
                let merged = local.merging(saved) { mine, theirs in
                    mine.merging(theirs) { $0.requests >= $1.requests ? $0 : $1 }
                }
                if let data = try? JSONEncoder().encode(merged) { d.set(data, forKey: key) }
            default:
                d.set(value, forKey: key)
            }
        }
        // 已经读进内存的设置跟着更新（时钟用 @AppStorage，会自己更新）
        aiConsent = d.object(forKey: "aiConsent") as? Bool ?? aiConsent
        showTiming = d.object(forKey: "showTiming") as? Bool ?? showTiming
        keyboardAnswer = d.bool(forKey: "keyboardAnswer")
        presolveAnswers = d.object(forKey: "presolveAnswers") as? Bool ?? presolveAnswers
        if let saved = d.data(forKey: "followUps"), let list = try? JSONDecoder().decode([FollowUpAction].self, from: saved) {
            followUps = list
        }
        UsageLog.shared.load()
        NotificationCenter.default.post(name: .stepwisePreferencesRestored, object: nil)
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
        guard let config = activeProvider else { throw LLMError(message: L("请先在设置里选择一个模型服务商。")) }
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
        noteGuides[qID] = nil
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
        noteGuides[qID] = nil
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
        var prompt = Tutor.pick("【我的作答】\n", "[My answer]\n") + (answer.isEmpty ? Tutor.pick("（见手写图片）", "(see the handwriting image)") : answer)
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
            // 做错了：看看同一个文件夹的笔记里有没有相关的知识点（在 mutate 外面，不能边改题库边读）
            if correct { self?.noteGuides[qID] = nil } else { self?.findRelatedNote(setID, qID, wrong: true) }
        }
    }

    /// note：学生补充的文字说明（卡在哪里），可以为空
    func requestHint(_ setID: UUID, _ qID: UUID, note: String? = nil) {
        guard let q = question(setID, qID) else { return }
        // 不会做：先看看笔记里有没有相关的知识点
        findRelatedNote(setID, qID, wrong: false)
        let level = q.hintCount + 1
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = ChatMessage(role: .user, kind: .hintRequest, text: String(localized: "需要进一步提示（第 \(level) 次）"),
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

    /// 点“卡了”：带上现在的手写和打的字，让 AI 找出卡在哪一步并针对那一步点拨。
    /// 回复记成一条提示（hintLevel 为 0），不占用“提示”按钮的档次
    func reportStuck(_ setID: UUID, _ qID: UUID, answer: String, handwriting: Data?) {
        // 不会做：先看看笔记里有没有相关的知识点
        findRelatedNote(setID, qID, wrong: false)
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageIDs = handwriting.map { [ImageStore.save($0)] } ?? []
        let message = ChatMessage(role: .user, kind: .hintRequest, text: L("卡了"),
                                  prompt: Tutor.stuckInstruction(hasImage: !imageIDs.isEmpty, typed: answer),
                                  imageIDs: imageIDs)
        run(setID, qID, userMessage: message, replyKind: .hint, purpose: .hint) { [weak self] full in
            self?.mutate(setID, qID) { q in
                var hint = ChatMessage(role: .assistant, kind: .hint, text: full)
                hint.hintLevel = ChatMessage.stuckHintLevel
                q.messages.append(hint)
                _ = self?.countReviewRound(&q)
            }
        }
        pending[qID]?.label = L("正在看你卡在哪…")
    }

    func requestSolution(_ setID: UUID, _ qID: UUID) {
        let message = ChatMessage(role: .user, kind: .solutionRequest, text: L("给出完整答案"), prompt: Tutor.solutionInstruction)
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
                q.messages.append(ChatMessage(role: .assistant, kind: .chat, text: display.isEmpty && !created.isEmpty ? L("出了一道新题：") : display,
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
        let existing = sets[si].questions.filter { GeneratedLabel.isGenerated($0.label, from: baseLabel) }.count
        var insertAt = qi + 1
        // 跳过之前已插入的变式题，保持顺序
        while insertAt < sets[si].questions.count && GeneratedLabel.isGenerated(sets[si].questions[insertAt].label, from: baseLabel) {
            insertAt += 1
        }
        var ids: [UUID] = []
        for (k, item) in items.enumerated() {
            var q = Question(label: baseLabel + GeneratedLabel.suffix + "\(existing + k + 1)", content: item.content,
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
                    throw LLMError(message: L("模型没有返回内容，请重试。"))
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
        guard q.isGenerated, let base = GeneratedLabel.base(of: q.label) else { return nil }
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
            result.append(LLMMessage(role: .user, parts: questionImages + [.text(Tutor.pick("（以上是题目原图，题目中的图形、表格以图片为准）", "(Above are the original images of the question; for figures and tables, go by the images.)"))]))
        }

        switch purpose {
        case .check:
            let blocks = [summary, summary == nil ? nil : Tutor.regradeNote, current.prompt ?? current.text]
            result.append(LLMMessage(role: .user, parts: images(current) + [.text(blocks.compactMap { $0 }.joined(separator: "\n\n"))]))
        case .hint, .solution, .presolve, .split, .note:
            var blocks = [summary]
            var parts: [LLMContent] = []
            if purpose == .hint, !current.imageIDs.isEmpty {
                // 点“卡了”：带的是现在的手写，作答说明已经写在这次的请求里
                parts = images(current)
            } else if purpose == .hint, let last = earlier.last(where: { $0.kind == .submission }) {
                parts = images(last)
                blocks.append(Tutor.pick("【我最近一次的作答】\n", "[My latest answer]\n")
                              + (last.text.isEmpty ? Tutor.pick("（见手写图片）", "(see the handwriting image)") : Tutor.clip(last.text, 1500)))
            }
            blocks.append(current.prompt ?? current.text)
            result.append(LLMMessage(role: .user, parts: parts + [.text(blocks.compactMap { $0 }.joined(separator: "\n\n"))]))
        case .chat, .newQuestion:
            var background = [summary]
            if let solution = earlier.last(where: { $0.kind == .solution }) {
                background.append(Tutor.pick("【完整答案和解题过程】\n", "[Full answer and worked solution]\n") + Tutor.clip(solution.text, 3000))
            }
            // 只带最近几轮对话，从学生的一句话开始
            var recent = Array(earlier.filter { $0.kind == .chat }.suffix(6)) + [current]
            while recent.first?.role == .assistant { recent.removeFirst() }
            for (i, m) in recent.enumerated() {
                var text = m.prompt ?? m.text
                let notes = background.compactMap { $0 }
                if i == 0 && !notes.isEmpty {
                    text = Tutor.pick("【这道题之前的批改和讲解】（背景信息）\n", "[Earlier checking and explanations for this question] (background)\n")
                        + notes.joined(separator: "\n\n") + "\n\n" + text
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
               progress: @escaping (GenerationProgress) -> Void) async throws -> QuestionSet {
        let client = try makeClient(for: .split)
        let chunks = Importer.chunks(for: material)
        guard !chunks.isEmpty else { throw LLMError(message: L("没有可以拆分的内容。")) }

        // 几部分同时拆（最多 3 部分），比一部分一部分等快得多；拆完按原来的顺序合并
        let tracker = SplitTracker(chunks: chunks, report: progress)
        tracker.report(force: true)
        typealias Parsed = (title: String?, items: [Tutor.SplitItem])
        var results = [Result<Parsed, Error>?](repeating: nil, count: chunks.count)
        let makeTask = { (i: Int) -> @Sendable () async throws -> (Int, Result<Parsed, Error>) in
            { [self] in
                do {
                    return (i, .success(try await self.splitChunk(i, chunks[i], count: chunks.count, client: client,
                                                                  requirement: requirement, tracker: tracker)))
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    return (i, .failure(error))
                }
            }
        }
        try await withThrowingTaskGroup(of: (Int, Result<Parsed, Error>).self) { group in
            var next = 0
            while next < min(3, chunks.count) {
                group.addTask(operation: makeTask(next))
                next += 1
            }
            while let (i, result) = try await group.next() {
                results[i] = result
                if next < chunks.count {
                    group.addTask(operation: makeTask(next))
                    next += 1
                }
            }
        }
        // 同时请求时偶尔会被限流：失败的部分单独再试一次，还是失败就算这部分拆不出来
        for i in results.indices {
            guard case .failure = results[i] else { continue }
            try Task.checkCancellation()
            if let retried = try? await splitChunk(i, chunks[i], count: chunks.count, client: client,
                                                   requirement: requirement, tracker: tracker) {
                results[i] = .success(retried)
            } else {
                tracker.finish(i)
            }
        }
        tracker.report(force: true)

        var questions: [Question] = []
        var keys: [String] = []          // 与 questions 一一对应的题号，用于合并重叠页产生的重复题
        var suggestedTitle: String?
        var failedParts: [Int] = []
        var firstError: Error?

        for (index, chunk) in chunks.enumerated() {
            let parsed: Parsed
            switch results[index] {
            case .success(let value)?:
                parsed = value
            case .failure(let error)?:
                // 某一部分失败（比如只有封面）不影响其他部分
                failedParts.append(index + 1)
                if firstError == nil { firstError = error }
                continue
            case nil:
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
            throw firstError ?? LLMError(message: L("没有识别出题目。可以调整拆分要求，或换一个能力更强的模型再试。"))
        }
        if !failedParts.isEmpty {
            errorMessage = String(localized: "共 \(chunks.count) 部分，其中第 \(failedParts.map(String.init).joined(separator: L("、"))) 部分没有识别成功，可能漏了题目。可以检查一下题目列表，必要时重新导入。")
        }

        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (suggestedTitle ?? material.name) : title
        return QuestionSet(title: finalTitle, requirement: requirement, questions: questions)
    }
}

extension AppStore {
    /// 拆一部分：边收边数已经写出来的题，写完检查选择题有没有漏选项
    fileprivate func splitChunk(_ index: Int, _ chunk: SplitChunk, count: Int, client: LLMClient, requirement: String,
                                tracker: SplitTracker) async throws -> (title: String?, items: [Tutor.SplitItem]) {
        var parts: [LLMContent] = chunk.images.map(LLMContent.image)
        var text = count > 1
            ? Tutor.pick("以下是题目文件的第 \(index + 1)/\(count) 部分（与前后部分各有一页重叠）。",
                         "Below is part \(index + 1) of \(count) of the question file (it overlaps the neighboring parts by one page).")
            : Tutor.pick("以下是题目文件的内容。", "Below is the content of the question file.")
        text += chunk.text.isEmpty ? Tutor.pick("内容见上面的图片。", "The content is in the images above.") : "\n\n" + chunk.text
        parts.append(.text(text))
        let system = Tutor.splitSystem(requirement: requirement, hasImages: !chunk.images.isEmpty, multiPart: count > 1)

        var output = ""
        for try await piece in client.stream(system: system, messages: [LLMMessage(role: .user, parts: parts)]) {
            output += piece
            tracker.update(index, output: output)
        }
        try Task.checkCancellation()
        var parsed = try Tutor.parseSplit(output)

        // 选择题漏了选项：把这几道题指出来，让模型对照原文重新输出
        let missing = parsed.items.filter { Tutor.looksLikeMissingOptions($0.content) }.map(\.label)
        if !missing.isEmpty {
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
        tracker.finish(index)
        return parsed
    }
}

/// 拆题的进度：每部分写了多少、已经写出哪些题号（重叠页里的同一道题只算一次）
@MainActor
final class SplitTracker {
    private var estimator: ChunkEstimator
    private var labels: [Set<String>]
    private let report: (GenerationProgress) -> Void
    private let parts: Int
    private let started = Date()
    private var lastReport = Date.distantPast

    init(chunks: [SplitChunk], report: @escaping (GenerationProgress) -> Void) {
        // 拆题基本是照抄原文：输出大约和原文一样长，一页图片大约 1300 字
        estimator = ChunkEstimator(chunks, ratio: 1.15, perImage: 1300, minimum: 800)
        labels = Array(repeating: [], count: chunks.count)
        parts = chunks.count
        self.report = report
    }

    func update(_ i: Int, output: String) {
        estimator.update(i, written: output.count)
        guard Date().timeIntervalSince(lastReport) > 0.25 else { return }
        labels[i] = Self.labels(in: output)
        report(force: false)
    }

    func finish(_ i: Int) {
        estimator.finish(i)
        report(force: true)
    }

    func report(force: Bool) {
        guard force || Date().timeIntervalSince(lastReport) > 0.25 else { return }
        lastReport = Date()
        let found = labels.reduce(into: Set<String>()) { $0.formUnion($1) }.count
        report(GenerationProgress(fraction: estimator.fraction, parts: parts, doneParts: estimator.doneCount,
                                  found: found, startedAt: started))
    }

    /// 已经写完的题（有了 </question>）的题号
    private static func labels(in output: String) -> Set<String> {
        let pattern = #"<question\s+label\s*=\s*"([^"]*)"[\s\S]*?</question>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = output as NSString
        return Set(regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
            .map { Tutor.labelKey(ns.substring(with: $0.range(at: 1))) })
    }
}

/// 需要先同意数据发送说明（会弹出说明页，不显示错误提示）
struct ConsentRequired: LocalizedError {
    var errorDescription: String? { L("需要先同意数据发送说明才能使用 AI 功能。") }
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
        let new = Folder(name: trimmed.isEmpty ? L("新文件夹") : trimmed, parentID: parent)
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
