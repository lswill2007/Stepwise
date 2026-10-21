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
            let task = Task {
                do {
                    let normalized = Self.normalized(messages)
                    let fastKey = "\(config.id)|\(model)"
                    // 这个模型之前拒绝过快速模式参数，就不再带
                    var useFast = options.fast && !FastModeMemory.isUnsupported(fastKey) && !fastParameters().isEmpty
                    var request = try makeChatRequest(system: system, messages: normalized, fast: useFast)
                    var (bytes, response) = try await Self.session.bytes(for: request)
                    var status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if useFast && (status == 400 || status == 422) {
                        // 模型不支持这些参数：记下来，去掉参数立即重试一次
                        FastModeMemory.markUnsupported(fastKey)
                        useFast = false
                        request = try makeChatRequest(system: system, messages: normalized, fast: false)
                        (bytes, response) = try await Self.session.bytes(for: request)
                        status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    }
                    if status != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line + "\n" }
                        throw LLMError(message: Self.describeError(status: status, body: body))
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let text = try parseChunk(json), !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
        let (data, response) = try await Self.session.data(for: request)
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

    // MARK: - 请求构造

    private func url(_ string: String) throws -> URL {
        guard let url = URL(string: string), url.scheme?.hasPrefix("http") == true else {
            throw LLMError(message: "接口地址无效：\(string)")
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
        "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"
    ]

    /// 快速模式下各家服务商用来减少思考的参数（会合并进请求体）。返回空表示这个模型没有可调的参数。
    func fastParameters() -> [String: Any] {
        let m = model.lowercased()
        switch config.apiProtocol {
        case .openAI:
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
            return prefixes.contains(where: m.hasPrefix) ? ["output_config": ["effort": "low"]] : [:]
        case .gemini:
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

    private func makeChatRequest(system: String, messages: [LLMMessage], fast: Bool = false) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw LLMError(message: "还没有填写 \(config.name) 的 API Key，请到设置里填写。") }
        guard !model.isEmpty else { throw LLMError(message: "还没有选择 \(config.name) 的模型，请到设置里选择。") }

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
                "system": system,
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
            for (key, value) in fastParameters() { body[key] = value }
        }

        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - 流式解析

    private func parseChunk(_ json: [String: Any]) throws -> String? {
        if let error = json["error"] {
            let msg = (error as? [String: Any])?["message"] as? String ?? "\(error)"
            throw LLMError(message: "模型返回错误：\(msg)")
        }
        switch config.apiProtocol {
        case .openAI:
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { return nil }
            var text = (choice["delta"] as? [String: Any])?["content"] as? String ?? ""
            if choice["finish_reason"] as? String == "length" { text += "\n\n（回答因长度限制被截断）" }
            return text

        case .anthropic:
            switch json["type"] as? String {
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any]
                return delta?["type"] as? String == "text_delta" ? delta?["text"] as? String : nil
            case "message_delta":
                switch (json["delta"] as? [String: Any])?["stop_reason"] as? String {
                case "refusal": return "\n\n（模型拒绝回答这个请求，可以换个说法或换个模型试试）"
                case "max_tokens": return "\n\n（回答因长度限制被截断）"
                default: return nil
                }
            default:
                return nil
            }

        case .gemini:
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { return nil }
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            return parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
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
            result.insert(LLMMessage(role: .user, parts: [.text("你好")]), at: 0)
        }
        return result
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
        case 401, 403: hint = "API Key 无效或没有权限。"
        case 404: hint = "接口地址或模型名称不对。"
        case 429: hint = "请求太频繁或余额不足。"
        case 400: hint = "请求被拒绝（如果附带了图片，可能是该模型不支持图片）。"
        default: hint = ""
        }
        return "请求失败（HTTP \(status)）\(hint)\n\(detail)"
    }
}

/// 记住哪些模型不接受快速模式参数，避免每次都多一次失败的请求
enum FastModeMemory {
    private static let lock = NSLock()
    private static var unsupported: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "fastModeUnsupported") ?? [])

    static func isUnsupported(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return unsupported.contains(key)
    }

    static func markUnsupported(_ key: String) {
        lock.lock()
        unsupported.insert(key)
        let list = Array(unsupported)
        lock.unlock()
        UserDefaults.standard.set(list, forKey: "fastModeUnsupported")
    }
}
