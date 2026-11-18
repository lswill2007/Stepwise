import Foundation
import Combine

/// 一次请求用掉的 token（服务商在流式回复的最后告诉我们）
struct LLMUsage: Equatable {
    var input = 0
    var output = 0
    /// 命中缓存的输入（比普通输入便宜）
    var cacheRead = 0
    /// 写入缓存的输入（Claude 按输入价的 1.25 倍收）
    var cacheWrite = 0
    /// 服务商直接报的实际费用（OpenRouter，美元）
    var reportedCostUSD: Double?
    /// 服务商实际用的模型（Claude 拒答时会自动换模型）
    var model: String?

    var isEmpty: Bool { input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 && reportedCostUSD == nil }
}

/// 每百万 token 的价格
struct ModelPrice: Codable, Equatable {
    var input: Double
    var output: Double
    /// 命中缓存的输入；为 nil 时按输入价的十分之一
    var cacheRead: Double?
    /// 写入缓存的输入；为 nil 时按输入价的 1.25 倍（Claude 的算法）
    var cacheWrite: Double?
    /// "USD" 或 "CNY"
    var currency: String
    /// 输入超过这么多 token 时用长上下文价格（Claude Haiku 5.5）
    var longThreshold: Int?
    var longInput: Double?
    var longOutput: Double?
    /// 按上下文长度分档的价格（价格表里的模型，可能有好几档）
    var tiers: [Tier]?

    /// 输入超过 above 个 token 时用的价格
    struct Tier: Codable, Equatable {
        var above: Int
        var input: Double
        var output: Double
        var cacheRead: Double?
        var cacheWrite: Double?
    }

    init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil, currency: String = "USD",
         longThreshold: Int? = nil, longInput: Double? = nil, longOutput: Double? = nil, tiers: [Tier]? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.currency = currency
        self.longThreshold = longThreshold
        self.longInput = longInput
        self.longOutput = longOutput
        self.tiers = tiers
    }

    func cost(_ u: LLMUsage) -> Double {
        let promptTokens = u.input + u.cacheRead + u.cacheWrite
        var inPrice = input, outPrice = output, readPrice = cacheRead, writePrice = cacheWrite
        if let threshold = longThreshold, promptTokens > threshold {
            inPrice = longInput ?? input
            outPrice = longOutput ?? output
            readPrice = nil
            writePrice = nil
        }
        // 用输入长度够得着的最高一档
        if let tier = (tiers ?? []).filter({ promptTokens > $0.above }).max(by: { $0.above < $1.above }) {
            inPrice = tier.input
            outPrice = tier.output
            readPrice = tier.cacheRead
            writePrice = tier.cacheWrite
        }
        let total = Double(u.input) * inPrice + Double(u.output) * outPrice
            + Double(u.cacheRead) * (readPrice ?? inPrice / 10)
            + Double(u.cacheWrite) * (writePrice ?? inPrice * 1.25)
        return total / 1_000_000
    }

    var symbol: String { currency == "CNY" ? "¥" : "$" }
}

/// 价格是从哪来的
enum PriceSource: Equatable {
    /// 自己在设置里填的
    case custom
    /// 模型厂商官网的价格（maker 是厂商名，如 Anthropic、OpenAI、DeepSeek）
    case official(maker: String)
    /// 官网价格表里查不到：用 Hugging Face 上各家推理服务商的中间价
    case huggingFace
    /// 官网价格表里查不到：用 AIHubMix 的价格
    case aihubmix

    var isOfficial: Bool { if case .official = self { return true } else { return false } }

    var label: String {
        switch self {
        case .custom: return L("自己填的价格")
        case .official(let maker): return String(format: L("%@ 官网价格"), maker)
        case .huggingFace: return L("Hugging Face 上各家的中间价（官网查不到）")
        case .aihubmix: return L("AIHubMix 价格（官网查不到）")
        }
    }
}

