import XCTest
import SwiftData
import UIKit
@testable import YouJi

@MainActor
final class OpenAIIntegrationTests: XCTestCase {
    private let game = AIAnalysisGame(platform: "PS", title: "宇宙机器人", totalMinutes: 120, trophyRatio: "1/10")
    private let completed = #"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"第一段"},{"type":"output_text","text":"第二段"}]}]}"#

    private func session(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) -> URLSession {
        OpenAIStub.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenAIStub.self]
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel(); OpenAIStub.handler = nil }
        return session
    }

    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { renderer in
            UIColor.blue.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData()!
    }

    private func store() throws -> ModelContainer {
        try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testResponsesRequestIncludesFrozenGamesAndConversationWithoutLocalMetadata() async throws {
        let log = OpenAIRequestLog()
        let response = Data(completed.utf8)
        let session = session { request in log.record(request); return (200, response) }
        let user = AIChatMessage(role: .user, content: "今晚玩什么？")
        let answer = try await AIAnalysisClient(session: session).chat(games: [game], messages: [user],
            apiKey: "test-placeholder", model: AISettingsStore.defaultModelName)
        XCTAssertEqual(answer.text, "第一段\n第二段")
        XCTAssertNil(answer.imageData)
        let request = try XCTUnwrap(log.requests.first)
        XCTAssertEqual(request.url, AISettingsStore.responsesURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-placeholder")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIStub.body(request)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["max_tokens"])
        XCTAssertNotNil(body["max_output_tokens"])
        XCTAssertTrue((body["instructions"] as? String)?.contains(game.title) == true)
        let messages = try XCTUnwrap(body["input"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": user.content]])
        XCTAssertFalse(String(decoding: OpenAIStub.body(request), as: UTF8.self).contains(user.id.uuidString))
        XCTAssertEqual(log.requests.count, 1)
    }

    func testIncompleteAndRefusedResponsesNeverBecomeSuccessfulReplies() async throws {
        for body in [
            #"{"status":"incomplete","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"partial"}]}]}"#,
            #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"private response"}]}]}"#,
            #"{"status":"completed","output":[{"type":"reasoning"}]}"#
        ] {
            let data = Data(body.utf8)
            let session = session { _ in (200, data) }
            do {
                _ = try await AIAnalysisClient(session: session).analyze(games: [game], apiKey: "test-placeholder", model: "test-model")
                XCTFail("Incomplete or refused output cannot be saved as an analysis")
            } catch let error as AIAnalysisError {
                XCTAssertFalse(error.localizedDescription.contains("private response"))
            }
        }
    }

    func testHTTPFailuresAreSafeAndAreNotAutomaticallyRetried() async throws {
        let log = OpenAIRequestLog()
        let session = session { request in
            log.record(request)
            return (429, Data(#"{"error":{"message":"private payload","code":"insufficient_quota"}}"#.utf8))
        }
        do {
            try await AIAnalysisClient(session: session).testConnection(apiKey: "test-placeholder", model: "test-model")
            XCTFail("Quota failure must be reported")
        } catch AIAnalysisError.insufficientQuota { }
        XCTAssertEqual(log.requests.count, 1)
    }

    func testImageGenerationRequestsOnePNGAndDecodesItsBytes() async throws {
        let image = png()
        let response = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": image.base64EncodedString()]]])
        let log = OpenAIRequestLog()
        let session = session { request in log.record(request); return (200, response) }
        let result = try await AIAnalysisClient(session: session).generateImage(prompt: "游戏画像", apiKey: "test-placeholder",
            model: AISettingsStore.defaultImageModelName, portrait: true)
        XCTAssertEqual(result, image)
        let request = try XCTUnwrap(log.requests.first)
        XCTAssertEqual(request.url, AISettingsStore.imagesURL)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIStub.body(request)) as? [String: Any])
        XCTAssertEqual(body["size"] as? String, "1024x1536")
        XCTAssertEqual(body["output_format"] as? String, "png")
        XCTAssertEqual(body["quality"] as? String, "medium")
        XCTAssertEqual(body["n"] as? Int, 1)
        XCTAssertNil(body["response_format"])
    }

    func testUnifiedChatLetsModelChooseImageWithoutAManualMode() async throws {
        let image = png()
        let response = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [
            ["type": "image_generation_call", "status": "completed", "result": image.base64EncodedString(), "revised_prompt": "宇宙冒险画像"],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "给你的冒险世界。"]]]
        ]])
        let log = OpenAIRequestLog()
        let session = session { request in log.record(request); return (200, response) }
        let result = try await AIAnalysisClient(session: session).chat(games: [game],
            messages: [AIChatMessage(role: .user, content: "帮我画一张游戏画像")],
            apiKey: "test-placeholder", model: "text-model", imageModel: "image-model")
        XCTAssertEqual(result.text, "给你的冒险世界。")
        XCTAssertEqual(result.imageData, image)
        let request = try XCTUnwrap(log.requests.first)
        XCTAssertEqual(request.url, AISettingsStore.responsesURL)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIStub.body(request)) as? [String: Any])
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        XCTAssertEqual(body["max_tool_calls"] as? Int, 1)
        let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(tool["type"] as? String, "image_generation")
        XCTAssertEqual(tool["model"] as? String, "image-model")
        XCTAssertEqual(tool["output_format"] as? String, "png")
        XCTAssertEqual(log.requests.count, 1)
    }

    func testImageOnlyUnifiedReplyCanBeSavedForAnOrdinaryUserMessage() throws {
        let store = try store()
        let conversation = try AIConversationActions.create(accountScope: "ps:a", games: [game], draft: "", in: store.mainContext)
        conversation.messages = [AIChatMessage(role: .user, content: "画一个世界")]
        try store.mainContext.save()
        let reply = try AIImageService.saveChatReply(AIChatReply(text: "", imageData: png(), imagePrompt: "一个冒险世界"),
            model: "image-model", conversationID: conversation.id, accountScope: "ps:a",
            expectedMessages: conversation.messages, revision: LocalDataRevision.current, in: store.mainContext)
        XCTAssertNotNil(reply.imageID)
        XCTAssertFalse(conversation.messages.first?.requestsImage ?? true)
        XCTAssertEqual(try LocalPersistence.conversation(conversation.id, in: ModelContext(store)).preview, "已生成图片")
    }

    func testRecentPlayDatesAndMinutesReachTheRequestWithoutLocalIdentifiers() async throws {
        let now = Date.now
        let record = GameRecord(applicationID: "ps:private-account:secret-title-id", accountID: "private-account", titleID: "secret-title-id",
            platform: .playStation, title: game.title, totalMinutes: 180, imageURL: "https://example.invalid/private-cover")
        record.personalNote = "do not transmit private note"
        let snapshots = [
            PlaySnapshot(gameID: record.applicationID, accountID: record.accountID, platform: .playStation, date: now.addingTimeInterval(-86_400), totalMinutes: 120, trophiesEarned: 1),
            PlaySnapshot(gameID: record.applicationID, accountID: record.accountID, platform: .playStation, date: now, totalMinutes: 180, trophiesEarned: 1)
        ]
        let recent = try AIRecentPlayContextBuilder.make(games: [record], snapshots: snapshots, activities: [], allocations: [], now: now)
        let log = OpenAIRequestLog()
        let data = Data(completed.utf8)
        let session = session { request in log.record(request); return (200, data) }
        _ = try await AIAnalysisClient(session: session).chat(games: [game], messages: [AIChatMessage(role: .user, content: "总结最近一个月")],
            apiKey: "test-placeholder", model: "text-model", recentPlay: recent)
        let request = try XCTUnwrap(log.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIStub.body(request)) as? [String: Any])
        let instructions = try XCTUnwrap(body["instructions"] as? String)
        XCTAssertTrue(instructions.contains(recent.startDayKey))
        XCTAssertTrue(instructions.contains("syncInterval"))
        XCTAssertTrue(instructions.contains("60"))
        for privateValue in [record.applicationID, record.accountID, record.titleID, record.imageURL, record.personalNote] {
            XCTAssertFalse(instructions.contains(privateValue))
        }
        XCTAssertEqual(body["tool_choice"] as? String, "auto", "A summary request must not force image generation")
    }

    func testImageURLsAndInvalidBase64AreRejectedWithoutFollowingThem() async throws {
        for body in [#"{"data":[{"url":"https://example.invalid/private.png"}]}"#,
                     #"{"data":[{"b64_json":"not an image"}]}"#] {
            let log = OpenAIRequestLog()
            let data = Data(body.utf8)
            let session = session { request in log.record(request); return (200, data) }
            do {
                _ = try await AIAnalysisClient(session: session).generateImage(prompt: "画图", apiKey: "test-placeholder", model: "image-model")
                XCTFail("Only valid embedded PNG data is accepted")
            } catch AIAnalysisError.invalidImage { }
            XCTAssertEqual(log.requests.count, 1)
        }
        XCTAssertThrowsError(try AIImageValidation.validate(Data(repeating: 0, count: AIImageValidation.maximumBytes + 1)))
    }

    func testChatImageAndAssistantMessageSaveTogetherAndDuplicateReplyIsRejected() throws {
        let store = try store()
        let conversation = try AIConversationActions.create(accountScope: "ps:a", games: [game], draft: "下一张图",
                                                             requestsImage: true, in: store.mainContext)
        conversation.messages = [AIChatMessage(role: .user, content: "画一个宇宙机器人", requestsImage: true)]
        try store.mainContext.save()
        let expected = conversation.messages
        let reply = try AIImageService.saveChatImage(data: png(), prompt: "test prompt", model: "image-model", conversationID: conversation.id,
            accountScope: conversation.accountScopeKey, expectedMessages: expected, revision: LocalDataRevision.current, in: store.mainContext)
        let fresh = ModelContext(store)
        let saved = try LocalPersistence.conversation(conversation.id, in: fresh)
        let images = try fresh.fetch(FetchDescriptor<AIGeneratedImage>())
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(saved.messages.last?.imageID, images.first?.id)
        XCTAssertEqual(saved.messages.last, reply)
        XCTAssertEqual(saved.draft, "下一张图")
        XCTAssertTrue(saved.draftRequestsImage)
        XCTAssertThrowsError(try AIImageService.saveChatImage(data: png(), prompt: "duplicate", model: "image-model", conversationID: conversation.id,
            accountScope: conversation.accountScopeKey, expectedMessages: expected, revision: LocalDataRevision.current, in: store.mainContext))
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<AIGeneratedImage>()), 1)
    }

    func testCancelledOrChangedProfileCannotReceiveLateImage() throws {
        let store = try store()
        let profile = AIProfileResult(accountScopeKey: "ps:a", platformFilter: "全部", minimumHours: 1,
                                      text: "探索型玩家", gameCount: 1, totalMinutes: 120)
        store.mainContext.insert(profile)
        try store.mainContext.save()
        XCTAssertThrowsError(try AIImageService.saveProfileImage(data: png(), prompt: "image", model: "image-model", profileID: profile.id,
            accountScope: "ps:a", expectedText: "outdated", revision: LocalDataRevision.current, in: store.mainContext))
        let revision = LocalDataRevision.current
        LocalDataRevision.invalidate()
        XCTAssertThrowsError(try AIImageService.saveProfileImage(data: png(), prompt: "image", model: "image-model", profileID: profile.id,
            accountScope: "ps:a", expectedText: profile.text, revision: revision, in: store.mainContext))
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<AIGeneratedImage>()), 0)
    }

    func testImagesAndImageDraftsRoundTripInVersionFourBackup() throws {
        let source = try store()
        let conversation = try AIConversationActions.create(accountScope: "ps:a", games: [game], draft: "下一张画像", requestsImage: true, in: source.mainContext)
        conversation.messages = [AIChatMessage(role: .user, content: "画出我的冒险世界", requestsImage: true)]
        try source.mainContext.save()
        let image = png()
        _ = try AIImageService.saveChatImage(data: image, prompt: "test prompt", model: "image-model", conversationID: conversation.id,
            accountScope: "ps:a", expectedMessages: conversation.messages, revision: LocalDataRevision.current, in: source.mainContext)
        let data = try ProductDataService.backupData(modelContext: source.mainContext)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 4)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-placeholder"))
        let target = try store()
        for _ in 0..<2 { _ = try ProductDataService.restore(data: data, modelContext: target.mainContext) }
        let restored = try LocalPersistence.conversation(conversation.id, in: target.mainContext)
        let images = try target.mainContext.fetch(FetchDescriptor<AIGeneratedImage>())
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.pngData, image)
        XCTAssertEqual(restored.messages.last?.imageID, images.first?.id)
        XCTAssertTrue(restored.draftRequestsImage)
        XCTAssertEqual(restored.draft, "下一张画像")
    }

    func testForeignImageInBackupIsRejectedBeforeAnyDataIsWritten() throws {
        let source = try store()
        let profile = AIProfileResult(accountScopeKey: "ps:a", platformFilter: "全部", minimumHours: 1, text: "分析", gameCount: 1, totalMinutes: 120)
        source.mainContext.insert(profile)
        try source.mainContext.save()
        try AIImageService.saveProfileImage(data: png(), prompt: "profile", model: "image-model", profileID: profile.id,
            accountScope: "ps:a", expectedText: profile.text, revision: LocalDataRevision.current, in: source.mainContext)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ProductDataService.backupData(modelContext: source.mainContext)) as? [String: Any])
        var images = try XCTUnwrap(json["generatedImages"] as? [[String: Any]])
        images[0]["accountScopeKey"] = "ps:b"
        json["generatedImages"] = images
        let target = try store()
        XCTAssertThrowsError(try ProductDataService.restore(data: JSONSerialization.data(withJSONObject: json), modelContext: target.mainContext))
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<AIGeneratedImage>()), 0)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<AIProfileResult>()), 0)
    }

    func testRemovingConversationCleansImagesAndAccountDeletionKeepsOtherImages() throws {
        let store = try store()
        let first = try AIConversationActions.create(accountScope: "ps:a", games: [game], draft: "", in: store.mainContext)
        let other = try AIConversationActions.create(accountScope: "ps:b", games: [game], draft: "", in: store.mainContext)
        for conversation in [first, other] {
            conversation.messages = [AIChatMessage(role: .user, content: "画图", requestsImage: true)]
            try store.mainContext.save()
            _ = try AIImageService.saveChatImage(data: png(), prompt: "image", model: "image-model", conversationID: conversation.id,
                accountScope: conversation.accountScopeKey, expectedMessages: conversation.messages, revision: LocalDataRevision.current, in: store.mainContext)
        }
        try ProductDataService.deleteArchive(platform: .playStation, accountID: "a", modelContext: store.mainContext)
        XCTAssertEqual(try store.mainContext.fetch(FetchDescriptor<AIGeneratedImage>()).map(\.accountScopeKey), ["ps:b"])
        try LocalPersistence.transaction(store.mainContext) { writer in
            try AIImageService.deleteImages(ownerID: other.id, origin: .conversation, in: writer)
            writer.delete(try LocalPersistence.conversation(other.id, in: writer))
        }
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<AIGeneratedImage>()), 0)
    }

    func testLegacyTextMessagesDecodeAndImagePromptsContainOnlyPermittedContext() throws {
        let messages = try JSONDecoder().decode([AIChatMessage].self, from: Data(#"[{"role":"user","content":"旧问题"}]"#.utf8))
        XCTAssertFalse(try XCTUnwrap(messages.first).requestsImage)
        XCTAssertNil(messages.first?.imageID)
        let reply = AIChatMessage(role: .assistant, content: "图片已生成。", imageID: UUID(), imageDescription: "宇宙探索")
        let prompt = AIPrompts.chatImagePrompt(games: [game], messages: messages + [reply])
        XCTAssertTrue(prompt.contains(game.title))
        XCTAssertTrue(prompt.contains("宇宙探索"))
        XCTAssertFalse(prompt.contains(reply.imageID!.uuidString))
        XCTAssertFalse(prompt.contains(reply.id.uuidString))
    }

    func testProviderMigrationDoesNotReuseLegacyModelOrEndpoint() {
        let defaults = UserDefaults.standard
        let keys = ["ai-analysis-model-name", "ai-analysis-endpoint", "openai-text-model", "openai-image-model"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer { for key in keys { defaults.set(previous[key] ?? nil, forKey: key) } }
        defaults.set("old-model", forKey: "ai-analysis-model-name")
        defaults.set("https://example.invalid/old-service", forKey: "ai-analysis-endpoint")
        defaults.removeObject(forKey: "openai-text-model")
        defaults.removeObject(forKey: "openai-image-model")
        XCTAssertEqual(AISettingsStore.modelName, AISettingsStore.defaultModelName)
        XCTAssertEqual(AISettingsStore.imageModelName, AISettingsStore.defaultImageModelName)
        XCTAssertEqual(AISettingsStore.responsesURL.host, "api.openai.com")
    }

    func testStaleChatWriterCannotReplaceNewMessagesOrDraftMode() throws {
        let store = try store()
        let conversation = try AIConversationActions.create(accountScope: "ps:a", games: [game], draft: "", in: store.mainContext)
        let message = AIChatMessage(role: .user, content: "画一个世界", requestsImage: true)
        try AIConversationActions.persistMessages(conversation.id, messages: [message], expecting: [], draft: "后续画面",
            requestsImage: true, revision: LocalDataRevision.current, in: store.mainContext)
        XCTAssertThrowsError(try AIConversationActions.persistMessages(conversation.id, messages: [], expecting: [], draft: "old draft",
            requestsImage: false, revision: LocalDataRevision.current, in: store.mainContext))
        let saved = try LocalPersistence.conversation(conversation.id, in: ModelContext(store))
        XCTAssertEqual(saved.messages, [message])
        XCTAssertEqual(saved.draft, "后续画面")
        XCTAssertTrue(saved.draftRequestsImage)
    }

    func testLegacyBackupWithoutImagesPreservesNewImagesAndImageDraftMode() throws {
        let store = try store()
        let conversation = try AIConversationActions.create(accountScope: "ps:a", games: [game], draft: "old", in: store.mainContext)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: ProductDataService.backupData(modelContext: store.mainContext)) as? [String: Any])
        old["formatVersion"] = 3
        old.removeValue(forKey: "generatedImages")
        var conversations = try XCTUnwrap(old["conversations"] as? [[String: Any]])
        conversations[0].removeValue(forKey: "draftRequestsImage")
        old["conversations"] = conversations
        conversation.messages = [AIChatMessage(role: .user, content: "画图", requestsImage: true)]
        conversation.updateDraft("下一张", requestsImage: true)
        try store.mainContext.save()
        _ = try AIImageService.saveChatImage(data: png(), prompt: "image", model: "image-model", conversationID: conversation.id,
            accountScope: "ps:a", expectedMessages: conversation.messages, revision: LocalDataRevision.current, in: store.mainContext)
        _ = try ProductDataService.restore(data: JSONSerialization.data(withJSONObject: old), modelContext: store.mainContext)
        let reopened = try LocalPersistence.conversation(conversation.id, in: ModelContext(store))
        XCTAssertNotNil(reopened.messages.last?.imageID)
        XCTAssertTrue(reopened.draftRequestsImage)
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<AIGeneratedImage>()), 1)
    }

    func testSQLiteMigrationAndExternalImageDataSurviveReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("before-images.store")
        let id = UUID()
        let png = png()
        do {
            let oldSchema = Schema([GameRecord.self, PlaySnapshot.self, DailyPlayActivity.self, PlayTimeAllocation.self,
                                    AIConversation.self, AIProfileResult.self, SavedGamePlan.self])
            let old = try ModelContainer(for: oldSchema, configurations: ModelConfiguration(url: url))
            let conversation = AIConversation(id: id, accountScopeKey: "ps:a", games: [game])
            conversation.messages = [AIChatMessage(role: .user, content: "画图", requestsImage: true)]
            old.mainContext.insert(conversation)
            try old.mainContext.save()
        }
        do {
            let current = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(url: url))
            let conversation = try LocalPersistence.conversation(id, in: current.mainContext)
            _ = try AIImageService.saveChatImage(data: png, prompt: "image", model: "image-model", conversationID: id,
                accountScope: "ps:a", expectedMessages: conversation.messages, revision: LocalDataRevision.current, in: current.mainContext)
        }
        let reopened = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(url: url))
        let images = try reopened.mainContext.fetch(FetchDescriptor<AIGeneratedImage>())
        XCTAssertEqual(images.first?.pngData, png)
        XCTAssertEqual(try LocalPersistence.conversation(id, in: reopened.mainContext).messages.last?.imageID, images.first?.id)
    }
}

private final class OpenAIRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { stored } }
    func record(_ request: URLRequest) { lock.withLock { stored.append(request) } }
}

private final class OpenAIStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badURL) }
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
