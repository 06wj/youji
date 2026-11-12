import Foundation
import CryptoKit

actor AIAnalysisClient {
    static let shared = AIAnalysisClient()
    private let session: URLSession
    private let redirectBlocker = OpenAIRedirectBlocker()

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 360
        self.session = session ?? URLSession(configuration: configuration)
    }

    func analyze(games: [AIAnalysisGame], apiKey: String, model: String) async throws -> String {
        guard !games.isEmpty else { throw AIAnalysisError.emptyGames }
        return try await completion(instructions: AIPrompts.personalitySystem(games: games),
            messages: [ResponseInputMessage(role: "user", content: AIPrompts.personalityRequest)],
            apiKey: apiKey, model: model, maxTokens: 4_096)
    }

    func testConnection(apiKey: String, model: String) async throws {
        _ = try await completion(instructions: "Reply with OK.",
            messages: [ResponseInputMessage(role: "user", content: "OK")],
            apiKey: apiKey, model: model, maxTokens: 1_024, brief: true)
    }

    func chat(games: [AIAnalysisGame], messages: [AIChatMessage], apiKey: String, model: String,
              imageModel: String = AISettingsStore.defaultImageModelName,
              recentPlay: AIRecentPlayContext? = nil, gameSnapshotDate: Date? = nil) async throws -> AIChatReply {
        guard !games.isEmpty else { throw AIAnalysisError.emptyChatGames }
        guard messages.contains(where: { $0.role == .user }) else { throw AIAnalysisError.emptyMessage }
        try recentPlay?.validate()
        try AISettingsStore.validateRequest(apiKey: apiKey, modelName: imageModel)
        let textModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ResponsesRequest(model: textModel, instructions: AIPrompts.chatSystem(games: games, recentPlay: recentPlay, gameSnapshotDate: gameSnapshotDate),
            input: messages.map { ResponseInputMessage(role: $0.role.rawValue, content: $0.requestText) },
            maxOutputTokens: 6_144,
            reasoning: textModel == AISettingsStore.defaultModelName ? ResponseReasoning(effort: "low") : nil,
            tools: [ResponseImageTool(model: imageModel.trimmingCharacters(in: .whitespacesAndNewlines))],
            toolChoice: messages.last?.requestsImage == true ? .image : .auto, maxToolCalls: 1)
        let data = try await send(url: AISettingsStore.responsesURL, body: body, apiKey: apiKey, model: textModel, imageRequest: true)
        let result = try decodedResponse(data)
        let text = try responseText(result)
        let images = result.output.filter { $0.type == "image_generation_call" }
        guard images.count <= 1 else { throw AIAnalysisError.invalidResponse }
        var png: Data?
        var description: String?
        if let image = images.first {
            guard image.status == "completed", let encoded = image.result,
                  encoded.utf8.count <= AIImageValidation.maximumBytes * 4 / 3 + 4,
                  let decoded = Data(base64Encoded: encoded) else { throw AIAnalysisError.invalidImage }
            try AIImageValidation.validate(decoded)
            png = decoded
            description = String((image.revisedPrompt ?? messages.last?.content ?? "游戏图片").prefix(32_000))
        }
        guard !text.isEmpty || png != nil else { throw AIAnalysisError.invalidResponse }
        return AIChatReply(text: text, imageData: png, imagePrompt: description)
    }

    func conversationTitle(messages: [AIChatMessage], apiKey: String, model: String) async throws -> String {
        guard messages.contains(where: { $0.role == .user }) else { throw AIAnalysisError.emptyMessage }
        let text = try await completion(instructions: AIPrompts.titleSystem,
            messages: [ResponseInputMessage(role: "user", content: AIPrompts.titleRequest(messages: messages))],
            apiKey: apiKey, model: model, maxTokens: 1_024, brief: true)
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = String(firstLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t#*`\"'“”‘’「」『』。！？")).prefix(18))
        guard !title.isEmpty else { throw AIAnalysisError.invalidResponse }
        return title
    }

    func generateImage(prompt: String, apiKey: String, model: String, portrait: Bool = false) async throws -> Data {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIAnalysisError.emptyMessage }
        guard prompt.count <= 32_000 else { throw AIAnalysisError.imagePromptTooLong }
        let body = ImageGenerationRequest(model: model.trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt,
                                          size: portrait ? "1024x1536" : "1024x1024")
        let data = try await send(url: AISettingsStore.imagesURL, body: body, apiKey: apiKey, model: model, imageRequest: true)
        guard let result = try? JSONDecoder().decode(ImageGenerationResponse.self, from: data),
              let encoded = result.data.first?.b64JSON,
              encoded.utf8.count <= AIImageValidation.maximumBytes * 4 / 3 + 4,
              let image = Data(base64Encoded: encoded) else { throw AIAnalysisError.invalidImage }
        try AIImageValidation.validate(image)
        return image
    }

    private func completion(instructions: String, messages: [ResponseInputMessage], apiKey: String, model: String,
                            maxTokens: Int, brief: Bool = false) async throws -> String {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ResponsesRequest(model: model, instructions: instructions, input: messages,
            maxOutputTokens: maxTokens,
            reasoning: model == AISettingsStore.defaultModelName ? ResponseReasoning(effort: brief ? "none" : "low") : nil)
        let data = try await send(url: AISettingsStore.responsesURL, body: body, apiKey: apiKey, model: model)
        let text = try responseText(decodedResponse(data))
        guard !text.isEmpty else { throw AIAnalysisError.invalidResponse }
        return text
    }

    private func decodedResponse(_ data: Data) throws -> ResponsesResult {
        guard let result = try? JSONDecoder().decode(ResponsesResult.self, from: data) else { throw AIAnalysisError.invalidResponse }
        guard result.status == "completed" else {
            if result.status == "incomplete" { throw AIAnalysisError.incompleteResponse }
            throw AIAnalysisError.invalidResponse
        }
        return result
    }

    private func responseText(_ result: ResponsesResult) throws -> String {
        let content = result.output.filter { $0.type == "message" && $0.role == "assistant" }.flatMap { $0.content ?? [] }
        guard !content.contains(where: { $0.type == "refusal" }) else { throw AIAnalysisError.refused }
        return content.filter { $0.type == "output_text" }.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send<Body: Encodable>(url: URL, body: Body, apiKey: String, model: String, imageRequest: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        try AISettingsStore.validateRequest(apiKey: apiKey, modelName: model)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = imageRequest ? 300 : 180
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        do {
            let (data, response) = try await session.data(for: request, delegate: redirectBlocker)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw AIAnalysisError.invalidResponse }
            guard 200..<300 ~= http.statusCode else {
                // Only a known error code is inspected. Never expose response bodies,
                // which can echo credentials, user prompts, or game context.
                let code = (try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data))?.error.code
                if code == "content_policy_violation" { throw AIAnalysisError.refused }
                if code == "insufficient_quota" { throw AIAnalysisError.insufficientQuota }
                throw AIAnalysisError.httpStatus(http.statusCode)
            }
            guard data.count <= (imageRequest ? 30_000_000 : 2_000_000) else { throw AIAnalysisError.invalidResponse }
            return data
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw AIAnalysisError.timedOut
            default: throw AIAnalysisError.connectionFailed
            }
        }
    }
}

