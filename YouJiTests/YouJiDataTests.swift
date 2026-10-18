import XCTest
import SwiftData
@testable import YouJi

final class YouJiDataTests: XCTestCase {
    func testRecordIDsAreSeparatedByAccount() {
        let first = GameRecord.recordID(platform: .playStation, accountID: "account-a", titleID: "game-1")
        let second = GameRecord.recordID(platform: .playStation, accountID: "account-b", titleID: "game-1")

        XCTAssertEqual(first, "ps:account-a:game-1")
        XCTAssertNotEqual(first, second)
    }

    func testNintendoDateParserSupportsKnownFormats() throws {
        XCTAssertNotNil(NintendoAPIClient.parseDate("2026-08-12"))
        XCTAssertNotNil(NintendoAPIClient.parseDate("2026-08-12T00:00:00+09:00"))
        XCTAssertNotNil(NintendoAPIClient.parseDate("2026-08-12T00:00:00.123Z"))
        let playedDay = NintendoAPIClient.parsePlayedDay("2026-08-12T00:00:00+09:00")
        XCTAssertEqual(Calendar.current.component(.day, from: try XCTUnwrap(playedDay)), 12)
    }

    func testNintendoHistoryNormalizesExactDailyActivity() throws {
        let now = try XCTUnwrap(NintendoAPIClient.parsePlayedDay("2026-08-13"))
        let history = StorePlayHistoryResponse(
            playHistories: [
                StorePlayHistory(
                    titleID: "game-1",
                    titleName: "Game",
                    imageURL: "",
                    firstPlayedAt: "2026-08-01",
                    lastPlayedAt: "2026-08-13",
                    totalPlayedMinutes: 300
                )
            ],
            recentPlayHistories: [
                StoreRecentDay(
                    playedDate: "2026-08-12",
                    dailyPlayHistories: [
                        StoreRecentTitle(titleID: "game-1", totalPlayedMinutes: 30),
                        StoreRecentTitle(titleID: "game-1", totalPlayedMinutes: 15),
                    ]
                ),
                StoreRecentDay(
                    playedDate: "2026-08-13",
                    dailyPlayHistories: [
                        StoreRecentTitle(titleID: "game-1", totalPlayedMinutes: 10),
                    ]
                ),
            ]
        )

        let normalized = NintendoAPIClient.normalize(history: history, now: now)

        XCTAssertEqual(normalized.games.first?.weeklyMinutes, [0, 0, 0, 0, 0, 45, 10])
        XCTAssertEqual(normalized.dailyActivities.count, 2)
        XCTAssertEqual(
            normalized.dailyActivities.reduce(0) { $0 + $1.totalMinutes },
            55
        )
    }

    func testNintendoStoreRequestsUseSupportedLocale() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NintendoURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let capturedRequests = CapturedRequests()

        NintendoURLProtocolStub.handler = { request in
            capturedRequests.append(request)
            let data: Data
            switch request.url?.path {
            case "/connect/1.0.0/api/token":
                data = Data(#"{"access_token":"access-token","expires_in":900}"#.utf8)
            case "/2.0.0/users/me":
                data = Data(#"{"id":"account-id","nickname":"玩家"}"#.utf8)
            case "/api/v2.0/users/me/play_histories":
                data = Data(#"{"playHistories":[],"recentPlayHistories":[]}"#.utf8)
            default:
                throw URLError(.badURL)
            }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, data)
        }
        defer { NintendoURLProtocolStub.handler = nil }

        _ = try await NintendoAPIClient(session: session).loadLibrary(sessionToken: "session-token")

        let historyRequest = try XCTUnwrap(capturedRequests.values.first {
            $0.url?.path == "/api/v2.0/users/me/play_histories"
        })
        XCTAssertEqual(historyRequest.value(forHTTPHeaderField: "gentry-locale"), "en-US")
        XCTAssertNil(historyRequest.value(forHTTPHeaderField: "Accept-Language"))
    }

    func testPlayStationAccountIDComesFromJWTSubject() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["sub": "account-123"])
            .base64URLEncodedString()
        let token = "header.\(payload).signature"

