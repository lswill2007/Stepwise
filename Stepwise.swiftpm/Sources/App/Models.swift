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

    var isStarred: Bool { starredAt != nil }
}

/// 做完一道题之后的快捷操作，可以在设置里自定义
struct FollowUpAction: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var prompt: String
    /// 会出新题：用“出新题模型”请求，出的题加入题目列表
    var makesQuestion = false

    static let defaults: [FollowUpAction] = [
        FollowUpAction(title: "出一道类似的新题", prompt: "请出一道考查相同知识点的类似新题。", makesQuestion: true),
        FollowUpAction(title: "出一道更难的题", prompt: "请出一道考查相同知识点、但更难一些的新题。", makesQuestion: true),
        FollowUpAction(title: "总结做题技巧", prompt: "请总结这道题用到的做题技巧和通用方法，以后遇到类似的题应该怎么想？"),
        FollowUpAction(title: "讲讲解题思路", prompt: "请从头讲一下这道题的解题思路：拿到题目时先注意什么，突破口在哪里？"),
        FollowUpAction(title: "还有别的解法吗", prompt: "这道题还有其他解法吗？请和原来的方法比较一下。"),
        FollowUpAction(title: "常见易错点", prompt: "这类题有哪些常见的易错点？")
    ]
}

struct QuestionSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var requirement: String = ""
    var questions: [Question]

    var doneCount: Int { questions.filter { $0.status.isDone }.count }
}
