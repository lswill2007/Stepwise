import Foundation

/// 界面语言：系统语言是中文时显示中文，其他语言显示英文
enum UILanguage {
    static var isEnglish: Bool {
        !(Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")
    }
}

/// AI 回答（批改、提示、笔记、周报）和发给 AI 的提示词用的语言
enum AILanguage: String, CaseIterable, Identifiable {
    /// 跟随界面语言
    case auto, chinese, english

    var id: String { rawValue }

    static let storageKey = "aiLanguage"

    static var current: AILanguage {
        AILanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .auto
    }

    static var isEnglish: Bool {
        switch current {
        case .auto: return UILanguage.isEnglish
        case .chinese: return false
        case .english: return true
        }
    }

    var title: String {
        switch self {
        case .auto: return String(localized: "跟随界面语言")
        case .chinese: return "中文"
        case .english: return "English"
        }
    }
}

extension Tutor {
    /// 按 AI 回答语言选中文或英文的提示词
    static func pick(_ zh: String, _ en: String) -> String { AILanguage.isEnglish ? en : zh }
}

/// 界面文字：按界面语言查翻译（key 就是代码里的中文原文，en.lproj 里是英文）。
/// 用在不是直接写在 Text / Button 里的文字上（存在变量里的、错误提示、拼起来的字符串）
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}
