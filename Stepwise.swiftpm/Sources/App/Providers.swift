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
    /// 常用模型（做题时右上角菜单里只显示这些）。可选类型：旧版本保存的配置里没有这个字段也能读取
    var favoriteModels: [String]?

    var apiKey: String { Keychain.get(id) ?? "" }
    var hasKey: Bool { !apiKey.isEmpty }

    /// 预设 + 拉取到的 + 当前填写的模型，去重后的完整列表
    var allModels: [String] {
        var seen = Set<String>()
        return ([model] + (favoriteModels ?? []) + presetModels + fetchedModels).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 切换菜单里显示的模型：当前模型 + 常用模型；还没设常用时用预设模型
    var menuModels: [String] {
        let favorites = favoriteModels ?? []
        var seen = Set<String>()
        return ([model] + (favorites.isEmpty ? presetModels : favorites)).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 聚合平台 / 中转：一个 Key 调用多家模型，快速批改参数要按模型名判断
    var isAggregator: Bool {
        isCustom || ProviderCatalog.aggregatorIDs.contains(id)
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
            note: "国内聚合平台，点“获取模型列表”选择"),
        ProviderConfig(
            id: "aihubmix", name: "AIHubMix (聚合)", apiProtocol: .openAI,
            baseURL: "https://aihubmix.com/v1", model: "",
            presetModels: [],
            note: "一个 Key 调用 GPT、Claude、Gemini、DeepSeek 等，点“获取模型列表”选择"),
        ProviderConfig(
            id: "302ai", name: "302.AI (聚合)", apiProtocol: .openAI,
            baseURL: "https://api.302.ai/v1", model: "",
            presetModels: [],
            note: "聚合平台，点“获取模型列表”选择"),
        ProviderConfig(
            id: "dmxapi", name: "DMXAPI (聚合)", apiProtocol: .openAI,
            baseURL: "https://www.dmxapi.cn/v1", model: "",
            presetModels: [],
            note: "聚合平台，点“获取模型列表”选择；接口地址以平台后台为准")
    ]

    /// 一个 Key 调用多家模型的平台
    static let aggregatorIDs: Set<String> = ["openrouter", "siliconflow", "aihubmix", "302ai", "dmxapi"]

    static func newCustom() -> ProviderConfig {
        ProviderConfig(
            id: "custom-" + UUID().uuidString, name: "自定义服务商", apiProtocol: .openAI,
            baseURL: "https://", model: "", presetModels: [],
            note: "任何兼容 OpenAI 接口的服务：其他聚合平台、OneAPI / NewAPI 中转、本地部署等", isCustom: true)
    }
}

/// 根据模型名称判断厂商、能否看图等（聚合平台里的模型名称各不相同，只能按名称推测）
enum ModelInfo {
    enum Family: String, CaseIterable {
        case openai = "OpenAI"
        case anthropic = "Claude"
        case google = "Gemini"
        case deepseek = "DeepSeek"
        case qwen = "通义千问"
        case zhipu = "智谱 GLM"
        case moonshot = "Kimi"
        case xai = "Grok"
        case doubao = "豆包"
        case meta = "Llama"
        case mistral = "Mistral"
        case other = "其他"
    }

    /// 去掉 “openai/”“anthropic/” 这类厂商前缀后的小写名称
    static func baseName(_ model: String) -> String {
        let lower = model.lowercased()
        return lower.split(separator: "/").last.map(String.init) ?? lower
    }

    static func family(_ model: String) -> Family {
        let full = model.lowercased()
        let name = baseName(model)
        func has(_ keys: [String]) -> Bool { keys.contains { name.hasPrefix($0) || full.hasPrefix($0 + "/") } }
        if has(["gpt", "o1", "o3", "o4", "chatgpt", "openai", "codex"]) { return .openai }
        if has(["claude", "anthropic"]) { return .anthropic }
        if has(["gemini", "gemma", "google"]) { return .google }
        if has(["deepseek"]) { return .deepseek }
        if has(["qwen", "qwq", "qvq", "alibaba"]) { return .qwen }
        if has(["glm", "chatglm", "zhipu", "thudm"]) { return .zhipu }
        if has(["kimi", "moonshot"]) { return .moonshot }
        if has(["grok", "x-ai", "xai"]) { return .xai }
        if has(["doubao", "bytedance"]) { return .doubao }
        if has(["llama", "meta"]) { return .meta }
        if has(["mistral", "mixtral", "codestral", "pixtral", "magistral"]) { return .mistral }
        return .other
    }

    /// 绘图、语音、向量、审核等不能用来做题的模型
    static func isNonChat(_ model: String) -> Bool {
        let name = baseName(model)
        let keys = ["embedding", "embed", "tts", "whisper", "dall-e", "dalle", "image", "imagen", "midjourney", "mj_", "flux",
                    "stable-diffusion", "sd3", "sdxl", "rerank", "moderation", "speech", "audio", "realtime", "transcribe",
                    "video", "veo", "sora", "kling", "suno", "music", "bge-", "-search-preview"]
        return keys.contains { name.contains($0) }
    }

    /// 可能支持看图（手写作答、图片题需要）
    static func likelyVision(_ model: String) -> Bool {
        let name = baseName(model)
        if name.contains("vision") || name.contains("-vl") || name.contains("vl-") || name.hasSuffix("vl")
            || name.contains("4v") || name.contains("5v") || name.contains("qvq") { return true }
        switch family(model) {
        case .anthropic: return !name.contains("instant") && !name.hasPrefix("claude-2")
        case .google: return name.hasPrefix("gemini")
        case .openai:
            return name.hasPrefix("gpt-4o") || name.hasPrefix("gpt-4.1") || name.hasPrefix("gpt-4-turbo")
                || name.hasPrefix("gpt-5") || name.hasPrefix("o3") || name.hasPrefix("o4") || name.hasPrefix("chatgpt-4o")
        case .xai: return name.hasPrefix("grok-4")
        case .meta: return name.contains("llama-4") || name.contains("llama4")
        case .doubao: return name.contains("seed") || name.contains("vision")
        case .moonshot: return name.contains("vision") || name.contains("latest")
        default: return false
        }
    }
}
