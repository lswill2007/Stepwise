import Foundation

enum ChatRole: String, Codable {
    case user, assistant
}

/// 题目对话中每条消息的用途，决定界面上怎么显示。
enum MessageKind: String, Codable {
    case submission       // 学生提交的作答
    case verdictCorrect   // 批改：正确
    case verdictWrong     // 批改：错误
    case hintRequest      // 学生请求提示
    case hint             // 提示
    case solutionRequest  // 学生请求完整答案
    case solution         // 完整答案
    case chat             // 通过后的自由对话
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: ChatRole
    var kind: MessageKind
    /// 显示给用户的文字
    var text: String
    /// 实际发给模型的文字（为空则用 text）
    var prompt: String?
    var imageIDs: [String] = []
    var createdAt = Date()
    /// 这条回复里生成的新题
    var generatedQuestionIDs: [UUID] = []
    /// AI 回复用时（秒）和所用模型，用于显示“用时”
    var duration: Double?
    var model: String?
    /// 请求提示时学生补充的文字说明（卡在哪里、哪里不懂）
    var note: String?
    /// 提示的档次：1 思路方向，2 关键一步，3 起是下一步写什么
    var hintLevel: Int?
    /// hintLevel 为这个值：点“卡了”得到的点拨，不算提示的档次
    static let stuckHintLevel = 0
    var isStuckHelp: Bool { kind == .hint && hintLevel == Self.stuckHintLevel }
    /// hintLevel 为这个值：点“下一步”由 AI 直接写出的一步，也不算提示的档次
    static let nextStepHintLevel = -1
    var isNextStep: Bool { kind == .hint && hintLevel == Self.nextStepHintLevel }
    /// 按档次算的提示（思路 → 关键一步 → 下一步写什么）；旧版本的提示没有记档次，也算
    var isLeveledHint: Bool { kind == .hint && (hintLevel ?? 1) > 0 }
    /// 批改时标出的出错位置，画在手写区对应的那一行
    var marks: [InkMark]?
    /// 学生用橡皮擦掉的批注（marks 里的序号，从 0 开始）
    var erasedMarks: [Int]?
    /// 用笔圈出来提问时圈住的地方（手写区坐标）；问题和回答都记着，回答贴在页边
    var region: InkRegion?
    /// 手写图片由识图模型（Haiku）逐行转写出的文字；有了它，检查、提示只发文字，不再发手写图片
    var transcript: String?
    /// 对某条 AI 回复的追问（有疑问、没学过）：问题和回答都记着是针对哪一条，回答贴在页边
    var about: ReplyFollowUp?
}

/// 对一条 AI 回复（检查反馈、提示、下一步、完整答案……）追问
struct ReplyFollowUp: Codable, Equatable {
    enum Kind: String, Codable {
        /// 直接写下哪里有疑问
        case doubt
        /// 里面有还没学过的知识点：换成学过的方法重讲
        case unlearned
    }
    /// 被追问的那条回复
    var id: UUID
    var kind: Kind
}

/// 批改标出的一处错误：第几行（手写区的横线行，从 1 开始）、一句短评
struct InkMark: Codable, Equatable {
    var line: Int
    var note: String
}

/// 手写区里的一块地方
struct InkRegion: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

enum QuestionStatus: String, Codable {
    case todo, wrong, passed, revealed

    /// 已通过（做对或已看答案），可以继续对话
    var isDone: Bool { self == .passed || self == .revealed }
}

struct Question: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var content: String
    var referenceAnswer: String?
    var imageIDs: [String] = []
    var status: QuestionStatus = .todo
    var draftAnswer: String = ""
    var hintCount = 0
    var messages: [ChatMessage] = []
    var isGenerated = false

    // 以下字段都是可选的：旧版本保存的数据里没有它们，也能正常读取

    /// 加入错题本的时间；nil 表示不在错题本里
    var starredAt: Date?
    /// 错题复习进行到第几轮（每检查一次或请求一次提示算一轮）；nil 表示没有在复习
    var reviewRounds: Int?
    /// 重新练习之前的作答记录（每次重新练习保存一份）
    var previousAttempts: [[ChatMessage]]?
    /// AI 出的新题：原题的内容和作答记录，批改新题时参考，更容易发现同样的问题
    var originNote: String?
    /// 没有参考答案的题，由 AI 在后台预先求解的答案（学生看不到）。批改时只需对答案，更快更准
    var aiAnswer: String?

    var isStarred: Bool { starredAt != nil }
}