private final class OpenAIRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct AIChatReply: Sendable {
    let text: String
    var imageData: Data? = nil
    var imagePrompt: String? = nil
}

struct AIAnalysisGame: Codable, Sendable, Equatable, Hashable {
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
    let imageID: UUID?
    let requestsImage: Bool
    let imageDescription: String?

    enum CodingKeys: String, CodingKey { case id, role, content, createdAt, imageID, requestsImage, imageDescription }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        role = try values.decode(Role.self, forKey: .role)
        content = try values.decode(String.self, forKey: .content)
        imageID = try values.decodeIfPresent(UUID.self, forKey: .imageID)
        requestsImage = try values.decodeIfPresent(Bool.self, forKey: .requestsImage) ?? false
        imageDescription = try values.decodeIfPresent(String.self, forKey: .imageDescription)
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
		createdAt: Date = .now,
        imageID: UUID? = nil,
        requestsImage: Bool = false,
        imageDescription: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
		self.createdAt = createdAt
        self.imageID = imageID
        self.requestsImage = requestsImage
        self.imageDescription = imageDescription
    }

    var requestText: String {
        if imageID != nil { return "[此前已生成一张图片，当前只提供文字描述，不含图片像素] \(imageDescription ?? content)" }
        return requestsImage ? "[绘图请求] \(content)" : content
    }

}


