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
    /// 预设服务商；每个服务商的低中高三档模型也放进它的预设模型里
    static let presets: [ProviderConfig] = basePresets.map { preset in
        guard let t = ModelTiers.forProvider(preset.id) else { return preset }
        var p = preset
        var seen = Set<String>()
        p.presetModels = ([t.high, t.mid, t.low] + preset.presetModels).filter { seen.insert($0).inserted }
        return p
    }

    private static let basePresets: [ProviderConfig] = [
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
            note: L("只有 deepseek-flash 能看图；deepseek-chat、deepseek-reasoner 不支持图片")),
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
            note: L("中国大陆需要开 VPN 才能连上，不开 VPN 可以改用通义千问或豆包。一个 Key 调用 GPT、Claude、Gemini、DeepSeek 等，点“获取模型列表”选择")),
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

/// 每个服务商能看图的模型分低、中、高三档：
/// - 低：只用来识别图像（手写作答、拍照导入的题目），快又便宜，不用来判断对错
/// - 中：“中级”组合里讲解、检查、出题、预先求解答案、整理笔记
/// - 高：“高级”组合里同上；每百万 token 的价格不超过 Claude Opus 5.5（$4 / $20）
/// 模型名称都对过 models.dev 上各服务商的模型列表（2026-11），聚合平台再对过平台自己的列表。
/// 中、高档都在 App 里实测过 8 道微积分检查（4 道错、4 道对，含漏绝对值、上下限代反、分部积分符号错）：
/// 判错一次就不用；每次检查要等半分钟以上的也不用。实测（经 AIHubMix，2026-11-20）：
/// Sonnet 5.5 8/8 约 3 秒、Opus 5.5 8/8 约 6 秒、gpt-6.1-terra 8/8 约 3 秒、gpt-6.2-sol 8/8 约 2 秒、
/// gemini-4-hydrogen 8/8 约 8 秒、gemini-4-neon 7/7 约 12 秒、qwen3.8-max 6/6 约 7 秒、
/// doubao-seed-2-1-pro 7/7 约 6 秒、grok-4.3 7/7 约 9 秒（grok-4.7 也全对，但平均 16 秒、最慢 31 秒）。
/// 没有预设的服务商：Kimi（kimi-k3.1-pro、kimi-k3 都把错的判成对）、qwen3.7-plus 同样判错（通义改用 qwen3.8-max），
/// DeepSeek（deepseek-flash 判得对但每次 70–140 秒）、智谱（glm-5v-turbo 判得对但每次 30–50 秒）、
/// 硅基流动（核对的模型测不了）、DMXAPI 和自定义（核对不了模型名称）
struct ModelTiers: Equatable {
    let low: String
    let mid: String
    let high: String

    static let byProvider: [String: ModelTiers] = [
        "anthropic": ModelTiers(low: "claude-haiku-5-5", mid: "claude-sonnet-5-5", high: "claude-opus-5-5"),
        // 中档用 gpt-6.1-terra：难题检查实测（54 次，含手写、繁体和英文 DSE 题）和 Sonnet 5.5 一样全对，
        // 更快，每次请求的费用约是 Sonnet 5.5 的 30%
        "aihubmix": ModelTiers(low: "claude-haiku-5-5", mid: "gpt-6.1-terra", high: "claude-opus-5-5"),
        "302ai": ModelTiers(low: "claude-haiku-5-5", mid: "claude-sonnet-5-5", high: "claude-opus-5-5"),
        "openrouter": ModelTiers(low: "anthropic/claude-haiku-5.5", mid: "anthropic/claude-sonnet-5.5", high: "anthropic/claude-opus-5.5"),
        // $0.1/$0.5、$1/$5、$2/$10
        "openai": ModelTiers(low: "gpt-6-luna", mid: "gpt-6.1-terra", high: "gpt-6.2-sol"),
        // $0.3/$2.5、$1.5/$7.5、$3/$15
        "gemini": ModelTiers(low: "gemini-3.5-flash-lite", mid: "gemini-4-hydrogen", high: "gemini-4-neon"),
        // qwen3.7-plus 实测把错的判成对，中、高档都用 qwen3.8-max（约 $1.8/$5.3，仍比 Sonnet 5.5 便宜）
        "qwen": ModelTiers(low: "qwen3.8-flash", mid: "qwen3.8-max", high: "qwen3.8-max"),
        // 2-1-turbo 测不了，中、高档都用实测全对的 2-1-pro（约 $0.9/$4.5）
        "doubao": ModelTiers(low: "doubao-seed-2-0-mini-260428", mid: "doubao-seed-2-1-pro-260628", high: "doubao-seed-2-1-pro-260628"),
        // grok-4.7 比 grok-4.3 慢一倍，实测没有更准，中、高档都用 grok-4.3（$1.25/$2.5）
        "xai": ModelTiers(low: "grok-4.20-0309-non-reasoning", mid: "grok-4.3", high: "grok-4.3")
    ]

    static func forProvider(_ id: String) -> ModelTiers? { byProvider[id] }

    /// 套用组合时找服务商的先后：当前使用的优先，其次按这个顺序找已填 Key 的
    static let providerOrder = ["anthropic", "aihubmix", "openrouter", "302ai", "openai", "gemini", "xai",
                                "qwen", "doubao"]
}

/// 搭配好的模型组合：一次设好当前模型、检查与提示、出新题（也用来预先求解）和整理笔记四个模型。
/// 用哪个模型由服务商的三档决定（ModelTiers）
struct ModelCombo: Identifiable, Equatable {
    let id: String

    var title: String { id == "advanced" ? L("高级") : L("中级") }

    /// 这个组合在某个服务商里用的模型
    func model(in tiers: ModelTiers) -> String { id == "advanced" ? tiers.high : tiers.mid }

    func summary(_ tiers: ModelTiers) -> String {
        let lead = id == "advanced" ? L("最准") : L("又快又准")
        return String(localized: "\(lead)：讲解、检查、出题、预先求解答案和整理笔记都用 \(model(in: tiers))，识别图片用 \(tiers.low)")
    }

    /// 检查答案不用低档模型：数学题（尤其微积分）容易改错。低档只用来识别图片
    static let advanced = ModelCombo(id: "advanced")
    static let intermediate = ModelCombo(id: "intermediate")
    static let all = [advanced, intermediate]
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