        XCTAssertEqual(try PlayStationAPIClient.accountID(from: token), "account-123")
    }

    func testLibraryHidesOnlyOldShortRecords() {
        let oldDate = Calendar.current.date(byAdding: .month, value: -7, to: .now)
        let shortOld = GameRecord(
            applicationID: "switch:a:short",
            accountID: "a",
            titleID: "short",
            platform: .switchConsole,
            title: "Short",
            totalMinutes: 59,
            lastPlayedAt: oldDate
        )
        let longOld = GameRecord(
            applicationID: "switch:a:long",
            accountID: "a",
            titleID: "long",
            platform: .switchConsole,
            title: "Long",
            totalMinutes: 60,
            lastPlayedAt: oldDate
        )

        XCTAssertTrue(shortOld.shouldHideFromLibrary)
        XCTAssertFalse(longOld.shouldHideFromLibrary)
        shortOld.isPinnedVisible = true
        XCTAssertFalse(shortOld.shouldHideFromLibrary)
        shortOld.isManuallyHidden = true
        XCTAssertTrue(shortOld.shouldHideFromLibrary)
    }

    func testAccountScopeIsStableAndSeparated() {
        XCTAssertEqual(
            AccountScope.key(playStationAccountID: "ps-a", nintendoAccountID: "ns-a"),
            "ps:ps-a|switch:ns-a"
        )
        XCTAssertNotEqual(
            AccountScope.key(playStationAccountID: "ps-a", nintendoAccountID: "ns-a"),
            AccountScope.key(playStationAccountID: "ps-b", nintendoAccountID: "ns-a")
        )
        XCTAssertTrue(AccountScope.contains("ps:123|switch:456", platform: .playStation, accountID: "123"))
        XCTAssertFalse(AccountScope.contains("ps:1234|switch:456", platform: .playStation, accountID: "123"))
    }

    func testLibraryShowsSingleRestoredArchiveWhenCurrentAccountIsMissing() {
        let playStation = GameRecord(
            applicationID: "ps:archive-ps:game",
            accountID: "archive-ps",
            titleID: "game",
            platform: .playStation,
            title: "PS Game"
        )
        let nintendo = GameRecord(
            applicationID: "switch:current-ns:game",
            accountID: "current-ns",
            titleID: "game",
            platform: .switchConsole,
            title: "NS Game"
        )

        let visible = AccountScope.visibleLibraryGames(
            [playStation, nintendo],
            playStationAccountID: "",
            nintendoAccountID: "current-ns"
        )

        XCTAssertEqual(Set(visible.map(\.applicationID)), Set([playStation.applicationID, nintendo.applicationID]))
    }

    func testLibraryDoesNotMergeMultipleRestoredAccountsWithoutASelection() {
        let first = GameRecord(
            applicationID: "ps:first:game",
            accountID: "first",
            titleID: "game",
            platform: .playStation,
            title: "First"
        )
        let second = GameRecord(
            applicationID: "ps:second:game",
            accountID: "second",
            titleID: "game",
            platform: .playStation,
            title: "Second"
        )

        let visible = AccountScope.visibleLibraryGames(
            [first, second],
            playStationAccountID: "",
            nintendoAccountID: ""
        )

        XCTAssertTrue(visible.isEmpty)
    }

    func testVisibleScopeUsesAutomaticallyDisplayedArchiveAccounts() {
        let playStation = GameRecord(
            applicationID: "ps:archive-ps:game",
            accountID: "archive-ps",
            titleID: "game",
            platform: .playStation,
            title: "PS Game"
        )
        let nintendo = GameRecord(
            applicationID: "switch:current-ns:game",
            accountID: "current-ns",
            titleID: "game",
            platform: .switchConsole,
            title: "NS Game"
        )

        XCTAssertEqual(
            AccountScope.visibleScopeKey(
                for: [playStation, nintendo],
                playStationAccountID: "",
                nintendoAccountID: "current-ns"
            ),
            "ps:archive-ps|switch:current-ns"
        )
    }

    func testLegacyScopeMigrationRequiresUnambiguousAccounts() {
        let playStation = GameRecord(
            applicationID: "ps:archive-ps:game",
            accountID: "archive-ps",
            titleID: "game",
            platform: .playStation,
            title: "PS Game"
        )
        let nintendo = GameRecord(
            applicationID: "switch:archive-ns:game",
            accountID: "archive-ns",
            titleID: "game",
            platform: .switchConsole,
            title: "NS Game"
        )
        XCTAssertEqual(
            AccountScope.unambiguousArchiveScopeKey(for: [playStation, nintendo]),
            "ps:archive-ps|switch:archive-ns"
        )

        let otherPlayStation = GameRecord(
            applicationID: "ps:other:game",
            accountID: "other",
            titleID: "game",
            platform: .playStation,
            title: "Other PS Game"
        )
        XCTAssertNil(
            AccountScope.unambiguousArchiveScopeKey(for: [playStation, otherPlayStation, nintendo])
        )
    }

    @MainActor
    func testDeletingArchiveDoesNotMatchAccountPrefix() throws {
        let container = try ModelContainer(
            for: GameRecord.self,
            PlaySnapshot.self,
            DailyPlayActivity.self,
            AIConversation.self,
            AIProfileResult.self,
            SavedGamePlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        context.insert(GameRecord(
            applicationID: "ps:123:game",
            accountID: "123",
            titleID: "game",
            platform: .playStation,
            title: "Deleted"
        ))
        context.insert(GameRecord(
            applicationID: "ps:1234:game",
            accountID: "1234",
            titleID: "game",
            platform: .playStation,
            title: "Kept"
        ))
        context.insert(AIConversation(accountScopeKey: "ps:123", games: []))
        context.insert(AIConversation(accountScopeKey: "ps:1234", games: []))
        try context.save()

        try ProductDataService.deleteArchive(
            platform: .playStation,
            accountID: "123",
            modelContext: context
        )

        XCTAssertEqual(try context.fetch(FetchDescriptor<GameRecord>()).map(\.accountID), ["1234"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<AIConversation>()).map(\.accountScopeKey), ["ps:1234"])
    }

    func testSnapshotInsightUsesCumulativeDeltas() {
        let now = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let before = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        let recent = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let snapshots = [
            PlaySnapshot(gameID: "ps:a:one", accountID: "a", platform: .playStation, date: before, totalMinutes: 100, trophiesEarned: 2),
            PlaySnapshot(gameID: "ps:a:one", accountID: "a", platform: .playStation, date: recent, totalMinutes: 250, trophiesEarned: 5),
            PlaySnapshot(gameID: "ps:a:two", accountID: "a", platform: .playStation, date: before, totalMinutes: 80, trophiesEarned: 0),
            PlaySnapshot(gameID: "ps:a:two", accountID: "a", platform: .playStation, date: recent, totalMinutes: 80, trophiesEarned: 0),
        ]

        let insight = PlayInsightCalculator.insight(snapshots: snapshots, since: start, now: now)

        XCTAssertEqual(insight.addedMinutes, 150)
        XCTAssertEqual(insight.addedTrophies, 3)
        XCTAssertEqual(insight.activeGames, 1)

        let contributions = PlayInsightCalculator.contributions(snapshots: snapshots, since: start, now: now)
        XCTAssertEqual(contributions, [
            PlayGameContribution(gameID: "ps:a:one", addedMinutes: 150, addedTrophies: 3),
        ])
    }

    func testSnapshotKeepsCumulativeValues() {
        let snapshot = PlaySnapshot(
            gameID: "ps:a:game",
            accountID: "a",
            platform: .playStation,
            totalMinutes: 371 * 60,
            trophiesEarned: 42
        )

        XCTAssertEqual(snapshot.gameID, "ps:a:game")
        XCTAssertEqual(snapshot.totalMinutes, 22_260)
        XCTAssertEqual(snapshot.trophiesEarned, 42)
        XCTAssertEqual(snapshot.platform, .playStation)
    }

    func testPlayTimelineBuildsChronologicalSnapshotChanges() {
        let first = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 100))
        let second = Calendar.current.date(byAdding: .day, value: 1, to: first)!
        let third = Calendar.current.date(byAdding: .day, value: 2, to: first)!
        let snapshots = [
            PlaySnapshot(snapshotID: "first", gameID: "ps:a:game", accountID: "a", platform: .playStation, date: first, totalMinutes: 100, trophiesEarned: 1),
            PlaySnapshot(snapshotID: "second", gameID: "ps:a:game", accountID: "a", platform: .playStation, date: second, totalMinutes: 160, trophiesEarned: 1),
            PlaySnapshot(snapshotID: "third", gameID: "ps:a:game", accountID: "a", platform: .playStation, date: third, totalMinutes: 190, trophiesEarned: 3),
        ]

        let entries = PlayTimelineBuilder.entries(
            snapshots: snapshots,
            activities: [],
            includedGameIDs: ["ps:a:game"]
        )

        XCTAssertEqual(entries.map(\.date), [second, third])
        XCTAssertEqual(entries.map(\.addedMinutes), [60, 30])
        XCTAssertEqual(entries.map(\.addedTrophies), [0, 2])
    }

    func testPlayHistoryChartScaleFocusesOnHighCumulativeValues() {
        let changingDomain = PlayHistoryChartBuilder.yDomain(totalMinutes: [200 * 60, 215 * 60])
        XCTAssertEqual(changingDomain.lowerBound, 197)
        XCTAssertEqual(changingDomain.upperBound, 218)

        let flatDomain = PlayHistoryChartBuilder.yDomain(totalMinutes: [200 * 60, 200 * 60])
        XCTAssertEqual(flatDomain.lowerBound, 198)
        XCTAssertEqual(flatDomain.upperBound, 202)
    }

    func testPlayHistoryAndTimelineMergeRecordsWithinOneDay() {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 100))
        let baseline = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        let morning = day.addingTimeInterval(9 * 60 * 60)
        let evening = day.addingTimeInterval(20 * 60 * 60)
        let snapshots = [
            PlaySnapshot(snapshotID: "baseline", gameID: "ps:a:game", accountID: "a", platform: .playStation, date: baseline, totalMinutes: 100, trophiesEarned: 0),
            PlaySnapshot(snapshotID: "morning", gameID: "ps:a:game", accountID: "a", platform: .playStation, date: morning, totalMinutes: 130, trophiesEarned: 1),
            PlaySnapshot(snapshotID: "evening", gameID: "ps:a:game", accountID: "a", platform: .playStation, date: evening, totalMinutes: 160, trophiesEarned: 2),
        ]

        let dailySnapshots = PlayHistoryChartBuilder.dailySnapshots(snapshots)
        XCTAssertEqual(dailySnapshots.count, 2)
        XCTAssertEqual(dailySnapshots.last?.snapshotID, "evening")

        let entries = PlayTimelineBuilder.entries(
            snapshots: snapshots,
            activities: [],
            includedGameIDs: ["ps:a:game"]
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.date, day)
        XCTAssertEqual(entries.first?.addedMinutes, 60)
        XCTAssertEqual(entries.first?.addedTrophies, 2)
    }

    func testPlayTimelinePrefersSwitchDailyActivityOverSnapshotChanges() {
        let first = Date(timeIntervalSince1970: 100)
        let second = Date(timeIntervalSince1970: 200)
        let activity = DailyPlayActivity(
            activityID: "switch:a:game:day",
            gameID: "switch:a:game",
            accountID: "a",
            titleID: "game",
            platform: .switchConsole,
            day: second,
            totalMinutes: 45
        )
        let snapshots = [
            PlaySnapshot(gameID: "switch:a:game", accountID: "a", platform: .switchConsole, date: first, totalMinutes: 100, trophiesEarned: 0),
            PlaySnapshot(gameID: "switch:a:game", accountID: "a", platform: .switchConsole, date: second, totalMinutes: 145, trophiesEarned: 0),
        ]

        let entries = PlayTimelineBuilder.entries(
            snapshots: snapshots,
            activities: [activity],
            includedGameIDs: ["switch:a:game"]
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.gameID, "switch:a:game")
        XCTAssertEqual(entries.first?.date, Calendar.current.startOfDay(for: second))
        XCTAssertEqual(entries.first?.addedMinutes, 45)
        XCTAssertEqual(entries.first?.source, .dailyActivity)
    }

    func testDailyActivityIDIsSeparatedByAccountAndDay() throws {
        let firstDay = try XCTUnwrap(NintendoAPIClient.parsePlayedDay("2026-08-12"))
        let secondDay = try XCTUnwrap(NintendoAPIClient.parsePlayedDay("2026-08-13"))
        let first = DailyPlayActivity.recordID(
            platform: .switchConsole,
            accountID: "account-a",
            titleID: "game-1",
            day: firstDay
        )

        XCTAssertEqual(first, "switch:account-a:game-1:2026-08-12")
        XCTAssertNotEqual(first, DailyPlayActivity.recordID(
            platform: .switchConsole,
            accountID: "account-b",
            titleID: "game-1",
            day: firstDay
        ))
        XCTAssertNotEqual(first, DailyPlayActivity.recordID(
            platform: .switchConsole,
            accountID: "account-a",
            titleID: "game-1",
            day: secondDay
        ))
    }

    func testDailyActivityDayKeyIsStableAcrossTimeZones() throws {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let day = try XCTUnwrap(shanghai.date(from: DateComponents(year: 2026, month: 8, day: 12)))

        let dayKey = DailyPlayActivity.dayKey(for: day, calendar: shanghai)
        let displayed = try XCTUnwrap(DailyPlayActivity.date(fromDayKey: dayKey, calendar: losAngeles))

        XCTAssertEqual(dayKey, "2026-08-12")
        XCTAssertEqual(losAngeles.dateComponents([.year, .month, .day], from: displayed), DateComponents(year: 2026, month: 8, day: 12))
    }

    @MainActor
    func testLegacyMigrationPreservesCustomDataAndHistoryReferences() throws {
        let container = try ModelContainer(
            for: GameRecord.self,
            PlaySnapshot.self,
            DailyPlayActivity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let legacy = GameRecord(
            applicationID: "switch:game",
            platform: .switchConsole,
            title: "Legacy Game",
            totalMinutes: 300
        )
        legacy.isFavorite = true
        legacy.personalNote = "不要丢失"
        legacy.playStatus = .replay
        let current = GameRecord(
            applicationID: "switch:account-a:game",
            accountID: "account-a",
            titleID: "game",
            platform: .switchConsole,
            title: "Current Game",
            totalMinutes: 120
        )
        let snapshot = PlaySnapshot(
            gameID: legacy.applicationID,
            accountID: "",
            platform: .switchConsole,
            totalMinutes: 300,
            trophiesEarned: 0
        )
        let day = try XCTUnwrap(NintendoAPIClient.parsePlayedDay("2026-08-12"))
        let activity = DailyPlayActivity(
            activityID: "switch:game:2026-08-12",
            gameID: legacy.applicationID,
            accountID: "",
            titleID: "game",
            platform: .switchConsole,
            day: day,
            totalMinutes: 45
        )
        context.insert(legacy)
        context.insert(current)
        context.insert(snapshot)
        context.insert(activity)
        try context.save()

        try LegacyRecordMigrator.migrate(
            platform: .switchConsole,
            accountID: "account-a",
            modelContext: context
        )

        let games = try context.fetch(FetchDescriptor<GameRecord>())
        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].applicationID, "switch:account-a:game")
        XCTAssertEqual(games[0].totalMinutes, 300)
        XCTAssertTrue(games[0].isFavorite)
        XCTAssertEqual(games[0].personalNote, "不要丢失")
        XCTAssertEqual(games[0].playStatus, .replay)
        XCTAssertEqual(snapshot.gameID, "switch:account-a:game")
        XCTAssertEqual(snapshot.accountID, "account-a")
        XCTAssertEqual(activity.gameID, "switch:account-a:game")
        XCTAssertEqual(activity.activityID, "switch:account-a:game:2026-08-12")
        XCTAssertEqual(activity.accountID, "account-a")
    }

	func testAIPromptsUseSharedGameBrainContext() {
        let games = [
            AIAnalysisGame(
                platform: "PS",
                title: "宇宙机器人",
                totalMinutes: 725,
                trophyRatio: "42/44（95%）"
            ),
            AIAnalysisGame(
                platform: "NS",
                title: "塞尔达传说",
                totalMinutes: 3_600,
                trophyRatio: nil
            ),
        ]

		let gameInfo = AIPrompts.gameListInfo(games: games)
		let personality = AIPrompts.personalitySystem(games: games)
		let chat = AIPrompts.chatSystem(games: games)

		XCTAssertTrue(personality.contains("游戏大脑"))
		XCTAssertTrue(chat.contains("游戏大脑"))
		XCTAssertTrue(gameInfo.contains("[PS] 宇宙机器人 | 游玩 12h 5m | 奖杯 42/44（95%）"))
		XCTAssertTrue(gameInfo.contains("[NS] 塞尔达传说 | 游玩 60h 0m"))
		XCTAssertFalse(gameInfo.contains("不适用"))
		XCTAssertFalse(gameInfo.contains("暂无数据"))
		XCTAssertEqual(AIPrompts.chatMinimumMinutes, 60)
	}

	func testConversationTitlePromptUsesRecentConversation() {
		let messages = [
			AIChatMessage(role: .user, content: "我接下来适合玩什么动作游戏？"),
			AIChatMessage(role: .assistant, content: "你偏爱探索和高完成度，可以试试银河战士。"),
		]

		let prompt = AIPrompts.titleRequest(messages: messages)

		XCTAssertTrue(AIPrompts.titleSystem.contains("只输出标题本身"))
		XCTAssertTrue(prompt.contains("我接下来适合玩什么动作游戏？"))
		XCTAssertTrue(prompt.contains("你偏爱探索和高完成度"))
	}

    @MainActor
    func testGameAndSnapshotPersistTogether() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: GameRecord.self,
            PlaySnapshot.self,
            DailyPlayActivity.self,
            configurations: configuration
        )
        let context = container.mainContext
        let game = GameRecord(
            applicationID: "ps:a:game",
            accountID: "a",
            titleID: "game",
            platform: .playStation,
            title: "Game",
            totalMinutes: 120
        )
        context.insert(game)
        context.insert(PlaySnapshot(
            gameID: game.applicationID,
            accountID: "a",
            platform: .playStation,
            totalMinutes: 120,
            trophiesEarned: 3
        ))
        let day = Calendar.current.startOfDay(for: .now)
        context.insert(DailyPlayActivity(
            activityID: DailyPlayActivity.recordID(
                platform: .switchConsole,
                accountID: "a",
                titleID: "switch-game",
                day: day
            ),
            gameID: "switch:a:switch-game",
            accountID: "a",
            titleID: "switch-game",
            platform: .switchConsole,
            day: day,
            totalMinutes: 45
        ))
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<GameRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PlaySnapshot>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DailyPlayActivity>()).first?.totalMinutes, 45)
    }

    @MainActor
    func testExistingNintendoWeekBackfillsDailyActivities() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: GameRecord.self,
            DailyPlayActivity.self,
            configurations: configuration
        )
        let context = container.mainContext
        let syncDay = try XCTUnwrap(NintendoAPIClient.parsePlayedDay("2026-08-13"))
        let game = GameRecord(
            applicationID: "switch:a:game",
            accountID: "a",
            titleID: "game",
            platform: .switchConsole,
            title: "Game",
            weeklyMinutes: [0, 0, 0, 0, 0, 30, 45]
        )
        game.updatedAt = syncDay
        game.weeklyEndingDayKey = "2026-08-13"
        context.insert(game)
        try context.save()

        SyncCoordinator().backfillNintendoDailyActivities(modelContext: context, force: true)

        let activities = try context.fetch(FetchDescriptor<DailyPlayActivity>())
        XCTAssertEqual(activities.count, 2)
        XCTAssertEqual(Set(activities.map(\.totalMinutes)), [30, 45])
        XCTAssertEqual(Set(activities.map(\.gameID)), [game.applicationID])
    }

	@MainActor
	func testAIConversationPersistsMessagesAndFrozenGameContext() throws {
		let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
		let container = try ModelContainer(for: AIConversation.self, configurations: configuration)
		let context = container.mainContext
		let games = [
			AIAnalysisGame(
				platform: "PS",
				title: "宇宙机器人",
				totalMinutes: 725,
				trophyRatio: "42/44（95%）"
			),
			AIAnalysisGame(
				platform: "NS",
				title: "塞尔达传说",
				totalMinutes: 3_600,
				trophyRatio: nil
			),
		]
		let conversation = AIConversation(accountScopeKey: "ps:a", games: games)
		conversation.title = "动作游戏推荐"
		conversation.messages = [
			AIChatMessage(role: .user, content: "推荐一款动作游戏"),
			AIChatMessage(role: .assistant, content: "可以试试宇宙机器人。"),
		]
		context.insert(conversation)
		try context.save()

		let stored = try XCTUnwrap(context.fetch(FetchDescriptor<AIConversation>()).first)
		XCTAssertEqual(stored.title, "动作游戏推荐")
		XCTAssertEqual(stored.messages.map(\.content), ["推荐一款动作游戏", "可以试试宇宙机器人。"])
		XCTAssertEqual(stored.messages.map(\.role), [.user, .assistant])
		XCTAssertEqual(stored.games, games)
		XCTAssertEqual(stored.accountScopeKey, "ps:a")
		XCTAssertEqual(stored.preview, "可以试试宇宙机器人。")
	}

    @MainActor
    func testCompleteBackupRoundTripExcludesCredentialsBySchema() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let source = try ModelContainer(
            for: GameRecord.self,
            PlaySnapshot.self,
            DailyPlayActivity.self,
            AIConversation.self,
            AIProfileResult.self,
            SavedGamePlan.self,
            configurations: configuration
        )
        let context = source.mainContext
        let game = GameRecord(
            applicationID: "switch:a:game",
            accountID: "a",
            titleID: "game",
            platform: .switchConsole,
            title: "Game",
            totalMinutes: 300,
            weeklyMinutes: [0, 0, 0, 0, 0, 20, 30]
        )
        game.isFavorite = true
        game.personalNote = "重温主线"
        game.playStatus = .replay
        context.insert(game)
        context.insert(PlaySnapshot(gameID: game.applicationID, accountID: "a", platform: .switchConsole, totalMinutes: 300, trophiesEarned: 0))
        context.insert(DailyPlayActivity(
            activityID: "switch:a:game:2026-08-13",
            gameID: game.applicationID,
            accountID: "a",
            titleID: "game",
            platform: .switchConsole,
            day: .now,
            totalMinutes: 30
        ))
        let conversation = AIConversation(accountScopeKey: "switch:a", games: [
            AIAnalysisGame(platform: "NS", title: "Game", totalMinutes: 300, trophyRatio: nil)
        ])
        conversation.messages = [AIChatMessage(role: .user, content: "聊聊这款游戏")]
        context.insert(conversation)
        let profile = AIProfileResult(
            accountScopeKey: "switch:a",
            platformFilter: "Switch",
            minimumHours: 1,
            text: "人格内容",
            gameCount: 1,
            totalMinutes: 300
        )
        context.insert(profile)
        let plan = SavedGamePlan(accountScopeKey: "switch:a", title: "Game", note: "下周重温")
        context.insert(plan)
        try context.save()

        let data = try ProductDataService.backupData(modelContext: context)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("apiKey"))
        XCTAssertFalse(text.contains("refreshToken"))

        let targetConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
        let target = try ModelContainer(
            for: GameRecord.self,
            PlaySnapshot.self,
            DailyPlayActivity.self,
            AIConversation.self,
            AIProfileResult.self,
            SavedGamePlan.self,
            configurations: targetConfiguration
        )
        let staleConversation = AIConversation(
            id: conversation.id,
            title: "旧标题",
            accountScopeKey: "switch:old",
            games: []
        )
        staleConversation.messages = []
        staleConversation.updatedAt = .distantPast
        target.mainContext.insert(staleConversation)
        target.mainContext.insert(AIProfileResult(
            id: profile.id,
            accountScopeKey: "switch:old",
            platformFilter: "全部",
            minimumHours: 50,
            text: "旧人格",
            gameCount: 0,
            totalMinutes: 0
        ))
        let stalePlan = SavedGamePlan(
            id: plan.id,
            accountScopeKey: "switch:old",
            title: "旧计划",
            isCompleted: true
        )
        stalePlan.updatedAt = .distantPast
        target.mainContext.insert(stalePlan)
        let staleActivity = DailyPlayActivity(
            activityID: "switch:a:game:2026-08-13",
            gameID: "switch:a:game",
            accountID: "a",
            titleID: "game",
            platform: .switchConsole,
            day: .distantPast,
            totalMinutes: 1
        )
        staleActivity.updatedAt = .distantPast
        target.mainContext.insert(staleActivity)
        try target.mainContext.save()
        let restoreSummary = try ProductDataService.restore(data: data, modelContext: target.mainContext)

        let restoredGame = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<GameRecord>()).first)
        XCTAssertEqual(restoreSummary, ProductRestoreSummary(gameCount: 1, snapshotCount: 1, dailyActivityCount: 1))
        XCTAssertEqual(restoredGame.personalNote, "重温主线")
        XCTAssertEqual(restoredGame.playStatus, .replay)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<PlaySnapshot>()), 1)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<DailyPlayActivity>()), 1)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<AIConversation>()), 1)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<AIProfileResult>()), 1)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<SavedGamePlan>()), 1)
        XCTAssertEqual(try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<DailyPlayActivity>()).first).totalMinutes, 30)
        let restoredConversation = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<AIConversation>()).first)
        XCTAssertEqual(restoredConversation.accountScopeKey, "switch:a")
        XCTAssertEqual(restoredConversation.messages.map(\.content), ["聊聊这款游戏"])
        XCTAssertEqual(restoredConversation.games.map(\.title), ["Game"])
        let restoredProfile = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<AIProfileResult>()).first)
        XCTAssertEqual(restoredProfile.text, "人格内容")
        XCTAssertEqual(restoredProfile.minimumHours, 1)
        let restoredPlan = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<SavedGamePlan>()).first)
        XCTAssertEqual(restoredPlan.title, "Game")
        XCTAssertEqual(restoredPlan.note, "下周重温")
        XCTAssertFalse(restoredPlan.isCompleted)
    }

    @MainActor
    func testRestoreKeepsNewerLocalGameEdits() throws {
        let source = try ModelContainer(
            for: GameRecord.self,
            PlaySnapshot.self,
            DailyPlayActivity.self,
            AIConversation.self,
            AIProfileResult.self,
            SavedGamePlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let oldGame = GameRecord(
            applicationID: "switch:a:game",
            accountID: "a",
            titleID: "game",
            platform: .switchConsole,
            title: "Game",
            totalMinutes: 100
        )
        oldGame.personalNote = "旧备注"
        oldGame.updatedAt = .distantPast
        source.mainContext.insert(oldGame)
        try source.mainContext.save()
        let backup = try ProductDataService.backupData(modelContext: source.mainContext)

        let target = try ModelContainer(
            for: GameRecord.self,
            PlaySnapshot.self,
            DailyPlayActivity.self,
            AIConversation.self,
            AIProfileResult.self,
            SavedGamePlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let newerGame = GameRecord(
            applicationID: "switch:a:game",
            accountID: "a",
            titleID: "game",
            platform: .switchConsole,
            title: "Game",
            totalMinutes: 180
        )
        newerGame.personalNote = "本机新备注"
        newerGame.updatedAt = .now
        target.mainContext.insert(newerGame)
        try target.mainContext.save()

        try ProductDataService.restore(data: backup, modelContext: target.mainContext)

        let restored = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<GameRecord>()).first)
        XCTAssertEqual(restored.totalMinutes, 180)
        XCTAssertEqual(restored.personalNote, "本机新备注")
    }

    @MainActor
    func testRestoreComparesLegacyUserEditsBeforeUpdatingPlatformData() throws {
        let source = try ModelContainer(
            for: GameRecord.self,
            PlaySnapshot.self,
            DailyPlayActivity.self,
            AIConversation.self,
            AIProfileResult.self,
            SavedGamePlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let backedUpGame = GameRecord(
            applicationID: "switch:a:game",
            accountID: "a",
            titleID: "game",
            platform: .switchConsole,
            title: "Game",
            totalMinutes: 180
        )
        backedUpGame.personalNote = "备份里的新备注"
        backedUpGame.isFavorite = true
        backedUpGame.userEditedAt = Date(timeIntervalSince1970: 200)
        backedUpGame.updatedAt = Date(timeIntervalSince1970: 300)
        source.mainContext.insert(backedUpGame)
        try source.mainContext.save()
        let backup = try ProductDataService.backupData(modelContext: source.mainContext)

        let target = try ModelContainer(
            for: GameRecord.self,
            PlaySnapshot.self,
            DailyPlayActivity.self,
            AIConversation.self,
            AIProfileResult.self,
            SavedGamePlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let legacyGame = GameRecord(
            applicationID: "switch:a:game",
            accountID: "a",
            titleID: "game",
            platform: .switchConsole,
            title: "Game",
            totalMinutes: 100
        )
        legacyGame.personalNote = "本机旧备注"
        legacyGame.updatedAt = Date(timeIntervalSince1970: 100)
        target.mainContext.insert(legacyGame)
        try target.mainContext.save()

        try ProductDataService.restore(data: backup, modelContext: target.mainContext)

        let restored = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<GameRecord>()).first)
        XCTAssertEqual(restored.totalMinutes, 180)
        XCTAssertEqual(restored.updatedAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(restored.personalNote, "备份里的新备注")
        XCTAssertTrue(restored.isFavorite)
        XCTAssertEqual(restored.userEditedAt, Date(timeIntervalSince1970: 200))
    }

    @MainActor
    func testRestoreImportsUserFieldsEvenWhenPlatformDataIsNewer() throws {
        let source = try ModelContainer(
            for: GameRecord.self,
            PlaySnapshot.self,
            DailyPlayActivity.self,
            AIConversation.self,
            AIProfileResult.self,
            SavedGamePlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let backedUpGame = GameRecord(
            applicationID: "switch:a:game",
            accountID: "a",
            titleID: "game",
            platform: .switchConsole,
            title: "Game",
            totalMinutes: 100
        )
        backedUpGame.personalNote = "备份里的私人备注"
        backedUpGame.isFavorite = true
        backedUpGame.updatedAt = .distantPast
        backedUpGame.userEditedAt = Date(timeIntervalSince1970: 100)
        source.mainContext.insert(backedUpGame)
        try source.mainContext.save()
        let backup = try ProductDataService.backupData(modelContext: source.mainContext)

        let target = try ModelContainer(
            for: GameRecord.self,
            PlaySnapshot.self,
            DailyPlayActivity.self,
            AIConversation.self,
            AIProfileResult.self,
            SavedGamePlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let freshlySyncedGame = GameRecord(
            applicationID: "switch:a:game",
            accountID: "a",
            titleID: "game",
            platform: .switchConsole,
            title: "Game",
            totalMinutes: 180
        )
        freshlySyncedGame.updatedAt = .now
        target.mainContext.insert(freshlySyncedGame)
        try target.mainContext.save()

        try ProductDataService.restore(data: backup, modelContext: target.mainContext)

        let restored = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<GameRecord>()).first)
        XCTAssertEqual(restored.totalMinutes, 180)
        XCTAssertEqual(restored.personalNote, "备份里的私人备注")
        XCTAssertTrue(restored.isFavorite)
    }
}

