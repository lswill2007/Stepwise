import Foundation

/// 三种接口格式覆盖了市面上绝大多数模型：国内厂商和聚合平台大多兼容 OpenAI 格式。
enum APIProtocol: String, Codable, CaseIterable, Identifiable {
    case openAI, anthropic, gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return L("OpenAI 兼容")
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
            note: L("platform.openai.com 获取 Key")),
        ProviderConfig(
            id: "anthropic", name: "Anthropic Claude", apiProtocol: .anthropic,
            baseURL: "https://api.anthropic.com", model: "claude-opus-5-5",
            presetModels: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"],
            note: L("platform.claude.com 获取 Key")),
        ProviderConfig(
            id: "gemini", name: "Google Gemini", apiProtocol: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-pro",
            presetModels: ["gemini-2.5-pro", "gemini-2.5-flash"],
            note: L("aistudio.google.com 获取 Key")),
        ProviderConfig(
            id: "deepseek", name: "DeepSeek", apiProtocol: .openAI,
            baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
            presetModels: ["deepseek-chat", "deepseek-reasoner"],
            note: L("不支持图片：手写作答和图片题请换用其他模型")),
        ProviderConfig(
            id: "qwen", name: L("通义千问"), apiProtocol: .openAI,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-max",
            presetModels: ["qwen-max", "qwen-plus", "qwen-vl-max"],
            note: L("阿里云百炼获取 Key；带 vl 的模型支持图片")),
        ProviderConfig(
            id: "moonshot", name: L("Kimi (月之暗面)"), apiProtocol: .openAI,
            baseURL: "https://api.moonshot.cn/v1", model: "kimi-latest",
            presetModels: ["kimi-latest", "moonshot-v1-128k-vision-preview"],
            note: L("platform.moonshot.cn 获取 Key")),
        ProviderConfig(
            id: "zhipu", name: L("智谱 GLM"), apiProtocol: .openAI,
            baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4.6",
            presetModels: ["glm-4.6", "glm-4.5v"],
            note: L("open.bigmodel.cn 获取 Key；带 v 的模型支持图片")),
        ProviderConfig(
            id: "doubao", name: L("豆包 (火山方舟)"), apiProtocol: .openAI,
            baseURL: "https://ark.cn-beijing.volces.com/api/v3", model: "",
            presetModels: [],
            note: L("模型处填写方舟控制台里的模型 ID 或接入点 ID")),
        ProviderConfig(
            id: "xai", name: "xAI Grok", apiProtocol: .openAI,
            baseURL: "https://api.x.ai/v1", model: "grok-4",
            presetModels: ["grok-4"],
            note: L("console.x.ai 获取 Key")),
        ProviderConfig(
            id: "openrouter", name: L("OpenRouter (聚合)"), apiProtocol: .openAI,
            baseURL: "https://openrouter.ai/api/v1", model: "",
            presetModels: [],
            note: L("一个 Key 用几乎所有模型，点“获取模型列表”选择")),
        ProviderConfig(
            id: "siliconflow", name: L("硅基流动 (聚合)"), apiProtocol: .openAI,
            baseURL: "https://api.siliconflow.cn/v1", model: "",
            presetModels: [],
            note: L("国内聚合平台，点“获取模型列表”选择")),
        ProviderConfig(
            id: "aihubmix", name: L("AIHubMix (聚合)"), apiProtocol: .openAI,
            baseURL: "https://aihubmix.com/v1", model: "",
            presetModels: [],
            note: L("一个 Key 调用 GPT、Claude、Gemini、DeepSeek 等，点“获取模型列表”选择")),
        ProviderConfig(
            id: "302ai", name: L("302.AI (聚合)"), apiProtocol: .openAI,
            baseURL: "https://api.302.ai/v1", model: "",
            presetModels: [],
            note: L("聚合平台，点“获取模型列表”选择")),
        ProviderConfig(
            id: "dmxapi", name: L("DMXAPI (聚合)"), apiProtocol: .openAI,
            baseURL: "https://www.dmxapi.cn/v1", model: "",
            presetModels: [],
            note: L("聚合平台，点“获取模型列表”选择；接口地址以平台后台为准"))
    ]

    /// 英文界面里国际服务商排前面，国内服务商放后面；自定义的放最后。中文界面保持原来的顺序
    static func displayOrder(_ list: [ProviderConfig]) -> [ProviderConfig] {
        guard UILanguage.isEnglish else { return list }
        let order = ["openai", "anthropic", "gemini", "openrouter", "xai", "deepseek", "aihubmix", "302ai",
                     "qwen", "moonshot", "zhipu", "doubao", "siliconflow", "dmxapi"]
        func rank(_ p: ProviderConfig) -> Int { order.firstIndex(of: p.id) ?? order.count }
        return list.enumerated().sorted { a, b in
            rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
        }.map(\.element)
    }

    /// 一个 Key 调用多家模型的平台
    static let aggregatorIDs: Set<String> = ["openrouter", "siliconflow", "aihubmix", "302ai", "dmxapi"]

    static func newCustom() -> ProviderConfig {
        ProviderConfig(
            id: "custom-" + UUID().uuidString, name: L("自定义服务商"), apiProtocol: .openAI,
            baseURL: "https://", model: "", presetModels: [],
            note: L("任何兼容 OpenAI 接口的服务：其他聚合平台、OneAPI / NewAPI 中转、本地部署等"), isCustom: true)
    }
}

