import XCTest
import SwiftData
@testable import YouJi

final class SavedPlanTests: XCTestCase {
    @MainActor
    private func container() throws -> ModelContainer {
        try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @MainActor
    private func game(account: String = "a", platform: GamePlatform = .playStation) -> GameRecord {
        GameRecord(applicationID: GameRecord.recordID(platform: platform, accountID: account, titleID: "same-title"),
                   accountID: account, titleID: "same-title", platform: platform, title: "同名游戏", totalMinutes: 120)
    }

    @MainActor
    func testPlanLinksUseFullIdentityRatherThanTitle() {
        let first = game()
        let otherAccount = game(account: "b")
        let otherPlatform = game(platform: .switchConsole)
        let plan = SavedGamePlan(accountScopeKey: "ps:a|switch:a", title: first.title, gameID: first.applicationID)
        XCTAssertTrue(plan.linkedGame(in: [otherAccount, otherPlatform, first]) === first)
        XCTAssertNil(plan.linkedGame(in: [otherAccount, otherPlatform]))
        plan.accountScopeKey = "ps:b"
        XCTAssertNil(plan.linkedGame(in: [first]))
    }

    @MainActor
    func testPlanBackupPreservesLinksAndReadsOlderBackups() throws {
        let source = try container()
        let game = game()
        let conversation = AIConversation(accountScopeKey: "ps:a", games: [])
        let plan = SavedGamePlan(accountScopeKey: "ps:a", title: "重温", note: String(repeating: "完整建议\n", count: 100),
                                 gameID: game.applicationID, sourceConversationID: conversation.id.uuidString)
        source.mainContext.insert(game)
        source.mainContext.insert(conversation)
        source.mainContext.insert(plan)
        source.mainContext.insert(AIProfileResult(accountScopeKey: "ps:a", platformFilter: "全部", minimumHours: 1,
                                                  text: "人格", gameCount: 1, totalMinutes: 120, inputFingerprint: "input-fingerprint"))
        try source.mainContext.save()
        let data = try ProductDataService.backupData(modelContext: source.mainContext)
        let target = try container()
        try ProductDataService.restore(data: data, modelContext: target.mainContext)
        let restored = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<SavedGamePlan>()).first)
        XCTAssertEqual(restored.gameID, game.applicationID)
        XCTAssertEqual(restored.sourceConversationID, conversation.id.uuidString)
        XCTAssertEqual(restored.note, plan.note)
        XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<AIProfileResult>()).first?.inputFingerprint, "input-fingerprint")

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var plans = try XCTUnwrap(json["plans"] as? [[String: Any]])
        plans[0].removeValue(forKey: "gameID")
        plans[0].removeValue(forKey: "sourceConversationID")
        json["plans"] = plans
        var profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        profiles[0].removeValue(forKey: "inputFingerprint")
        json["profiles"] = profiles
        let oldTarget = try container()
        try ProductDataService.restore(data: JSONSerialization.data(withJSONObject: json), modelContext: oldTarget.mainContext)
        let old = try XCTUnwrap(oldTarget.mainContext.fetch(FetchDescriptor<SavedGamePlan>()).first)
        XCTAssertEqual(old.gameID, "")
        XCTAssertEqual(old.sourceConversationID, "")
        XCTAssertEqual(old.note, plan.note)
        XCTAssertEqual(try oldTarget.mainContext.fetch(FetchDescriptor<AIProfileResult>()).first?.inputFingerprint, "")
    }

    @MainActor
    func testPlanEditingRejectsAnotherAccountAndStartIsExplicit() throws {
        let store = try container()
        let local = game()
        let foreign = game(account: "b")
        let plan = SavedGamePlan(accountScopeKey: "ps:a", title: "原计划", note: "原说明")
        [local, foreign].forEach { store.mainContext.insert($0) }
        store.mainContext.insert(plan)
        try store.mainContext.save()
        XCTAssertThrowsError(try ProductDataService.updatePlan(plan.id, accountScopeKey: "ps:a", title: "不能写入", note: "不能写入", gameID: foreign.applicationID, modelContext: store.mainContext))
        XCTAssertEqual(plan.title, "原计划")
        XCTAssertEqual(plan.gameID, "")
        try ProductDataService.updatePlan(plan.id, accountScopeKey: "ps:a", title: "准备开始", note: "新的完整说明", gameID: local.applicationID, modelContext: store.mainContext)
        XCTAssertEqual(plan.title, "准备开始")
        XCTAssertEqual(local.playStatus, .played)
        XCTAssertFalse(plan.isCompleted)
        try ProductDataService.startPlan(plan.id, accountScopeKey: "ps:a", modelContext: store.mainContext)
        XCTAssertEqual(local.playStatus, .playing)
        XCTAssertEqual(foreign.playStatus, .played)
        XCTAssertTrue(plan.isCompleted)
    }

    @MainActor
    func testMissingLinkedGameRetainsTextAndCannotStart() throws {
        let store = try container()
        let plan = SavedGamePlan(accountScopeKey: "ps:a", title: "保留计划", note: "游戏删除后仍可阅读", gameID: "ps:a:removed")
        store.mainContext.insert(plan)
        try store.mainContext.save()
        XCTAssertThrowsError(try ProductDataService.startPlan(plan.id, accountScopeKey: "ps:a", modelContext: store.mainContext))
        XCTAssertFalse(plan.isCompleted)
        let data = try ProductDataService.backupData(modelContext: store.mainContext)
        let target = try container()
        try ProductDataService.restore(data: data, modelContext: target.mainContext)
        let restored = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<SavedGamePlan>()).first)
        XCTAssertEqual(restored.note, "游戏删除后仍可阅读")
        XCTAssertEqual(restored.gameID, "ps:a:removed")
    }

    @MainActor
    func testInvalidPlanBackupDoesNotMutateArchive() throws {
        let source = try container()
        let foreign = game(account: "b")
        source.mainContext.insert(foreign)
        source.mainContext.insert(SavedGamePlan(accountScopeKey: "ps:a", title: "错误关联", gameID: foreign.applicationID))
        try source.mainContext.save()
        let data = try ProductDataService.backupData(modelContext: source.mainContext)
        let target = try container()
        XCTAssertThrowsError(try ProductDataService.restore(data: data, modelContext: target.mainContext))
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<GameRecord>()), 0)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<SavedGamePlan>()), 0)
    }

    @MainActor
    func testReadOnlyWriteLeavesPlanAndGameUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("plans.store")
        do {
            let writable = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(url: url))
            let game = game()
            writable.mainContext.insert(game)
            writable.mainContext.insert(SavedGamePlan(accountScopeKey: "ps:a", title: "原计划", gameID: game.applicationID))
            try writable.mainContext.save()
        }
        let readOnly = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(url: url, allowsSave: false))
        let plan = try XCTUnwrap(readOnly.mainContext.fetch(FetchDescriptor<SavedGamePlan>()).first)
        let game = try XCTUnwrap(readOnly.mainContext.fetch(FetchDescriptor<GameRecord>()).first)
        XCTAssertThrowsError(try ProductDataService.startPlan(plan.id, accountScopeKey: "ps:a", modelContext: readOnly.mainContext))
        XCTAssertThrowsError(try ProductDataService.updateGame(game.applicationID, field: \.isFavorite, value: true, modelContext: readOnly.mainContext))
        XCTAssertFalse(plan.isCompleted)
        XCTAssertEqual(game.playStatus, .played)
        XCTAssertFalse(game.isFavorite)
    }

    @MainActor
    func testEarlierPlanSQLiteSchemaAddsEmptyLinksAndKeepsFullText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy-plans.store")
        do {
            let schema = Schema(versionedSchema: BeforePlanLinks.self)
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            old.mainContext.insert(BeforePlanLinks.SavedGamePlan())
            try old.mainContext.save()
        }
        let current = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(url: url))
        let plan = try XCTUnwrap(current.mainContext.fetch(FetchDescriptor<SavedGamePlan>()).first)
        XCTAssertEqual(plan.title, "以前的计划")
        XCTAssertEqual(plan.note, "保留完整文字")
        XCTAssertEqual(plan.gameID, "")
        XCTAssertEqual(plan.sourceConversationID, "")
        XCTAssertFalse(plan.isCompleted)
    }
}

