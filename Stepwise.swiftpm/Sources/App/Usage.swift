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
    /// "USD" 或 "CNY"
    var currency: String
    /// 输入超过这么多 token 时用长上下文价格（Claude Haiku 5.5）
    var longThreshold: Int?
    var longInput: Double?
    var longOutput: Double?

    init(input: Double, output: Double, cacheRead: Double? = nil, currency: String = "USD",
         longThreshold: Int? = nil, longInput: Double? = nil, longOutput: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.currency = currency
        self.longThreshold = longThreshold
        self.longInput = longInput
        self.longOutput = longOutput
    }

    func cost(_ u: LLMUsage) -> Double {
        let promptTokens = u.input + u.cacheRead + u.cacheWrite
        let long = longThreshold.map { promptTokens > $0 } ?? false
        let inPrice = long ? (longInput ?? input) : input
        let outPrice = long ? (longOutput ?? output) : output
        let readPrice = cacheRead ?? inPrice / 10
        let total = Double(u.input) * inPrice + Double(u.output) * outPrice
            + Double(u.cacheRead) * readPrice + Double(u.cacheWrite) * inPrice * 1.25
        return total / 1_000_000
    }

    var symbol: String { currency == "CNY" ? "¥" : "$" }
}

/// 模型价格：Anthropic 官方的 Claude 价格内置；其他服务商的价格各家不同、经常变，由用户在设置里填
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

    /// 内置价格：只用于直连 Anthropic 官方接口（聚合平台、中转的价格各不相同）
    static func builtIn(provider: String, model: String) -> ModelPrice? {
        guard provider == "anthropic" else { return nil }
        let name = ModelInfo.baseName(model)
        if let p = anthropic[name] { return p }
        // 带日期后缀的旧写法：claude-xxx-20250101
        return anthropic.first { name.hasPrefix($0.key + "-") }?.value
    }

    static func price(provider: String, model: String) -> ModelPrice? {
        custom(provider: provider, model: model) ?? builtIn(provider: provider, model: model)
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

    struct UnpricedTokens: Codable, Equatable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var isEmpty: Bool { input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 }
        var usage: LLMUsage { LLMUsage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite) }
    }

    mutating func add(_ other: UsageTotals) {
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
        if let reported = usage.reportedCostUSD {
            t.cost["USD"] = reported
        } else if let price = PriceBook.price(provider: provider, model: model) {
            t.cost[price.currency] = price.cost(usage)
        } else {
            t.unpriced = .init(input: usage.input, output: usage.output, cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite)
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