private struct ResponseInputMessage: Encodable {
    let role: String
    let content: String
}
private struct ResponseReasoning: Encodable { let effort: String }
private struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: [ResponseInputMessage]
    let maxOutputTokens: Int
    let reasoning: ResponseReasoning?
    var tools: [ResponseImageTool]? = nil
    var toolChoice: ResponseToolChoice? = nil
    var maxToolCalls: Int? = nil
    let store = false
    let stream = false
    enum CodingKeys: String, CodingKey {
        case model, instructions, input, reasoning, store, stream
        case maxOutputTokens = "max_output_tokens"
        case tools
        case toolChoice = "tool_choice"
        case maxToolCalls = "max_tool_calls"
    }
}
private struct ResponseImageTool: Encodable {
    let model: String
    let type = "image_generation"
    let action = "generate"
    let quality = "medium"
    let size = "auto"
    let outputFormat = "png"
    enum CodingKeys: String, CodingKey {
        case model, type, action, quality, size
        case outputFormat = "output_format"
    }
}
private enum ResponseToolChoice: Encodable {
    case auto, image
    func encode(to encoder: Encoder) throws {
        if self == .auto {
            var container = encoder.singleValueContainer()
            try container.encode("auto")
        } else {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode("image_generation", forKey: .type)
        }
    }
    private enum Key: String, CodingKey { case type }
}

private struct ResponsesResult: Decodable {
    let status: String
    let output: [ResponseOutput]
}
private struct ResponseOutput: Decodable {
    let type: String
    let role: String?
    let content: [ResponseContent]?
    let status: String?
    let result: String?
    let revisedPrompt: String?
    enum CodingKeys: String, CodingKey {
        case type, role, content, status, result
        case revisedPrompt = "revised_prompt"
    }
}
private struct ResponseContent: Decodable {
    let type: String
    let text: String?
}
private struct ImageGenerationRequest: Encodable {
    let model: String
    let prompt: String
    let size: String
    let n = 1
    let quality = "medium"
    let outputFormat = "png"
    enum CodingKeys: String, CodingKey {
        case model, prompt, size, n, quality
        case outputFormat = "output_format"
    }
}
private struct ImageGenerationResponse: Decodable {
    let data: [Item]
    struct Item: Decodable {
        let b64JSON: String?
        enum CodingKeys: String, CodingKey { case b64JSON = "b64_json" }
    }
}
private struct OpenAIErrorResponse: Decodable {
    let error: Details
    struct Details: Decodable { let code: String? }
}

enum AIAnalysisError: LocalizedError {
    case emptyGames, emptyChatGames, emptyMessage, missingConfiguration
    case invalidResponse, incompleteResponse, invalidImage, imagePromptTooLong, refused, insufficientQuota
    case httpStatus(Int)
    case timedOut, connectionFailed

    var errorDescription: String? {
        switch self {
        case .emptyGames: "当前筛选没有可分析的游戏。"
        case .emptyChatGames: "还没有游玩超过 1 小时的游戏。"
        case .emptyMessage: "请输入想聊或想画的内容。"
        case .missingConfiguration: "请先在设置中填写 OpenAI API Key。"
        case .invalidResponse: "OpenAI 返回了无法识别的内容，请稍后重试。"
        case .incompleteResponse: "这次回复未生成完整，请缩短问题或换用其他文字模型后重试。"
        case .invalidImage: "未收到可保存的图片，请稍后重试。"
        case .imagePromptTooLong: "这段对话太长，无法完整用于绘图。请新开对话并简述画面要求。"
        case .refused: "这次内容未能生成，请调整描述后重试。"
        case .insufficientQuota: "OpenAI API 额度不足，请在 OpenAI 平台检查用量与账单。"
        case .timedOut: "OpenAI 响应超时，请稍后重试。绘图可能需要更长时间；已有内容会保留。"
        case .connectionFailed: "暂时连接不到 OpenAI，请检查网络后重试。"
        case .httpStatus(let status):
            switch status {
            case 401: "OpenAI API Key 无效或已失效，请在设置中更新。"
            case 403: "OpenAI 拒绝了请求，请检查账号、地区及所选模型的使用权限。绘图可能需要完成组织验证。"
            case 400, 404, 422: "OpenAI 未接受请求，请检查所选文字或绘图模型是否可用。"
            case 402: "OpenAI API 额度不足，请检查账户账单。"
            case 429: "请求过于频繁或 OpenAI API 额度已用完，请稍后重试或检查用量。"
            case 500...599: "OpenAI 暂时不可用，请稍后重试。"
            default: "OpenAI 返回错误（\(status)），请稍后重试。"
            }
        }
    }
}
