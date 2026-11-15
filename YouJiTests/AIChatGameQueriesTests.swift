import SwiftData
import XCTest
@testable import YouJi

@MainActor
final class AIChatGameQueriesTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ key: String) -> Date {
        DailyPlayActivity.date(fromDayKey: key, calendar: utc)!
    }

    private func store() throws -> ModelContainer {
        try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func game(_ id: String, title: String, minutes: Int, platform: GamePlatform = .playStation,
                      account: String = "private-ps", earned: Int = 0, defined: Int = 0,
                      lastPlayed: Date? = nil) -> GameRecord {
        let game = GameRecord(applicationID: GameRecord.recordID(platform: platform, accountID: account, titleID: id),
            accountID: account, titleID: id, platform: platform, title: title, totalMinutes: minutes,
            imageURL: "https://example.invalid/private-cover", lastPlayedAt: lastPlayed,
            trophiesEarned: earned, trophiesDefined: defined)
        game.updatedAt = date("2026-11-04")
        game.personalNote = "private note"
        return game
    }

    private func libraryArgs(_ overrides: [String: Any] = [:]) throws -> String {
        let base: [String: Any] = ["platform": "all", "title_contains": NSNull(), "min_minutes_exclusive": NSNull(),
            "max_minutes_inclusive": NSNull(), "platinum_only": false, "sort_by": "total_minutes",
            "ascending": false, "fields": ["total_minutes"], "limit": 10, "offset": 0]
        return try arguments(base.merging(overrides, uniquingKeysWith: { _, new in new }))
    }

    private func activityArgs(_ overrides: [String: Any] = [:]) throws -> String {
        let base: [String: Any] = ["platform": "all", "title_contains": NSNull(), "start_day": "2026-11-01",
            "end_day": "2026-11-04", "group_by": "game", "sort_by": "minutes",
            "include_trophies": false, "limit": 10, "offset": 0]
        return try arguments(base.merging(overrides, uniquingKeysWith: { _, new in new }))
    }

    private func arguments(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func object(_ output: AIChatToolOutput) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.json.utf8)) as? [String: Any])
    }

    func testStrictDurationPagingAndCountOnlyStayWithinTheArchive() throws {
        let store = try store()
        let matches = [game("secret-id", title: "冒险", minutes: 121),
                       game("other-title", title: "旅行", minutes: 130, platform: .switchConsole, account: "private-ns")]
        matches[0].isManuallyHidden = true
        for record in matches + [
            game("boundary", title: "刚好两小时", minutes: 120),
            game("foreign", title: "另一个账号的游戏", minutes: 320, account: "private-ps-elsewhere")
        ] { store.mainContext.insert(record) }
        try store.mainContext.save()
        let queries = AIChatGameQueries(accountScope: "ps:private-ps|switch:private-ns", in: store.mainContext)
        let output = try queries.execute(name: "query_games", arguments: libraryArgs(["min_minutes_exclusive": 120, "limit": 1]))
        let page = try object(output)
        XCTAssertTrue(output.queriedRecords)
        XCTAssertEqual(page["matchingCount"] as? Int, 2)
        XCTAssertEqual(page["nextOffset"] as? Int, 1)
        XCTAssertEqual((page["games"] as? [[String: Any]])?.first?["title"] as? String, "旅行")
        XCTAssertNil(page["matchingTotalMinutes"])
        let next = try object(queries.execute(name: "query_games",
            arguments: libraryArgs(["min_minutes_exclusive": 120, "limit": 1, "offset": 1])))
        XCTAssertNil(next["nextOffset"])
        XCTAssertEqual((next["games"] as? [[String: Any]])?.first?["totalMinutes"] as? Int, 121)
        let count = try object(queries.execute(name: "query_games", arguments: libraryArgs(["min_minutes_exclusive": 120, "limit": 0])))
        XCTAssertEqual(count["matchingTotalMinutes"] as? Int, 251)
        XCTAssertEqual((count["games"] as? [[String: Any]])?.count, 0)
        for secret in ["private-ps", "private-ns", "secret-id", "private-cover", "private note", "刚好两小时", "另一个账号的游戏"] {
            XCTAssertFalse(output.json.contains(secret))
        }
    }

    func testTrophyRankingsUseDifferentMetricsAndOmitUnknownOrSwitchTrophies() throws {
        let store = try store()
        for record in [
            game("count", title: "奖杯最多", minutes: 200, earned: 40, defined: 100),
            game("completion", title: "完成率最高", minutes: 150, earned: 10, defined: 10),
            game("unknown", title: "未知奖杯", minutes: 200),
            game("switch", title: "旅行", minutes: 300, platform: .switchConsole, account: "private-ns", earned: 100, defined: 100)
        ] { store.mainContext.insert(record) }
        try store.mainContext.save()
        let queries = AIChatGameQueries(accountScope: "ps:private-ps|switch:private-ns", in: store.mainContext)
        let count = try object(queries.execute(name: "query_games",
            arguments: libraryArgs(["sort_by": "trophies_earned", "fields": ["trophies"]])))
        let countRows = try XCTUnwrap(count["games"] as? [[String: Any]])
        XCTAssertEqual(countRows.compactMap { $0["title"] as? String }, ["奖杯最多", "完成率最高"])
        XCTAssertEqual(countRows[0]["trophiesEarned"] as? Int, 40)
        XCTAssertNil(countRows[0]["totalMinutes"])
        let completion = try object(queries.execute(name: "query_games",
            arguments: libraryArgs(["sort_by": "trophy_completion", "limit": 1])))
        XCTAssertEqual((completion["games"] as? [[String: Any]])?.first?["title"] as? String, "完成率最高")
        let switchOnly = try object(queries.execute(name: "query_games",
            arguments: libraryArgs(["platform": "ns", "fields": ["trophies"]])))
        XCTAssertNil((switchOnly["games"] as? [[String: Any]])?.first?["trophiesEarned"])
    }

    func testActivityUsesOneTotalFromFinalTimelineDates() throws {
        let store = try store()
        let allocated = game("allocated", title: "冒险游戏", minutes: 1_440)
        let crossing = game("crossing", title: "动作游戏", minutes: 1_003)
        let short = game("short", title: "短时游戏", minutes: 12, platform: .switchConsole, account: "private-ns")
        let dateOnly = game("date", title: "仅有日期", minutes: 333, lastPlayed: date("2026-11-03"))
        let foreign = game("allocated", title: "其他账号", minutes: 1_440, account: "private-ps-elsewhere")
        [allocated, crossing, short, dateOnly, foreign].forEach { store.mainContext.insert($0) }

        func snapshot(_ game: GameRecord, _ day: String, _ minutes: Int, trophies: Int = 0) -> PlaySnapshot {
            let value = PlaySnapshot(gameID: game.applicationID, accountID: game.accountID, platform: game.platform,
                date: date(day).addingTimeInterval(3_600), totalMinutes: minutes, trophiesEarned: trophies)
            store.mainContext.insert(value)
            return value
        }

        let start = snapshot(allocated, "2026-10-30", 600)
        let end = snapshot(allocated, "2026-11-02", 1_320, trophies: 3)
        _ = snapshot(allocated, "2026-11-04", 1_440, trophies: 4)
        _ = snapshot(crossing, "2026-10-29", 3)
        _ = snapshot(crossing, "2026-11-02", 780)
        _ = snapshot(crossing, "2026-11-05", 1_003)
        _ = snapshot(foreign, "2026-11-01", 10)
        _ = snapshot(foreign, "2026-11-03", 400)
        var allocation = PlayTimeResolver.draft(from: start, to: end, calendar: utc)
        allocation.days = [.init(dayKey: "2026-10-31", minutes: 360), .init(dayKey: "2026-11-01", minutes: 360)]
        store.mainContext.insert(try PlayTimeAllocation(allocation))

        short.weeklyMinutes = [0, 0, 0, 0, 0, 99, 12]
        short.weeklyEndingDayKey = "2026-11-03"
        let exactZero = DailyPlayActivity(
            activityID: DailyPlayActivity.recordID(platform: .switchConsole, accountID: short.accountID, titleID: short.titleID, dayKey: "2026-11-02"),
            gameID: short.applicationID, accountID: short.accountID, titleID: short.titleID, platform: .switchConsole,
            day: date("2026-11-02"), totalMinutes: 0)
        exactZero.updatedAt = date("2026-11-04")
        store.mainContext.insert(exactZero)
        try store.mainContext.save()

        let queries = AIChatGameQueries(accountScope: "ps:private-ps|switch:private-ns", in: store.mainContext,
            now: date("2026-11-15"), calendar: utc)
        let output = try queries.execute(name: "query_play_activity", arguments: activityArgs(["include_trophies": true]))
        let response = try object(output)
        let totals = try XCTUnwrap(response["totals"] as? [String: Any])
        XCTAssertEqual(Set(totals.keys), ["minutes", "psTrophyChange"])
        XCTAssertEqual(totals["minutes"] as? Int, 1_269)
        XCTAssertEqual(totals["psTrophyChange"] as? Int, 4)
        XCTAssertEqual(response["knownPlayedGameCount"] as? Int, 4)
        let rows = try XCTUnwrap(response["games"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["title"] as? String }, ["动作游戏", "冒险游戏", "短时游戏", "仅有日期"])
        XCTAssertEqual(rows.compactMap { ($0["totals"] as? [String: Any])?["minutes"] as? Int }, [777, 480, 12])
        XCTAssertEqual(rows.first { $0["title"] as? String == "仅有日期" }?["lastPlayedDay"] as? String, "2026-11-03")
        for secret in [start.snapshotID, allocated.applicationID, "private-ps", "private-cover", "private note", "其他账号", "720"] {
            XCTAssertFalse(output.json.contains(secret))
        }
        let daily = try object(queries.execute(name: "query_play_activity", arguments: activityArgs(["group_by": "day"])))
        let days = try XCTUnwrap(daily["days"] as? [[String: Any]])
        XCTAssertEqual(days.compactMap { $0["day"] as? String }, ["2026-11-02", "2026-11-01", "2026-11-04", "2026-11-03"])
        XCTAssertEqual(days.compactMap { $0["minutes"] as? Int }, [777, 360, 120, 12])
        XCTAssertEqual(days.compactMap { $0["minutes"] as? Int }.reduce(0, +), totals["minutes"] as? Int)
        let byGameDay = try object(queries.execute(name: "query_play_activity",
            arguments: activityArgs(["group_by": "game_day", "sort_by": "recent", "limit": 1])))
        let gameDays = try XCTUnwrap(byGameDay["gameDays"] as? [[String: Any]])
        XCTAssertEqual(gameDays.first?["title"] as? String, "冒险游戏")
        XCTAssertEqual(gameDays.first?["minutes"] as? Int, 120)
        XCTAssertEqual(byGameDay["nextOffset"] as? Int, 1)
    }

    func testInvalidArgumentsAndStaleRevisionsNeverReadRecords() throws {
        let store = try store()
        let queries = AIChatGameQueries(accountScope: "ps:private-ps", in: store.mainContext,
            now: date("2026-11-15"), calendar: utc)
        for (name, args) in [
            ("query_games", try libraryArgs(["account_id": "let me cross accounts"])),
            ("query_games", try libraryArgs(["limit": 21])),
            ("query_play_activity", try activityArgs(["start_day": "2026-11-31"])),
            ("query_play_activity", try activityArgs(["end_day": "2026-11-20"])),
            ("arbitrary_sql", "{}")
        ] {
            let reply = try queries.execute(name: name, arguments: args)
            XCTAssertFalse(reply.queriedRecords)
            XCTAssertNotNil(try object(reply)["error"])
        }
        LocalDataRevision.invalidate()
        XCTAssertThrowsError(try queries.execute(name: "query_games", arguments: libraryArgs())) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testOpeningOldSQLiteRemovesAllSnapshotChatsAndTheirImages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("before-chat-tools.store")
        do {
            let schema = Schema(versionedSchema: BeforeChatQueries.self)
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            let first = BeforeChatQueries.AIConversation()
            let another = BeforeChatQueries.AIConversation()
            another.accountScopeKey = "switch:someone"
            let profile = AIProfileResult(accountScopeKey: "ps:private-ps", platformFilter: "全部",
                minimumHours: 1, text: "已保存的分析", gameCount: 1, totalMinutes: 120)
            old.mainContext.insert(first)
            old.mainContext.insert(another)
            old.mainContext.insert(profile)
            old.mainContext.insert(game("store", title: "保留游戏", minutes: 120))
            old.mainContext.insert(SavedGamePlan(accountScopeKey: first.accountScopeKey, title: "保留清单",
                sourceConversationID: first.id.uuidString))
            for (id, origin) in [(first.id, AIGeneratedImage.Origin.conversation), (profile.id, .profile)] {
                old.mainContext.insert(AIGeneratedImage(accountScopeKey: first.accountScopeKey, ownerID: id, origin: origin,
                    prompt: "示例图片", modelName: "fixture", pngData: Data([0])))
            }
            try old.mainContext.save()
        }
        let opened = LocalDatabaseState(storeURL: url)
        let context = try XCTUnwrap(opened.container, opened.failure ?? "").mainContext
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIConversation>()), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AIGeneratedImage>()).map(\.originRaw), ["profile"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AIProfileResult>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SavedGamePlan>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<GameRecord>()).map(\.title), ["保留游戏"])

        let currentID = try AIConversationActions.create(accountScope: "ps:private-ps", draft: "新草稿", in: context).id
        opened.retry()
        let reopened = try XCTUnwrap(opened.container, opened.failure ?? "").mainContext
        let saved = try LocalPersistence.conversation(currentID, in: reopened)
        XCTAssertEqual(saved.draft, "新草稿")
        XCTAssertEqual(saved.usesLocalQueries, true)
    }
}

private enum BeforeChatQueries: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [GameRecord.self, PlaySnapshot.self, DailyPlayActivity.self, PlayTimeAllocation.self,
         AIConversation.self, AIProfileResult.self, SavedGamePlan.self, AIGeneratedImage.self]
    }

    @Model
    final class AIConversation {
        @Attribute(.unique) var id = UUID()
        var title = "旧对话"
        var createdAt = Date.now
        var updatedAt = Date.now
        var titleGeneratedAt: Date?
        var messagesData: Data
        var gameContextData: Data
        var accountScopeKey: String = ""
        var draft: String = ""
        var draftRequestsImage: Bool = false
        var recentPlayContextData: Data?

        init() {
            messagesData = Data(#"[{"role":"user","content":"旧问题"}]"#.utf8)
            gameContextData = Data("[]".utf8)
            accountScopeKey = "ps:private-ps"
            draft = "旧草稿"
            recentPlayContextData = Data("旧近期快照".utf8)
        }
    }
}
