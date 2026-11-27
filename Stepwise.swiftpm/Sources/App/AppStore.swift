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

/// AI 请求的用途，决定用哪个模型、是否用快速模式
enum RequestPurpose {
    case check, hint, solution, chat, newQuestion, presolve, split
    /// 导入资料生成笔记：可以单独选一个整理长资料能力强的模型
    case note

    /// 批改和提示：可以用单独的批改模型和快速模式
    var isGrading: Bool { self == .check || self == .hint }
}

/// AI 正在流式写出的一段文字。不放在 AppStore 的 @Published 里：
/// 那样每收到一段字，整个 App 所有看着 store 的页面（左栏、目录、整本题、整篇笔记）都要重算一遍，
/// 输出的时候上下翻页就一顿一顿的。单独一个对象，只有显示这段字的那一小块跟着刷新
@MainActor
final class LiveText: ObservableObject {
    @Published var text = ""
}

/// 读出正在写的文字交给 content；只有这一小块跟着刷新
struct LiveTextReader<Content: View>: View {
    @ObservedObject var live: LiveText
    @ViewBuilder let content: (String) -> Content

    var body: some View { content(live.text) }
}

@MainActor
final class AppStore: ObservableObject {
    /// 正在写的文字（题目 id、笔记 id、回答块 id、批注 id、便签 id → 文字），见 LiveText
    private var liveTexts: [UUID: LiveText] = [:]

    /// 某个回复正在写的文字；没有就建一个空的（不会让页面刷新）
    func live(_ id: UUID) -> LiveText {
        if let existing = liveTexts[id] { return existing }
        let created = LiveText()
        liveTexts[id] = created
        return created
    }

    /// 写完了：最终的文字已经存进题目 / 笔记，不再需要
    func endLive(_ id: UUID) {
        liveTexts[id] = nil
    }

    // MARK: 题库
    @Published var sets: [QuestionSet] = [] { didSet { scheduleSave() } }
    /// 左侧的分级文件夹，单独存在 folders.json
    @Published var folders: [Folder] = [] { didSet { saveFolders() } }
    /// 左栏里点中的文件夹：没有打开笔记、白板、题集时，右边一格一格排出它里面的东西（nil 为最外层）
    @Published var selectedFolderID: UUID?
    /// 在文件夹菜单里点了“导入题目到这里”“导入资料生成笔记到这里”：导入页默认放到这个文件夹
    var importFolderHint: UUID?
    /// 选了题集（或收藏）、笔记就不再显示白板
    @Published var selectedSetID: UUID? { didSet { if selectedSetID != nil, selectedBoardID != nil { selectedBoardID = nil }; rememberOpened() } }
    @Published var selectedQuestionID: UUID? {
        didSet {
            rememberOpened()
            if openSolutionQuestion != selectedQuestionID { openSolutionQuestion = nil }
        }
    }
    /// 现在展开着完整答案的那道题。刚看完答案、或点了“再看答案”时设上；
    /// 离开这道题（翻到别的题、换题集）就清掉，回来时答案先盖住，免得重做时照着抄
    @Published var openSolutionQuestion: UUID?

    // MARK: 笔记
    /// 笔记模式的文档，单独存在 notes.json
    @Published var notes: [NoteDoc] = [] { didSet { scheduleNotesSave() } }
    @Published var selectedNoteID: UUID? { didSet { if selectedNoteID != nil, selectedBoardID != nil { selectedBoardID = nil }; rememberOpened() } }

    // MARK: 白板
    /// AI 白板，单独存在 boards.json
    @Published var boards: [Whiteboard] = [] { didSet { scheduleBoardsSave() } }
    @Published var selectedBoardID: UUID? { didSet { rememberOpened() } }
    /// 正在回复的便签（白板 id → 便签 id）；每块白板同时只问一处
    @Published var boardJobs: [UUID: UUID] = [:]
    var boardTasks: [UUID: Task<Void, Never>] = [:]
    private var boardsSaveTask: Task<Void, Never>?
    /// 正在生成或回答的笔记（每篇笔记同时只有一个）
    @Published var noteJobs: [UUID: NoteJob] = [:]
    /// 左侧笔记目录点了哪一块，笔记就滚到哪一块
    @Published var noteJump: UUID?
    var noteTasks: [UUID: Task<Void, Never>] = [:]
    /// 做题卡住时找到的相关笔记（题目 id → 引导）；正在找的任务
    @Published var noteGuides: [UUID: NoteGuide] = [:]
    var noteGuideTasks: [UUID: Task<Void, Never>] = [:]
    /// 这道题找过、没找到（或者关掉了引导）时笔记的样子：笔记没变就不再花钱问一遍
    var noteGuideChecked: [UUID: Int] = [:]
    /// 正在看的引导：笔记页上临时荧光笔标出重点，页边有“详细记录”
    @Published var activeNoteGuide: NoteGuide?
    private var notesSaveTask: Task<Void, Never>?

    /// 左侧“收藏”这一项的固定 id
    static let mistakeBookID = UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!

    var isMistakeBook: Bool { selectedSetID == Self.mistakeBookID }
    // MARK: 分栏怎么显示
    //
    // 三样东西，各管各的：
    // · 左栏（题集、笔记、白板的列表）：收起 = .detailOnly。宽屏时左栏挤在页面旁边，不会浮在页面上（见 RootView）
    // · 中间栏（题目列表、笔记目录）：listHidden，向左拽收起、从页面左边拽回来。左栏收起时中间栏照样显示
    // · 全屏：左栏、中间栏都收起，只留页面；退出全屏时左栏回到全屏前的样子，中间栏跟着 listHidden

    /// 左栏显不显示（系统分栏的状态）
    @Published var columnVisibility: NavigationSplitViewVisibility = .all {
        didSet {
            // 只用两种：左栏开着（.all）或收起（.detailOnly）。窄屏时系统的分栏可能给别的值，统一成 .all
            if columnVisibility != .detailOnly && columnVisibility != .all {
                columnVisibility = .all
            }
            // 全屏时用系统按钮、边缘划动把左栏拉了回来：不再算全屏，中间栏也回来
            if isFullScreen && columnVisibility != .detailOnly { isFullScreen = false }
        }
    }

    /// 左栏收起来了（全屏、或者点了左栏上的收起按钮）
    var sidebarHidden: Bool { columnVisibility == .detailOnly }

    /// 全屏：只留页面
    @Published private(set) var isFullScreen = false
    /// 进全屏前左栏是不是开着，退出时照原样放回
    private var sidebarBeforeFullScreen = true

    /// 中间的白色栏（题目列表、笔记目录）拽到左边收起来了，记住上次的选择
    @Published var listHidden: Bool = UserDefaults.standard.bool(forKey: "listHidden") {
        didSet { UserDefaults.standard.set(listHidden, forKey: "listHidden") }
    }

    // MARK: 栏滑进滑出时页面不跟着一帧帧变宽变窄
    //
    // 页面（题目、笔记）宽度一变就要重排：公式、页边批注、每道题的手写画布都跟着重新量、重新画，一次要好几百毫秒。
    // 以前栏滑动的每一帧页面都变一次宽，动画一开始就卡住半秒，手写的字也在这期间整块消失。
    // 现在栏滑动时页面保持原来的宽度，整块跟着挪（只是移动位置，很便宜）；滑完再一次排成新的宽度

