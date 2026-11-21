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

    func testInitialChatRequestHasToolSchemasAndConversationOnly() async throws {
        let store = try store()
        store.mainContext.insert(GameRecord(applicationID: "ps:private-account:private-id",
            accountID: "private-account", titleID: "private-id", platform: .playStation, title: game.title, totalMinutes: 180))
        try store.mainContext.save()
        let log = OpenAIRequestLog()
        let response = Data(completed.utf8)
        let session = session { request in log.record(request); return (200, response) }
        let user = AIChatMessage(role: .user, content: "PS 如何截图？")
        let answer = try await AIAnalysisClient(session: session).chat(messages: [user],
            apiKey: "test-placeholder", model: AISettingsStore.defaultModelName,
            queries: AIChatGameQueries(accountScope: "ps:private-account", in: store.mainContext))
        XCTAssertEqual(answer.text, "第一段\n第二段")
        XCTAssertNil(answer.imageData)
        XCTAssertFalse(answer.usedLocalRecords)
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
        XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
        XCTAssertNil(body["previous_response_id"])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let functions = tools.filter { $0["type"] as? String == "function" }
        XCTAssertEqual(functions.compactMap { $0["name"] as? String }, ["query_games", "query_play_activity"])
        for tool in functions {
            let schema = try XCTUnwrap(tool["parameters"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual(tool["strict"] as? Bool, true)
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            XCTAssertEqual(Set(schema["required"] as? [String] ?? []), Set(properties.keys))
        }
        let messages = try XCTUnwrap(body["input"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": user.content]])
        let encoded = String(decoding: OpenAIStub.body(request), as: UTF8.self)
        for secret in [user.id.uuidString, game.title, "private-account", "private-id"] {
            XCTAssertFalse(encoded.contains(secret))
        }
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
        let store = try store()
        let image = png()
        let response = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [
            ["type": "image_generation_call", "status": "completed", "result": image.base64EncodedString(), "revised_prompt": "宇宙冒险画像"],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "给你的冒险世界。"]]]
        ]])
        let log = OpenAIRequestLog()
        let session = session { request in log.record(request); return (200, response) }
        let result = try await AIAnalysisClient(session: session).chat(
            messages: [AIChatMessage(role: .user, content: "帮我画一张游戏画像")],
            apiKey: "test-placeholder", model: "text-model", imageModel: "image-model",
            queries: AIChatGameQueries(accountScope: "ps:a", in: store.mainContext))
        XCTAssertEqual(result.text, "给你的冒险世界。")
        XCTAssertEqual(result.imageData, image)
        let request = try XCTUnwrap(log.requests.first)
        XCTAssertEqual(request.url, AISettingsStore.responsesURL)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIStub.body(request)) as? [String: Any])
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        XCTAssertEqual(body["max_tool_calls"] as? Int, 1)
        let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first { $0["type"] as? String == "image_generation" })
        XCTAssertEqual(tool["type"] as? String, "image_generation")
        XCTAssertEqual(tool["model"] as? String, "image-model")
        XCTAssertEqual(tool["output_format"] as? String, "png")
        XCTAssertEqual(log.requests.count, 1)
    }

    func testImageOnlyUnifiedReplyCanBeSavedForAnOrdinaryUserMessage() throws {
        let store = try store()
        let conversation = try AIConversationActions.create(accountScope: "ps:a", draft: "", in: store.mainContext)
        conversation.messages = [AIChatMessage(role: .user, content: "画一个世界")]
        try store.mainContext.save()
        let reply = try AIImageService.saveChatReply(AIChatReply(text: "", imageData: png(), imagePrompt: "一个冒险世界"),
            model: "image-model", conversationID: conversation.id, accountScope: "ps:a",
            expectedMessages: conversation.messages, revision: LocalDataRevision.current, in: store.mainContext)
        XCTAssertNotNil(reply.imageID)
        XCTAssertFalse(conversation.messages.first?.requestsImage ?? true)
        XCTAssertEqual(try LocalPersistence.conversation(conversation.id, in: ModelContext(store)).preview, "已生成图片")
    }

    func testModelQueriesActivityAndReceivesOnlyProjectedResultsOnContinuation() async throws {
        let store = try store()
        let now = Date.now
        let start = DailyPlayActivity.dayKey(for: Calendar.current.date(byAdding: .day, value: -29, to: now)!)
        let end = DailyPlayActivity.dayKey(for: PlayDay.label(for: now))
        let record = GameRecord(applicationID: "ps:private-account:secret-title-id", accountID: "private-account", titleID: "secret-title-id",
            platform: .playStation, title: game.title, totalMinutes: 180, imageURL: "https://example.invalid/private-cover")
        record.personalNote = "do not transmit private note"
        let snapshots = [
            PlaySnapshot(gameID: record.applicationID, accountID: record.accountID, platform: .playStation, date: now.addingTimeInterval(-86_400), totalMinutes: 120, trophiesEarned: 1),
            PlaySnapshot(gameID: record.applicationID, accountID: record.accountID, platform: .playStation, date: now, totalMinutes: 180, trophiesEarned: 1)
        ]
        store.mainContext.insert(record)
        for snapshot in snapshots { store.mainContext.insert(snapshot) }
        try store.mainContext.save()
        let arguments = """
            {"platform":"ps","title_contains":null,"start_day":"\(start)","end_day":"\(end)",
            "group_by":"game","sort_by":"minutes","include_trophies":false,"limit":5,"offset":0}
            """
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_123", "encrypted_content": "opaque", "summary": []]
        let toolCall: [String: Any] = ["type": "function_call", "id": "fc_123", "call_id": "call_1",
            "name": "query_play_activity", "arguments": arguments, "status": "completed"]
        let call = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [reasoning, toolCall]])
        let log = OpenAIRequestLog()
        let data = Data(completed.utf8)
        let session = session { request in
            log.record(request)
            return (200, log.requests.count == 1 ? call : data)
        }
        let reply = try await AIAnalysisClient(session: session).chat(messages: [AIChatMessage(role: .user, content: "总结最近一个月")],
            apiKey: "test-placeholder", model: "text-model",
            queries: AIChatGameQueries(accountScope: "ps:private-account", in: store.mainContext, now: now))
        XCTAssertTrue(reply.usedLocalRecords)
        XCTAssertEqual(log.requests.count, 2)
        let firstRequest = try XCTUnwrap(log.requests.first)
        XCTAssertFalse(String(decoding: OpenAIStub.body(firstRequest), as: UTF8.self).contains(record.title))
        let continuation = try XCTUnwrap(log.requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIStub.body(continuation)) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String }, [nil, "reasoning", "function_call", "function_call_output"])
        XCTAssertEqual(input[1]["encrypted_content"] as? String, "opaque")
        XCTAssertEqual(input[2]["arguments"] as? String, arguments)
        XCTAssertEqual(input[3]["call_id"] as? String, "call_1")
        let result = try XCTUnwrap(input[3]["output"] as? String)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(payload["startDay"] as? String, start)
        XCTAssertEqual(payload["totals"] as? [String: Int], ["minutes": 60])
        XCTAssertTrue(result.contains(record.title))
        for privateValue in [record.applicationID, record.accountID, record.titleID, record.imageURL, record.personalNote] + snapshots.map(\.snapshotID) {
            XCTAssertFalse(result.contains(privateValue))
        }
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
    }

    func testChatQueriesAreBoundedAcrossAReply() async throws {
        let store = try store()
        let budget = AIChatGameQueries.maximumCalls
        let arguments = """
            {"platform":"all","title_contains":null,"min_minutes_exclusive":null,"max_minutes_inclusive":null,
            "platinum_only":false,"sort_by":"total_minutes","ascending":false,"fields":[],"limit":0,"offset":0}
            """
        let log = OpenAIRequestLog()
        let answer = Data(completed.utf8)
        let session = session { request in
            log.record(request)
            let count = log.requests.count
            if count > budget { return (200, answer) }
            let response = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [
                ["type": "function_call", "call_id": "call_\(count)", "name": "query_games", "arguments": arguments]
            ]])
            return (200, response)
        }
        let reply = try await AIAnalysisClient(session: session).chat(messages: [AIChatMessage(role: .user, content: "游戏数")],
            apiKey: "test-placeholder", model: "text-model", queries: AIChatGameQueries(accountScope: "ps:a", in: store.mainContext))
        XCTAssertTrue(reply.usedLocalRecords)
        XCTAssertEqual(log.requests.count, budget + 1)
        let request = try XCTUnwrap(log.requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIStub.body(request)) as? [String: Any])
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.compactMap { $0["type"] as? String }, ["image_generation"])
        XCTAssertEqual((body["input"] as? [[String: Any]])?.filter { $0["type"] as? String == "function_call_output" }.count, budget)
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
        let conversation = try AIConversationActions.create(accountScope: "ps:a", draft: "下一张图",
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
        let conversation = try AIConversationActions.create(accountScope: "ps:a", draft: "下一张画像", requestsImage: true, in: source.mainContext)
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

    func testRestoreSkipsOldSnapshotChatsAndTheirImagesButKeepsOtherData() throws {
        let source = try store()
        let old = try AIConversationActions.create(accountScope: "ps:a", draft: "旧草稿", in: source.mainContext)
        let current = try AIConversationActions.create(accountScope: "ps:a", draft: "新草稿", in: source.mainContext)
        let game = GameRecord(applicationID: "ps:a:game", accountID: "a", titleID: "game",
                              platform: .playStation, title: "游玩记录", totalMinutes: 222)
        let plan = SavedGamePlan(accountScopeKey: "ps:a", title: "待玩", sourceConversationID: old.id.uuidString)
        source.mainContext.insert(game)
        source.mainContext.insert(plan)
        source.mainContext.insert(AIGeneratedImage(accountScopeKey: "ps:a", ownerID: old.id, origin: .conversation,
            prompt: "旧聊天图片", modelName: "test-image", pngData: png()))
        try source.mainContext.save()
        var backup = try XCTUnwrap(JSONSerialization.jsonObject(with: ProductDataService.backupData(modelContext: source.mainContext)) as? [String: Any])
        var chats = try XCTUnwrap(backup["conversations"] as? [[String: Any]])
        let legacy = try XCTUnwrap(chats.firstIndex { $0["id"] as? String == old.id.uuidString })
        chats[legacy].removeValue(forKey: "usesLocalQueries")
        chats[legacy]["messages"] = "旧会话正文无需解析"
        backup["conversations"] = chats
        let target = try store()
        _ = try ProductDataService.restore(data: JSONSerialization.data(withJSONObject: backup), modelContext: target.mainContext)
        XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<AIConversation>()).map(\.id), [current.id])
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<AIGeneratedImage>()), 0)
        XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<GameRecord>()).map(\.totalMinutes), [222])
        XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<SavedGamePlan>()).map(\.sourceConversationID), [old.id.uuidString])
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
        let first = try AIConversationActions.create(accountScope: "ps:a", draft: "", in: store.mainContext)
        let other = try AIConversationActions.create(accountScope: "ps:b", draft: "", in: store.mainContext)
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

    func testImageMessageRequestIncludesDescriptionWithoutLocalIdentifiers() throws {
        let messages = try JSONDecoder().decode([AIChatMessage].self, from: Data(#"[{"role":"user","content":"旧问题"}]"#.utf8))
        XCTAssertFalse(try XCTUnwrap(messages.first).requestsImage)
        XCTAssertNil(messages.first?.imageID)
        let reply = AIChatMessage(role: .assistant, content: "图片已生成。", imageID: UUID(), imageDescription: "宇宙探索")
        let prompt = reply.requestText
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
        let conversation = try AIConversationActions.create(accountScope: "ps:a", draft: "", in: store.mainContext)
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
        let conversation = try AIConversationActions.create(accountScope: "ps:a", draft: "old", in: store.mainContext)
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
            let conversation = AIConversation(id: id, accountScopeKey: "ps:a")
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
