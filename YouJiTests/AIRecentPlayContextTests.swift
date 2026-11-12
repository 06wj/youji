import XCTest
import SwiftData
@testable import YouJi

@MainActor
final class AIRecentPlayContextTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func date(_ key: String, hour: Int = 12) -> Date {
        DailyPlayActivity.date(fromDayKey: key, calendar: utc)!.addingTimeInterval(Double(hour * 3_600))
    }
    private func game(_ id: String = "game", account: String = "private-account", platform: GamePlatform = .playStation,
                      minutes: Int = 120) -> GameRecord {
        let result = GameRecord(applicationID: GameRecord.recordID(platform: platform, accountID: account, titleID: id),
            accountID: account, titleID: id, platform: platform, title: "\(platform.shortName) 游戏 \(id)", totalMinutes: minutes)
        result.updatedAt = date("2026-10-01")
        return result
    }
    private func snapshot(_ game: GameRecord, id: String, day: String, minutes: Int, trophies: Int = 0) -> PlaySnapshot {
        PlaySnapshot(snapshotID: id, gameID: game.applicationID, accountID: game.accountID, platform: game.platform,
                     date: date(day), totalMinutes: minutes, trophiesEarned: trophies)
    }
    private func activity(_ game: GameRecord, day: String, minutes: Int) -> DailyPlayActivity {
        let activity = DailyPlayActivity(activityID: "\(game.applicationID):\(day)", gameID: game.applicationID,
            accountID: game.accountID, titleID: game.titleID, platform: game.platform, day: date(day), totalMinutes: minutes)
        activity.updatedAt = date(day)
        return activity
    }
    private func store() throws -> ModelContainer {
        try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testWindowIncludesShortSessionsAndExcludesOtherAccountsAndOutOfRangeDays() throws {
        let store = try store()
        let short = game("short", platform: .switchConsole, minutes: 30)
        let foreign = game("foreign", account: "other-account", platform: .switchConsole)
        store.mainContext.insert(short)
        store.mainContext.insert(foreign)
        for item in [activity(short, day: "2026-10-14", minutes: 9), activity(short, day: "2026-10-15", minutes: 10),
                     activity(short, day: "2026-11-13", minutes: 20), activity(short, day: "2026-11-14", minutes: 15),
                     activity(foreign, day: "2026-11-12", minutes: 900)] { store.mainContext.insert(item) }
        try store.mainContext.save()
        let context = try AIRecentPlayContextBuilder.capture(accountScope: "switch:private-account", in: store.mainContext,
                                                             now: date("2026-11-13", hour: 18), calendar: utc)
        XCTAssertEqual(context.startDayKey, "2026-10-15")
        XCTAssertEqual(context.endDayKey, "2026-11-13")
        XCTAssertEqual(context.records.map(\.minutes), [10, 20])
        let prompt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.promptText().utf8)) as? [String: Any])
        XCTAssertEqual(prompt["dailyRecordedMinutes"] as? Int, 30)
        XCTAssertEqual((prompt["games"] as? [[String: Any]])?.first?["dailyRecordedMinutes"] as? Int, 30)
        XCTAssertTrue(AIGameContext.snapshot([short]).isEmpty, "Lifetime background remains strictly over one hour")
        let json = try context.promptText()
        XCTAssertFalse(json.contains("private-account"))
        XCTAssertFalse(json.contains("other-account"))
        XCTAssertFalse(json.contains(foreign.title))
    }

    func testPSAllocationsReplaceRawMinutesWithoutMovingTrophies() throws {
        let game = game()
        let start = snapshot(game, id: "start", day: "2026-10-30", minutes: 600, trophies: 2)
        let end = snapshot(game, id: "end", day: "2026-11-02", minutes: 1_320, trophies: 4)
        var allocation = PlayTimeResolver.draft(from: start, to: end, calendar: utc)
        allocation.days = ["2026-10-31", "2026-11-01", "2026-11-02"].map { .init(dayKey: $0, minutes: 240) }
        let context = try AIRecentPlayContextBuilder.make(games: [game], snapshots: [start, end], activities: [],
            allocations: [allocation], now: date("2026-11-13"), calendar: utc)
        XCTAssertEqual(context.dailyMinutes, 720)
        XCTAssertEqual(context.intervalMinutes, 0)
        XCTAssertEqual(context.records.filter { $0.timing == .day }.map(\.minutes), [240, 240, 240])
        let trophies = try XCTUnwrap(context.records.first { $0.trophyChange != 0 })
        XCTAssertEqual(trophies.dayKey, "2026-11-02")
        XCTAssertEqual(trophies.trophyChange, 2)
        XCTAssertEqual(trophies.timing, .syncInterval)
    }

    func testZeroGrowthDefinesTheNextIntervalAndCorrectionsRemainSigned() throws {
        let game = game()
        let snapshots = [
            snapshot(game, id: "start", day: "2026-10-10", minutes: 500),
            snapshot(game, id: "zero", day: "2026-11-10", minutes: 500),
            snapshot(game, id: "growth", day: "2026-11-11", minutes: 650),
            snapshot(game, id: "correction", day: "2026-11-12", minutes: 450)
        ]
        let context = try AIRecentPlayContextBuilder.make(games: [game], snapshots: snapshots, activities: [], allocations: [],
                                                         now: date("2026-11-13"), calendar: utc)
        XCTAssertEqual(context.records.map(\.minutes), [150, -200])
        XCTAssertEqual(context.records.first?.observedFrom, date("2026-11-10"))
        XCTAssertEqual(context.intervalMinutes, -50)
        XCTAssertEqual(context.dailyMinutes, 0)
    }

    func testCrossWindowIntervalRetainsItsActualStartAndFirstSnapshotIsNotActivity() throws {
        let game = game()
        let start = snapshot(game, id: "start", day: "2026-09-30", minutes: 100)
        let end = snapshot(game, id: "end", day: "2026-11-01", minutes: 700)
        let context = try AIRecentPlayContextBuilder.make(games: [game], snapshots: [start, end], activities: [], allocations: [],
                                                         now: date("2026-11-13"), calendar: utc)
        XCTAssertEqual(context.records.first?.observedFrom, date("2026-09-30"))
        XCTAssertEqual(context.records.first?.timing, .syncInterval)
        let firstOnly = try AIRecentPlayContextBuilder.make(games: [game], snapshots: [end], activities: [], allocations: [],
                                                           now: date("2026-11-13"), calendar: utc)
        XCTAssertTrue(firstOnly.records.isEmpty)
        XCTAssertEqual(firstOnly.lastObservedAt, end.date)
    }

    func testExactZeroOverridesWeeklyFallbackAndNoSnapshotMinutesAreDoubleCounted() throws {
        let game = game(platform: .switchConsole)
        game.weeklyEndingDayKey = "2026-11-13"
        game.weeklyMinutes = [0, 0, 0, 0, 0, 45, 60]
        game.updatedAt = date("2026-11-13")
        let zero = activity(game, day: "2026-11-13", minutes: 0)
        let context = try AIRecentPlayContextBuilder.make(games: [game], snapshots: [
            snapshot(game, id: "a", day: "2026-11-10", minutes: 100),
            snapshot(game, id: "b", day: "2026-11-13", minutes: 205)
        ], activities: [zero], allocations: [], now: date("2026-11-13", hour: 18), calendar: utc)
        XCTAssertEqual(context.records.map(\.dayKey), ["2026-11-12"])
        XCTAssertEqual(context.dailyMinutes, 45)
        XCTAssertEqual(context.intervalMinutes, 0)
    }

    func testThirtyNaturalDaysAreStableAcrossDSTAndEncoding() throws {
        var calendar = utc
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let context = try AIRecentPlayContextBuilder.make(games: [], snapshots: [], activities: [], allocations: [],
                                                         now: date("2026-11-13"), calendar: calendar)
        XCTAssertEqual(context.startDayKey, "2026-10-15")
        XCTAssertEqual(context.endDayKey, "2026-11-13")
        XCTAssertEqual(try JSONDecoder().decode(AIRecentPlayContext.self, from: context.encoded()), context)
    }

    func testEachSendUpdatesRecentContextWhileRetryKeepsItsStoredSnapshot() throws {
        let store = try store()
        let game = game()
        store.mainContext.insert(game)
        store.mainContext.insert(snapshot(game, id: "start", day: "2026-11-10", minutes: 100))
        store.mainContext.insert(snapshot(game, id: "end", day: "2026-11-11", minutes: 160))
        try store.mainContext.save()
        let lifetime = AIGameContext.snapshot([game])
        let conversation = try AIConversationActions.create(accountScope: "ps:private-account", games: lifetime, draft: "", in: store.mainContext)
        let first = try AIRecentPlayContextBuilder.capture(accountScope: conversation.accountScopeKey, in: store.mainContext,
                                                          now: date("2026-11-11", hour: 18), calendar: utc)
        let question = AIChatMessage(role: .user, content: "总结最近一个月")
        try AIConversationActions.persistMessages(conversation.id, messages: [question], expecting: [], draft: "", requestsImage: false,
            recentPlay: first, revision: LocalDataRevision.current, in: store.mainContext)
        store.mainContext.insert(snapshot(game, id: "later", day: "2026-11-12", minutes: 220))
        try store.mainContext.save()
        XCTAssertEqual(try conversation.readRecentPlayContext(), first)
        let latest = try AIRecentPlayContextBuilder.capture(accountScope: conversation.accountScopeKey, in: store.mainContext,
                                                           now: date("2026-11-13"), calendar: utc)
        XCTAssertEqual(latest.intervalMinutes, 120)
        try AIConversationActions.persistMessages(conversation.id, messages: [question, AIChatMessage(role: .user, content: "再总结一次")],
            expecting: [question], draft: "", requestsImage: false, recentPlay: latest, revision: LocalDataRevision.current, in: store.mainContext)
        XCTAssertEqual(try conversation.readRecentPlayContext(), latest)
        XCTAssertEqual(conversation.games, lifetime)
    }

    func testBackupRoundTripAndOlderBackupWithoutRecentFieldPreserveContext() throws {
        let source = try store()
        let recent = try AIRecentPlayContextBuilder.make(games: [], snapshots: [], activities: [], allocations: [],
                                                        now: date("2026-11-13"), calendar: utc)
        let conversation = try AIConversationActions.create(accountScope: "ps:a", games: [], draft: "question", recentPlay: recent, in: source.mainContext)
        let data = try ProductDataService.backupData(modelContext: source.mainContext)
        let target = try store()
        _ = try ProductDataService.restore(data: data, modelContext: target.mainContext)
        let restored = try LocalPersistence.conversation(conversation.id, in: target.mainContext)
        XCTAssertEqual(try restored.readRecentPlayContext(), recent)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var conversations = try XCTUnwrap(old["conversations"] as? [[String: Any]])
        conversations[0].removeValue(forKey: "recentPlayContext")
        conversations[0].removeValue(forKey: "rawRecentPlayContextData")
        old["conversations"] = conversations
        _ = try ProductDataService.restore(data: JSONSerialization.data(withJSONObject: old), modelContext: target.mainContext)
        XCTAssertEqual(try restored.readRecentPlayContext(), recent)
    }

    func testNearMidnightObservationCannotRoundIntoAnotherBackupDay() throws {
        let store = try store()
        let now = date("2026-11-14", hour: 0).addingTimeInterval(-0.0001)
        let recent = try AIRecentPlayContextBuilder.make(games: [], snapshots: [], activities: [], allocations: [], now: now, calendar: utc)
        let conversation = try AIConversationActions.create(accountScope: "ps:a", games: [], draft: "", recentPlay: recent, in: store.mainContext)
        let target = try self.store()
        _ = try ProductDataService.restore(data: ProductDataService.backupData(modelContext: store.mainContext), modelContext: target.mainContext)
        let restored = try LocalPersistence.conversation(conversation.id, in: target.mainContext)
        XCTAssertEqual(try restored.readRecentPlayContext()?.endDayKey, "2026-11-13")
    }

    func testInvalidTypedRecentContextIsRejectedBeforeRestore() throws {
        let source = try store()
        let recent = try AIRecentPlayContextBuilder.make(games: [], snapshots: [], activities: [], allocations: [], now: date("2026-11-13"), calendar: utc)
        _ = try AIConversationActions.create(accountScope: "ps:a", games: [], draft: "", recentPlay: recent, in: source.mainContext)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ProductDataService.backupData(modelContext: source.mainContext)) as? [String: Any])
        var conversations = try XCTUnwrap(json["conversations"] as? [[String: Any]])
        var context = try XCTUnwrap(conversations[0]["recentPlayContext"] as? [String: Any])
        context["startDayKey"] = "2026-01-01"
        conversations[0]["recentPlayContext"] = context
        json["conversations"] = conversations
        let target = try store()
        XCTAssertThrowsError(try ProductDataService.restore(data: JSONSerialization.data(withJSONObject: json), modelContext: target.mainContext))
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<AIConversation>()), 0)
    }

    func testCorruptRecentContextIsPreservedButCannotReachARequest() throws {
        let source = try store()
        let conversation = try AIConversationActions.create(accountScope: "ps:a", games: [], draft: "", in: source.mainContext)
        let raw = Data("unreadable recent context".utf8)
        conversation.recentPlayContextData = raw
        try source.mainContext.save()
        XCTAssertThrowsError(try conversation.readRecentPlayContext())
        XCTAssertFalse(conversation.hasUnreadableContent, "A derived recent context must not hide the readable chat")
        let target = try store()
        _ = try ProductDataService.restore(data: ProductDataService.backupData(modelContext: source.mainContext), modelContext: target.mainContext)
        let restored = try LocalPersistence.conversation(conversation.id, in: target.mainContext)
        XCTAssertEqual(restored.recentPlayContextData, raw)
        XCTAssertThrowsError(try restored.readRecentPlayContext())
    }

    func testEarlierConversationSQLiteMigratesWithoutChangingDraftOrMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("before-recent.store")
        do {
            let schema = Schema(versionedSchema: BeforeRecentContext.self)
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            old.mainContext.insert(BeforeRecentContext.AIConversation())
            try old.mainContext.save()
        }
        let current = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(url: url))
        let conversation = try XCTUnwrap(current.mainContext.fetch(FetchDescriptor<AIConversation>()).first)
        XCTAssertEqual(conversation.title, "旧对话")
        XCTAssertEqual(conversation.draft, "保留草稿")
        XCTAssertEqual(conversation.messages.first?.content, "旧问题")
        XCTAssertNil(try conversation.readRecentPlayContext())
    }
}

private enum BeforeRecentContext: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [AIConversation.self] }
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
        var draftRequestsImage: Bool = false
        init() {
            let now = Date.now
            id = UUID()
            title = "旧对话"
            createdAt = now
            updatedAt = now
            messagesData = Data(#"[{"role":"user","content":"旧问题"}]"#.utf8)
            gameContextData = Data("[]".utf8)
            accountScopeKey = "ps:a"
            draft = "保留草稿"
        }
    }
}