/// 搭配好的模型组合：一次设好当前模型、检查与提示、出新题（也用来预先求解）和整理笔记四个模型。
/// 模型名称已对过 Anthropic 官方、AIHubMix 和 OpenRouter 的模型列表（2026-11）
struct ModelCombo: Identifiable, Equatable {
    let id: String
    /// 用 Anthropic 官方的模型名称写；在其他服务商那里用 `modelID(_:for:)` 换成它的写法
    let main: String
    let grading: String
    let question: String
    let note: String

    var title: String {
        id == "advanced" ? L("高级") : L("中级")
    }

    var summary: String {
        id == "advanced"
            ? L("最准：讲解、检查、整理笔记用 Claude Opus 5.5，出新题和预先求解答案用推理最强的 Claude Fable 5.2")
            : L("又快又准：讲解、检查、整理笔记用 Claude Sonnet 5.5，出新题和预先求解答案用 Claude Opus 5.5")
    }

    /// 检查答案不用 Haiku 这类轻量模型：数学题（尤其微积分）容易改错。FrontierMath 第 4 档（2026-11）：
    /// Haiku 5.5 约 46%，Sonnet 5.5 约 80%，Opus 5.5 约 95%。
    /// 出新题模型也用来在后台预先求解没有参考答案的题，检查时拿它对答案，所以选更强的一档
    static let advanced = ModelCombo(id: "advanced", main: "claude-opus-5-5", grading: "claude-opus-5-5",
                                     question: "claude-fable-5-2", note: "claude-opus-5-5")
    static let intermediate = ModelCombo(id: "intermediate", main: "claude-sonnet-5-5", grading: "claude-sonnet-5-5",
                                         question: "claude-opus-5-5", note: "claude-sonnet-5-5")
    static let all = [advanced, intermediate]

    /// 能用这些组合的服务商（按优先顺序）：只放模型名称核对过的
    static let providerIDs = ["anthropic", "aihubmix", "openrouter"]