private final class CapturedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var values: [URLRequest] {
        lock.withLock { requests }
    }

    func append(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }
}

private final class NintendoURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension YouJiDataTests {
    @MainActor
    private func safetyContainer() throws -> ModelContainer {
        try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func stubSession(body: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NintendoURLProtocolStub.self]
        NintendoURLProtocolStub.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        return URLSession(configuration: configuration)
    }

    func testTrophyCountsAcceptKnownNumberRepresentationsAndRejectUnknownValues() throws {
        let counts = try JSONDecoder().decode(PlayStationTrophyCounts.self, from: Data(#"{"bronze":"12","silver":2.0,"gold":1,"platinum":" 0 "}"#.utf8))
        XCTAssertEqual(counts.total, 15)
        for body in [#"{"bronze":"unknown","silver":null}"#, #"{}"#,
                     #"{"bronze":-1,"silver":0,"gold":0,"platinum":0}"#,
                     #"{"bronze":0.5,"silver":0,"gold":0,"platinum":0}"#,
                     #"{"bronze":1e100,"silver":0,"gold":0,"platinum":0}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(PlayStationTrophyCounts.self, from: Data(body.utf8)))
        }
    }

    func testDurationCompatibilityAndInvalidDurationNeverBecomesZero() throws {
        for (value, expected) in [("PT2H30M", 150), ("P1D", 1440), ("P1DT2H", 1560),
                                  ("PT90S", 1), ("PT1.5H", 90), ("PT0S", 0), (" pt1h ", 60)] {
            XCTAssertEqual(try PlayStationAPIClient.minutes(from: value), expected)
        }
        for value in ["unavailable", "", "P", "PT", "P1DT", "PT-1H", "PT99999999999999999999999999999H"] {
            XCTAssertThrowsError(try PlayStationAPIClient.minutes(from: value))
        }
    }

    func testInvalidDurationRejectsEntirePlayedGamesPayload() async throws {
        let session = stubSession(body: #"{"titles":[{"titleId":"g","name":"Game","playDuration":"unavailable"}],"totalItemCount":1}"#)
        defer { NintendoURLProtocolStub.handler = nil }
        let claims = try JSONSerialization.data(withJSONObject: ["sub": "test-account"]).base64URLEncodedString()
        do {
            _ = try await PlayStationAPIClient(session: session).loadGames(accessToken: "test.\(claims).test")
            XCTFail("Invalid duration must not enter persistence")
        } catch PlayStationSyncError.decode { }
    }

    func testTrophiesRequireMatchingTitleAndCompleteCounts() async throws {
        let session = stubSession(body: #"{"titles":[{"npTitleId":"other","trophyTitles":[{"definedTrophies":{"bronze":5,"silver":0,"gold":0,"platinum":0},"earnedTrophies":{"bronze":4,"silver":0,"gold":0,"platinum":0}}]}]}"#)
        defer { NintendoURLProtocolStub.handler = nil }
        let result = try await PlayStationAPIClient(session: session).loadTrophy(titleID: "requested", accessToken: "test")
        XCTAssertNil(result)
    }

    @MainActor
    func testUnreadableConversationSurvivesBackupRestoreByteForByte() throws {
        let source = try safetyContainer()
        let conversation = AIConversation(accountScopeKey: "switch:a", games: [])
        conversation.messagesData = Data(#"[{"role":"unrecognized","content":"recoverable text"}]"#.utf8)
        conversation.gameContextData = Data("partial game context".utf8)
        source.mainContext.insert(conversation)
        try source.mainContext.save()
        XCTAssertTrue(conversation.hasUnreadableContent)
        XCTAssertFalse(conversation.canDiscardEmptyConversation)
        let backup = try ProductDataService.backupData(modelContext: source.mainContext)
        let target = try safetyContainer()
        try ProductDataService.restore(data: backup, modelContext: target.mainContext)
        let restored = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<AIConversation>()).first)
        XCTAssertEqual(restored.messagesData, conversation.messagesData)
        XCTAssertEqual(restored.gameContextData, conversation.gameContextData)
        XCTAssertTrue(restored.hasUnreadableContent)
        XCTAssertFalse(restored.canDiscardEmptyConversation)
    }

    func testLegacyChatMessagesHaveStableIDsWithoutLosingContent() throws {
        let conversation = AIConversation(games: [])
        conversation.messagesData = Data(#"[{"role":"user","content":"相同内容"},{"role":"user","content":"相同内容"}]"#.utf8)
        XCTAssertFalse(conversation.hasUnreadableContent)
        XCTAssertEqual(conversation.messages.map(\.content), ["相同内容", "相同内容"])
        XCTAssertEqual(conversation.messages.map(\.id), conversation.messages.map(\.id))
        XCTAssertEqual(Set(conversation.messages.map(\.id)).count, 2)
        XCTAssertFalse(conversation.canDiscardEmptyConversation)
    }

    @MainActor
    func testRestoreRejectsConflictingIdentityBeforeChangingAnyRecords() throws {
        let container = try safetyContainer()
        let game = GameRecord(applicationID: "switch:a:g", accountID: "a", titleID: "g", platform: .switchConsole, title: "Original", totalMinutes: 120)
        container.mainContext.insert(game)
        try container.mainContext.save()
        let data = try ProductDataService.backupData(modelContext: container.mainContext)
        var backup = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var games = try XCTUnwrap(backup["games"] as? [[String: Any]])
        games[0]["accountID"] = "b"
        games[0]["updatedAt"] = "2030-01-01T00:00:00Z"
        games[0]["title"] = "Must not overwrite"
        backup["games"] = games
        XCTAssertThrowsError(try ProductDataService.restore(data: JSONSerialization.data(withJSONObject: backup), modelContext: container.mainContext))
        XCTAssertEqual(game.accountID, "a")
        XCTAssertEqual(game.title, "Original")
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    @MainActor
    func testRestoreRejectsDuplicatesNegativeValuesAndBrokenReferences() throws {
        let container = try safetyContainer()
        let game = GameRecord(applicationID: "switch:a:g", accountID: "a", titleID: "g", platform: .switchConsole, title: "Game", totalMinutes: 120)
        container.mainContext.insert(game)
        try container.mainContext.save()
        let data = try ProductDataService.backupData(modelContext: container.mainContext)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let games = try XCTUnwrap(original["games"] as? [[String: Any]])
        for mutation in 0..<3 {
            var backup = original
            if mutation == 0 { backup["games"] = games + games }
            if mutation == 1 {
                var invalid = games
                invalid[0]["totalMinutes"] = -1
                backup["games"] = invalid
            }
            if mutation == 2 {
                backup["snapshots"] = [["snapshotID": "bad-reference", "gameID": "switch:b:missing", "accountID": "a", "platform": "Switch", "date": "2026-01-01T00:00:00Z", "totalMinutes": 1, "trophiesEarned": 0]]
            }
            XCTAssertThrowsError(try ProductDataService.restore(data: JSONSerialization.data(withJSONObject: backup), modelContext: container.mainContext))
            XCTAssertEqual(game.totalMinutes, 120)
            XCTAssertFalse(container.mainContext.hasChanges)
        }
    }

    @MainActor
    func testVersionOneBackupWithMissingNewCollectionsAndUserFieldsStillRestores() throws {
        let data = Data(#"{"formatVersion":1,"createdAt":"2026-01-01T00:00:00Z","games":[{"applicationID":"switch:game","platform":"Switch","title":"Legacy","totalMinutes":120,"updatedAt":"2026-01-01T00:00:00Z"}]}"#.utf8)
        let target = try safetyContainer()
        try ProductDataService.restore(data: data, modelContext: target.mainContext)
        let game = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<GameRecord>()).first)
        XCTAssertEqual(game.accountID, "")
        XCTAssertEqual(game.titleID, "game")
        XCTAssertEqual(game.weeklyMinutes, Array(repeating: 0, count: 7))
        try LegacyRecordMigrator.migrate(platform: .switchConsole, accountID: "a", modelContext: target.mainContext)
        XCTAssertEqual(game.applicationID, "switch:a:game")
    }

    @MainActor
    func testRepeatedRestoreIsIdempotentAndKeepsFractionalEditTime() throws {
        let source = try safetyContainer()
        let game = GameRecord(applicationID: "switch:a:g", accountID: "a", titleID: "g", platform: .switchConsole, title: "Game")
        game.personalNote = "Note"
        game.userEditedAt = Date(timeIntervalSince1970: 100.125)
        source.mainContext.insert(game)
        source.mainContext.insert(PlaySnapshot(gameID: game.applicationID, accountID: "a", platform: .switchConsole, totalMinutes: 1, trophiesEarned: 0))
        try source.mainContext.save()
        let data = try ProductDataService.backupData(modelContext: source.mainContext)
        let target = try safetyContainer()
        try ProductDataService.restore(data: data, modelContext: target.mainContext)
        try ProductDataService.restore(data: data, modelContext: target.mainContext)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<GameRecord>()), 1)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<PlaySnapshot>()), 1)
        XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<GameRecord>()).first?.userEditedAt, game.userEditedAt)
    }

    @MainActor
    func testFailedDeleteAndRestoreLeaveNoPendingMutations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        do {
            let writable = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(url: url))
            writable.mainContext.insert(GameRecord(applicationID: "switch:a:g", accountID: "a", titleID: "g", platform: .switchConsole, title: "Original"))
            try writable.mainContext.save()
        }
        let readOnly = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(url: url, allowsSave: false))
        let context = readOnly.mainContext
        XCTAssertThrowsError(try ProductDataService.deleteArchive(platform: .switchConsole, accountID: "a", modelContext: context))
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetch(FetchDescriptor<GameRecord>()).map(\.applicationID), ["switch:a:g"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GameRecord>()), 1)
        let source = try safetyContainer()
        source.mainContext.insert(GameRecord(applicationID: "switch:b:other", accountID: "b", titleID: "other", platform: .switchConsole, title: "New"))
        try source.mainContext.save()
        XCTAssertThrowsError(try ProductDataService.restore(data: ProductDataService.backupData(modelContext: source.mainContext), modelContext: context))
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetch(FetchDescriptor<GameRecord>()).map(\.applicationID), ["switch:a:g"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GameRecord>()), 1)
    }

    @MainActor
    func testFailedBatchDoesNotRollbackPreviouslyEditedNotes() throws {
        let container = try safetyContainer()
        let game = GameRecord(applicationID: "switch:a:g", accountID: "a", titleID: "g", platform: .switchConsole, title: "Game")
        container.mainContext.insert(game)
        try container.mainContext.save()
        game.personalNote = "Unrelated unsaved note"
        XCTAssertThrowsError(try LocalPersistence.transaction(container.mainContext) { writer in
            let stored = try XCTUnwrap(writer.fetch(FetchDescriptor<GameRecord>()).first)
            writer.delete(stored)
            throw CocoaError(.fileReadUnknown)
        })
        XCTAssertEqual(game.personalNote, "Unrelated unsaved note")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<GameRecord>()), 1)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    @MainActor
    func testLegacyMergeDoesNotAdvanceUserEditDateToPlatformSyncDate() throws {
        let container = try safetyContainer()
        let legacy = GameRecord(applicationID: "switch:g", platform: .switchConsole, title: "Game")
        legacy.updatedAt = Date(timeIntervalSince1970: 100)
        legacy.personalNote = "Old note"
        let current = GameRecord(applicationID: "switch:a:g", accountID: "a", titleID: "g", platform: .switchConsole, title: "Game")
        current.updatedAt = Date(timeIntervalSince1970: 300)
        container.mainContext.insert(legacy)
        container.mainContext.insert(current)
        try container.mainContext.save()
        try LegacyRecordMigrator.migrate(platform: .switchConsole, accountID: "a", modelContext: container.mainContext)
        XCTAssertEqual(current.userEditedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(current.updatedAt, Date(timeIntervalSince1970: 300))
    }

    @MainActor
    func testRevisionRejectsPendingWritesAfterDeleteAndRestore() async throws {
        let container = try safetyContainer()
        let backup = try ProductDataService.backupData(modelContext: container.mainContext)
        let beforeRestore = LocalDataRevision.current
        try ProductDataService.restore(data: backup, modelContext: container.mainContext)
        XCTAssertThrowsError(try LocalDataRevision.check(beforeRestore))
        let beforeDelete = LocalDataRevision.current
        try await ProductDataService.deleteAllLocalData(modelContext: container.mainContext)
        XCTAssertThrowsError(try LocalDataRevision.check(beforeDelete))
        XCTAssertNoThrow(try LocalDataRevision.check(LocalDataRevision.current))
    }

    func testFrozenAnalysisFilterStaysWithItsGamePayload() {
        let request = AIProfileRequest(accountScopeKey: "switch:a", platformFilter: "Switch", minimumHours: 1,
                                       games: [AIAnalysisGame(platform: "NS", title: "Game", totalMinutes: 120, trophyRatio: nil)])
        let result = request.result(text: "Analysis")
        XCTAssertEqual(result.platformFilter, "Switch")
        XCTAssertEqual(result.minimumHours, 1)
        XCTAssertEqual(result.accountScopeKey, "switch:a")
        XCTAssertEqual(result.totalMinutes, 120)
    }

    func testSingleRestoredAccountIsAlsoUsedByCalendar() {
        let game = GameRecord(applicationID: "switch:a:g", accountID: "a", titleID: "g", platform: .switchConsole, title: "Game")
        XCTAssertEqual(AccountScope.displayAccountID(for: .switchConsole, currentAccountID: "", games: [game]), "a")
        let other = GameRecord(applicationID: "switch:b:g", accountID: "b", titleID: "g", platform: .switchConsole, title: "Other")
        XCTAssertNil(AccountScope.displayAccountID(for: .switchConsole, currentAccountID: "", games: [game, other]))
    }

    func testDayKeysRejectImpossibleDatesAndIgnoreSystemCalendarEra() throws {
        XCTAssertNil(DailyPlayActivity.date(fromDayKey: "2026-02-31"))
        XCTAssertNil(DailyPlayActivity.date(fromDayKey: "2026-13-01"))
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-18T00:00:00Z"))
        XCTAssertEqual(DailyPlayActivity.dayKey(for: date, calendar: calendar), "2026-10-18")
        XCTAssertEqual(DailyPlayActivity.date(fromDayKey: "2026-10-18", calendar: calendar), date)
    }

    @MainActor
    func testUnreadableStoreCanBeExportedAndRecoveredWithoutReplacingOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("default.store")
        let bytes = Data("not a valid SQLite database; preserve these original bytes".utf8)
        try bytes.write(to: url)
        let state = LocalDatabaseState(storeURL: url)
        XCTAssertNil(state.container)
        XCTAssertNotNil(state.failure)
        XCTAssertNoThrow(try state.rawArchive())
        XCTAssertThrowsError(try state.recover(from: Data("invalid backup".utf8)))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let source = try safetyContainer()
        source.mainContext.insert(GameRecord(applicationID: "switch:a:g", accountID: "a", titleID: "g", platform: .switchConsole, title: "Recovered"))
        try source.mainContext.save()
        try state.recover(from: ProductDataService.backupData(modelContext: source.mainContext))
        let restored = try XCTUnwrap(state.container)
        XCTAssertEqual(try restored.mainContext.fetchCount(FetchDescriptor<GameRecord>()), 1)
        XCTAssertNotEqual(state.storeURL, url)
        let nextLaunch = LocalDatabaseState(storeURL: url)
        XCTAssertEqual(nextLaunch.storeURL, state.storeURL)
        XCTAssertNotNil(nextLaunch.container)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let reopened = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(url: state.storeURL))
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<GameRecord>()).first?.title, "Recovered")
    }
}