/// 模型价格：所有模型都按厂商官网价格算（不管经哪个服务商调用）。
/// Claude 的官网价格内置（没网也能算）；其他模型查 models.dev 整理的各家官网价格表，每次打开 App 时更新；
/// 官网价格表里查不到的才用 Hugging Face / AIHubMix 的价格。用户在设置里自己填的价格优先
enum PriceBook {
    /// Anthropic 官方 API 价格（美元 / 百万 token，2026-11-03）
    static let anthropic: [String: ModelPrice] = [
        "claude-fable-5-2": ModelPrice(input: 8, output: 40, cacheRead: 0.20),
        "claude-fable-5-1": ModelPrice(input: 10, output: 50),
        "claude-fable-5": ModelPrice(input: 10, output: 50),
        "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.20),
        "claude-opus-5": ModelPrice(input: 5, output: 25),
        "claude-opus-4-8": ModelPrice(input: 5, output: 25),
        "claude-opus-4-7": ModelPrice(input: 5, output: 25),
        "claude-opus-4-6": ModelPrice(input: 5, output: 25),
        "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.10),
        "claude-sonnet-5": ModelPrice(input: 2, output: 10),
        "claude-sonnet-4-6": ModelPrice(input: 3, output: 15),
        "claude-haiku-5-5": ModelPrice(input: 0.10, output: 0.50, longThreshold: 100_000, longInput: 0.50, longOutput: 2.50),
        "claude-haiku-4-5": ModelPrice(input: 1, output: 5)
    ]

    static let pricesKey = "modelPrices"

    static func key(provider: String, model: String) -> String { provider + "|" + model }

    /// 用户填的价格（按服务商 + 模型）
    static func custom(provider: String, model: String) -> ModelPrice? {
        guard let data = UserDefaults.standard.data(forKey: pricesKey),
              let all = try? JSONDecoder().decode([String: ModelPrice].self, from: data) else { return nil }
        return all[key(provider: provider, model: model)]
    }

    static func setCustom(_ price: ModelPrice?, provider: String, model: String) {
        var all: [String: ModelPrice] = [:]
        if let data = UserDefaults.standard.data(forKey: pricesKey),
           let saved = try? JSONDecoder().decode([String: ModelPrice].self, from: data) { all = saved }
        all[key(provider: provider, model: model)] = price
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: pricesKey) }
    }

    /// 内置的 Claude 官网价格（经任何服务商调用 Claude 都按它算）
    static func builtIn(provider: String, model: String) -> ModelPrice? {
        let name = ModelInfo.baseName(model).replacingOccurrences(of: ".", with: "-")
        if let p = anthropic[name] { return p }
        // 带日期后缀的旧写法：claude-xxx-20250101
        return anthropic.first { name.hasPrefix($0.key + "-") }?.value
    }

    /// 不算自己填的：内置的 Claude 官网价格，或者价格表里查到的
    static func automatic(provider: String, model: String) -> (price: ModelPrice, source: PriceSource)? {
        if let p = builtIn(provider: provider, model: model) { return (p, .official(maker: "Anthropic")) }
        return OnlinePrices.shared.lookup(provider: provider, model: model)
    }

    static func lookup(provider: String, model: String) -> (price: ModelPrice, source: PriceSource)? {
        if let p = custom(provider: provider, model: model) { return (p, .custom) }
        return automatic(provider: provider, model: model)
    }

    static func price(provider: String, model: String) -> ModelPrice? {
        lookup(provider: provider, model: model)?.price
    }
}

/// 网上公开的模型价格表（都是美元 / 百万 token，不用 API Key）：
/// - models.dev：整理好的各家厂商官网价格（Anthropic、OpenAI、Google、DeepSeek、通义、智谱、Kimi、xAI……），
///   还记着各个聚合平台上的模型名对应哪个官方模型，所以经 AIHubMix 等调用时也能查到官网价格
/// - Hugging Face 推理服务：开源模型在各家推理服务商的价格（官网价格表里没有时用中间价）
/// - AIHubMix：官网价格表和 Hugging Face 都查不到时最后用它
/// 每次打开 App 时更新一次（之后超过一天也会再更新），存在缓存文件夹里，没网时用上次的
final class OnlinePrices: @unchecked Sendable {
    static let shared = OnlinePrices()