/// 左侧资料库的分级文件夹：文件夹里可以放笔记、白板、题集，也可以再放文件夹
struct Folder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// 上一级文件夹；nil 表示最外层
    var parentID: UUID?
    var collapsed = false
    /// 文件夹的颜色（FolderColor 的 rawValue）；旧数据没有，按 id 挑一个，每次都一样
    var color: String?

    var tint: FolderColor {
        if let color, let c = FolderColor(rawValue: color) { return c }
        let sum = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 + Int($1) } }
        return FolderColor.allCases[sum % FolderColor.allCases.count]
    }
}

/// 文件夹可选的颜色：左栏里每个文件夹画成这个颜色的一条圆角条
enum FolderColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, cyan, blue, indigo, purple, pink, gray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: return L("红色")
        case .orange: return L("橙色")
        case .yellow: return L("黄色")
        case .green: return L("绿色")
        case .teal: return L("青绿色")
        case .cyan: return L("天蓝色")
        case .blue: return L("蓝色")
        case .indigo: return L("靛蓝色")
        case .purple: return L("紫色")
        case .pink: return L("粉色")
        case .gray: return L("灰色")
        }
    }
}

/// 资料库里的一项：题集、笔记或白板，都可以放进任意一个文件夹
enum LibraryItem: Identifiable {
    case set(QuestionSet)
    case note(NoteDoc)
    case board(Whiteboard)

    var id: UUID {
        switch self {
        case .set(let s): return s.id
        case .note(let n): return n.id
        case .board(let b): return b.id
        }
    }

    var folderID: UUID? {
        switch self {
        case .set(let s): return s.folderID
        case .note(let n): return n.folderID
        case .board(let b): return b.folderID
        }
    }

    var createdAt: Date {
        switch self {
        case .set(let s): return s.createdAt
        case .note(let n): return n.createdAt
        case .board(let b): return b.createdAt
        }
    }

    var title: String {
        switch self {
        case .set(let s): return s.title
        case .note(let n): return n.title
        case .board(let b): return b.title
        }
    }

    /// 拖放时带的文字：“set:…”“note:…”“board:…”
    var dragKey: String {
        switch self {
        case .set(let s): return "set:\(s.id.uuidString)"
        case .note(let n): return "note:\(n.id.uuidString)"
        case .board(let b): return "board:\(b.id.uuidString)"
        }
    }
}

/// 做完一道题之后的快捷操作，可以在设置里自定义
struct FollowUpAction: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var prompt: String
    /// 会出新题：用“出新题模型”请求，出的题加入题目列表
    var makesQuestion = false

    static let defaults: [FollowUpAction] = [
        FollowUpAction(title: L("出一道类似的新题"), prompt: L("请出一道考查相同知识点的类似新题。"), makesQuestion: true),
        FollowUpAction(title: L("出一道更难的题"), prompt: L("请出一道考查相同知识点、但更难一些的新题。"), makesQuestion: true),
        FollowUpAction(title: L("总结做题技巧"), prompt: L("请总结这道题用到的做题技巧和通用方法，以后遇到类似的题应该怎么想？")),
        FollowUpAction(title: L("讲讲解题思路"), prompt: L("请从头讲一下这道题的解题思路：拿到题目时先注意什么，突破口在哪里？")),
        FollowUpAction(title: L("还有别的解法吗"), prompt: L("这道题还有其他解法吗？请和原来的方法比较一下。")),
        FollowUpAction(title: L("常见易错点"), prompt: L("这类题有哪些常见的易错点？"))
    ]
}

struct QuestionSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var requirement: String = ""
    var questions: [Question]
    /// 所在的文件夹；nil 表示放在最外层（旧版本的数据没有这个字段）
    var folderID: UUID?
    /// 笔记里的练习题也存成一个题集（借用做题、批改的全部功能），记着属于哪篇笔记；这种题集不显示在左侧题集列表里
    var noteID: UUID?

    var doneCount: Int { questions.filter { $0.status.isDone }.count }
    var passedCount: Int { questions.filter { $0.status == .passed }.count }
    var revealedCount: Int { questions.filter { $0.status == .revealed }.count }
}

/// 笔记模式：导入 PDF 后按要求生成的可编辑文档
/// 根据别的题出的新题，题号后面加的记号（“3-新1”）：新出的题按界面语言，认题号时两种都认
enum GeneratedLabel {
    static var suffix: String { L("-新") }
    static let allSuffixes = ["-新", "-new"]

    static func isGenerated(_ label: String, from base: String) -> Bool {
        allSuffixes.contains { label.hasPrefix(base + $0) }
    }

    /// “3-新1” → “3”
    static func base(of label: String) -> String? {
        for s in allSuffixes {
            if let r = label.range(of: s, options: .backwards) { return String(label[..<r.lowerBound]) }
        }
        return nil
    }
}