private enum BeforePlanLinks: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [SavedGamePlan.self] }

    @Model
    final class SavedGamePlan {
        @Attribute(.unique) var id: UUID
        var accountScopeKey: String
        var title: String
        var note: String
        var createdAt: Date
        var updatedAt: Date = Date.distantPast
        var isCompleted: Bool

        init() {
            id = UUID()
            accountScopeKey = "ps:a"
            title = "以前的计划"
            note = "保留完整文字"
            createdAt = Date(timeIntervalSince1970: 100)
            updatedAt = .now
            isCompleted = false
        }
    }
}

extension SavedPlanTests {
    @MainActor
    func testWeeklyAnchorAndDraftBackupRoundTripAndLegacyDefaults() throws {
        let source = try container()
        let game = game(platform: .switchConsole)
        game.weeklyEndingDayKey = "2026-10-19"
        game.weeklyMinutes = [1, 2, 3, 4, 5, 6, 7]
        let conversation = AIConversation(accountScopeKey: "switch:a", games: [])
        conversation.draft = "尚未发送的追问，请完整保留"
        source.mainContext.insert(game)
        source.mainContext.insert(conversation)
        try source.mainContext.save()
        let data = try ProductDataService.backupData(modelContext: source.mainContext)
        let target = try container()
        try ProductDataService.restore(data: data, modelContext: target.mainContext)
        let restoredGame = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<GameRecord>()).first)
        let restoredConversation = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<AIConversation>()).first)
        XCTAssertEqual(restoredGame.weeklyEndingDayKey, "2026-10-19")
        XCTAssertEqual(restoredGame.weeklyMinutes, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(restoredConversation.draft, conversation.draft)
        XCTAssertFalse(restoredConversation.canDiscardEmptyConversation)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var games = try XCTUnwrap(json["games"] as? [[String: Any]])
        games[0].removeValue(forKey: "weeklyEndingDayKey")
        json["games"] = games
        var conversations = try XCTUnwrap(json["conversations"] as? [[String: Any]])
        conversations[0].removeValue(forKey: "draft")
        json["conversations"] = conversations
        let legacyTarget = try container()
        try ProductDataService.restore(data: JSONSerialization.data(withJSONObject: json), modelContext: legacyTarget.mainContext)
        XCTAssertEqual(try legacyTarget.mainContext.fetch(FetchDescriptor<GameRecord>()).first?.weeklyEndingDayKey, "")
        XCTAssertEqual(try legacyTarget.mainContext.fetch(FetchDescriptor<AIConversation>()).first?.draft, "")
    }

    @MainActor
    func testDraftMergeHonorsEditDatesAndLegacyMissingField() throws {
        let source = try container()
        let conversation = AIConversation(accountScopeKey: "ps:a", games: [])
        conversation.draft = "旧草稿"
        conversation.updatedAt = Date(timeIntervalSince1970: 100)
        source.mainContext.insert(conversation)
        try source.mainContext.save()
        let target = try container()
        let local = AIConversation(id: conversation.id, accountScopeKey: "ps:a", games: [])
        local.draft = "本地较新草稿"
        local.updatedAt = Date(timeIntervalSince1970: 200)
        target.mainContext.insert(local)
        try target.mainContext.save()
        try ProductDataService.restore(data: ProductDataService.backupData(modelContext: source.mainContext), modelContext: target.mainContext)
        XCTAssertEqual(local.draft, "本地较新草稿")

        conversation.draft = "备份较新草稿"
        conversation.updatedAt = Date(timeIntervalSince1970: 300)
        try source.mainContext.save()
        let newerData = try ProductDataService.backupData(modelContext: source.mainContext)
        try ProductDataService.restore(data: newerData, modelContext: target.mainContext)
        XCTAssertEqual(local.draft, "备份较新草稿")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: newerData) as? [String: Any])
        var conversations = try XCTUnwrap(json["conversations"] as? [[String: Any]])
        conversations[0].removeValue(forKey: "draft")
        conversations[0]["updatedAt"] = "2026-10-19T00:00:00Z"
        json["conversations"] = conversations
        try ProductDataService.restore(data: JSONSerialization.data(withJSONObject: json), modelContext: target.mainContext)
        XCTAssertEqual(local.draft, "备份较新草稿")

        conversation.draft = ""
        conversation.updatedAt = Date.distantFuture
        try source.mainContext.save()
        try ProductDataService.restore(data: ProductDataService.backupData(modelContext: source.mainContext), modelContext: target.mainContext)
        XCTAssertEqual(local.draft, "")
    }

    @MainActor
    func testWeeklyAnchorRejectsMalformedOrImpossibleDatesBeforeRestore() throws {
        let source = try container()
        source.mainContext.insert(game(platform: .switchConsole))
        try source.mainContext.save()
        let data = try ProductDataService.backupData(modelContext: source.mainContext)
        for invalidDate in ["2026-02-30", "2026-2-28", "2026-10-19T00:00:00Z", "today"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var games = try XCTUnwrap(json["games"] as? [[String: Any]])
            games[0]["weeklyEndingDayKey"] = invalidDate
            json["games"] = games
            let target = try container()
            XCTAssertThrowsError(try ProductDataService.restore(data: JSONSerialization.data(withJSONObject: json), modelContext: target.mainContext))
            XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<GameRecord>()), 0)
        }
    }

    @MainActor
    func testEarlierGameAndConversationSQLiteSchemaKeepsDataWithEmptyMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy-metadata.store")
        do {
            let schema = Schema(versionedSchema: BeforeAnchorAndDraft.self)
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            old.mainContext.insert(BeforeAnchorAndDraft.GameRecord())
            old.mainContext.insert(BeforeAnchorAndDraft.AIConversation())
            try old.mainContext.save()
        }
        let current = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(url: url))
        let game = try XCTUnwrap(current.mainContext.fetch(FetchDescriptor<GameRecord>()).first)
        let conversation = try XCTUnwrap(current.mainContext.fetch(FetchDescriptor<AIConversation>()).first)
        XCTAssertEqual(game.weeklyEndingDayKey, "")
        XCTAssertEqual(game.weeklyMinutes, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(game.personalNote, "旧备注")
        XCTAssertEqual(conversation.draft, "")
        XCTAssertEqual(conversation.title, "以前的对话")
        XCTAssertEqual(conversation.messages.first?.content, "保留旧消息")
    }
}