private final class DeferredResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []
    var isWaiting: Bool { lock.withLock { !pending.isEmpty } }
    func enqueue(_ response: @escaping @Sendable () -> Void) { lock.withLock { pending.append(response) } }
    func release() {
        let responses = lock.withLock { let values = pending; pending.removeAll(); return values }
        responses.forEach { $0() }
    }
}

private final class DeferredNintendoProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var gate: DeferredResponseGate?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        switch request.url?.path {
        case "/connect/1.0.0/api/session_token": body = #"{"session_token":"test-placeholder"}"#
        case "/connect/1.0.0/api/token": body = #"{"access_token":"test-placeholder","expires_in":900}"#
        case "/2.0.0/users/me": body = #"{"id":"pending-account","nickname":"Test"}"#
        case "/api/v2.0/users/me/play_histories":
            body = #"{"playHistories":[{"titleId":"g","titleName":"Stale response","imageUrl":"","firstPlayedAt":"2026-01-01","lastPlayedAt":"2026-01-01","totalPlayedMinutes":120}],"recentPlayHistories":[]}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let respond: @Sendable () -> Void = { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if request.url?.path == "/api/v2.0/users/me/play_histories", let gate = Self.gate {
            gate.enqueue(respond)
        } else { respond() }
    }
    override func stopLoading() {}
}