struct NoteDoc: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    /// 来源文件名和生成要求，显示在标题下面
    var sourceName = ""
    var prompt = ""
    /// 笔记里的练习题所在的题集（不显示在题集列表里）
    var exerciseSetID: UUID
    var blocks: [NoteBlock] = []
    /// 用笔圈出来问的批注，写在页边（旧数据没有）
    var comments: [NoteComment]?
    /// 所在的文件夹；做题时会到同一个文件夹里找相关的笔记（旧数据没有，放在最外层）
    var folderID: UUID?
    /// 排版用的纸宽。旧笔记没有，按 460 排；新笔记用更宽的纸，公式和表格少换行。
    /// 一篇笔记的纸宽不能改，否则涂鸦、圈出来问的位置会和文字对不上
    var paperWidth: Double?
    /// 整页涂鸦（空白处的笔迹）对应的排版：每一块的上下边（纸的坐标，按块 id）。
    /// 块变高、插入、挪动时，空白处的笔迹跟着块挪（旧数据没有）
    var pageInkAnchors: [String: [Double]]?

    static let legacyPaperWidth: Double = 460
    static let currentPaperWidth: Double = 540
    var paper: Double { paperWidth ?? Self.legacyPaperWidth }
}

/// 笔记页边的一条批注：用笔圈住一段，问一句，AI 的回答像小字写在页边
struct NoteComment: Codable, Identifiable, Equatable {
    var id = UUID()
    /// 圈在哪一块、哪个位置（这一块里的坐标）
    var blockID: UUID
    var region: InkRegion
    var question: String
    var answer = ""
    /// 收起成一个小对话图标
    var minimized = false
    /// 已经记到笔记里了
    var savedToNote = false
    var createdAt = Date()
}

/// 笔记里的一块
struct NoteBlock: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text       // 笔记正文（Markdown + LaTeX），AI 生成或自己写的
        case exercise   // 练习题：题目、手写区、批改都用做题页的
        case answer     // 选中文字提问后 AI 的回答
        case canvas     // 手写块：和笔记一样宽的一块空白纸，写到底自动加长（笔迹按块 id 存）
    }

    var id = UUID()
    var kind: Kind
    var text = ""
    /// 练习题在题集里的 id
    var questionID: UUID?
    /// 提问时选中的文字和问题
    var quote: String?
    var question: String?
    /// 手写块的纸：点阵、方格或空白（旧数据没有，按点阵）
    var paper: PaperStyle?
    /// 练习题折起来了：只露出一行题目，看笔记时不占地方
    var collapsed: Bool?
}

/// 空白纸的样式：白板和笔记里的手写块用。纸色不变，只画点或格子
enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case dots, grid, blank

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dots: return L("点阵")
        case .grid: return L("方格")
        case .blank: return L("空白")
        }
    }

    var icon: String {
        switch self {
        case .dots: return "circle.grid.3x3"
        case .grid: return "squareshape.split.3x3"
        case .blank: return "square"
        }
    }

    /// 点和格子的间距（纸的坐标）
    static let spacing: CGFloat = 28
}

/// AI 白板：一大张可以随便写的纸。写下题目和解答，框选一部分发给 AI 检查，回复以便签浮在画布上
struct Whiteboard: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var paper: PaperStyle = .dots
    /// AI 的回复（便签），按发出的先后
    var notes: [BoardNote] = []
    /// 隐藏所有便签（随时可以再显示）
    var notesHidden = false
    /// 所在的文件夹；nil 表示放在最外层（旧数据没有）
    var folderID: UUID?
}

/// 白板上的一组便签：框选一处发给 AI，回复写在一张便签上，指出的问题按行号在旁边列出
struct BoardNote: Codable, Identifiable, Equatable {
    var id = UUID()
    /// 框住的地方（画布坐标）
    var region: InkRegion
    /// 便签左上角（画布坐标），可以拖动
    var x: Double
    var y: Double
    /// 自己问的问题；nil 表示“检查”
    var question: String?
    /// 检查的结论：correct / wrong / unsure
    var verdict: String?
    var text = ""
    var comments: [BoardComment] = []
    /// 收起成一个小图标
    var minimized = false
    var createdAt = Date()
    var model: String?
    /// 拖右下角放大、缩小的倍数（连字一起）；nil 为原来的大小
    var scale: Double?
}

/// 便签里指出的一处：第几行（发给 AI 的图片左边印的行号）和那一行在画布上的位置
struct BoardComment: Codable, Equatable {
    var line: Int
    var note: String
    var rect: InkRegion?
}
