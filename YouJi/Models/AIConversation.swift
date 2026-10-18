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
    var draft: String = ""

    init(
        id: UUID = UUID(),
        title: String = "新对话",
        createdAt: Date = .now,
        accountScopeKey: String = "",
        games: [AIAnalysisGame],
        draft: String = ""
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.accountScopeKey = accountScopeKey
        self.draft = draft
        self.messagesData = Self.encode([AIChatMessage]())
        self.gameContextData = Self.encode(games)
    }

    func readMessages() throws -> [AIChatMessage] {
        try JSONDecoder().decode([AIChatMessage].self, from: messagesData)
    }

    func readGames() throws -> [AIAnalysisGame] {
        try JSONDecoder().decode([AIAnalysisGame].self, from: gameContextData)
    }

    var hasUnreadableContent: Bool {
        (try? readMessages()) == nil || (try? readGames()) == nil
    }

    var canDiscardEmptyConversation: Bool {
        !hasUnreadableContent && ((try? readMessages().isEmpty) == true)
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var needsReply: Bool {
        !hasUnreadableContent && messages.last?.role == .user
    }

    func updateDraft(_ value: String, editedAt: Date = .now) {
        guard draft != value else { return }
        draft = value
        updatedAt = editedAt
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
        if hasUnreadableContent { return "内容暂时无法读取，原始记录已保留" }
        let savedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !savedDraft.isEmpty { return "草稿 · \(savedDraft)" }
        return messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? "开始聊聊你的游戏"
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