extension YouJiDataTests {
    @MainActor
    func testPendingAuthorizationCannotWriteAfterDeleteOrRestore() async throws {
        for restoreInsteadOfDelete in [false, true] {
            let gate = DeferredResponseGate()
            DeferredNintendoProtocol.gate = gate
            defer { gate.release(); DeferredNintendoProtocol.gate = nil }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DeferredNintendoProtocol.self]
            let session = URLSession(configuration: configuration)
            let coordinator = SyncCoordinator(nintendoAPI: NintendoAPIClient(session: session))
            let container = try safetyContainer()
            let original = GameRecord(applicationID: "switch:a:original", accountID: "a", titleID: "original", platform: .switchConsole, title: "Local", totalMinutes: 60)
            container.mainContext.insert(original)
            try container.mainContext.save()
            let backup = try ProductDataService.backupData(modelContext: container.mainContext)
            let operation = Task {
                await coordinator.finishAuthorization(code: "test", verifier: "test", modelContext: container.mainContext)
            }
            for _ in 0..<300 {
                if gate.isWaiting { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard gate.isWaiting else { operation.cancel(); XCTFail("Stub request never reached the gate"); return }
            if restoreInsteadOfDelete {
                try ProductDataService.restore(data: backup, modelContext: container.mainContext)
            } else {
                try await ProductDataService.deleteAllLocalData(modelContext: container.mainContext)
            }
            gate.release()
            await operation.value
            let games = try container.mainContext.fetch(FetchDescriptor<GameRecord>())
            XCTAssertEqual(games.map(\.applicationID), restoreInsteadOfDelete ? ["switch:a:original"] : [])
            XCTAssertFalse(coordinator.isSyncing)
            XCTAssertNil(coordinator.errorMessage)
            XCTAssertFalse(container.mainContext.hasChanges)
        }
    }
}

// A real earlier on-disk entity shape, before userEditedAt existed. Keeping the
// entity name/attributes verifies SQLite migration rather than an in-memory clone.
private enum BeforeUserEditDate: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [GameRecord.self] }

    @Model final class GameRecord {
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
        var isFavorite: Bool = false
        var isManuallyHidden: Bool = false
        var isPinnedVisible: Bool = false
        var personalNote: String = ""
        var playStatusRaw: String = "玩过"

        init() {
            applicationID = "switch:a:legacy"
            accountID = "a"
            titleID = "legacy"
            title = "Old on-disk game"
            totalMinutes = 120
            imageURL = ""
            weeklyMinutesData = Data("[0,0,0,0,0,0,30]".utf8)
            updatedAt = Date(timeIntervalSince1970: 100)
            personalNote = "Preserve an earlier version's note"
            isFavorite = true
        }
    }
}

