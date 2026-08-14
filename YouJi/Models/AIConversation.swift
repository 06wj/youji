import Foundation
import SwiftData

@Model
final class AIConversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var titleGeneratedAt: Date?
    var messagesData: Data
    var gameContextData: Data
    var accountScopeKey: String = ""

    init(
        id: UUID = UUID(),
        title: String = "新对话",
        createdAt: Date = .now,
        accountScopeKey: String = "",
        games: [AIAnalysisGame]
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.accountScopeKey = accountScopeKey
        self.messagesData = Self.encode([AIChatMessage]())
        self.gameContextData = Self.encode(games)
    }

    var messages: [AIChatMessage] {
        get { Self.decode([AIChatMessage].self, from: messagesData) ?? [] }
        set {
            messagesData = Self.encode(newValue)
            updatedAt = .now
        }
    }

    var games: [AIAnalysisGame] {
        get { Self.decode([AIAnalysisGame].self, from: gameContextData) ?? [] }
        set { gameContextData = Self.encode(newValue) }
    }

    var preview: String {
        messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? "开始聊聊你的游戏"
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