    /// 同一个模型在不同服务商那里的名称：OpenRouter 写成 anthropic/claude-opus-5.5，Anthropic 官方和 AIHubMix 一样
    static func modelID(_ model: String, for providerID: String) -> String {
        guard providerID == "openrouter" else { return model }
        // claude-opus-5-5 → anthropic/claude-opus-5.5（只把版本号之间的“-”换成“.”）
        let fixed = model.replacingOccurrences(of: #"-(\d+)-(\d+)$"#, with: "-$1.$2", options: .regularExpression)
        return "anthropic/" + fixed
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

        /// 显示用的名称（按界面语言）
        var title: String { L(rawValue) }
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

    /// 可能是反应快的轻量模型（批改用）：flash、haiku、mini 之类。推理（思考）模型不算
    static func likelyFast(_ model: String) -> Bool {
        let name = baseName(model)
        guard !isNonChat(model) else { return false }
        // o 系列是推理模型，名字带 mini 也要先思考很久
        if family(model) == .openai && name.first == "o" { return false }
        let slow = ["thinking", "reasoner", "-pro", "opus", "deep-research", "-max", "qwq", "qvq", "-r1"]
        if slow.contains(where: { name.contains($0) }) { return false }
        let fast = ["flash", "haiku", "mini", "nano", "lite", "turbo", "-fast", "air", "-8b", "-7b", "-small", "instant", "-speed"]
        return fast.contains { name.contains($0) }
    }

    /// 检查作答的推荐顺序：逻辑推理强、能看图的旗舰模型（检查要准，宁可慢一点）。
    /// 名称对过 Anthropic、AIHubMix、OpenRouter 的模型列表（2026-11）；前面的数学推理更强
    private static let recommendedChecking = [
        "claude-opus-5-5", "claude-sonnet-5-5", "gpt-6.2-astra", "gemini-4-neon", "gpt-6.2-sol", "gemini-4-argon",
        "gemini-4-carbon", "claude-fable-5", "claude-opus-5", "claude-sonnet-5", "gpt-6", "gemini-4", "gemini-3.1-pro",
        "gemini-3-pro", "claude-opus-4", "claude-sonnet-4-6", "gpt-5", "gemini-2.5-pro", "o3"
    ]

    /// 轻量模型：快，但数学题（尤其微积分）容易改错，不推荐用来检查
    static func isLight(_ model: String) -> Bool {
        let name = baseName(model)
        let light = ["haiku", "flash", "-mini", "nano", "lite", "-fast", "turbo", "air", "-8b", "-7b", "-small", "instant",
                     "-speed", "hydrogen", "luna", "terra"]
        return light.contains { name.contains($0) }
    }

    /// 适合检查作答：推理强、能看图；分数越高越推荐，nil 表示不推荐
    static func checkingScore(_ model: String) -> Int? {
        guard !isNonChat(model), !isLight(model), likelyVision(model) else { return nil }
        let name = baseName(model).replacingOccurrences(of: ".", with: "-")
        guard let index = recommendedChecking.firstIndex(where: { name.contains($0.replacingOccurrences(of: ".", with: "-")) }) else {
            return nil
        }
        var score = 1000 - index * 10
        // 带日期、preview 的通常是旧快照
        if name.contains("preview") || name.range(of: #"\d{6,}"#, options: .regularExpression) != nil { score -= 3 }
        return score
    }

    /// 整理长资料（生成笔记）的推荐顺序：上下文长、理解和归纳能力强；能看图的靠前（公式多的 PDF 按图片发送）
    private static let recommendedLongContext = [
        "claude-opus-5", "claude-sonnet-5", "gemini-3-pro", "gemini-2.5-pro", "claude-sonnet-4-5", "claude-opus-4", "claude-sonnet-4", "gpt-5",
        "gpt-4.1", "qwen3-vl-plus", "qwen-vl-max", "doubao-seed-1.6", "glm-4.5v", "kimi-k2", "kimi-latest",
        "qwen3-max", "qwen-long", "deepseek-v3", "deepseek-chat"
    ]

    /// 适合整理长资料生成笔记；分数越高越推荐，nil 表示不在推荐里
    static func longContextScore(_ model: String) -> Int? {
        guard !isNonChat(model) else { return nil }
        let name = baseName(model).replacingOccurrences(of: ".", with: "-")
        // 名字里写明上下文很长的（moonshot-v1-128k 等）也推荐，排在上面这些后面
        let longMarkers = ["-128k", "-200k", "-256k", "-1m", "long"]
        let index = recommendedLongContext.firstIndex(where: { name.contains($0.replacingOccurrences(of: ".", with: "-")) })
            ?? (longMarkers.contains(where: name.contains) ? recommendedLongContext.count : nil)
        guard let index else { return nil }
        // 轻量版本（gpt-5-mini、flash 等）整理长资料不够稳。注意 gemini 里本身就有 “mini”，要匹配 “-mini”
        if ["-mini", "nano", "lite", "flash", "-fast"].contains(where: name.contains) { return nil }
        var score = 1000 - index * 10
        if likelyVision(model) { score += 3 }
        if name.contains("preview") || name.range(of: #"\d{6,}"#, options: .regularExpression) != nil { score -= 3 }
        return score
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
            return name.hasPrefix("gpt-6") || name.hasPrefix("gpt-4o") || name.hasPrefix("gpt-4.1") || name.hasPrefix("gpt-4-turbo")
                || name.hasPrefix("gpt-5") || name.hasPrefix("o3") || name.hasPrefix("o4") || name.hasPrefix("chatgpt-4o")
        case .xai: return name.hasPrefix("grok-4")
        case .meta: return name.contains("llama-4") || name.contains("llama4")
        case .doubao: return name.contains("seed") || name.contains("vision")
        case .moonshot: return name.contains("vision") || name.contains("latest")
        default: return false
        }
    }
}