private enum BeforeAnchorAndDraft: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [GameRecord.self, AIConversation.self] }

    @Model
    final class GameRecord {
        @Attribute(.unique) var applicationID: String
        var accountID: String = ""
        var titleID: String = ""
        var platformRaw: String = "Switch"
        var title: String
        var totalMinutes: Int
        var imageURL: String
        var firstPlayedAt: Date?
        var lastPlayedAt: Date?
        var weeklyMinutesData: Data
        var trophiesEarned: Int = 0
        var trophiesDefined: Int = 0
        var platinumTrophiesEarned: Int = 0
        var trophiesSyncedAt: Date?
        var updatedAt: Date
        var userEditedAt: Date = Date.distantPast
        var isFavorite: Bool = false
        var isManuallyHidden: Bool = false
        var isPinnedVisible: Bool = false
        var personalNote: String = ""
        var playStatusRaw: String = "玩过"

        init() {
            applicationID = "switch:a:legacy"
            accountID = "a"
            titleID = "legacy"
            title = "以前的游戏"
            totalMinutes = 120
            imageURL = ""
            weeklyMinutesData = Data("[1,2,3,4,5,6,7]".utf8)
            updatedAt = Date(timeIntervalSince1970: 100)
            personalNote = "旧备注"
        }
    }

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

        init() {
            id = UUID()
            title = "以前的对话"
            createdAt = Date(timeIntervalSince1970: 100)
            updatedAt = .now
            messagesData = Data("[{\"role\":\"user\",\"content\":\"保留旧消息\"}]".utf8)
            gameContextData = Data("[]".utf8)
            accountScopeKey = "switch:a"
        }
    }
}
