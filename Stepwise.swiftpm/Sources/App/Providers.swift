import Foundation

/// 三种接口格式覆盖了市面上绝大多数模型：国内厂商和聚合平台大多兼容 OpenAI 格式。
enum APIProtocol: String, Codable, CaseIterable, Identifiable {
    case openAI, anthropic, gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        }
    }
}

struct ProviderConfig: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var apiProtocol: APIProtocol
    var baseURL: String
    var model: String
    var presetModels: [String]
    var fetchedModels: [String] = []
    var note: String = ""
    var isCustom = false

    var apiKey: String { Keychain.get(id) ?? "" }
    var hasKey: Bool { !apiKey.isEmpty }

    /// 预设 + 拉取到的 + 当前填写的模型，去重后的完整列表
    var allModels: [String] {
        var seen = Set<String>()
        return ([model] + presetModels + fetchedModels).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

enum ProviderCatalog {
    /// 模型名称更新很快，这里只放常用的；在设置里点“获取模型列表”可拉取服务商当前提供的全部模型。
    static let presets: [ProviderConfig] = [
        ProviderConfig(
            id: "openai", name: "OpenAI", apiProtocol: .openAI,
            baseURL: "https://api.openai.com/v1", model: "gpt-5",
            presetModels: ["gpt-5", "gpt-5-mini", "o3", "gpt-4.1"],
            note: "platform.openai.com 获取 Key"),
        ProviderConfig(
            id: "anthropic", name: "Anthropic Claude", apiProtocol: .anthropic,
            baseURL: "https://api.anthropic.com", model: "claude-opus-5-5",
            presetModels: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"],
            note: "platform.claude.com 获取 Key"),
        ProviderConfig(
            id: "gemini", name: "Google Gemini", apiProtocol: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-pro",
            presetModels: ["gemini-2.5-pro", "gemini-2.5-flash"],
            note: "aistudio.google.com 获取 Key"),
        ProviderConfig(
            id: "deepseek", name: "DeepSeek", apiProtocol: .openAI,
            baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
            presetModels: ["deepseek-chat", "deepseek-reasoner"],
            note: "不支持图片：手写作答和图片题请换用其他模型"),
        ProviderConfig(
            id: "qwen", name: "通义千问", apiProtocol: .openAI,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-max",
            presetModels: ["qwen-max", "qwen-plus", "qwen-vl-max"],
            note: "阿里云百炼获取 Key；带 vl 的模型支持图片"),
        ProviderConfig(
            id: "moonshot", name: "Kimi (月之暗面)", apiProtocol: .openAI,
            baseURL: "https://api.moonshot.cn/v1", model: "kimi-latest",
            presetModels: ["kimi-latest", "moonshot-v1-128k-vision-preview"],
            note: "platform.moonshot.cn 获取 Key"),
        ProviderConfig(
            id: "zhipu", name: "智谱 GLM", apiProtocol: .openAI,
            baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4.6",
            presetModels: ["glm-4.6", "glm-4.5v"],
            note: "open.bigmodel.cn 获取 Key；带 v 的模型支持图片"),
        ProviderConfig(
            id: "doubao", name: "豆包 (火山方舟)", apiProtocol: .openAI,
            baseURL: "https://ark.cn-beijing.volces.com/api/v3", model: "",
            presetModels: [],
            note: "模型处填写方舟控制台里的模型 ID 或接入点 ID"),
        ProviderConfig(
            id: "xai", name: "xAI Grok", apiProtocol: .openAI,
            baseURL: "https://api.x.ai/v1", model: "grok-4",
            presetModels: ["grok-4"],
            note: "console.x.ai 获取 Key"),
        ProviderConfig(
            id: "openrouter", name: "OpenRouter (聚合)", apiProtocol: .openAI,
            baseURL: "https://openrouter.ai/api/v1", model: "",
            presetModels: [],
            note: "一个 Key 用几乎所有模型，点“获取模型列表”选择"),
        ProviderConfig(
            id: "siliconflow", name: "硅基流动 (聚合)", apiProtocol: .openAI,
            baseURL: "https://api.siliconflow.cn/v1", model: "",
            presetModels: [],
            note: "国内聚合平台，点“获取模型列表”选择")
    ]

    static func newCustom() -> ProviderConfig {
        ProviderConfig(
            id: "custom-" + UUID().uuidString, name: "自定义服务商", apiProtocol: .openAI,
            baseURL: "https://", model: "", presetModels: [],
            note: "任何兼容 OpenAI 接口的服务（含中转、本地部署）", isCustom: true)
    }
}
