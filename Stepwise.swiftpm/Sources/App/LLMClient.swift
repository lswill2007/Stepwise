import Foundation

enum LLMContent {
    case text(String)
    case image(Data) // JPEG
}

struct LLMMessage {
    var role: ChatRole
    var parts: [LLMContent]
}

/// 单次请求的选项
struct RequestOptions {
    /// 快速模式：让模型少思考（用于检查答案、给提示）
    var fast = false
    /// 只是照抄图上的字（手写转写）：不用想，思考压到最低。只在 fast 时起作用
    var transcribing = false
    /// 最多等服务器多少秒开始回应（收到响应头为止）；超过就当连不上。nil 不限（正式请求：推理模型可能想很久）。
    /// 只管“连上之前”，连上以后模型想多久都不受影响
    var responseTimeout: TimeInterval? = nil
}

struct LLMError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 直接用 URLSession 调用各家接口，统一成流式文本输出。
struct LLMClient {
    let config: ProviderConfig
    let apiKey: String

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // 推理模型可能思考很久才吐出第一个字
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 1800
        return URLSession(configuration: cfg)
    }()

    private var base: String {
        var s = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private var model: String { config.model.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - 对外接口

    func stream(system: String, messages: [LLMMessage], options: RequestOptions = RequestOptions()) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let gate = ResponseGate()
            let host = URL(string: base)?.host ?? base
            let task = Task {
                do {
                    let normalized = Self.normalized(messages)
                    let fastKey = "\(config.id)|\(model)"
                    // 这个模型之前拒绝过快速模式参数，就不再带
                    var useFast = options.fast && !ParameterMemory.fastMode.isUnsupported(fastKey) && !fastParameters(transcribing: options.transcribing).isEmpty
                    // 转写和普通请求的快速模式参数不一样，成功过的分开记
                    let fastGoodKey = fastKey + (options.transcribing ? "|transcribe" : "")
                    // OpenAI 兼容接口要请求了才在最后报用量；之前拒绝过这个参数的服务商就不再带
                    var useUsage = config.apiProtocol == .openAI && !ParameterMemory.usageOption.isUnsupported(config.id)
                    var request = try makeChatRequest(system: system, messages: normalized, fast: useFast, transcribing: options.transcribing, usage: useUsage)
                    var (bytes, response) = try await Self.session.bytes(for: request)
                    // 等太久已经放弃了：不再往下走
                    guard gate.markResponded() else { throw CancellationError() }
                    var status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    // 参数不被接受：先去掉报用量的参数重试，还不行再去掉快速模式参数；重试成功才记下是哪个参数不被接受。
                    // 带着它成功过的参数不去掉（报错是别的原因，重发一遍也一样）
                    var dropped: String?
                    while status == 400 || status == 422 {
                        let canDropUsage = useUsage && !ParameterMemory.usageOption.isKnownGood(config.id)
                        let canDropFast = useFast && !ParameterMemory.fastMode.isKnownGood(fastGoodKey)
                        guard canDropUsage || canDropFast else { break }
                        if canDropUsage { useUsage = false; dropped = "usage" } else { useFast = false; dropped = "fast" }
                        request = try makeChatRequest(system: system, messages: normalized, fast: useFast, transcribing: options.transcribing, usage: useUsage)
                        (bytes, response) = try await Self.session.bytes(for: request)
                        status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    }
                    if status == 200 {
                        if dropped == "usage" { ParameterMemory.usageOption.markUnsupported(config.id) }
                        if dropped == "fast" { ParameterMemory.fastMode.markUnsupported(fastKey) }
                        if useUsage { ParameterMemory.usageOption.markGood(config.id) }
                        if useFast { ParameterMemory.fastMode.markGood(fastGoodKey) }
                    }
                    if status != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line + "\n" }
                        throw LLMError(message: Self.describeError(status: status, body: body))
                    }
                    var usage = LLMUsage()
                    // 不管正常结束、出错还是被停止，已经报回来的用量都记下
                    defer { UsageLog.record(provider: config.id, model: model, usage: usage) }
                    var yielded = false
                    // 不是 "data:" 开头的行：服务商没按流式回（或者中转站用 200 回了一段 JSON 报错），留着最后看
                    var plain = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else {
                            if !yielded, plain.utf8.count < 32_000 { plain += line + "\n" }
                            continue
                        }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        readUsage(json, into: &usage)
                        if let text = try parseChunk(json), !text.isEmpty {
                            yielded = true
                            continuation.yield(text)
                        }
                    }
                    // 一个字也没收到：看看是不是整段的回答或报错。以前这种情况只说“模型没有返回内容”，看不到真正的原因
                    if !yielded, let text = try plainReply(plain), !text.isEmpty {
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: gate.timedOut ? Self.unreachableError(host: host) : Self.friendlyError(error, host: host))
                }
            }
            // 等服务器回应的时限：到点还没收到响应头就停掉请求，报“连不上”
            let watchdog = options.responseTimeout.map { seconds in
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    if !Task.isCancelled, gate.markTimedOut() { task.cancel() }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                watchdog?.cancel()
            }
        }
    }

    func complete(system: String, messages: [LLMMessage], options: RequestOptions = RequestOptions()) async throws -> String {
        var result = ""
        for try await chunk in stream(system: system, messages: messages, options: options) {
            result += chunk
        }
        return result
    }

    func listModels() async throws -> [String] {
        var request: URLRequest
        switch config.apiProtocol {
        case .openAI:
            request = URLRequest(url: try url(base + "/models"))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request = URLRequest(url: try url(anthropicRoot + "/v1/models?limit=1000"))
            addAnthropicHeaders(&request)
        case .gemini:
            request = URLRequest(url: try url(base + "/models?pageSize=1000"))
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        let host = request.url?.host ?? base
        let (data, response) = try await Self.withDeadline(Self.quickTimeout, host: host) { [request] in
            do {
                return try await Self.session.data(for: request)
            } catch {
                throw Self.friendlyError(error, host: host)
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw LLMError(message: Self.describeError(status: status, body: String(decoding: data, as: UTF8.self)))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let ids: [String]
        switch config.apiProtocol {
        case .openAI, .anthropic:
            ids = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        case .gemini:
            ids = (json["models"] as? [[String: Any]] ?? [])
                .filter { ($0["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") }
                .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
        }
        return ids.sorted()
    }

    // MARK: - 提前建连接

    private static let warmLock = NSLock()
    private static var lastWarm: [String: Date] = [:]

    /// 向服务商的接口地址发一个空的 HEAD 请求（不带 Key、不带内容），把 TLS 连接建好放进连接池。
    /// 写字时调用，之后点“检查”的请求直接复用这条连接，省掉连接和握手（离服务商远时能省半秒到一秒）
    static func warmUp(_ config: ProviderConfig) {
        var root = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        guard let url = URL(string: root), url.scheme == "https", let host = url.host else { return }
        let recent = warmLock.withLock { () -> Bool in
            let recent = lastWarm[host].map { Date().timeIntervalSince($0) < 40 } ?? false
            if !recent { lastWarm[host] = Date() }
            return recent
        }
        guard !recent else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        session.dataTask(with: request).resume()
    }

    // MARK: - 请求构造

    private func url(_ string: String) throws -> URL {
        guard let url = URL(string: string), url.scheme?.hasPrefix("http") == true else {
            throw LLMError(message: String(localized: "接口地址无效：\(string)"))
        }
        return url
    }

    private var anthropicRoot: String {
        base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
    }

    private func addAnthropicHeaders(_ request: inout URLRequest) {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    /// 这些 Claude 模型可能因安全分类器拒答，开启服务端自动回退到其他模型。
    private static let anthropicFallbackModels: Set<String> = [
        "claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"
    ]

    /// 快速模式下各家服务商用来减少思考的参数（会合并进请求体）。返回空表示这个模型没有可调的参数。
    /// transcribing：只是照抄手写，不受检查数学题时“最低 medium”的限制，压到最低
    func fastParameters(transcribing: Bool = false) -> [String: Any] {
        let m = model.lowercased()
        switch config.apiProtocol {
        case .openAI:
            if config.id != "openrouter" && config.isAggregator {
                return Self.aggregatorFastParameters(model: model, transcribing: transcribing)
            }
            switch config.id {
            case "openai":
                // 只有推理模型接受 reasoning_effort
                if m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") {
                    return ["reasoning_effort": "low"]
                }
                return [:]
            case "openrouter":
                return ["reasoning": ["effort": "low"]]
            case "qwen", "siliconflow":
                return ["enable_thinking": false]
            case "zhipu", "moonshot", "doubao":
                return ["thinking": ["type": "disabled"]]
            default:
                return [:]
            }
        case .anthropic:
            // 支持 effort 参数的 Claude 模型
            let prefixes = ["claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5",
                            "claude-sonnet-4-6", "claude-sonnet-5", "claude-haiku-5", "claude-fable", "claude-mythos"]
            guard prefixes.contains(where: m.hasPrefix) else { return [:] }
            // Claude 5 系列在 low 下数学题常常不怎么想就下结论，容易改错：快速检查最低用 medium
            let claude5 = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable", "claude-mythos"]
            return ["output_config": ["effort": claude5.contains(where: m.hasPrefix) && !transcribing ? "medium" : "low"]]
        case .gemini:
            if m.contains("gemini-4") {
                return ["generationConfig": ["thinkingConfig": ["thinkingLevel": transcribing ? "low" : "medium"]]]
            }
            if m.contains("gemini-3") {
                return ["generationConfig": ["thinkingConfig": ["thinkingLevel": "low"]]]
            }
            if m.contains("2.5-flash") {
                return ["generationConfig": ["thinkingConfig": ["thinkingBudget": 0]]]
            }
            if m.contains("2.5-pro") {
                return ["generationConfig": ["thinkingConfig": ["thinkingBudget": 128]]]
            }
            return [:]
        }
    }

    /// 聚合平台（OpenAI 兼容格式）：按模型所属厂商带上对应的少思考参数；平台不接受时会自动去掉重试
    static func aggregatorFastParameters(model: String, transcribing: Bool = false) -> [String: Any] {
        let name = ModelInfo.baseName(model)
        switch ModelInfo.family(model) {
        case .openai:
            let reasoning = name.hasPrefix("gpt-5") || name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4")
            return reasoning ? ["reasoning_effort": "low"] : [:]
        case .google:
            // Gemini 的 OpenAI 兼容接口接受 reasoning_effort；Gemini 4 检查数学题最低用 medium
            if name.contains("gemini-4") { return ["reasoning_effort": transcribing ? "low" : "medium"] }
            return (name.contains("2.5") || name.contains("gemini-3")) ? ["reasoning_effort": "low"] : [:]
        case .qwen:
            return (name.hasPrefix("qwen3") || name.hasPrefix("qwq") || name.contains("plus") || name.contains("max"))
                ? ["enable_thinking": false] : [:]
        case .zhipu:
            return (name.contains("4.5") || name.contains("4.6") || name.contains("glm-z")) ? ["thinking": ["type": "disabled"]] : [:]
        case .moonshot, .doubao:
            return name.contains("thinking") ? [:] : ["thinking": ["type": "disabled"]]
        default:
            return [:]
        }
    }

    private func makeChatRequest(system: String, messages: [LLMMessage], fast: Bool = false, transcribing: Bool = false, usage: Bool = false) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw LLMError(message: String(localized: "还没有填写 \(config.name) 的 API Key，请到设置里填写。")) }
        guard !model.isEmpty else { throw LLMError(message: String(localized: "还没有选择 \(config.name) 的模型，请到设置里选择。")) }
        // 选了粤语回答：所有请求的系统提示词最后都加上粤语要求
        let system = AILanguage.decorate(system: system)

        var request: URLRequest
        var body: [String: Any]

        switch config.apiProtocol {
        case .openAI:
            request = URLRequest(url: try url(base + "/chat/completions"))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            var msgs: [[String: Any]] = [["role": "system", "content": system]]
            for m in messages {
                let hasImage = m.parts.contains { if case .image = $0 { return true } else { return false } }
                let content: Any
                if hasImage {
                    content = m.parts.map { part -> [String: Any] in
                        switch part {
                        case .text(let t): return ["type": "text", "text": t]
                        case .image(let d): return ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + d.base64EncodedString()]]
                        }
                    }
                } else {
                    // 纯文字用字符串形式，兼容性最好（部分国内接口不接受数组）
                    content = m.parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n\n")
                }
                msgs.append(["role": m.role == .user ? "user" : "assistant", "content": content])
            }
            body = ["model": model, "messages": msgs, "stream": true]
            if usage {
                // 最后一块里带上用了多少 token；OpenRouter 还会报实际花了多少钱
                body["stream_options"] = ["include_usage": true]
                if config.id == "openrouter" { body["usage"] = ["include": true] }
            }

        case .anthropic:
            request = URLRequest(url: try url(anthropicRoot + "/v1/messages"))
            addAnthropicHeaders(&request)
            let msgs: [[String: Any]] = messages.map { m in
                [
                    "role": m.role == .user ? "user" : "assistant",
                    "content": m.parts.map { part -> [String: Any] in
                        switch part {
                        case .text(let t): return ["type": "text", "text": t]
                        case .image(let d): return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": d.base64EncodedString()]]
                        }
                    }
                ]
            }
            body = [
                "model": model,
                "max_tokens": model.hasPrefix("claude-3") ? 8192 : 32000,
                // 系统提示词（题目、参考答案、辅导要求）同一道题每次都一样：标成可缓存，
                // 接下来的检查、提示读缓存，更快也更便宜（太短的提示词服务商会自动不缓存）
                "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
                "messages": msgs,
                "stream": true
            ]
            if Self.anthropicFallbackModels.contains(model) {
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }

        case .gemini:
            let path = "/models/\(model):streamGenerateContent?alt=sse"
            request = URLRequest(url: try url(base + path))
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let contents: [[String: Any]] = messages.map { m in
                [
                    "role": m.role == .user ? "user" : "model",
                    "parts": m.parts.map { part -> [String: Any] in
                        switch part {
                        case .text(let t): return ["text": t]
                        case .image(let d): return ["inline_data": ["mime_type": "image/jpeg", "data": d.base64EncodedString()]]
                        }
                    }
                ]
            }
            body = ["systemInstruction": ["parts": [["text": system]]], "contents": contents]
        }

        if fast {
            for (key, value) in fastParameters(transcribing: transcribing) { body[key] = value }
        }

        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - 流式解析

    /// 从流式回复里读出用量。各家报的位置不同；同一项后来报的数覆盖先前的
    private func readUsage(_ json: [String: Any], into usage: inout LLMUsage) {
        func int(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }
        switch config.apiProtocol {
        case .openAI:
            guard let u = json["usage"] as? [String: Any] else { return }
            let cached = int((u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]) ?? 0
            if let p = int(u["prompt_tokens"]) { usage.input = max(0, p - cached); usage.cacheRead = cached }
            if let c = int(u["completion_tokens"]) { usage.output = c }
            if let cost = (u["cost"] as? NSNumber)?.doubleValue { usage.reportedCostUSD = cost }
        case .anthropic:
            var u: [String: Any]?
            if json["type"] as? String == "message_start", let message = json["message"] as? [String: Any] {
                u = message["usage"] as? [String: Any]
                if let m = message["model"] as? String, !m.isEmpty { usage.model = m }
            } else if json["type"] as? String == "message_delta" {
                u = json["usage"] as? [String: Any]
            }
            guard let u else { return }
            if let v = int(u["input_tokens"]) { usage.input = v }
            if let v = int(u["output_tokens"]) { usage.output = v }
            if let v = int(u["cache_read_input_tokens"]) { usage.cacheRead = v }
            if let v = int(u["cache_creation_input_tokens"]) { usage.cacheWrite = v }
        case .gemini:
            guard let u = json["usageMetadata"] as? [String: Any] else { return }
            let cached = int(u["cachedContentTokenCount"]) ?? 0
            if let p = int(u["promptTokenCount"]) { usage.input = max(0, p - cached); usage.cacheRead = cached }
            // 思考用的 token 按输出计费
            let out = (int(u["candidatesTokenCount"]) ?? 0) + (int(u["thoughtsTokenCount"]) ?? 0)
            if out > 0 { usage.output = out }
        }
    }

    /// 没按流式返回的整段回复：有报错就报出来，有回答就取出回答
    private func plainReply(_ body: String) throws -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if json["error"] != nil { return try parseChunk(json) }
        switch config.apiProtocol {
        case .openAI:
            let message = ((json["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any]
            return message?["content"] as? String
        case .anthropic:
            let blocks = json["content"] as? [[String: Any]] ?? []
            return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .gemini:
            return try parseChunk(json)
        }
    }

    private func parseChunk(_ json: [String: Any]) throws -> String? {
        if let error = json["error"] {
            let msg = (error as? [String: Any])?["message"] as? String ?? "\(error)"
            throw LLMError(message: String(localized: "模型返回错误：\(msg)"))
        }
        switch config.apiProtocol {
        case .openAI:
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { return nil }
            var text = (choice["delta"] as? [String: Any])?["content"] as? String ?? ""
            switch choice["finish_reason"] as? String {
            case "length": text += L("\n\n（回答因长度限制被截断）")
            // 被服务商的内容审核拦下：以前什么也不说，看起来像回答到一半就停了
            case "content_filter": text += L("\n\n（模型拒绝回答这个请求，可以换个说法或换个模型试试）")
            default: break
            }
            return text

        case .anthropic:
            switch json["type"] as? String {
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any]
                return delta?["type"] as? String == "text_delta" ? delta?["text"] as? String : nil
            case "message_delta":
                switch (json["delta"] as? [String: Any])?["stop_reason"] as? String {
                case "refusal": return L("\n\n（模型拒绝回答这个请求，可以换个说法或换个模型试试）")
                case "max_tokens": return L("\n\n（回答因长度限制被截断）")
                default: return nil
                }
            default:
                return nil
            }

        case .gemini:
            // 整个请求被拦下（没有 candidates）：说清楚，不只显示“模型没有返回内容”
            if let reason = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
                throw LLMError(message: String(localized: "模型拒绝处理这个请求（\(reason)），可以换个说法或换个模型试试。"))
            }
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { return nil }
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            var text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            switch candidate["finishReason"] as? String {
            case "MAX_TOKENS": text += L("\n\n（回答因长度限制被截断）")
            case "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII":
                text += L("\n\n（模型拒绝回答这个请求，可以换个说法或换个模型试试）")
            default: break
            }
            return text
        }
    }

    // MARK: - 工具

    /// 合并相邻同角色消息、保证以用户消息开头（Anthropic / Gemini 要求角色交替）。
    static func normalized(_ messages: [LLMMessage]) -> [LLMMessage] {
        var result: [LLMMessage] = []
        for m in messages where !m.parts.isEmpty {
            if let last = result.last, last.role == m.role {
                result[result.count - 1].parts += m.parts
            } else {
                result.append(m)
            }
        }
        if result.first?.role == .assistant {
            result.insert(LLMMessage(role: .user, parts: [.text(Tutor.pick("你好", "Hello"))]), at: 0)
        }
        return result
    }

    // MARK: - 连不上时的提示

    /// 测试连接、获取模型列表最多等服务器多少秒：连得上的话几秒内就有回应，不用让人干等
    static let quickTimeout: TimeInterval = 20

    /// 在时限内做完 operation，否则报“连不上”
    static func withDeadline<T>(_ seconds: TimeInterval, host: String,
                                _ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw unreachableError(host: host)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    static func unreachableError(host: String) -> LLMError {
        LLMError(message: String(localized: "连不上 \(host)：服务器一直没有回应。可以先在 Safari 里打开这个网址试试；打不开就是当前网络到不了这个服务商，可以换个网络，或到服务商后台查有没有别的接口地址。"))
    }

    /// 把系统的网络错误（“请求超时。”这类）换成说得清原因和办法的提示；其他错误原样返回
    static func friendlyError(_ error: Error, host: String) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return LLMError(message: L("没有连上网络。如果别的 App 能上网，请在 iPad 的“设置”里找到 Stepwise，允许它使用无线数据。"))
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
            return unreachableError(host: host)
        default:
            return error
        }
    }

    static func describeError(status: Int, body: String) -> String {
        var detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            let obj = (json as? [[String: Any]])?.first ?? (json as? [String: Any]) ?? [:]
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                detail = msg
            } else if let msg = obj["error"] as? String {
                detail = msg
            } else if let msg = obj["message"] as? String {
                detail = msg
            }
        }
        if detail.count > 400 { detail = String(detail.prefix(400)) + "…" }
        let hint: String
        switch status {
        case 401, 403: hint = L("API Key 无效或没有权限。")
        case 404: hint = L("接口地址或模型名称不对。")
        case 429: hint = L("请求太频繁或余额不足。")
        case 400: hint = L("请求被拒绝（如果附带了图片，可能是该模型不支持图片）。")
        default: hint = ""
        }
        return String(localized: "请求失败（HTTP \(status)）\(hint)\n\(detail)")
    }
}

