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
        let container = try ModelContainer(for: GameRecord.self, PlaySnapshot.self, configurations: configuration)
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
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<GameRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PlaySnapshot>()).count, 1)
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
		let conversation = AIConversation(games: games)
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
		XCTAssertEqual(stored.preview, "可以试试宇宙机器人。")
	}
}
