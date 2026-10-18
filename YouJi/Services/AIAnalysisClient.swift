import Foundation
import CryptoKit

actor AIAnalysisClient {
    static let shared = AIAnalysisClient()
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration)
    }

    func analyze(games: [AIAnalysisGame], apiKey: String, model: String) async throws -> String {
        guard !games.isEmpty else { throw AIAnalysisError.emptyGames }
        return try await completion(
            messages: [ChatMessage(role: "system", content: AIPrompts.personalitySystem(games: games)),
                       ChatMessage(role: "user", content: AIPrompts.personalityRequest)],
            apiKey: apiKey, model: model, temperature: 0.6, maxTokens: 700
        )
    }

    func testConnection(apiKey: String, model: String) async throws {
        _ = try await completion(messages: [ChatMessage(role: "user", content: "只回复 OK")],
                                 apiKey: apiKey, model: model, temperature: 0, maxTokens: 8)
    }

    func chat(games: [AIAnalysisGame], messages: [AIChatMessage], apiKey: String, model: String) async throws -> String {
        guard !games.isEmpty else { throw AIAnalysisError.emptyChatGames }
        guard messages.contains(where: { $0.role == .user }) else { throw AIAnalysisError.emptyMessage }
        return try await completion(
            messages: [ChatMessage(role: "system", content: AIPrompts.chatSystem(games: games))]
                + messages.map { ChatMessage(role: $0.role.rawValue, content: $0.content) },
            apiKey: apiKey, model: model, temperature: 0.65, maxTokens: 900
        )
    }

    func conversationTitle(messages: [AIChatMessage], apiKey: String, model: String) async throws -> String {
        guard messages.contains(where: { $0.role == .user }) else { throw AIAnalysisError.emptyMessage }
        let rawTitle = try await completion(
            messages: [ChatMessage(role: "system", content: AIPrompts.titleSystem),
                       ChatMessage(role: "user", content: AIPrompts.titleRequest(messages: messages))],
            apiKey: apiKey, model: model, temperature: 0.3, maxTokens: 30
        )
        let title = Self.cleanTitle(rawTitle)
        guard !title.isEmpty else { throw AIAnalysisError.invalidResponse }
        return title
    }

    private func completion(messages: [ChatMessage], apiKey: String, model: String,
                            temperature: Double, maxTokens: Int) async throws -> String {
        let url = try AISettingsStore.validate(apiKey: apiKey, modelName: model, endpoint: AISettingsStore.endpointString)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model.trimmingCharacters(in: .whitespacesAndNewlines), messages: messages, stream: false, temperature: temperature, maxTokens: maxTokens
        ))
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIAnalysisError.invalidResponse }
            guard 200..<300 ~= http.statusCode else {
                // Never surface provider response bodies: they can contain request
                // content or credentials. Status-specific guidance is enough to act.
                throw AIAnalysisError.httpStatus(http.statusCode)
            }
            let result: ChatResponse
            do { result = try JSONDecoder().decode(ChatResponse.self, from: data) }
            catch { throw AIAnalysisError.invalidResponse }
            guard let content = result.choices.first?.message.content?
                .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
                throw AIAnalysisError.invalidResponse
            }
            return content
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw AIAnalysisError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw AIAnalysisError.connectionFailed
            default: throw AIAnalysisError.connectionFailed
            }
        }
    }

    private static func cleanTitle(_ rawTitle: String) -> String {
        let firstLine = rawTitle.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t#*`\"'“”‘’「」『』。！？"))
        return String(trimmed.prefix(18))
    }
}

struct AIAnalysisGame: Codable, Sendable, Equatable {
    let platform: String
    let title: String
    let totalMinutes: Int
    let trophyRatio: String?
}

struct AIChatMessage: Codable, Identifiable, Sendable, Equatable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let content: String
	let createdAt: Date

    enum CodingKeys: String, CodingKey { case id, role, content, createdAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        role = try values.decode(Role.self, forKey: .role)
        content = try values.decode(String.self, forKey: .content)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        if let storedID = try values.decodeIfPresent(UUID.self, forKey: .id) {
            id = storedID
        } else {
            // Old message JSON did not always have an ID/date. Keep fallback IDs
            // stable across reads and distinguish identical messages by array index.
            let path = decoder.codingPath.map(\.stringValue).joined(separator: "/")
            let bytes = Array(SHA256.hash(data: Data("\(path):\(role.rawValue):\(content)".utf8)).prefix(16))
            id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }
    }

    init(
        id: UUID = UUID(),
        role: Role,
		content: String,
		createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.content = content
		self.createdAt = createdAt
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String?

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

private struct ChatResponse: Decodable {
    let choices: [ChatChoice]
}

private struct ChatChoice: Decodable {
    let message: ChatMessage
}

enum AIAnalysisError: LocalizedError {
    case emptyGames
    case emptyChatGames
    case emptyMessage
    case missingConfiguration
    case invalidResponse
    case httpStatus(Int)
    case timedOut
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .emptyGames: "当前筛选没有可分析的游戏。"
        case .emptyChatGames: "还没有游玩超过 1 小时的游戏。"
        case .emptyMessage: "请输入想聊的内容。"
        case .missingConfiguration: "请先在设置中填写 API Key 和模型名称。"
        case .invalidResponse: "服务返回了无法识别的内容。请确认使用 Chat Completions 兼容接口，或稍后重试。"
        case .timedOut: "模型响应超时，请稍后重试，或在设置中换用响应更快的模型。已保存的对话不会丢失。"
        case .connectionFailed: "暂时连接不到 AI 服务。请检查网络和接口地址后重试。"
        case .httpStatus(let status):
            switch status {
            case 401, 403: "AI 服务拒绝了密钥。请在设置中检查 API Key 是否属于该服务，并确认有使用此模型的权限。"
            case 400, 404, 422: "AI 服务未接受请求。请检查完整接口地址、模型名称及 Chat Completions 兼容性。"
            case 402: "AI 服务账户的额度不足，请在服务商处检查余额后重试。"
            case 429: "请求过于频繁或服务额度已用完。请稍后重试，或在服务商处检查额度。"
            case 500...599: "AI 服务暂时不可用，请稍后重试。"
            default: "AI 服务返回错误（\(status)），请检查配置或稍后重试。"
            }
        }
    }
}
