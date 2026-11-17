import Foundation
import Network

struct AISettings: Equatable {
    var baseURL: String
    var model: String
    var wifiOnly: Bool
    var manualOnly: Bool

    static let apiKeyAccount = "openai_compatible_api_key"

    static var current: AISettings {
        let defaults = UserDefaults.standard
        return AISettings(
            baseURL: defaults.string(forKey: "ai.baseURL") ?? "https://api.openai.com/v1",
            model: defaults.string(forKey: "ai.model") ?? "gpt-4o-mini",
            wifiOnly: defaults.object(forKey: "ai.wifiOnly") as? Bool ?? true,
            manualOnly: defaults.object(forKey: "ai.manualOnly") as? Bool ?? true
        )
    }

    func save(apiKey: String?) {
        let defaults = UserDefaults.standard
        defaults.set(baseURL, forKey: "ai.baseURL")
        defaults.set(model, forKey: "ai.model")
        defaults.set(wifiOnly, forKey: "ai.wifiOnly")
        defaults.set(manualOnly, forKey: "ai.manualOnly")
        if let apiKey {
            if apiKey.isEmpty {
                KeychainHelper.delete(account: Self.apiKeyAccount)
            } else {
                KeychainHelper.set(apiKey, account: Self.apiKeyAccount)
            }
        }
    }

    var apiKey: String? {
        KeychainHelper.get(account: Self.apiKeyAccount)
    }

    var isConfigured: Bool {
        !(apiKey ?? "").isEmpty && !baseURL.isEmpty && !model.isEmpty
    }
}

enum OpenAICompatibleClient {
    struct ChatMessage: Encodable {
        let role: String
        let content: String
    }

    struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    static func summarize(transcript: String, settings: AISettings) async throws -> String {
        guard let key = settings.apiKey, !key.isEmpty else {
            throw SummaryError.notConfigured
        }
        if settings.wifiOnly {
            let expensive = await isExpensivePath()
            if expensive {
                throw SummaryError.wifiOnly
            }
        }

        var base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else {
            throw SummaryError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let prompt = """
        请用简体中文对以下语音转写做总结分析，输出：
        1) 摘要（2-4 句）
        2) 要点列表
        3) 可选行动项（若有）

        转写内容：
        \(transcript)
        """
        let body = ChatRequest(
            model: settings.model,
            messages: [
                .init(role: "system", content: "你是简洁的中文会议/备忘录助手。"),
                .init(role: "user", content: prompt)
            ],
            temperature: 0.3
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SummaryError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SummaryError.http(http.statusCode, raw)
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw SummaryError.empty
        }
        return content
    }

    private static func isExpensivePath() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "TapNote.NWPath")
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.isExpensive || path.isConstrained)
            }
            monitor.start(queue: queue)
        }
    }
}

enum SummaryError: LocalizedError {
    case notConfigured
    case wifiOnly
    case badURL
    case badResponse
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "未配置 API Key"
        case .wifiOnly: return "当前为蜂窝网络，设置要求仅 Wi-Fi"
        case .badURL: return "Base URL 无效"
        case .badResponse: return "响应无效"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .empty: return "模型返回为空"
        }
    }
}