    /// 页面现在多宽（RootView 量好写进来）
    var pageWidth: CGFloat = 0
    /// 栏正在滑：页面先按这个宽度排，滑完变回 nil
    @Published private(set) var frozenPageWidth: CGFloat?
    private var pageUnfreeze: DispatchWorkItem?

    /// 马上要收起 / 拉出一栏：页面先保持现在的宽度，栏滑完再换成新的宽度
    func holdPageWidth(for duration: Double = 0.32) {
        #if os(iOS)
        // 手写的画布先垫上截图：栏滑动时 PencilKit 会把字丢掉一会儿
        NotificationCenter.default.post(name: PadCanvasView.pageWillMove, object: nil)
        #endif
        guard pageWidth > 0 else { return }
        if frozenPageWidth == nil { frozenPageWidth = pageWidth }
        pageUnfreeze?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.frozenPageWidth = nil }
        pageUnfreeze = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// 进 / 出全屏。不在全屏但左栏收着时“退出”就是把左栏放回来（白板只有左栏，收起左栏就是全屏）
    func setFullScreen(_ on: Bool) {
        holdPageWidth()
        withAnimation(.easeInOut(duration: 0.25)) {
            if on {
                if !isFullScreen { sidebarBeforeFullScreen = !sidebarHidden }
                isFullScreen = true
                columnVisibility = .detailOnly
            } else {
                let restore = isFullScreen ? sidebarBeforeFullScreen : true
                isFullScreen = false
                columnVisibility = restore ? .all : .detailOnly
            }
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

    /// 学生标记过“还没学”的知识点：AI 讲解时不用（写进每次请求的系统提示词）
    @Published var unlearnedTopics: [String] = UserDefaults.standard.stringArray(forKey: Tutor.unlearnedTopicsKey) ?? [] {
        didSet { UserDefaults.standard.set(unlearnedTopics, forKey: Tutor.unlearnedTopicsKey); saveSettingsFile() }
    }

    func addUnlearnedTopic(_ topic: String) {
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty, !unlearnedTopics.contains(where: { $0.caseInsensitiveCompare(topic) == .orderedSame }) else { return }
        unlearnedTopics.append(topic)
    }

    /// 导入后在后台预先求解没有参考答案的题
    @Published var presolveAnswers: Bool = UserDefaults.standard.object(forKey: "presolveAnswers") as? Bool ?? true {
        didSet { UserDefaults.standard.set(presolveAnswers, forKey: "presolveAnswers") }
    }
    /// 正在后台求解的题
    private var presolving: Set<UUID> = []
    /// 预先求解失败的题和失败的时间：题目每次滚进屏幕都会来求解，失败了隔一会儿再试，不每次都花一次请求
    private var presolveFailedAt: [UUID: Date] = [:]

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
    private var foldersSaveTask: Task<Void, Never>?
    /// 模型设置文件（settings.json）停一会儿再写，填 API Key 时不用每个字都写一次
    private var settingsSaveTask: Task<Void, Never>?
    /// 正在套用设置文件：这期间的赋值不写回文件
    private var applyingSettings = false
    /// 储存位置里的 settings.json 存在但读不出来：不写，免得把里面的 API Key 覆盖掉
    private var settingsFileBlocked = false
    private var replyTasks: [UUID: Task<Void, Never>] = [:]
    /// 每次回复的编号：停下后马上又点了检查，旧的那次收尾时不去清新的这次的状态
    private var replyTokens: [UUID: UUID] = [:]

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

    private static let lastOpenedKey = "lastOpened"

    /// 记下现在打开的是哪块白板、哪篇笔记，或哪个题集的哪道题，下次打开 App 回到这里
    private func rememberOpened() {
        guard isLoaded else { return }
        var value: [String: String]
        if let id = selectedBoardID {
            value = ["kind": "board", "id": id.uuidString]
        } else if let id = selectedNoteID {
            value = ["kind": "note", "id": id.uuidString]
        } else if let id = selectedSetID {
            value = ["kind": "set", "id": id.uuidString]
            if let qID = selectedQuestionID { value["question"] = qID.uuidString }
        } else {
            return
        }
        UserDefaults.standard.set(value, forKey: Self.lastOpenedKey)
    }

    /// 打开 App 时回到上次打开的白板、笔记或题集（停在上次那道题）；
    /// 没有记录、或者那一份已经删了，就回到最近的题集，停在第一道还没完成的题
    private func selectRecent() {
        if let last = UserDefaults.standard.dictionary(forKey: Self.lastOpenedKey) as? [String: String],
           let id = last["id"].flatMap({ UUID(uuidString: $0) }) {
            switch last["kind"] {
            case "board" where board(id) != nil:
                selectBoard(id)
                return
            case "note" where note(id) != nil:
                selectNote(id)
                return
            case "set":
                if let set = questionSets.first(where: { $0.id == id }) {
                    let qID = last["question"].flatMap { UUID(uuidString: $0) }
                    selectedSetID = id
                    selectedQuestionID = set.questions.first(where: { $0.id == qID })?.id
                        ?? set.questions.first(where: { !$0.status.isDone })?.id ?? set.questions.first?.id
                    return
                }
            default:
                break
            }
        }
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
        var undecodable: [String] = []
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
        // 读得到但解不开（比如用更新的版本存过、或是 iCloud 冲突文件）：先备份原文件，再挡住保存，
        // 绝不能让之后的保存把空列表写回去
        func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
            guard let data = load(url) else { return nil }
            if let decoded = try? JSONDecoder().decode(type, from: data) { return decoded }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let name = url.deletingPathExtension().lastPathComponent
            let backup = url.deletingLastPathComponent().appendingPathComponent("\(name)-backup-\(stamp).json")
            try? DataLocation.write(data, to: backup)
            snapshot.undecodable.append(url.lastPathComponent)
            return nil
        }
        if let decoded = decode([QuestionSet].self, from: libraryURL) {
            snapshot.sets = decoded.map(cleaned)
        }
        if let decoded = decode([NoteDoc].self, from: notesURL) {
            snapshot.notes = decoded
        }
        if let decoded = decode([Whiteboard].self, from: boardsURL) {
            snapshot.boards = decoded
        }
        if let decoded = decode([Folder].self, from: foldersURL) {
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
        writesBlocked = !snapshot.unreadable.isEmpty || !snapshot.undecodable.isEmpty
        if !snapshot.unreadable.isEmpty {
            errorMessage = String(localized: "读不到储存位置里的 \(snapshot.unreadable.joined(separator: L("、")))（可能还没从 iCloud 下载完）。为了不覆盖原来的数据，现在的改动不会保存。请确认网络和 iCloud 正常后重新打开 App。")
        } else if !snapshot.undecodable.isEmpty {
            errorMessage = String(localized: "储存位置里的 \(snapshot.undecodable.joined(separator: L("、"))) 打不开（可能是用更新版本的 Stepwise 存的），原文件已经另存了一份备份。为了不覆盖原来的数据，现在的改动不会保存。请更新到最新版本后重新打开 App。")
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
        foldersSaveTask?.cancel()
        guard !writesBlocked else { return }
        // 拉下控制中心、切到别的 App 都会来这里：自上次写盘以后没改过的文件不再整个重写
        for (url, encode) in [(Self.libraryURL, { [sets] in try? JSONEncoder().encode(sets) }),
                              (Self.notesURL, { [notes] in try? JSONEncoder().encode(notes) }),
                              (Self.boardsURL, { [boards] in try? JSONEncoder().encode(boards) })] as [(URL, () -> Data?)]
        where SaveLedger.shared.hasPending(url) {
            let generation = SaveLedger.shared.issue(url)
            if let data = encode() { SaveLedger.shared.write(data, to: url, generation: generation) }
        }
        // 文件夹以前改一次就马上写一次；现在停一下再写，还没写的这里补上
        if SaveLedger.shared.hasPending(Self.foldersURL), let data = try? JSONEncoder().encode(folders) {
            SaveLedger.shared.write(data, to: Self.foldersURL, generation: SaveLedger.shared.issue(Self.foldersURL))
        }
    }

    /// 停一会儿再在后台写盘；写之前先排好号，晚排的写过了，早排的就不再写（免得旧数据盖掉新的）
    private func scheduleWrite<Value: Encodable>(_ value: Value, to url: URL, after delay: UInt64,
                                                            replacing task: inout Task<Void, Never>?) {
        task?.cancel()
        let generation = SaveLedger.shared.issue(url)
        task = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(value) else { return }
            SaveLedger.shared.write(data, to: url, generation: generation)
        }
    }

    /// 便签在流式回复、拖动时变化很频繁，停一会儿再写盘
    private func scheduleBoardsSave() {
        guard !loading, !writesBlocked else { return }
        scheduleWrite(boards, to: Self.boardsURL, after: 800_000_000, replacing: &boardsSaveTask)
    }

    /// 笔记在流式生成时变化很频繁，停一会儿再写盘
    private func scheduleNotesSave() {
        guard !loading, !writesBlocked else { return }
        // 地址在这里先定下来：等待期间换了储存位置，也不会写到新位置去
        scheduleWrite(notes, to: Self.notesURL, after: 800_000_000, replacing: &notesSaveTask)
    }

    private func scheduleSave() {
        guard !loading, !writesBlocked else { return }
        scheduleWrite(sets, to: Self.libraryURL, after: 600_000_000, replacing: &saveTask)
    }

    /// 折叠、展开文件夹也会改：以前每次都在主线程上立刻写盘（删文件夹、导入备份时一个一个写），现在停一下在后台写
    private func saveFolders() {
        guard !loading, !writesBlocked else { return }
        scheduleWrite(folders, to: Self.foldersURL, after: 300_000_000, replacing: &foldersSaveTask)
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
    func changeDataLocation(to destination: DataLocation.Target?, mode: LocationChange) async throws {
        guard !hasBackgroundWork else {
            throw LocationError(message: L("AI 正在回复或生成笔记，等它完成后再换储存位置。"))
        }
        let source = DataLocation.root
        let target = destination?.folder ?? DataLocation.defaultRoot
        guard !DataLocation.isSame(source, target) else { return }
        // 数据在选的文件夹下面的 Stepwise Files 里时，要访问选的那一层才能读写里面
        let scope = destination?.scope
        let accessing = scope?.startAccessingSecurityScopedResource() ?? false
        defer { if accessing { scope?.stopAccessingSecurityScopedResource() } }
        // 先把最近的改动写进原来的位置（包括还排着队的手写笔迹）
        saveNow()
        DrawingStore.flush()
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
            if let destination {
                try DataLocation.adopt(destination)
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
        if destination != nil {
            if mode == .copyCurrent || !applySettings(snapshot.settings) { writeSettingsFile() }
        } else {
            settingsFileBlocked = false
        }
        // 换了一份数据：原来选中的题集、笔记可能已经不在了
        selectedNoteID = nil
        selectedSetID = nil
        selectedQuestionID = nil
        noteGuides = [:]
        activeNoteGuide = nil
        selectRecent()
    }

    /// 在文件选择器里选了一个文件夹：找到或新建里面的 Stepwise Files，然后自动读取——
    /// 里面已经有 Stepwise 数据就改用那份；没有就把现在的数据复制进去。原来位置的数据都不删。返回给用户看的结果
    func useFolder(_ picked: URL) async throws -> String {
        guard !hasBackgroundWork else {
            throw LocationError(message: L("AI 正在回复或生成笔记，等它完成后再换储存位置。"))
        }
        let (target, contents) = try await Task.detached(priority: .userInitiated) { () throws -> (DataLocation.Target, DataLocation.Contents) in
            let target = try DataLocation.resolve(picked)
            let accessing = target.scope.startAccessingSecurityScopedResource()
            defer { if accessing { target.scope.stopAccessingSecurityScopedResource() } }
            return (target, DataLocation.inspect(target.folder))
        }.value
        let place = DataLocation.describe(target.folder)
        if DataLocation.isSame(target.folder, DataLocation.root) {
            return String(localized: "数据现在就存在“\(place)”。")
        }
        let before = String(localized: "\(questionSets.count) 个题集、\(notes.count) 篇笔记")
        let hadData = !questionSets.isEmpty || !notes.isEmpty || !boards.isEmpty
        if case .stepwise = contents {
            try await changeDataLocation(to: target, mode: .useExisting)
            let now = String(localized: "\(questionSets.count) 个题集、\(notes.count) 篇笔记")
            var message = String(localized: "已读取“\(place)”里的数据：\(now)。")
            if hadData { message += String(localized: "原来位置的\(before)没有删除，改回原来的位置就能看到。") }
            return message
        }
        try await changeDataLocation(to: target, mode: .copyCurrent)
        return hadData
            ? String(localized: "“\(place)”里还没有数据，已把现在的\(before)复制进去，之后都存在那里。")
            : String(localized: "之后题目、笔记和设置都存在“\(place)”。")
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
        // 学习时间每 20 秒、每次翻页停下都会改设置：停 3 秒再写，连着改只写一次
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
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
        let url = DataLocation.url(DataLocation.settingsFile)
        // 内容和上次写的（或启动时读到的）一样就不再写（文件夹在 iCloud 里时每写一次都要上传）。
        // 其他设置按内容比，不按字节比：同样的设置每次打包出来的顺序可能不一样
        let content = SettingsContent(file, at: url)
        if let content, let last = lastSettingsWrite, content.matches(last) { return }
        guard let data = try? encoder.encode(file) else { return }
        if (try? DataLocation.write(data, to: url)) != nil { lastSettingsWrite = content }
    }
    private var lastSettingsWrite: SettingsContent?

    /// settings.json 里写了什么：其他设置以外的部分按排好序的 JSON 比，其他设置解开成字典比
    private struct SettingsContent {
        let url: URL
        let core: Data
        let preferences: NSDictionary

        init?(_ file: SettingsFile, at url: URL) {
            var core = file
            core.preferences = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(core) else { return nil }
            self.url = url
            self.core = data
            preferences = file.preferences
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary } ?? [:]
        }

        func matches(_ other: SettingsContent) -> Bool {
            url == other.url && core == other.core && preferences.isEqual(other.preferences)
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
        // 记下文件里是什么：套用完和文件一样时，启动后不用马上整个重写一遍（连同 API Key 上传 iCloud）
        lastSettingsWrite = SettingsContent(file, at: DataLocation.url(DataLocation.settingsFile))
        return true
    }

    // MARK: - 其他设置和学习时间

    /// 上面单独存过的模型设置、储存位置本身不放进 preferences
    private static let excludedPreferenceKeys: Set<String> = [
        DataLocation.bookmarkKey, DataLocation.subfolderKey, DataLocation.promptedKey, "providers", "activeProvider", "gradingProvider", "gradingModel",
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
        ReadingPosition.reloadAll()
        aiConsent = d.object(forKey: "aiConsent") as? Bool ?? aiConsent
        showTiming = d.object(forKey: "showTiming") as? Bool ?? showTiming
        keyboardAnswer = d.bool(forKey: "keyboardAnswer")
        presolveAnswers = d.object(forKey: "presolveAnswers") as? Bool ?? presolveAnswers
        unlearnedTopics = d.stringArray(forKey: Tutor.unlearnedTopicsKey) ?? unlearnedTopics
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

    // MARK: - 模型组合

    /// 套用模型组合时用哪个服务商：当前使用的有三档预设就用它，否则按 ModelTiers.providerOrder 找已填 Key 的
    var comboProvider: ProviderConfig? {
        let usable = providers.filter { ModelTiers.forProvider($0.id) != nil && $0.hasKey }
        if let active = usable.first(where: { $0.id == activeProviderID }) { return active }
        return ModelTiers.providerOrder.lazy.compactMap { id in usable.first { $0.id == id } }.first
    }

    /// 已填 Key、有三档预设的服务商（设置里可以选用哪个服务商的组合）
    var comboProviders: [ProviderConfig] {
        ProviderCatalog.displayOrder(providers.filter { ModelTiers.forProvider($0.id) != nil && $0.hasKey })
    }

    /// 读手写用的模型（服务商的低档模型）；没有可用的服务商时为 nil
    func handwritingReader() -> LLMClient? {
        visionProvider.map { LLMClient(config: $0, apiKey: $0.apiKey) }
    }

    /// 让识图模型把手写图片逐行转写成文字；失败或空白时返回 nil
    nonisolated static func transcribe(_ image: Data, with reader: LLMClient) async -> String? {
        let blank: Set<String> = ["（空白）", "(空白)", "(blank)", "blank", "空白"]
        let strips = ImageUtil.horizontalStrips(image)
        let parts = await transcribeStrips(strips) { strip in
            let text = try? await reader.complete(
                system: Tutor.transcribeSystem,
                messages: [LLMMessage(role: .user, parts: [.image(strip), .text(Tutor.pick("请逐行转写。", "Transcribe it line by line."))])],
                options: RequestOptions(fast: true, transcribing: true))
            let lines = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return lines.isEmpty ? nil : lines
        }
        guard let parts else { return nil }
        // 分了段时，空白的那几段不要
        let kept = parts.count > 1 ? parts.filter { !blank.contains($0) } : parts
        return kept.isEmpty ? parts.first : kept.joined(separator: "\n")
    }

    /// 几段手写图片同时转写，按上下顺序返回；有一段失败就当整个失败（调用的地方会照旧发图片）
    nonisolated static func transcribeStrips(_ strips: [Data], _ one: @escaping (Data) async -> String?) async -> [String]? {
        if strips.count == 1 { return await one(strips[0]).map { [$0] } }
        return await withTaskGroup(of: (Int, String?).self) { group in
            for (i, strip) in strips.enumerated() {
                group.addTask { (i, await one(strip)) }
            }
            var results = [String?](repeating: nil, count: strips.count)
            for await (i, text) in group {
                guard let text else { group.cancelAll(); return nil }
                results[i] = text
            }
            return results.compactMap { $0 }
        }
    }

    /// 图像识别（手写作答、导入题目时的照片、扫描件、按图片发送的 PDF 页）一律用服务商的低档模型：只是把图上的字抄下来，
    /// 快又便宜。先用检查模型所在的服务商，其次当前服务商，再其次任意已填 Key、有三档预设的服务商；都没有时为 nil（照旧发图片）
    var visionProvider: ProviderConfig? {
        let candidates = [gradingProvider, activeProvider, comboProvider].compactMap { $0 }
        guard var p = candidates.first(where: { $0.hasKey && ModelTiers.forProvider($0.id) != nil }),
              let tiers = ModelTiers.forProvider(p.id) else { return nil }
        p.model = tiers.low
        return p
    }

    /// 一次设好当前模型、检查与提示、出新题和整理笔记四个模型（用 providerID 这个服务商的三档预设）
    func applyCombo(_ combo: ModelCombo, providerID: String? = nil) {
        guard let p = providerID.flatMap({ id in providers.first { $0.id == id && $0.hasKey } }) ?? comboProvider,
              let tiers = ModelTiers.forProvider(p.id) else { return }
        let model = combo.model(in: tiers)
        select(provider: p.id, model: model)
        gradingProviderID = p.id
        gradingModel = model
        questionProviderID = p.id
        questionModel = model
        noteProviderID = p.id
        noteModel = model
        // 先用强模型解出答案，检查时对答案，不容易改错
        presolveAnswers = true
    }

    /// 现在的设置正好是哪个组合（任何一个模型改过就不算）
    var currentCombo: ModelCombo? {
        guard let p = activeProvider, let tiers = ModelTiers.forProvider(p.id) else { return nil }
        return ModelCombo.all.first { c in
            let m = c.model(in: tiers)
            return p.model == m
                && gradingProviderID == p.id && gradingModel == m
                && questionProviderID == p.id && questionModel == m
                && noteProviderID == p.id && noteModel == m
        }
    }

    func deleteProvider(_ id: String) {
        Keychain.set("", for: id)
        providers.removeAll { $0.id == id }
        if activeProviderID == id { activeProviderID = "anthropic" }
    }

    /// 先和检查、提示用的服务商建好网络连接（不发送任何内容），之后的请求复用这条连接，少等一次握手
    func warmUpGrading() {
        guard aiConsent == true, let config = gradingProvider ?? activeProvider, config.hasKey else { return }
        LLMClient.warmUp(config)
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
        // 先改一份副本：没变就不动 sets，免得整个 App 重新渲染、题库重新写盘（滚动时每道题移出屏幕都会来这里）
        var q = sets[si].questions[qi]
        change(&q)
        guard q != sets[si].questions[qi] else { return }
        sets[si].questions[qi] = q
    }

    /// 和这道题共用题干的其他题（按题集里的顺序，不含它自己）
    func stemSiblings(_ setID: UUID, _ qID: UUID) -> [Question] {
        guard let questions = set(setID)?.questions,
              let group = questions.first(where: { $0.id == qID })?.stemGroup else { return [] }
        return questions.filter { $0.stemGroup == group && $0.id != qID }
    }

    /// 学生在“有疑问”里补充了题目原文没有的数据或条件：记在这道题上；共用题干的几道题一起记
    /// （缺的多半是题干、图上的数据，每一问都用得着）。预先求解的答案是缺着条件解的，作废重解
    func addSupplements(_ setID: UUID, _ qID: UUID, _ items: [String]) {
        let items = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !items.isEmpty else { return }
        let ids = [qID] + stemSiblings(setID, qID).map(\.id)
        for id in ids {
            mutate(setID, id) { q in
                var all = q.supplements ?? []
                for item in items where !all.contains(item) { all.append(item) }
                guard all != (q.supplements ?? []) else { return }
                q.supplements = all
                q.aiAnswer = nil
            }
        }
        presolve(setID, ids)
    }

    /// 删掉一条补充的条件（共用题干的几道题一起删）
    func removeSupplement(_ setID: UUID, _ qID: UUID, _ item: String) {
        let ids = [qID] + stemSiblings(setID, qID).map(\.id)
        for id in ids {
            mutate(setID, id) { q in
                guard let all = q.supplements, all.contains(item) else { return }
                let rest = all.filter { $0 != item }
                q.supplements = rest.isEmpty ? nil : rest
                q.aiAnswer = nil
            }
        }
        presolve(setID, ids)
    }

    func addSet(_ newSet: QuestionSet) {
        sets.insert(newSet, at: 0)
        selectedSetID = newSet.id
        selectedQuestionID = newSet.questions.first?.id
        presolve(newSet.id, newSet.questions.map(\.id))
    }

    func deleteSet(_ id: UUID) {
        guard let s = set(id) else { return }
        ReadingPosition.forget([id])
        for q in s.questions { cancelReply(q.id) }
        // 连“重新练习”之前那几轮的手写图片一起删（以前漏了，一直留在 images 文件夹里）
        ImageStore.delete(LibraryBackup.imageIDs(in: s))
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
        noteGuides[qID] = nil
        noteGuideChecked[qID] = nil
        DrawingStore.delete([qID])
    }

    // MARK: - 收藏

    /// 收藏里的所有题，按加入时间从新到旧
    var starredEntries: [(setID: UUID, question: Question)] {
        sets.flatMap { set in set.questions.filter(\.isStarred).map { (set.id, $0) } }
            .sorted { ($0.question.starredAt ?? .distantPast) > ($1.question.starredAt ?? .distantPast) }
    }

    /// 收藏里有几道题（只数数，不用排序）
    var starredCount: Int {
        sets.reduce(0) { total, set in total + set.questions.reduce(0) { $0 + ($1.isStarred ? 1 : 0) } }
    }

    func toggleStar(_ setID: UUID, _ qID: UUID) {
        mutate(setID, qID) { q in
            q.starredAt = q.isStarred ? nil : Date()
        }
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
        }
        noteGuides[qID] = nil
        noteGuideChecked[qID] = nil
        DrawingStore.delete([qID])
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
            if let failed = presolveFailedAt[id], Date().timeIntervalSince(failed) < 300 { return false }
            return (q.referenceAnswer ?? "").isEmpty && q.aiAnswer == nil
        }
        guard !todo.isEmpty, let client = try? makeClient(for: .presolve) else { return }
        presolving.formUnion(todo)
        // 在主线程先把题目和图片准备好
        let jobs: [(UUID, String, [LLMMessage])] = todo.compactMap { id in
            guard let q = question(setID, id) else { return nil }
            let images = q.imageIDs.compactMap(ImageStore.load).map(LLMContent.image)
            return (id, Tutor.presolveSystem(for: q, siblings: stemSiblings(setID, id)),
                    [LLMMessage(role: .user, parts: images + [.text(Tutor.presolveInstruction)])])
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
                            self.presolveFailedAt[id] = nil
                        } else {
                            self.presolveFailedAt[id] = Date()
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

        run(setID, qID, userMessage: message, replyKind: .verdictWrong, purpose: .check,
            transcribe: handwriting) { [weak self] full in
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
                if correct {
                    if q.status != .revealed { q.status = .passed }
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
        run(setID, qID, userMessage: message, replyKind: .hint, purpose: .hint, waitingLabel: L("正在看你卡在哪…")) { [weak self] full in
            self?.mutate(setID, qID) { q in
                var hint = ChatMessage(role: .assistant, kind: .hint, text: full)
                hint.hintLevel = ChatMessage.stuckHintLevel
                q.messages.append(hint)
            }
        }
    }

    /// 点“下一步”：卡了太久写不下去，带上现在的手写和打的字，让 AI 直接接着写出一步。
    /// 回复记成一条提示（hintLevel 为 -1），不占用提示的档次
    func requestNextStep(_ setID: UUID, _ qID: UUID, answer: String, handwriting: Data?) {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageIDs = handwriting.map { [ImageStore.save($0)] } ?? []
        let message = ChatMessage(role: .user, kind: .hintRequest, text: L("写出下一步"),
                                  prompt: Tutor.nextStepInstruction(hasImage: !imageIDs.isEmpty, typed: answer),
                                  imageIDs: imageIDs)
        run(setID, qID, userMessage: message, replyKind: .hint, purpose: .hint, waitingLabel: L("正在写下一步…")) { [weak self] full in
            self?.mutate(setID, qID) { q in
                var step = ChatMessage(role: .assistant, kind: .hint, text: full)
                step.hintLevel = ChatMessage.nextStepHintLevel
                q.messages.append(step)
            }
        }
    }

    func requestSolution(_ setID: UUID, _ qID: UUID) {
        let message = ChatMessage(role: .user, kind: .solutionRequest, text: L("给出完整答案"), prompt: Tutor.solutionInstruction)
        run(setID, qID, userMessage: message, replyKind: .solution, purpose: .solution) { [weak self] full in
            self?.mutate(setID, qID) { q in
                q.messages.append(ChatMessage(role: .assistant, kind: .solution, text: full))
                if q.status != .passed { q.status = .revealed }
            }
            // 刚看的答案直接展开
            self?.openSolutionQuestion = qID
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

    /// 对一条 AI 回复有疑问：直接写下哪里不明白，回答贴在页边
    func askAboutReply(_ setID: UUID, _ qID: UUID, about reply: ChatMessage, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let q = question(setID, qID) else { return }
        let follow = ReplyFollowUp(id: reply.id, kind: .doubt)
        var message = ChatMessage(role: .user, kind: .chat, text: text,
                                  prompt: Tutor.doubtInstruction(about: reply, question: text, done: q.status.isDone))
        message.about = follow
        run(setID, qID, userMessage: message, replyKind: .chat, purpose: .chat, inMargin: true,
            waitingLabel: L("正在想你问的…")) { [weak self] full in
            // 疑问里补充了题目没有的数据：AI 用 <given> 记下来，存到题目上，之后批改都按它来
            let (text, given) = Tutor.extractGiven(full)
            self?.mutate(setID, qID) { q in
                var answer = ChatMessage(role: .assistant, kind: .chat, text: text, prompt: given.isEmpty ? nil : full)
                answer.about = follow
                q.messages.append(answer)
            }
            self?.addSupplements(setID, qID, given)
        }
    }

    /// 回复里有没学过的知识点：换成学过的方法重讲，并记下这个知识点，以后都不用。
    /// topic 为空：学生说不出名字，由 AI 判断，名字从回复里的 <topic> 取
    func reexplainWithoutTopic(_ setID: UUID, _ qID: UUID, about reply: ChatMessage, topic: String) {
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let q = question(setID, qID) else { return }
        let follow = ReplyFollowUp(id: reply.id, kind: .unlearned)
        var message = ChatMessage(role: .user, kind: .chat,
                                  text: topic.isEmpty ? L("这里有我没学过的知识点") : String(localized: "我还没学过：\(topic)"),
                                  prompt: Tutor.unlearnedInstruction(about: reply, topic: topic, done: q.status.isDone))
        message.about = follow
        message.note = topic.isEmpty ? nil : topic
        if !topic.isEmpty { addUnlearnedTopic(topic) }
        run(setID, qID, userMessage: message, replyKind: .chat, purpose: .chat, inMargin: true,
            waitingLabel: L("正在换成你学过的方法…")) { [weak self] full in
            let (text, named) = Tutor.extractTopic(full)
            if topic.isEmpty, let named { self?.addUnlearnedTopic(named) }
            self?.mutate(setID, qID) { q in
                var answer = ChatMessage(role: .assistant, kind: .chat, text: text, prompt: full)
                answer.about = follow
                answer.note = topic.isEmpty ? named : topic
                q.messages.append(answer)
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
                     purpose: RequestPurpose, inMargin: Bool = false, transcribe handwriting: Data? = nil,
                     waitingLabel: String? = nil,
                     finish: @escaping (String) -> Void) {
        guard !isBusy(qID) else { return }
        let client: LLMClient
        do { client = try makeClient(for: purpose) } catch {
            if !(error is ConsentRequired) { errorMessage = error.localizedDescription }
            ImageStore.delete(userMessage.imageIDs)
            return
        }
        mutate(setID, qID) { $0.messages.append(userMessage) }
        guard let q = question(setID, qID) else { return }

        let system = Tutor.tutorSystem(for: q, origin: q.originNote ?? legacyOrigin(of: q, in: setID),
                                       siblings: stemSiblings(setID, qID))
        func makeHistory(_ q: Question, _ current: ChatMessage) -> [LLMMessage] {
            var history = Self.context(for: q, current: current, purpose: purpose)
            // 之前的回复也在上下文里，模型容易照着它们的开头和用字写（“同学你好！”、繁体题用简体回答），在这次的请求最后再提醒一次
            if !history.isEmpty {
                history[history.count - 1].parts.append(.text(Tutor.replyReminder(for: q)))
            }
            return history
        }
        let history = makeHistory(q, userMessage)
        // 手写先交给识图模型（Haiku）逐行转写，检查、提示模型只看文字：
        // 检查和“卡了”转写这次的手写；“求助”转写最近一次作答里还没转写过的手写
        let target: ChatMessage? = {
            guard purpose == .check || purpose == .hint else { return nil }
            if !userMessage.imageIDs.isEmpty { return userMessage }
            guard purpose == .hint, let last = q.messages.last(where: { $0.kind == .submission && $0.id != userMessage.id }),
                  !last.imageIDs.isEmpty, last.transcript == nil else { return nil }
            return last
        }()
        let targetImage = target.flatMap { $0.imageIDs.first }.flatMap(ImageStore.load) ?? handwriting
        let reader = target == nil || targetImage == nil ? nil : handwritingReader()
        let options = RequestOptions(fast: purpose.isGrading && quickGrading)
        let modelName = client.config.model
        pending[qID] = PendingReply(kind: replyKind, inMargin: inMargin, label: reader == nil ? waitingLabel : L("正在读手写…"))
        live(qID).text = ""
        let started = Date()
        let token = UUID()
        replyTokens[qID] = token

        replyTasks[qID] = Task { [weak self] in
            var full = ""
            var lastFlush = Date.distantPast
            var history = history
            do {
                if let reader, let target, let targetImage {
                    let lines = await Self.transcribe(targetImage, with: reader)
                    try Task.checkCancellation()
                    // 转写失败：照旧把手写图片发给检查模型
                    if let self, let lines {
                        var updated = target
                        updated.transcript = lines
                        if purpose == .check && target.id == userMessage.id {
                            let typed = userMessage.text.isEmpty ? "" : Tutor.pick("【打字作答】\n", "[Typed answer]\n") + userMessage.text + "\n\n"
                            updated.prompt = typed + Tutor.transcribedAnswer(lines) + "\n\n" + Tutor.checkInstruction(lineNumbers: true)
                        }
                        self.mutate(setID, qID) { q in
                            if let i = q.messages.firstIndex(where: { $0.id == target.id }) { q.messages[i] = updated }
                        }
                        let current = target.id == userMessage.id ? updated : userMessage
                        if let q = self.question(setID, qID) { history = makeHistory(q, current) }
                    }
                    self?.pending[qID]?.label = waitingLabel
                }
                for try await chunk in client.stream(system: system, messages: history, options: options) {
                    full += chunk
                    // 限制刷新频率，长回答流式输出时界面不卡
                    if Date().timeIntervalSince(lastFlush) > 0.08 {
                        self?.live(qID).text = full
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
                if self.replyTokens[qID] == token { self.pending[qID] = nil }
                // 失败时撤回这次的提问，方便直接重试
                self.mutate(setID, qID) { q in q.messages.removeAll { $0.id == userMessage.id } }
                ImageStore.delete(userMessage.imageIDs)
                if !(error is CancellationError) {
                    self.errorMessage = error.localizedDescription
                }
            }
            guard let self, self.replyTokens[qID] == token else { return }
            self.endLive(qID)
            self.replyTasks[qID] = nil
            self.replyTokens[qID] = nil
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
            result.append(LLMMessage(role: .user, parts: questionImages + [.text(Tutor.pick("（以上是题目中的图，图形、表格以图片为准）", "(Above are the figures from the question; for figures and tables, go by the images.)"))]))
        }

        switch purpose {
        case .check:
            let blocks = [summary, summary == nil ? nil : Tutor.regradeNote, current.prompt ?? current.text]
            // 已经转写成文字的手写不再发图片
            let answerImages = current.transcript != nil ? [] : images(current)
            result.append(LLMMessage(role: .user, parts: answerImages + [.text(blocks.compactMap { $0 }.joined(separator: "\n\n"))]))
        case .hint, .solution, .presolve, .split, .note:
            var blocks = [summary]
            var parts: [LLMContent] = []
            if purpose == .hint, !current.imageIDs.isEmpty {
                // 点“卡了”：带的是现在的手写（转写过就只带文字），作答说明已经写在这次的请求里
                if let transcript = current.transcript {
                    blocks.append(Tutor.handwritingTranscript(transcript))
                } else {
                    parts = images(current)
                }
            } else if purpose == .hint, let last = earlier.last(where: { $0.kind == .submission }) {
                var answer = Tutor.pick("【我最近一次的作答】\n", "[My latest answer]\n")
                if let transcript = last.transcript {
                    if !last.text.isEmpty { answer += Tutor.clip(last.text, 1500) + "\n" }
                    answer += Tutor.handwritingTranscript(transcript, title: Tutor.pick("手写部分", "Handwritten part"))
                } else {
                    parts = images(last)
                    answer += last.text.isEmpty ? Tutor.pick("（见手写图片）", "(see the handwriting image)") : Tutor.clip(last.text, 1500)
                }
                blocks.append(answer)
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
        // 图片部分交给识图模型，文字部分仍用当前模型
        let imageClient = visionProvider.map { LLMClient(config: $0, apiKey: $0.apiKey) } ?? client
        let chunks = Importer.chunks(for: material)
        guard !chunks.isEmpty else { throw LLMError(message: L("没有可以拆分的内容。")) }

        // 几部分同时拆（最多 3 部分），比一部分一部分等快得多；拆完按原来的顺序合并
        let tracker = SplitTracker(chunks: chunks, report: progress)
        tracker.report(force: true)
        typealias Parsed = (title: String?, items: [Tutor.SplitItem], truncated: Bool)
        var results = [Result<Parsed, Error>?](repeating: nil, count: chunks.count)
        let makeTask = { (i: Int) -> @Sendable () async throws -> (Int, Result<Parsed, Error>) in
            { [self] in
                do {
                    return (i, .success(try await self.splitChunk(i, chunks[i], count: chunks.count,
                                                                  client: chunks[i].images.isEmpty ? client : imageClient,
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
            if let retried = try? await splitChunk(i, chunks[i], count: chunks.count,
                                                                  client: chunks[i].images.isEmpty ? client : imageClient,
                                                   requirement: requirement, tracker: tracker) {
                results[i] = .success(retried)
            } else {
                tracker.finish(i)
            }
        }
        tracker.report(force: true)

        var questions: [Question] = []
        var keys: [String] = []          // 与 questions 一一对应的题号，用于合并重叠页产生的重复题
        var stemGroups: [String: UUID] = [:]   // “第几部分:题干编号” → 共用这段题干的那一组
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
            // 回答写到长度上限被截断：最后一道写了一半被丢掉，告诉用户这一部分可能漏了题
            if parsed.truncated { failedParts.append(index + 1) }

            // 重叠页里重复的题已经分过组：这一部分里同一段题干的其他题跟着进同一组
            for item in parsed.items {
                guard let id = item.stemID, let existing = keys.firstIndex(of: Tutor.labelKey(item.label)),
                      let group = questions[existing].stemGroup else { continue }
                stemGroups["\(index):\(id)"] = group
            }
            for item in parsed.items {
                let key = Tutor.labelKey(item.label)
                let groupKey = item.stem == nil ? nil : item.stemID.map { "\(index):\($0)" }
                if let existing = keys.firstIndex(of: key) {
                    // 先拆到的那份没认出共用题干，这一份认出来了
                    if let stem = item.stem, let groupKey, questions[existing].stem == nil {
                        let group = stemGroups[groupKey] ?? UUID()
                        stemGroups[groupKey] = group
                        questions[existing].stem = stem
                        questions[existing].stemGroup = group
                        questions[existing].content = item.content
                    }
                    // 重叠页里的同一道题：补上缺失的答案，题干取更完整的那份
                    if questions[existing].referenceAnswer == nil, let answer = item.answer {
                        questions[existing].referenceAnswer = answer
                    } else if let answer = item.answer, answer.count > (questions[existing].referenceAnswer?.count ?? 0) {
                        questions[existing].referenceAnswer = answer
                    }
                    // 题干取更完整的那份（一份带共用题干、一份不带时不比：不带的那份把题干也写进了内容，本来就长）
                    if (item.stem == nil) == (questions[existing].stem == nil),
                       item.content.count > questions[existing].content.count {
                        questions[existing].content = item.content
                    }
                    // 先拆到的那份没认出图，这一份认出来了
                    if questions[existing].imageIDs.isEmpty {
                        questions[existing].imageIDs = await Self.figureImages(for: item, in: chunk.images).map(ImageStore.save)
                    }
                    continue
                }
                let imageIDs = await Self.figureImages(for: item, in: chunk.images).map(ImageStore.save)
                var question = Question(label: item.label, content: item.content,
                                        referenceAnswer: item.answer, imageIDs: imageIDs)
                if let stem = item.stem, let groupKey {
                    let group = stemGroups[groupKey] ?? UUID()
                    stemGroups[groupKey] = group
                    question.stem = stem
                    question.stemGroup = group
                }
                questions.append(question)
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
    /// 题目的图：按模型给的位置从页面里截出图形；没给位置、或位置不对时附上整页
    nonisolated static func figureImages(for item: Tutor.SplitItem, in pages: [Data]) async -> [Data] {
        guard item.hasFigure, !pages.isEmpty else { return [] }
        let stemPage = item.page ?? (pages.count == 1 ? 1 : nil)
        return await Task.detached(priority: .userInitiated) {
            var result: [Data] = []
            var wholePages: Set<Int> = []
            func addWhole(_ page: Int?) {
                guard let page, pages.indices.contains(page - 1), wholePages.insert(page).inserted else { return }
                result.append(pages[page - 1])
            }
            if item.figures.isEmpty { addWhole(stemPage) }
            for box in item.figures {
                // 写了图片序号但超出范围时，可能是按整个文件数的页码，退回题干那一页
                let page = box.page.flatMap { pages.indices.contains($0 - 1) ? $0 : nil } ?? stemPage
                guard let page, pages.indices.contains(page - 1) else { continue }
                if let crop = FigureCrop.crop(pages[page - 1], box: box) {
                    result.append(crop)
                } else {
                    addWhole(page)
                }
            }
            return result
        }.value
    }

    /// 拆一部分：边收边数已经写出来的题，写完检查选择题有没有漏选项
    fileprivate func splitChunk(_ index: Int, _ chunk: SplitChunk, count: Int, client: LLMClient, requirement: String,
                                tracker: SplitTracker) async throws -> (title: String?, items: [Tutor.SplitItem], truncated: Bool) {
        var parts: [LLMContent] = chunk.images.map(LLMContent.image)
        var text = count > 1
            ? Tutor.pick("以下是题目文件的第 \(index + 1)/\(count) 部分（与前后部分各有一页重叠）。",
                         "Below is part \(index + 1) of \(count) of the question file (it overlaps the neighboring parts by one page).")
            : Tutor.pick("以下是题目文件的内容。", "Below is the content of the question file.")
        text += chunk.text.isEmpty ? Tutor.pick("内容见上面的图片。", "The content is in the images above.") : "\n\n" + chunk.text
        parts.append(.text(text))
        let system = Tutor.splitSystem(requirement: requirement, hasImages: !chunk.images.isEmpty, multiPart: count > 1)

        var output = ""
        var written = 0   // 边收边数：每来一小段都把整段 output 数一遍，越往后越慢
        for try await piece in client.stream(system: system, messages: [LLMMessage(role: .user, parts: parts)]) {
            output += piece
            written += piece.count
            tracker.update(index, output: output, written: written)
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
        return (parsed.title, parsed.items, output.contains(L("\n\n（回答因长度限制被截断）")))
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

    func update(_ i: Int, output: String, written: Int) {
        estimator.update(i, written: written)
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

    /// 资料库按文件夹排好：每个文件夹（nil 为最外层）里直接放的子文件夹和题集、笔记、白板。
    /// 指向已经不存在的文件夹的东西放到最外层，不会丢
    struct LibraryIndex {
        var folders: [UUID?: [Folder]] = [:]
        var items: [UUID?: [LibraryItem]] = [:]
        /// 文件夹里（包括子文件夹）一共多少个笔记、白板、题集
        var counts: [UUID: Int] = [:]
    }

    func libraryIndex() -> LibraryIndex {
        var index = LibraryIndex()
        let ids = Set(folders.map(\.id))
        func place(_ id: UUID?) -> UUID? { id.flatMap { ids.contains($0) ? $0 : nil } }
        for f in folders { index.folders[place(f.parentID), default: []].append(f) }
        for key in index.folders.keys {
            index.folders[key]?.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        var all: [LibraryItem] = questionSets.map { .set($0) }
        all += notes.map { .note($0) }
        all += boards.map { .board($0) }
        for item in all { index.items[place(item.folderID), default: []].append(item) }
        // 新的在上面
        for key in index.items.keys {
            index.items[key]?.sort { $0.createdAt > $1.createdAt }
        }
        func count(_ id: UUID, _ depth: Int) -> Int {
            guard depth < 50 else { return 0 }
            let n = (index.items[id]?.count ?? 0) + (index.folders[id] ?? []).reduce(0) { $0 + count($1.id, depth + 1) }
            index.counts[id] = n
            return n
        }
        for f in index.folders[nil] ?? [] { _ = count(f.id, 0) }
        return index
    }

    /// 打开着笔记、白板、题集或收藏（右边是页面，不是一格一格的资料库）
    var hasOpenItem: Bool {
        board(selectedBoardID) != nil || note(selectedNoteID) != nil || isMistakeBook || set(selectedSetID) != nil
    }

    /// 点文件夹：关掉打开的东西，右边排出这个文件夹里的东西（nil 为最外层）
    func browseFolder(_ id: UUID?) {
        selectedFolderID = folder(id)?.id
        selectBoard(nil)
        selectNote(nil)
        selectedSetID = nil
        selectedQuestionID = nil
    }

    /// 打开一篇笔记、一块白板、一个题集或收藏
    func openItem(_ id: UUID) {
        if board(id) != nil {
            selectBoard(id)
            return
        }
        selectedBoardID = nil
        if note(id) != nil {
            selectNote(id)
            return
        }
        selectedNoteID = nil
        selectedSetID = id
        // 上次看到哪道题就回到哪道题；没看过的从第一道没做完的题开始
        let last = ReadingPosition.load(id)?.item
        if id == Self.mistakeBookID {
            let entries = starredEntries.map(\.question.id)
            selectedQuestionID = entries.first { $0 == last } ?? entries.first
        } else {
            let questions = set(id)?.questions ?? []
            selectedQuestionID = questions.first(where: { $0.id == last })?.id
                ?? questions.first(where: { !$0.status.isDone })?.id ?? questions.first?.id
        }
    }

    /// 导入页默认放到哪个文件夹：文件夹菜单里点的那个，否则是现在选中的东西所在的文件夹
    func takeImportFolder() -> UUID? {
        defer { importFolderHint = nil }
        return folder(importFolderHint)?.id ?? currentFolderID
    }

    /// 现在选中的笔记、白板或题集所在的文件夹：新建、导入时默认放到这里
    var currentFolderID: UUID? {
        if !hasOpenItem { return folder(selectedFolderID)?.id }
        let raw: UUID?
        if let id = selectedBoardID { raw = board(id)?.folderID }
        else if let id = selectedNoteID { raw = note(id)?.folderID }
        else { raw = set(selectedSetID)?.folderID }
        return folder(raw)?.id
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
        // 颜色按顺序轮着来，挨着的文件夹颜色不一样
        let colors = FolderColor.allCases
        let new = Folder(name: trimmed.isEmpty ? L("新文件夹") : trimmed, parentID: parent,
                         color: colors[folders.count % colors.count].rawValue)
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

    func setFolderColor(_ id: UUID, _ color: FolderColor) {
        guard let i = folders.firstIndex(where: { $0.id == id }), folders[i].color != color.rawValue else { return }
        folders[i].color = color.rawValue
    }

    /// 删除文件夹：里面的笔记、白板、题集和子文件夹移到上一级，不会删除任何内容
    func deleteFolder(_ id: UUID) {
        guard let f = folder(id) else { return }
        for i in folders.indices where folders[i].parentID == id { folders[i].parentID = f.parentID }
        for i in sets.indices where sets[i].folderID == id { sets[i].folderID = f.parentID }
        for i in notes.indices where notes[i].folderID == id { notes[i].folderID = f.parentID }
        for i in boards.indices where boards[i].folderID == id { boards[i].folderID = f.parentID }
        folders.removeAll { $0.id == id }
    }

    /// 上级文件夹不存在、或者互相嵌套成环的文件夹（只可能来自损坏的备份）放回最外层，里面的题集不会看不见。
    /// 旧版本的文件夹没有颜色：按先后轮着给一个，挨着的文件夹颜色不一样，以后也不会变
    func repairFolders() {
        if folders.contains(where: { $0.color == nil }) {
            let colors = FolderColor.allCases
            var colored = folders
            for i in colored.indices where colored[i].color == nil {
                colored[i].color = colors[i % colors.count].rawValue
            }
            folders = colored
        }
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

    /// 把一篇笔记、一块白板或一个题集移到某个文件夹（nil 为最外层）
    func moveItem(_ id: UUID, to folderID: UUID?) {
        if let i = notes.firstIndex(where: { $0.id == id }) {
            guard notes[i].folderID != folderID else { return }
            notes[i].folderID = folderID
        } else if let i = boards.firstIndex(where: { $0.id == id }) {
            guard boards[i].folderID != folderID else { return }
            boards[i].folderID = folderID
        } else {
            moveSet(id, to: folderID)
            return
        }
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

/// 同一个文件的写盘按排号的先后：后排的号写过了，先排的就不再写，旧数据不会盖掉新数据。
/// 也记着每个文件最后排的号写好没有，没改过的文件不用重写
final class SaveLedger: @unchecked Sendable {
    static let shared = SaveLedger()
    private let lock = NSLock()
    private var issued: [String: Int] = [:]
    private var written: [String: Int] = [:]
    /// 每个文件一把写盘锁：写大文件（尤其是 iCloud 里的）时，主线程排号、查状态不用等它写完
    private var fileLocks: [String: NSLock] = [:]

    func issue(_ url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        let next = (issued[url.path] ?? 0) + 1
        issued[url.path] = next
        return next
    }

    /// 排过号、还没写好（读进来以后没改过的不算）
    func hasPending(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let last = issued[url.path] else { return false }
        return written[url.path] != last
    }

    /// 同一个文件同一时间只有一处在写；写盘时只拿这个文件的锁，不挡住主线程排号
    func write(_ data: Data, to url: URL, generation: Int) {
        let fileLock: NSLock = {
            lock.lock(); defer { lock.unlock() }
            if let existing = fileLocks[url.path] { return existing }
            let created = NSLock()
            fileLocks[url.path] = created
            return created
        }()
        fileLock.lock(); defer { fileLock.unlock() }
        let latest: Int = { lock.lock(); defer { lock.unlock() }; return written[url.path] ?? 0 }()
        guard generation > latest else { return }
        if (try? DataLocation.write(data, to: url)) != nil {
            lock.lock(); defer { lock.unlock() }
            written[url.path] = max(written[url.path] ?? 0, generation)
        }
    }
}
