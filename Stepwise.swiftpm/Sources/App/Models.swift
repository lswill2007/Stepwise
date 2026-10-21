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
}

struct QuestionSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var requirement: String = ""
    var questions: [Question]

    var doneCount: Int { questions.filter { $0.status.isDone }.count }
}
