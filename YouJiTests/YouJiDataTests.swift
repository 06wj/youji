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
        target.mainContext.insert(SavedGamePlan(
            id: plan.id,
            accountScopeKey: "switch:old",
            title: "旧计划",
            isCompleted: true
        ))
        target.mainContext.insert(DailyPlayActivity(
            activityID: "switch:a:game:2026-08-13",
            gameID: "switch:a:game",
            accountID: "a",
            titleID: "game",
            platform: .switchConsole,
            day: .distantPast,
            totalMinutes: 1
        ))
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