extension YouJiDataTests {
    @MainActor
    func testEarlierSQLiteSchemaMigratesWithoutLosingUserData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.store")
        do {
            let schema = Schema(versionedSchema: BeforeUserEditDate.self)
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            old.mainContext.insert(BeforeUserEditDate.GameRecord())
            try old.mainContext.save()
        }
        let current = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(url: url))
        let game = try XCTUnwrap(current.mainContext.fetch(FetchDescriptor<GameRecord>()).first)
        XCTAssertEqual(game.applicationID, "switch:a:legacy")
        XCTAssertEqual(game.personalNote, "Preserve an earlier version's note")
        XCTAssertTrue(game.isFavorite)
        XCTAssertEqual(game.totalMinutes, 120)
        XCTAssertEqual(game.weeklyMinutes.last, 30)
        XCTAssertEqual(game.resolvedUserEditedAt, Date(timeIntervalSince1970: 100))
    }

    @MainActor
    func testOlderReadableBackupRepairsOnlyDamagedConversationComponents() throws {
        let source = try safetyContainer()
        let old = AIConversation(createdAt: Date(timeIntervalSince1970: 100), games: [
            AIAnalysisGame(platform: "NS", title: "Game", totalMinutes: 120, trophyRatio: nil)
        ])
        old.messages = [AIChatMessage(role: .user, content: "Old message")]
        old.updatedAt = Date(timeIntervalSince1970: 100)
        source.mainContext.insert(old)
        try source.mainContext.save()
        let backup = try ProductDataService.backupData(modelContext: source.mainContext)
        let target = try safetyContainer()
        let damaged = AIConversation(id: old.id, games: [])
        damaged.messages = [AIChatMessage(role: .user, content: "Newer readable message")]
        damaged.gameContextData = Data("damaged".utf8)
        damaged.updatedAt = Date(timeIntervalSince1970: 200)
        target.mainContext.insert(damaged)
        try target.mainContext.save()
        try ProductDataService.restore(data: backup, modelContext: target.mainContext)
        XCTAssertEqual(damaged.messages.map(\.content), ["Newer readable message"])
        XCTAssertEqual(damaged.games.map(\.title), ["Game"])
        XCTAssertFalse(damaged.hasUnreadableContent)
    }

    @MainActor
    func testUnreadableBackupDoesNotReplaceReadableLocalMessages() throws {
        let source = try safetyContainer()
        let bad = AIConversation(games: [])
        bad.messagesData = Data("damaged".utf8)
        bad.updatedAt = Date(timeIntervalSince1970: 300)
        source.mainContext.insert(bad)
        try source.mainContext.save()
        let target = try safetyContainer()
        let local = AIConversation(id: bad.id, games: [])
        local.messages = [AIChatMessage(role: .user, content: "Keep me")]
        local.updatedAt = Date(timeIntervalSince1970: 100)
        target.mainContext.insert(local)
        try target.mainContext.save()
        try ProductDataService.restore(data: ProductDataService.backupData(modelContext: source.mainContext), modelContext: target.mainContext)
        XCTAssertEqual(local.messages.map(\.content), ["Keep me"])
        XCTAssertFalse(local.hasUnreadableContent)
    }

    @MainActor
    func testBackupPreservesOrphanHistoryWithConsistentIdentity() throws {
        let source = try safetyContainer()
        source.mainContext.insert(PlaySnapshot(gameID: "switch:a:missing-game", accountID: "a", platform: .switchConsole, totalMinutes: 120, trophiesEarned: 0))
        try source.mainContext.save()
        let target = try safetyContainer()
        try ProductDataService.restore(data: ProductDataService.backupData(modelContext: source.mainContext), modelContext: target.mainContext)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<PlaySnapshot>()), 1)
    }
}

