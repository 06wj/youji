import XCTest
import SwiftData
@testable import YouJi

@MainActor
final class LibraryExperienceTests: XCTestCase {
    private var calendar: Calendar { Calendar.current }
    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
    }
    private func game(_ id: String = "a", account: String = "one", syncedDay: Int = 18,
                      platform: GamePlatform = .switchConsole) -> GameRecord {
        let game = GameRecord(applicationID: GameRecord.recordID(platform: platform, accountID: account, titleID: id),
                              accountID: account, titleID: id, platform: platform, title: id,
                              totalMinutes: 1000, weeklyMinutes: [10, 20, 30, 40, 50, 60, 70])
        game.updatedAt = date(syncedDay)
        game.weeklyEndingDayKey = DailyPlayActivity.dayKey(for: date(syncedDay))
        return game
    }
    private func activity(_ game: GameRecord, day: Int, minutes: Int, account: String? = nil) -> DailyPlayActivity {
        let activity = DailyPlayActivity(activityID: DailyPlayActivity.recordID(platform: game.platform,
            accountID: account ?? game.accountID, titleID: game.titleID, day: date(day)),
            gameID: game.applicationID, accountID: account ?? game.accountID, titleID: game.titleID,
            platform: game.platform, day: date(day), totalMinutes: minutes)
        activity.updatedAt = date(day)
        return activity
    }

    func testYesterdaySnapshotDoesNotSlideIntoToday() {
        let result = NintendoActivityWindow.make(games: [game()], activities: [], now: date(19))
        XCTAssertEqual(result.days.map(\.recordedMinutes), [20, 30, 40, 50, 60, 70, nil])
        XCTAssertEqual(result.days.last?.dayKey, "2026-10-19")
        XCTAssertEqual(result.totalMinutes, 270)
        XCTAssertEqual(result.incompleteDays, 1)
    }

    func testExactDailyRecordWinsAndForeignAccountCannotOverride() {
        let game = game()
        let result = NintendoActivityWindow.make(games: [game], activities: [
            activity(game, day: 18, minutes: 125), activity(game, day: 18, minutes: 9999, account: "other")
        ], now: date(19))
        XCTAssertEqual(result.days[5].recordedMinutes, 125)
        XCTAssertEqual(result.totalMinutes, 325)
    }

    func testMissingCoverageAndObservedZeroAreDifferent() {
        let known = game("known", syncedDay: 19)
        known.weeklyMinutes = Array(repeating: 0, count: 7)
        let stale = game("stale", syncedDay: 10)
        let result = NintendoActivityWindow.make(games: [known, stale], activities: [], now: date(19))
        XCTAssertEqual(result.days.last?.recordedMinutes, 0)
        XCTAssertEqual(result.days.last?.missingGames, 1)
        XCTAssertEqual(result.days.last?.isPartial, true)
        XCTAssertTrue(result.hasRecords)
    }

    func testOldAndFutureSnapshotsDoNotBecomeCurrentActivity() {
        let result = NintendoActivityWindow.make(games: [game("old", syncedDay: 1), game("future", syncedDay: 20)],
                                                  activities: [], now: date(19))
        XCTAssertFalse(result.hasRecords)
        XCTAssertTrue(result.days.allSatisfy { $0.recordedMinutes == nil })
        XCTAssertEqual(result.totalMinutes, 0)
    }

    func testLegacyArrayWithoutDateAnchorIsNotShiftedIntoCurrentWeek() {
        let legacy = game()
        legacy.weeklyEndingDayKey = ""
        let result = NintendoActivityWindow.make(games: [legacy], activities: [activity(legacy, day: 18, minutes: 30)], now: date(19))
        XCTAssertEqual(result.totalMinutes, 30)
        XCTAssertNil(result.days[4].recordedMinutes)
    }

    func testStableWindowDateSurvivesTimezoneChangeWithoutDoubleCounting() {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let game = game()
        game.weeklyMinutes = [0, 0, 0, 0, 0, 0, 60]
        game.weeklyEndingDayKey = "2026-10-19"
        game.updatedAt = ISO8601DateFormatter().date(from: "2026-10-19T00:30:00+08:00")!
        let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00-07:00")!
        let daily = activity(game, day: 19, minutes: 60)
        daily.updatedAt = game.updatedAt
        let result = NintendoActivityWindow.make(games: [game], activities: [daily], now: now, calendar: losAngeles)
        XCTAssertEqual(result.totalMinutes, 60)
        XCTAssertEqual(result.days.last?.recordedMinutes, 60)
        XCTAssertEqual(result.days[5].recordedMinutes, 0)
    }

    func testEmptyLibraryOffersRecoveryMatchingState() {
        XCTAssertEqual(LibraryEmptyReason.resolve(isConnected: true, hasSynced: false, recordCount: 0,
                                                  visibleCount: 0, hasIssue: false), .awaitingSync)
        XCTAssertEqual(LibraryEmptyReason.resolve(isConnected: true, hasSynced: true, recordCount: 0,
                                                  visibleCount: 0, hasIssue: false), .noRecords)
        XCTAssertEqual(LibraryEmptyReason.resolve(isConnected: false, hasSynced: false, recordCount: 4,
                                                  visibleCount: 0, hasIssue: true), .hidden(4))
        XCTAssertEqual(LibraryEmptyReason.resolve(isConnected: false, hasSynced: false, recordCount: 0,
                                                  visibleCount: 0, hasIssue: true), .failed)
        XCTAssertEqual(LibraryEmptyReason.resolve(isConnected: false, hasSynced: false, recordCount: 0,
                                                  visibleCount: 0, hasIssue: false), .disconnected)
    }

    func testWeeklyReviewKeepsAccountScopeAndUsesChangesNotLifetimeTotals() {
        let ps = game("ps", platform: .playStation)
        let ns = game("ns")
        let foreign = game("foreign", account: "other")
        let snapshots = [
            PlaySnapshot(gameID: ps.applicationID, accountID: ps.accountID, platform: ps.platform,
                         date: date(12), totalMinutes: 1000, trophiesEarned: 3),
            PlaySnapshot(gameID: ps.applicationID, accountID: ps.accountID, platform: ps.platform,
                         date: date(18), totalMinutes: 1120, trophiesEarned: 5),
            PlaySnapshot(gameID: ps.applicationID, accountID: "other", platform: ps.platform,
                         date: date(19), totalMinutes: 9999, trophiesEarned: 100)
        ]
        let result = LocalWeeklyReview.make(games: [ps, ns], snapshots: snapshots,
            activities: [activity(ns, day: 18, minutes: 45), activity(ns, day: 3, minutes: 900),
                         activity(foreign, day: 18, minutes: 9999)], now: date(19))
        XCTAssertEqual(result.totalMinutes, 165)
        XCTAssertEqual(result.totalTrophies, 2)
        XCTAssertEqual(result.games.map(\.id), [ps.applicationID, ns.applicationID])
    }

    func testFirstSnapshotIsNotAnInventedWeekOfPlay() {
        let game = game(platform: .playStation)
        let snapshot = PlaySnapshot(gameID: game.applicationID, accountID: game.accountID,
            platform: game.platform, date: date(19), totalMinutes: 99999, trophiesEarned: 50)
        let result = LocalWeeklyReview.make(games: [game], snapshots: [snapshot], activities: [], now: date(19))
        XCTAssertTrue(result.hasBaseline)
        XCTAssertTrue(result.games.isEmpty)
        XCTAssertEqual(result.totalMinutes, 0)
        XCTAssertTrue(result.narrative.contains("没有新的游玩变化记录"))
    }
}