    struct Table: Codable {
        var fetched: Date
        /// 「厂商/模型」（小写）→ 官网价格
        var official: [String: ModelPrice] = [:]
        /// 模型名（小写，不带「组织/」）→「厂商/模型」
        var officialAlias: [String: String] = [:]
        /// 厂商 ID → 显示的名字（如 deepseek → DeepSeek）
        var makers: [String: String] = [:]
        /// 小写的模型名 → AIHubMix 价格
        var aihubmix: [String: ModelPrice] = [:]
        /// 小写的模型 ID（如 deepseek-ai/deepseek-v3）→ 推理服务商 → 价格
        var huggingFace: [String: [String: ModelPrice]] = [:]
        /// Hugging Face 上模型作者自己提供的服务商（它的价格就是官网价格）：模型 ID → (服务商, 显示名)
        var huggingFaceAuthor: [String: [String]] = [:]
    }

    static let modelsDevURL = URL(string: "https://models.dev/api.json")!
    static let aihubmixURL = URL(string: "https://aihubmix.com/api/v1/models")!
    static let huggingFaceURL = URL(string: "https://router.huggingface.co/v1/models")!

    private let lock = NSLock()
    private var table: Table?
    /// Hugging Face 模型名的最后一段 → 完整 ID（用户只写了 DeepSeek-V3 这种时也能查到）
    private var hfByBase: [String: String] = [:]
    private var refreshing = false

    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("model-prices-v2.json")
    }

    private init() {
        if let url = Self.fileURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Table.self, from: data) {
            install(saved)
        }
    }

    private func install(_ t: Table) {
        var byBase: [String: String] = [:]
        for id in t.huggingFace.keys { byBase[ModelInfo.baseName(id)] = id }
        lock.lock()
        table = t
        hfByBase = byBase
        lock.unlock()
    }

    /// 价格表更新的时间；还没拿到过为 nil
    var fetchedAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return table?.fetched
    }

    var isRefreshing: Bool {
        lock.lock(); defer { lock.unlock() }
        return refreshing
    }

    /// 同一个模型在各处的写法不同：claude-haiku-4.5 / claude-haiku-4-5、带不带「组织/」
    private static func nameVariants(_ model: String) -> [String] {
        let base = ModelInfo.baseName(model)
        var names = [base, base.replacingOccurrences(of: ".", with: "-")]
        if base.hasSuffix(":free") { names.append(String(base.dropLast(5))) }
        return names
    }

    func lookup(provider: String, model: String) -> (price: ModelPrice, source: PriceSource)? {
        lock.lock()
        let t = table, byBase = hfByBase
        lock.unlock()
        guard let t else { return nil }
        let full = model.lowercased()
        let names = Self.nameVariants(model)

        // 1. 官网价格
        var officialKeys: [String] = []
        if full.contains("/") { officialKeys.append(full) }
        for name in names {
            if let key = t.officialAlias[name] { officialKeys.append(key) }
        }
        for key in officialKeys {
            if let p = t.official[key] {
                let maker = String(key.split(separator: "/").first ?? "")
                return (p, .official(maker: t.makers[maker] ?? maker))
            }
        }

        // 2. Hugging Face：模型作者自己的服务就是官网价格，否则取各家的中间价（不算免费的）
        if let id = t.huggingFace[full] != nil ? full : names.lazy.compactMap({ byBase[$0] }).first,
           let offers = t.huggingFace[id], !offers.isEmpty {
            if let author = t.huggingFaceAuthor[id], author.count == 2, let p = offers[author[0]] {
                return (p, .official(maker: author[1]))
            }
            let paid = offers.values.filter { $0.input > 0 || $0.output > 0 }
            if paid.isEmpty { return (ModelPrice(input: 0, output: 0), .huggingFace) }
            func median(_ v: [Double]) -> Double {
                let s = v.sorted()
                return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
            }
            return (ModelPrice(input: median(paid.map(\.input)), output: median(paid.map(\.output))), .huggingFace)
        }

        // 3. AIHubMix
        if let p = t.aihubmix[full] ?? names.lazy.compactMap({ t.aihubmix[$0] }).first {
            return (p, .aihubmix)
        }
        return nil
    }

    /// 打开 App 时调用一次：不管多久前更新过都重新拿
    func refreshOnLaunch() { refreshIfNeeded(force: true) }

    /// 超过一天没更新就去网上拿新的；拿到后通知用量页面重新算
    func refreshIfNeeded(force: Bool = false) {
        lock.lock()
        let stale = force || (table?.fetched).map { Date().timeIntervalSince($0) > 24 * 3600 } ?? true
        let start = stale && !refreshing
        if start { refreshing = true }
        lock.unlock()
        guard start else { return }
        Task { @MainActor in UsageLog.shared.objectWillChange.send() }
        Task.detached(priority: .utility) {
            async let o = Self.fetchModelsDev()
            async let a = Self.fetchAIHubMix()
            async let h = Self.fetchHuggingFace()
            let (official, ahm, hf) = await (o, a, h)
            let old = self.lock.withLock { self.table }
            if official != nil || ahm != nil || hf != nil {
                // 有哪一边没拿到就沿用上次的
                var t = Table(fetched: Date())
                t.official = official?.prices ?? old?.official ?? [:]
                t.officialAlias = official?.alias ?? old?.officialAlias ?? [:]
                t.makers = official?.makers ?? old?.makers ?? [:]
                t.aihubmix = ahm ?? old?.aihubmix ?? [:]
                t.huggingFace = hf?.offers ?? old?.huggingFace ?? [:]
                t.huggingFaceAuthor = hf?.authors ?? old?.huggingFaceAuthor ?? [:]
                self.install(t)
                if let url = Self.fileURL, let data = try? JSONEncoder().encode(t) { try? data.write(to: url, options: .atomic) }
            }
            self.lock.withLock { self.refreshing = false }
            await MainActor.run { UsageLog.shared.objectWillChange.send() }
        }
    }

    private static func get(_ url: URL) async -> Any? {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    /// models.dev / AIHubMix 的价格写法相同：input、output、cache_read、cache_write、按上下文分档的 tiers
    static func parsePrice(_ p: [String: Any]) -> ModelPrice? {
        guard let input = number(p["input"]), let output = number(p["output"]) else { return nil }
        let tiers: [ModelPrice.Tier] = (p["tiers"] as? [[String: Any]] ?? []).compactMap { t in
            guard let tier = t["tier"] as? [String: Any], (tier["type"] as? String) == "context",
                  let size = number(tier["size"]), let i = number(t["input"]), let o = number(t["output"]) else { return nil }
            return ModelPrice.Tier(above: Int(size), input: i, output: o,
                                   cacheRead: number(t["cache_read"]), cacheWrite: number(t["cache_write"]))
        }
        return ModelPrice(input: input, output: output,
                          cacheRead: number(p["cache_read"]), cacheWrite: number(p["cache_write"]),
                          tiers: tiers.isEmpty ? nil : tiers)
    }

    /// 豆包没有被别处标成官方模型，单独当作厂商
    private static let extraMakers: Set<String> = ["volcengine"]

    static func fetchModelsDev() async -> (prices: [String: ModelPrice], alias: [String: String], makers: [String: String])? {
        guard let json = await get(modelsDevURL) as? [String: [String: Any]] else { return nil }
        // 别处标的「官方模型」（canonical_model_id，如 anthropic/claude-haiku-4-5）的前缀就是厂商
        var canonicalVotes: [String: [String: Int]] = [:]
        var makerIDs = extraMakers
        for (_, provider) in json {
            for (id, m) in provider["models"] as? [String: [String: Any]] ?? [:] {
                guard let canonical = (m["canonical_model_id"] as? String)?.lowercased(), canonical.contains("/") else { continue }
                makerIDs.insert(String(canonical.split(separator: "/")[0]))
                for name in nameVariants(id) { canonicalVotes[name, default: [:]][canonical, default: 0] += 1 }
            }
        }
        var prices: [String: ModelPrice] = [:]
        var alias: [String: String] = [:]
        var makers: [String: String] = [:]
        for maker in makerIDs {
            guard let provider = json[maker], let models = provider["models"] as? [String: [String: Any]] else { continue }
            makers[maker] = provider["name"] as? String ?? maker
            for (id, m) in models {
                guard let cost = m["cost"] as? [String: Any], let price = parsePrice(cost) else { continue }
                let key = maker + "/" + id.lowercased()
                prices[key] = price
            }
        }
        // 模型名 → 官方模型：大多数地方标的那个（且官网价格表里有）；
        // 没人标过的，用厂商自己价格表里同名的模型
        var own: [String: [String]] = [:]
        for key in prices.keys.sorted() {
            let id = String(key.split(separator: "/", maxSplits: 1)[1])
            for name in nameVariants(id) { own[name, default: []].append(key) }
        }
        for name in Set(canonicalVotes.keys).union(own.keys) {
            let voted = (canonicalVotes[name] ?? [:]).filter { prices[$0.key] != nil }
                .max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
            if let key = voted ?? own[name]?.first { alias[name] = key }
        }
        return prices.isEmpty ? nil : (prices, alias, makers)
    }

    static func fetchAIHubMix() async -> [String: ModelPrice]? {
        guard let json = await get(aihubmixURL) as? [String: Any], let list = json["data"] as? [[String: Any]] else { return nil }
        var result: [String: ModelPrice] = [:]
        for m in list {
            guard let id = m["model_id"] as? String, let p = m["pricing"] as? [String: Any], let price = parsePrice(p) else { continue }
            result[id.lowercased()] = price
        }
        return result
    }

    static func fetchHuggingFace() async -> (offers: [String: [String: ModelPrice]], authors: [String: [String]])? {
        guard let json = await get(huggingFaceURL) as? [String: Any], let list = json["data"] as? [[String: Any]] else { return nil }
        var offers: [String: [String: ModelPrice]] = [:]
        var authors: [String: [String]] = [:]
        for m in list {
            guard let id = (m["id"] as? String)?.lowercased(), let providers = m["providers"] as? [[String: Any]] else { continue }
            var list: [String: ModelPrice] = [:]
            for p in providers {
                guard let name = p["provider"] as? String, let pricing = p["pricing"] as? [String: Any],
                      let i = number(pricing["input"]), let o = number(pricing["output"]) else { continue }
                list[name] = ModelPrice(input: i, output: o)
                if (p["is_model_author"] as? Bool) == true {
                    authors[id] = [name, p["provider_name"] as? String ?? name]
                }
            }
            if !list.isEmpty { offers[id] = list }
        }
        return (offers, authors)
    }
}

