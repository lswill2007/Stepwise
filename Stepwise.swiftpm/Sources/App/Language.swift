import Foundation

/// 界面语言：系统语言是中文时显示中文（繁体系统显示繁体，用香港用词），其他语言显示英文
enum UILanguage {
    static var isEnglish: Bool {
        !(Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")
    }

    /// 系统语言是繁体中文（香港、台湾、澳门）
    static var isTraditional: Bool {
        Bundle.main.preferredLocalizations.first == "zh-Hant"
    }
}

/// AI 回答（批改、提示、笔记、周报）和发给 AI 的提示词用的语言
enum AILanguage: String, CaseIterable, Identifiable {
    /// 跟随界面语言（繁体界面默认用粤语）
    case auto, chinese, cantonese, english

    var id: String { rawValue }

    static let storageKey = "aiLanguage"

    static var current: AILanguage {
        AILanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .auto
    }

    static var isEnglish: Bool {
        switch current {
        case .auto: return UILanguage.isEnglish
        case .chinese, .cantonese: return false
        case .english: return true
        }
    }

    /// 用粤语回答（给香港 DSE 学生）：用的还是中文那套提示词，另外在系统提示词最后加上粤语要求
    static var isCantonese: Bool {
        switch current {
        case .auto: return UILanguage.isTraditional
        case .cantonese: return true
        case .chinese, .english: return false
        }
    }

    /// 粤语的要求：讲解用粤语口语，答案和笔记用 DSE 的繁体书面语，抄录原文保持原样
    static let cantoneseRule = """


    【回答語言（優先於前面「使用中文」的要求）】
    學生喺香港讀書、準備 DSE。請全部用繁體字同香港常用詞，學科術語用香港中學同 DSE 課程嘅中文叫法。
    - 批改、提示、講解、追問、對話、學習報告：用自然嘅香港粵語口語，好似補習老師同學生傾偈咁（例如「呢度」「係」「唔使」「咁樣」「即係」），句子要短、易明。
    - 完整答案、示範解題步驟、新出嘅題目、筆記入面嘅定義、定理同結論：用 DSE 試卷要求嘅規範書面語（繁體），等學生可以直接照住寫入試卷。呢啲部分一個粵語口語字都唔可以有：唔好用「喺、嘅、我哋、佢、係、唔、咗、嚟、睇、俾、畀、啲、咁、呢」，要寫「在、的、我們、它、是、不、了、來、看、給、些、這樣、這」。如果想用口語解釋，放喺書面語部分之前或者之後，單獨成段。
    - 學生要求睇完整答案時，要將每一小題完整解答、寫出最終答案，唔好只俾提示，亦唔好叫學生自己先試。
    - 抄錄題目原文（拆分題目、引用原題）時保持原文，唔好翻譯，亦唔好轉換字體。
    - 程式要求嘅標籤（例如 <verdict>、<question>、<note>）照原樣輸出，唔好翻譯；數學式照用 LaTeX。
    """

    /// 发给 AI 的系统提示词：选了粤语时在最后加上粤语要求
    static func decorate(system: String) -> String {
        isCantonese && !system.isEmpty ? system + cantoneseRule : system
    }

    var title: String {
        switch self {
        case .auto: return String(localized: "跟随界面语言")
        case .chinese: return String(localized: "简体中文")
        case .cantonese: return String(localized: "粤语（DSE）")
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
