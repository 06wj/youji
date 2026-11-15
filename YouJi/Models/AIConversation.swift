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
    // Retain the old columns so SwiftData can open existing stores for cleanup.
    var gameContextData: Data
    var recentPlayContextData: Data?
    var usesLocalQueries: Bool?
    var accountScopeKey: String = ""
    var draft: String = ""
    var draftRequestsImage: Bool = false

    init(
        id: UUID = UUID(),
        title: String = "新对话",
        createdAt: Date = .now,
        accountScopeKey: String = "",
        draft: String = ""
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.accountScopeKey = accountScopeKey
        self.draft = draft
        self.messagesData = Self.encode([AIChatMessage]())
        self.gameContextData = Data("[]".utf8)
        self.usesLocalQueries = true
    }

    func readMessages() throws -> [AIChatMessage] {
        try JSONDecoder().decode([AIChatMessage].self, from: messagesData)
    }

    var hasUnreadableContent: Bool {
        (try? readMessages()) == nil
    }

    var canDiscardEmptyConversation: Bool {
        !hasUnreadableContent && ((try? readMessages().isEmpty) == true)
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var needsReply: Bool {
        !hasUnreadableContent && messages.last?.role == .user
    }

    func updateDraft(_ value: String, requestsImage: Bool? = nil, editedAt: Date = .now) {
        guard draft != value || requestsImage.map({ $0 != draftRequestsImage }) == true else { return }
        draft = value
        if let requestsImage { draftRequestsImage = requestsImage }
        updatedAt = editedAt
    }

    var messages: [AIChatMessage] {
        get { Self.decode([AIChatMessage].self, from: messagesData) ?? [] }
        set {
            messagesData = Self.encode(newValue)
            updatedAt = .now
        }
    }

    var preview: String {
        if hasUnreadableContent { return "内容暂时无法读取，原始记录已保留" }
        let savedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !savedDraft.isEmpty { return "草稿 · \(savedDraft)" }
        guard let last = messages.last else { return "开始聊聊你的游戏" }
        let text = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty && last.imageID != nil ? "已生成图片" : text
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