/// 某一天、某个服务商的某个模型一共用了多少
struct UsageTotals: Codable, Equatable {
    var requests = 0
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// 记的时候已经知道价格的部分：按币种累计的费用
    var cost: [String: Double] = [:]
    /// 记的时候还不知道价格的 token：之后填了价格再按现在的价格算
    var unpriced = UnpricedTokens()
    /// 费用是按官网价格算的（旧版本记的费用可能是聚合平台的价格，读出来时改成按官网价格重算）
    var officialPricing: Bool?

    struct UnpricedTokens: Codable, Equatable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var isEmpty: Bool { input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 }
        var usage: LLMUsage { LLMUsage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite) }
    }

    mutating func add(_ other: UsageTotals) {
        if other.officialPricing == true && (requests == 0 || officialPricing == true) { officialPricing = true }
        requests += other.requests
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        for (c, v) in other.cost { cost[c, default: 0] += v }
        unpriced.input += other.unpriced.input
        unpriced.output += other.unpriced.output
        unpriced.cacheRead += other.unpriced.cacheRead
        unpriced.cacheWrite += other.unpriced.cacheWrite
    }

    var totalTokens: Int { input + output + cacheRead + cacheWrite }
}

/// token 用量记录：按天、按服务商和模型累计，存在本 App 的 UserDefaults（会跟设置一起存进储存文件夹）
@MainActor
final class UsageLog: ObservableObject {
    static let shared = UsageLog()

