import Foundation

actor AIAnalysisClient {
    static let shared = AIAnalysisClient()

    private let session: URLSession
    private var endpoint: URL { AISettingsStore.endpointURL }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration)
    }

    func analyze(games: [AIAnalysisGame], apiKey: String, model: String) async throws -> String {
		guard !games.isEmpty else { throw AIAnalysisError.emptyGames }
        guard !apiKey.isEmpty, !model.isEmpty else { throw AIAnalysisError.missingConfiguration }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: AIPrompts.personalitySystem(games: games)),
                ChatMessage(role: "user", content: AIPrompts.personalityRequest),
            ],
            stream: false,
            temperature: 0.6,
            maxTokens: 700
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIAnalysisError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            let apiError = try? JSONDecoder().decode(ChatErrorResponse.self, from: data)
            throw AIAnalysisError.server(apiError?.error.message ?? "AI 服务返回错误（\(http.statusCode)）")
        }
        let result = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = result.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw AIAnalysisError.invalidResponse
        }
        return content
    }

    func testConnection(apiKey: String, model: String) async throws {
        guard !apiKey.isEmpty, !model.isEmpty else { throw AIAnalysisError.missingConfiguration }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: "只回复 OK")],
            stream: false,
            temperature: 0,
            maxTokens: 8
        ))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIAnalysisError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            let apiError = try? JSONDecoder().decode(ChatErrorResponse.self, from: data)
            throw AIAnalysisError.server(apiError?.error.message ?? "AI 服务返回错误（\(http.statusCode)）")
        }
    }

    func chat(
        games: [AIAnalysisGame],
        messages: [AIChatMessage],
        apiKey: String,
        model: String
    ) async throws -> String {
		guard !games.isEmpty else { throw AIAnalysisError.emptyChatGames }
        guard messages.contains(where: { $0.role == .user }) else {
            throw AIAnalysisError.emptyMessage
        }
        guard !apiKey.isEmpty, !model.isEmpty else { throw AIAnalysisError.missingConfiguration }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: AIPrompts.chatSystem(games: games)),
            ] + messages.map { ChatMessage(role: $0.role.rawValue, content: $0.content) },
            stream: false,
            temperature: 0.65,
            maxTokens: 900
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIAnalysisError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            let apiError = try? JSONDecoder().decode(ChatErrorResponse.self, from: data)
            throw AIAnalysisError.server(apiError?.error.message ?? "AI 服务返回错误（\(http.statusCode)）")
        }
        let result = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = result.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw AIAnalysisError.invalidResponse
        }
        return content
    }

	func conversationTitle(
		messages: [AIChatMessage],
		apiKey: String,
		model: String
	) async throws -> String {
		guard messages.contains(where: { $0.role == .user }) else {
			throw AIAnalysisError.emptyMessage
		}
		guard !apiKey.isEmpty, !model.isEmpty else { throw AIAnalysisError.missingConfiguration }

		var request = URLRequest(url: endpoint)
		request.httpMethod = "POST"
		request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONEncoder().encode(ChatRequest(
			model: model,
			messages: [
				ChatMessage(role: "system", content: AIPrompts.titleSystem),
				ChatMessage(role: "user", content: AIPrompts.titleRequest(messages: messages)),
			],
			stream: false,
			temperature: 0.3,
			maxTokens: 30
		))

		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse else { throw AIAnalysisError.invalidResponse }
		guard 200..<300 ~= http.statusCode else {
			let apiError = try? JSONDecoder().decode(ChatErrorResponse.self, from: data)
			throw AIAnalysisError.server(apiError?.error.message ?? "AI 服务返回错误（\(http.statusCode)）")
		}
		let result = try JSONDecoder().decode(ChatResponse.self, from: data)
		guard let rawTitle = result.choices.first?.message.content else {
			throw AIAnalysisError.invalidResponse
		}
		let title = Self.cleanTitle(rawTitle)
		guard !title.isEmpty else { throw AIAnalysisError.invalidResponse }
		return title
	}

	private static func cleanTitle(_ rawTitle: String) -> String {
		let firstLine = rawTitle
			.split(whereSeparator: \.isNewline)
			.first
			.map(String.init) ?? ""
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

private struct ChatErrorResponse: Decodable {
    let error: ChatErrorBody
}

private struct ChatErrorBody: Decodable {
    let message: String
}

enum AIAnalysisError: LocalizedError {
    case emptyGames
	case emptyChatGames
    case emptyMessage
    case missingConfiguration
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .emptyGames: "当前筛选没有可分析的游戏。"
		case .emptyChatGames: "还没有游玩超过 1 小时的游戏。"
        case .emptyMessage: "请输入想聊的内容。"
        case .missingConfiguration: "请先在设置中填写 API Key 和模型名称。"
        case .invalidResponse: "AI 返回的数据无法读取，请稍后重试。"
        case .server(let message): message
        }
    }
}
