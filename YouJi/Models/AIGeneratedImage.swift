import Foundation
import SwiftData

@Model
final class AIGeneratedImage {
    @Attribute(.unique) var id: UUID
    var accountScopeKey: String
    var ownerID: UUID
    var originRaw: String
    var createdAt: Date
    var prompt: String
    var modelName: String
    @Attribute(.externalStorage) var pngData: Data

    init(id: UUID = UUID(), accountScopeKey: String, ownerID: UUID, origin: Origin,
         createdAt: Date = .now, prompt: String, modelName: String, pngData: Data) {
        self.id = id
        self.accountScopeKey = accountScopeKey
        self.ownerID = ownerID
        self.originRaw = origin.rawValue
        self.createdAt = createdAt
        self.prompt = prompt
        self.modelName = modelName
        self.pngData = pngData
    }

    enum Origin: String, Codable, Sendable { case conversation, profile }
}