    /// 天（yyyy-MM-dd）→「服务商|模型」→ 用量
    @Published private(set) var days: [String: [String: UsageTotals]] = [:]

    private static let storageKey = "tokenUsage"

    private init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode([String: [String: UsageTotals]].self, from: data) else {
            days = [:]
            return
        }
        days = saved
        repriceOldRecords()
    }

    private func model(of key: String) -> String {
        let parts = key.split(separator: "|", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : ""
    }

    /// 旧版本按聚合平台的价格记下的费用：清掉，把 token 改成「待算」，显示时按现在的官网价格算
    private func repriceOldRecords() {
        var changed = false
        for (day, models) in days {
            for (key, t) in models where t.officialPricing != true {
                var n = t
                n.officialPricing = true
                // OpenRouter 报回来的实际扣费没有 token 以外的信息可重算，只在查不到官网价格时保留
                let provider = key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
                if provider != "openrouter" || PriceBook.price(provider: provider, model: model(of: key)) != nil {
                    n.cost = [:]
                    n.unpriced = .init(input: t.input, output: t.output, cacheRead: t.cacheRead, cacheWrite: t.cacheWrite)
                }
                days[day]?[key] = n
                changed = true
            }
        }
        if changed { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(days) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    nonisolated static func record(provider: String, model: String, usage: LLMUsage) {
        guard !usage.isEmpty else { return }
        Task { @MainActor in shared.add(provider: provider, model: usage.model ?? model, usage: usage) }
    }

    private func add(provider: String, model: String, usage: LLMUsage) {
        var t = UsageTotals()
        t.requests = 1
        t.input = usage.input
        t.output = usage.output
        t.cacheRead = usage.cacheRead
        t.cacheWrite = usage.cacheWrite
        t.officialPricing = true
        // 按官网价格算；查不到时才用 OpenRouter 报回来的实际扣费
        if let price = PriceBook.price(provider: provider, model: model) {
            t.cost[price.currency] = price.cost(usage)
        } else if let reported = usage.reportedCostUSD {
            t.cost["USD"] = reported
        } else {
            t.unpriced = .init(input: usage.input, output: usage.output, cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite)
            // 价格表可能还没拿到或者过期了：拿到后这些 token 会按价格表补算
            OnlinePrices.shared.refreshIfNeeded()
        }
        let day = Self.dayKey(Date())
        days[day, default: [:]][PriceBook.key(provider: provider, model: model), default: UsageTotals()].add(t)
        save()
    }

    func clear() {
        days = [:]
        save()
    }

    /// 从 since 那天（含）起，按「服务商|模型」合计
    func totals(since: Date?) -> [String: UsageTotals] {
        let start = since.map(Self.dayKey)
        var result: [String: UsageTotals] = [:]
        for (day, models) in days where start.map({ day >= $0 }) ?? true {
            for (key, t) in models { result[key, default: UsageTotals()].add(t) }
        }
        return result
    }

    /// 一组用量的费用：记的时候已算好的，加上没价格的 token 按现在填的价格算；还有没价格的就标出来
    static func cost(of totals: [String: UsageTotals]) -> (amounts: [String: Double], missing: Bool) {
        var amounts: [String: Double] = [:]
        var missing = false
        for (key, t) in totals {
            for (c, v) in t.cost { amounts[c, default: 0] += v }
            guard !t.unpriced.isEmpty else { continue }
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2, let price = PriceBook.price(provider: parts[0], model: parts[1]) {
                amounts[price.currency, default: 0] += price.cost(t.unpriced.usage)
            } else {
                missing = true
            }
        }
        return (amounts, missing)
    }

    static func format(_ amounts: [String: Double]) -> String {
        let parts = amounts.sorted { $0.key > $1.key }.filter { $0.value > 0 }.map { currency, value -> String in
            let symbol = currency == "CNY" ? "¥" : "$"
            let digits = value < 0.01 ? 4 : (value < 1 ? 3 : 2)
            return symbol + String(format: "%.\(digits)f", value)
        }
        return parts.isEmpty ? "0" : parts.joined(separator: " + ")
    }

    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