/// 请求和“等太久”的计时器谁先到：先收到响应头就算连上了，先到时限就算连不上，只有一个能成
private final class ResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var state = 0  // 0 还在等，1 已回应，2 已超时

    var timedOut: Bool { lock.withLock { state == 2 } }

    /// 收到回应；已经超时放弃了就返回 false
    func markResponded() -> Bool {
        lock.withLock {
            if state == 0 { state = 1 }
            return state == 1
        }
    }

    /// 到时限；已经回应过了就返回 false
    func markTimedOut() -> Bool {
        lock.withLock {
            if state == 0 { state = 2 }
            return state == 2
        }
    }
}

/// 记住哪些服务商 / 模型不接受某个可选参数（存下来，避免每次都多一次失败的请求），
/// 以及这次打开 App 以来带着它成功过的：之后再报 400 就不是这个参数的问题（比如模型不能看图），
/// 不用去掉它把题目和手写图片再发一遍，直接报错
final class ParameterMemory: @unchecked Sendable {
    /// 快速模式参数，按“服务商|模型”记
    static let fastMode = ParameterMemory(defaultsKey: "fastModeUnsupported")
    /// stream_options（报用量）参数，按服务商记
    static let usageOption = ParameterMemory(defaultsKey: "usageOptionUnsupported")

    private let lock = NSLock()
    private let defaultsKey: String
    private var unsupported: Set<String>
    private var knownGood: Set<String> = []

    private init(defaultsKey: String) {
        self.defaultsKey = defaultsKey
        unsupported = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    func isUnsupported(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return unsupported.contains(key)
    }

    func markUnsupported(_ key: String) {
        lock.lock()
        unsupported.insert(key)
        knownGood.remove(key)
        let list = Array(unsupported)
        lock.unlock()
        UserDefaults.standard.set(list, forKey: defaultsKey)
    }

    func isKnownGood(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return knownGood.contains(key)
    }

    func markGood(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        knownGood.insert(key)
    }
}
