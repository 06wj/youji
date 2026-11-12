import XCTest
import SwiftData
@testable import YouJi

@MainActor
final class AIProductExperienceTests: XCTestCase {
    func testChatSnapshotKeepsOnlyAllowedFieldsAndStrictPlayTimeWithinAccount() throws {
        let eligible = GameRecord(applicationID: "ps:local-account:one", accountID: "local-account", titleID: "one",
                                  platform: .playStation, title: "冒险", totalMinutes: 61,
                                  imageURL: "https://example.invalid/private-cover", trophiesEarned: 1, trophiesDefined: 10)
        eligible.personalNote = "私人备注不能进入 AI"
        eligible.isManuallyHidden = true
        let boundary = GameRecord(applicationID: "ps:local-account:two", accountID: "local-account", titleID: "two",
                                  platform: .playStation, title: "刚好一小时", totalMinutes: 60)
        let otherAccount = GameRecord(applicationID: "ps:another-account:one", accountID: "another-account", titleID: "one",
                                      platform: .playStation, title: "另一个人的游戏", totalMinutes: 300)
        let selected = AIGameContext.games(in: "ps:local-account", from: [eligible, boundary, otherAccount])
        let snapshot = AIGameContext.snapshot(selected)
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.title, "冒险")
        let payload = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(payload.contains("local-account"))
        XCTAssertFalse(payload.contains("private-cover"))
        XCTAssertFalse(payload.contains("私人备注"))
    }

    func testContextChangeDetectsContentWithoutTreatingOrderAsAnUpdate() {
        let first = AIAnalysisGame(platform: "PS", title: "冒险", totalMinutes: 120, trophyRatio: "1/10")
        let second = AIAnalysisGame(platform: "NS", title: "旅行", totalMinutes: 200, trophyRatio: nil)
        XCTAssertFalse(AIGameContext.hasChanged(frozen: [first, second], latest: [second, first]))
        let updated = AIAnalysisGame(platform: "PS", title: "冒险", totalMinutes: 120, trophyRatio: "2/10")
        XCTAssertTrue(AIGameContext.hasChanged(frozen: [first, second], latest: [updated, second]))
        XCTAssertTrue(AIGameContext.hasChanged(frozen: [first, second], latest: [first]))
        XCTAssertNotEqual(AIGameContext.fingerprint([first]), AIGameContext.fingerprint([updated]))
    }

    func testContextComparisonPreservesDuplicateGames() {
        let first = AIAnalysisGame(platform: "PS", title: "冒险", totalMinutes: 120, trophyRatio: nil)
        let second = AIAnalysisGame(platform: "NS", title: "冒险", totalMinutes: 120, trophyRatio: nil)
        XCTAssertFalse(AIGameContext.hasChanged(frozen: [first, first, second], latest: [second, first, first]))
        XCTAssertTrue(AIGameContext.hasChanged(frozen: [first, first, second], latest: [second, second, first]))
    }

    func testRapidTypingCoalescesIntoOneDraftWrite() async throws {
        let store = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let conversation = try AIConversationActions.create(accountScope: "ps:a", games: [], draft: "", in: store.mainContext)
        let input = AIChatDraft(text: "", requestsImage: false, delay: .milliseconds(30))
        var writes = 0
        input.activate { value in
            try LocalPersistence.transaction(store.mainContext) { writer in
                let saved = try LocalPersistence.conversation(conversation.id, in: writer)
                saved.updateDraft(value.text, requestsImage: value.requestsImage)
            }
            writes += 1
        } onError: { _ in XCTFail("Draft save unexpectedly failed") }
        for character in "今晚想玩一个适合轻松探索的游戏" {
            input.text.append(character)
            input.scheduleSave()
        }
        XCTAssertEqual(writes, 0, "Typing must not synchronously write to SwiftData")
        for _ in 0..<100 where writes == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(try LocalPersistence.conversation(conversation.id, in: ModelContext(store)).draft, input.text)
        input.deactivate()
        XCTAssertEqual(writes, 1, "Closing an already saved draft must be a no-op")
    }

    func testLeavingOrBackgroundingImmediatelyFlushesLatestDraftAndMode() async throws {
        let input = AIChatDraft(text: "", requestsImage: false, delay: .milliseconds(30))
        var saved: [AIChatDraft.Value] = []
        input.activate { saved.append($0) } onError: { _ in XCTFail() }
        input.text = "画一个冒险世界"
        input.requestsImage = true
        input.scheduleSave()
        input.flush()
        XCTAssertEqual(saved, [.init(text: "画一个冒险世界", requestsImage: true)])
        input.text = "带一点水彩风格"
        input.scheduleSave()
        input.deactivate()
        XCTAssertEqual(saved.last, .init(text: "带一点水彩风格", requestsImage: true))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(saved.count, 2, "Cancelled delayed saves cannot replay after the immediate flush")
    }

    func testSendingCancelsQueuedDraftAndDoesNotRestoreSentText() async throws {
        let input = AIChatDraft(text: "", requestsImage: false, delay: .milliseconds(30))
        var saved: [AIChatDraft.Value] = []
        input.activate { saved.append($0) } onError: { _ in XCTFail() }
        input.text = "已经发送的问题"
        input.scheduleSave()
        // The message transaction has already saved an empty composer.
        input.acknowledgeSaved(.init(text: "", requestsImage: false))
        input.text = ""
        input.scheduleSave()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(input.text, "")
        input.deactivate()
    }

    func testSeedDraftIsSavedOnceAndFailedDraftCanBeRetried() {
        let input = AIChatDraft(text: "预填问题", requestsImage: false, storedText: "")
        var saved: [AIChatDraft.Value] = []
        var shouldFail = false
        var failures = 0
        input.activate { value in
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            saved.append(value)
        } onError: { _ in failures += 1 }
        XCTAssertEqual(saved.count, 1)
        input.flush()
        XCTAssertEqual(saved.count, 1)
        input.text = "保留未能保存的草稿"
        shouldFail = true
        input.flush()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(input.text, "保留未能保存的草稿")
        shouldFail = false
        input.flush()
        XCTAssertEqual(saved.last?.text, input.text)
        input.deactivate()
    }

    func testDelayedDraftCannotWriteAfterArchiveInvalidation() async throws {
        let input = AIChatDraft(text: "", requestsImage: false, delay: .milliseconds(30))
        let revision = LocalDataRevision.current
        var writes = 0
        input.activate { _ in
            try LocalDataRevision.check(revision)
            writes += 1
        } onError: { error in XCTAssertTrue(error is CancellationError) }
        input.text = "旧档案的草稿"
        input.scheduleSave()
        LocalDataRevision.invalidate()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(writes, 0)
        input.deactivate()
    }

    func testLatestProfileRestoresOnlyMatchingAccountAndFilter() {
        let old = profile(scope: "ps:a", platform: "全部", hours: 1, day: 1)
        let latest = profile(scope: "ps:a", platform: "Switch", hours: 10, day: 3)
        let unrelated = profile(scope: "ps:b", platform: "全部", hours: 1, day: 5)
        let profiles = [latest, old, unrelated]
        XCTAssertEqual(AIProfileSelection.latest(in: profiles, accountScope: "ps:a")?.id, latest.id)
        XCTAssertEqual(AIProfileSelection.latest(in: profiles, accountScope: "ps:a", platform: "全部", minimumHours: 1)?.id, old.id)
        XCTAssertNil(AIProfileSelection.latest(in: profiles, accountScope: "ps:a", platform: "全部", minimumHours: 10))
    }

    func testDraftCarriesProfileAndDoesNotReuseAssistantReplyAsNewQuestion() {
        let analysis = "你是偏爱探索的玩家。"
        XCTAssertTrue(AIPrompts.profileFollowUpDraft(analysis).contains(analysis))
        let messages = [AIChatMessage(role: .user, content: "今晚玩什么？"),
                        AIChatMessage(role: .assistant, content: "考虑重温冒险。")]
        XCTAssertEqual(AIPrompts.latestRecordDraft(messages: messages), "今晚玩什么？")
    }

    func testOpenAIConfigurationUsesFixedEndpointsAndRequiresBothModels() throws {
        XCTAssertEqual(AISettingsStore.responsesURL.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(AISettingsStore.imagesURL.absoluteString, "https://api.openai.com/v1/images/generations")
        XCTAssertThrowsError(try AISettingsStore.validate(apiKey: "", modelName: "text", imageModelName: "image"))
        XCTAssertThrowsError(try AISettingsStore.validate(apiKey: "placeholder", modelName: " ", imageModelName: "image"))
        XCTAssertThrowsError(try AISettingsStore.validate(apiKey: "placeholder", modelName: "text", imageModelName: " "))
        XCTAssertThrowsError(try AISettingsStore.validate(apiKey: "placeholder\nvalue", modelName: "text", imageModelName: "image"))
    }

    func testEditedDraftSurvivesReopeningAndKeepsEmptyConversation() throws {
        let store = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let conversation = try AIConversationActions.create(
            accountScope: "ps:a", games: [], draft: "初始推荐草稿", in: store.mainContext
        )
        XCTAssertTrue(conversation.modelContext === store.mainContext)
        XCTAssertFalse(conversation.canDiscardEmptyConversation)
        let editedAt = conversation.updatedAt.addingTimeInterval(60)
        try LocalPersistence.transaction(store.mainContext) { writer in
            let saved = try LocalPersistence.conversation(conversation.id, in: writer)
            saved.updateDraft("我改过的问题，周末有两小时。", editedAt: editedAt)
        }
        let freshContext = ModelContext(store)
        let reopened = try LocalPersistence.conversation(conversation.id, in: freshContext)
        XCTAssertEqual(reopened.draft, "我改过的问题，周末有两小时。")
        XCTAssertEqual(reopened.updatedAt, editedAt)
        XCTAssertTrue(reopened.messages.isEmpty)
        XCTAssertFalse(reopened.canDiscardEmptyConversation)
        XCTAssertTrue(reopened.preview.hasPrefix("草稿"))
        reopened.updateDraft(reopened.draft, editedAt: editedAt.addingTimeInterval(30))
        XCTAssertEqual(reopened.updatedAt, editedAt, "Reading an unchanged draft must not make an old version newer")
        reopened.updateDraft("  ")
        XCTAssertTrue(reopened.canDiscardEmptyConversation)
    }

    func testPendingUserMessageRestoresRetryWithoutAddingAnyMessage() throws {
        let store = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let conversation = AIConversation(accountScopeKey: "ps:a", games: [])
        conversation.messages = [AIChatMessage(role: .user, content: "今晚玩什么？")]
        store.mainContext.insert(conversation)
        try store.mainContext.save()
        let reopened = try LocalPersistence.conversation(conversation.id, in: ModelContext(store))
        XCTAssertTrue(reopened.needsReply)
        XCTAssertEqual(reopened.messages.count, 1)
        reopened.messages += [AIChatMessage(role: .assistant, content: "可以重温冒险。")]
        XCTAssertFalse(reopened.needsReply)
        reopened.messagesData = Data("unreadable".utf8)
        XCTAssertFalse(reopened.needsReply)
    }

    func testLatestConversationUsesUIContextAndLeavesOriginalSnapshotUnchanged() throws {
        let store = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let oldGame = AIAnalysisGame(platform: "PS", title: "冒险", totalMinutes: 120, trophyRatio: nil)
        let newGame = AIAnalysisGame(platform: "PS", title: "冒险", totalMinutes: 180, trophyRatio: nil)
        let original = try AIConversationActions.create(accountScope: "ps:a", games: [oldGame], draft: "原问题", in: store.mainContext)
        let next = try AIConversationActions.create(accountScope: "ps:a", games: [newGame], draft: original.draft, in: store.mainContext)
        XCTAssertTrue(next.modelContext === store.mainContext)
        XCTAssertNotEqual(next.id, original.id)
        XCTAssertEqual(original.games, [oldGame])
        XCTAssertEqual(next.games, [newGame])
        XCTAssertEqual(next.draft, "原问题")
        XCTAssertTrue(next.messages.isEmpty)
    }

    func testLegacyMigrationKeepsOnlyLinkedUnscopedPlansWithTheirConversation() throws {
        let store = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let game = GameRecord(applicationID: "ps:a:one", accountID: "a", titleID: "one", platform: .playStation, title: "冒险", totalMinutes: 120)
        let legacy = AIConversation(createdAt: .distantPast, games: [])
        let other = AIConversation(accountScopeKey: "ps:b", games: [])
        let linked = SavedGamePlan(accountScopeKey: "", title: "旧建议", sourceConversationID: legacy.id.uuidString)
        let unlinked = SavedGamePlan(accountScopeKey: "", title: "其他灵感")
        let foreign = SavedGamePlan(accountScopeKey: "ps:b", title: "保留账号", sourceConversationID: legacy.id.uuidString)
        let unrelated = SavedGamePlan(accountScopeKey: "", title: "其他来源", sourceConversationID: other.id.uuidString)
        store.mainContext.insert(game)
        [legacy, other].forEach { store.mainContext.insert($0) }
        [linked, unlinked, foreign, unrelated].forEach { store.mainContext.insert($0) }
        try store.mainContext.save()
        try AIConversationActions.migrateLegacyConversations(to: "ps:a", games: [game], in: store.mainContext)
        let fresh = ModelContext(store)
        XCTAssertEqual(try LocalPersistence.conversation(legacy.id, in: fresh).accountScopeKey, "ps:a")
        XCTAssertGreaterThan(try LocalPersistence.conversation(legacy.id, in: fresh).updatedAt, Date.distantPast)
        let plans = try fresh.fetch(FetchDescriptor<SavedGamePlan>())
        XCTAssertEqual(plans.first { $0.id == linked.id }?.accountScopeKey, "ps:a")
        XCTAssertEqual(plans.first { $0.id == unlinked.id }?.accountScopeKey, "")
        XCTAssertEqual(plans.first { $0.id == foreign.id }?.accountScopeKey, "ps:b")
        XCTAssertEqual(plans.first { $0.id == unrelated.id }?.accountScopeKey, "")
    }

    private func profile(scope: String, platform: String, hours: Int, day: TimeInterval) -> AIProfileResult {
        AIProfileResult(accountScopeKey: scope, platformFilter: platform, minimumHours: hours,
                        generatedAt: Date(timeIntervalSince1970: day), text: "分析", gameCount: 2, totalMinutes: 300)
    }
}
