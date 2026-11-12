import Foundation
import ImageIO
import Photos
import SwiftData
import UIKit
import UniformTypeIdentifiers

enum AIImageValidation {
    static let maximumBytes = 20_000_000

    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              (CGImageSourceGetType(source) as String?) == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4_096).contains(width), (1...4_096).contains(height), width * height <= 16_777_216 else {
            throw AIAnalysisError.invalidImage
        }
    }

    static func thumbnail(_ data: Data, maximumSize: Int = 640) -> UIImage? {
        guard (try? validate(data)) != nil, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumSize
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

@MainActor
enum AIImageService {
    static func saveProfileImage(data: Data, prompt: String, model: String, profileID: UUID,
                                 accountScope: String, expectedText: String, revision: UUID, in context: ModelContext) throws {
        try LocalDataRevision.check(revision)
        try AIImageValidation.validate(data)
        try LocalPersistence.transaction(context) { writer in
            guard let profile = try writer.fetch(FetchDescriptor<AIProfileResult>(predicate: #Predicate { $0.id == profileID })).first,
                  profile.accountScopeKey == accountScope, profile.text == expectedText else { throw CancellationError() }
            writer.insert(AIGeneratedImage(accountScopeKey: accountScope, ownerID: profileID, origin: .profile,
                                           prompt: prompt, modelName: model, pngData: data))
        }
    }

    static func saveChatImage(data: Data, prompt: String, model: String, conversationID: UUID,
                              accountScope: String, expectedMessages: [AIChatMessage], revision: UUID,
                              in context: ModelContext) throws -> AIChatMessage {
        try saveChatReply(AIChatReply(text: "图片已生成。", imageData: data, imagePrompt: prompt), model: model,
            conversationID: conversationID, accountScope: accountScope, expectedMessages: expectedMessages,
            revision: revision, in: context)
    }

    static func saveChatReply(_ result: AIChatReply, model: String, conversationID: UUID,
                             accountScope: String, expectedMessages: [AIChatMessage], revision: UUID,
                             in context: ModelContext) throws -> AIChatMessage {
        try LocalDataRevision.check(revision)
        if let data = result.imageData { try AIImageValidation.validate(data) }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || result.imageData != nil else { throw AIAnalysisError.invalidResponse }
        return try LocalPersistence.transaction(context) { writer in
            let conversation = try LocalPersistence.conversation(conversationID, in: writer)
            guard conversation.accountScopeKey == accountScope,
                  try conversation.readMessages() == expectedMessages,
                  expectedMessages.last?.role == .user else { throw CancellationError() }
            var imageID: UUID?
            let description = result.imagePrompt ?? expectedMessages.last?.content ?? "游戏图片"
            if let data = result.imageData {
                let image = AIGeneratedImage(accountScopeKey: accountScope, ownerID: conversationID, origin: .conversation,
                    prompt: String(description.prefix(32_000)), modelName: model, pngData: data)
                imageID = image.id
                writer.insert(image)
            }
            let reply = AIChatMessage(role: .assistant, content: text, imageID: imageID,
                                      imageDescription: imageID == nil ? nil : description)
            conversation.messages = expectedMessages + [reply]
            return reply
        }
    }

    static func deleteImages(ownerID: UUID, origin: AIGeneratedImage.Origin, in context: ModelContext) throws {
        let kind = origin.rawValue
        for image in try context.fetch(FetchDescriptor<AIGeneratedImage>(predicate: #Predicate {
            $0.ownerID == ownerID && $0.originRaw == kind
        })) { context.delete(image) }
    }

    static func saveToPhotos(_ data: Data) async throws {
        try AIImageValidation.validate(data)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw AIImageSaveError.permissionDenied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}

enum AIImageSaveError: LocalizedError {
    case permissionDenied
    var errorDescription: String? { "未获得保存到相册的权限。你仍可通过分享保存到“文件”。" }
}


enum AIConversationWriteError: LocalizedError {
    case changed
    var errorDescription: String? { "这段对话已有新的内容，请返回列表重新打开后继续。" }
}