extension YouJiDataTests {
    @MainActor
    func testInjectedSaveFailureRollsBackInsertUpdateAndDelete() throws {
        let container = try safetyContainer()
        let game = GameRecord(applicationID: "switch:a:g", accountID: "a", titleID: "g", platform: .switchConsole, title: "Original", totalMinutes: 120)
        container.mainContext.insert(game)
        try container.mainContext.save()
        for operation in 0..<3 {
            XCTAssertThrowsError(try LocalPersistence.transaction(container.mainContext, save: { _ in
                throw CocoaError(.fileWriteOutOfSpace)
            }) { writer in
                let record = try XCTUnwrap(writer.fetch(FetchDescriptor<GameRecord>()).first)
                if operation == 0 { writer.delete(record) }
                if operation == 1 { record.totalMinutes = 0; record.personalNote = "Must roll back" }
                if operation == 2 { writer.insert(GameRecord(applicationID: "switch:a:new", accountID: "a", titleID: "new", platform: .switchConsole, title: "New")) }
            })
            let stored = try container.mainContext.fetch(FetchDescriptor<GameRecord>())
            XCTAssertEqual(stored.map(\.applicationID), ["switch:a:g"])
            XCTAssertEqual(stored.first?.totalMinutes, 120)
            XCTAssertEqual(stored.first?.personalNote, "")
            XCTAssertFalse(container.mainContext.hasChanges)
        }
    }
}
