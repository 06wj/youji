import XCTest
import SwiftData
@testable import YouJi

@MainActor
final class PlayTimeAllocationTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ key: String, hour: Int = 0) -> Date {
        DailyPlayActivity.date(fromDayKey: key, calendar: utc)!.addingTimeInterval(Double(hour * 3_600))
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func seed(_ context: ModelContext, account: String = "a") throws -> (GameRecord, [PlaySnapshot], PlayTimeAllocationValue) {
        let game = GameRecord(applicationID: "ps:\(account):game", accountID: account, titleID: "game",
                              platform: .playStation, title: "Test game", totalMinutes: 1_320, trophiesEarned: 4, trophiesDefined: 20)
        let snapshots = [
            PlaySnapshot(snapshotID: "\(account)-start", gameID: game.applicationID, accountID: account, platform: .playStation,
                         date: date("2026-10-30", hour: 12), totalMinutes: 600, trophiesEarned: 2),
            PlaySnapshot(snapshotID: "\(account)-end", gameID: game.applicationID, accountID: account, platform: .playStation,
                         date: date("2026-11-02", hour: 12), totalMinutes: 1_320, trophiesEarned: 4)
        ]
        context.insert(game)
        for snapshot in snapshots { context.insert(snapshot) }
        try context.save()
        var value = PlayTimeResolver.draft(from: snapshots[0], to: snapshots[1], calendar: utc)
        value.days = ["2026-10-31", "2026-11-01", "2026-11-02"].map { AllocatedPlayDay(dayKey: $0, minutes: 240) }
        return (game, snapshots, value)
    }

    private func save(_ value: PlayTimeAllocationValue, in context: ModelContext, expected: Date? = nil,
                      now: Date? = nil) throws {
        try PlayTimeAllocationService.save(value, expectedUpdatedAt: expected, revision: LocalDataRevision.current,
                                           modelContext: context, now: now ?? date("2026-11-03"))
    }

    private func values(_ context: ModelContext) throws -> [PlayTimeAllocationValue] {
        try context.fetch(FetchDescriptor<PlayTimeAllocation>()).map { try $0.readValue() }
    }

    func testTwelveHoursBecomeThreeDaysWithoutChangingSourceDataOrTrophies() throws {
        let store = try container()
        let (game, snapshots, value) = try seed(store.mainContext)
        let updatedAt = game.updatedAt
        try save(value, in: store.mainContext)
        let stored = try values(store.mainContext)
        XCTAssertEqual(game.totalMinutes, 1_320)
        XCTAssertEqual(game.updatedAt, updatedAt)
        XCTAssertEqual(snapshots.map(\.totalMinutes), [600, 1_320])
        XCTAssertEqual(snapshots.map(\.trophiesEarned), [2, 4])
        XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<PlaySnapshot>()), 2)
        let timeline = PlayTimelineBuilder.entries(snapshots: snapshots, activities: [], includedGameIDs: [game.applicationID],
                                                   allocations: stored, calendar: utc)
        XCTAssertEqual(timeline.map(\.addedMinutes), [240, 240, 240])
        XCTAssertEqual(timeline.map(\.date), [date("2026-10-31"), date("2026-11-01"), date("2026-11-02")])
        XCTAssertEqual(timeline.map(\.addedTrophies), [0, 0, 2])
        let chart = PlayTimeResolver.historyPoints(snapshots: snapshots, allocations: stored, calendar: utc)
        XCTAssertEqual(chart.map(\.totalMinutes), [600, 840, 1_080, 1_320])
    }

    func testCrossMonthStatisticsUsePlayDatesEvenWhenSyncedLater() throws {
        let store = try container()
        let (_, snapshots, value) = try seed(store.mainContext)
        let october = PlayInsightCalculator.insight(snapshots: snapshots, since: date("2026-10-01"),
            now: date("2026-11-01").addingTimeInterval(-1), allocations: [value], calendar: utc)
        let november = PlayInsightCalculator.insight(snapshots: snapshots, since: date("2026-11-01"),
            now: date("2026-11-03"), allocations: [value], calendar: utc)
        XCTAssertEqual(october.addedMinutes, 240)
        XCTAssertEqual(october.addedTrophies, 0)
        XCTAssertEqual(november.addedMinutes, 480)
        XCTAssertEqual(november.addedTrophies, 2)
        XCTAssertEqual(october.addedMinutes + november.addedMinutes, value.totalMinutes)
    }

    func testWeeklyReviewUsesAllocatedDaysAndKeepsAccountIsolation() throws {
        let store = try container()
        let (game, snapshots, value) = try seed(store.mainContext)
        let (_, otherSnapshots, other) = try seed(store.mainContext, account: "b")
        let review = LocalWeeklyReview.make(games: [game], snapshots: snapshots + otherSnapshots, activities: [],
            now: date("2026-11-07", hour: 12), calendar: utc, allocations: [value, other])
        XCTAssertEqual(review.totalMinutes, 480, "October 31 is outside this seven-day window")
        XCTAssertEqual(review.games.count, 1)
        XCTAssertEqual(review.totalTrophies, 2)
    }

    func testLaterSyncAndSameDayIncreasesStayIndependent() throws {
        let store = try container()
        let (game, snapshots, value) = try seed(store.mainContext)
        let next = PlaySnapshot(snapshotID: "later", gameID: game.applicationID, accountID: "a", platform: .playStation,
                                date: date("2026-11-02", hour: 20), totalMinutes: 1_440, trophiesEarned: 5)
        let timeline = PlayTimelineBuilder.entries(snapshots: snapshots + [next], activities: [], includedGameIDs: [game.applicationID],
                                                   allocations: [value], calendar: utc)
        XCTAssertEqual(timeline.map(\.addedMinutes), [240, 240, 360])
        XCTAssertEqual(timeline.last?.addedTrophies, 3)
        XCTAssertEqual(PlayTimeResolver.editableIntervals(snapshots: snapshots + [next], allocations: [value]).count, 2)
        XCTAssertEqual(PlayTimeResolver.historyPoints(snapshots: snapshots + [next], allocations: [value], calendar: utc).last?.totalMinutes, 1_440)
    }

    func testImportedIntermediateSnapshotDoesNotDoubleCountAllocatedRange() throws {
        let store = try container()
        let (game, snapshots, value) = try seed(store.mainContext)
        let middle = PlaySnapshot(snapshotID: "middle", gameID: game.applicationID, accountID: "a", platform: .playStation,
                                 date: date("2026-11-01", hour: 12), totalMinutes: 960, trophiesEarned: 3)
        try PlayTimeResolver.validate([value], snapshots: snapshots + [middle])
        let timeline = PlayTimelineBuilder.entries(snapshots: snapshots + [middle], activities: [], includedGameIDs: [game.applicationID],
                                                   allocations: [value], calendar: utc)
        XCTAssertEqual(timeline.map(\.addedMinutes), [240, 240, 240])
        XCTAssertEqual(timeline.reduce(0) { $0 + $1.addedTrophies }, 2)
        XCTAssertEqual(PlayTimeResolver.editableIntervals(snapshots: snapshots + [middle], allocations: [value]).count, 1)
    }

    func testLatestZeroIncreaseObservationStartsTheNextAllocationInterval() throws {
        let store = try container()
        let (game, snapshots, _) = try seed(store.mainContext)
        let unchanged = PlaySnapshot(snapshotID: "latest-unchanged", gameID: game.applicationID, accountID: "a",
                                     platform: .playStation, date: date("2026-11-01", hour: 18),
                                     totalMinutes: 600, trophiesEarned: 2)
        let history = snapshots + [unchanged]
        let intervals = PlayTimeResolver.editableIntervals(snapshots: history, allocations: [], calendar: utc)
        let interval = try XCTUnwrap(intervals.first)
        XCTAssertEqual(intervals.count, 1, "Zero increases are retained as boundaries, not offered as time to distribute")
        XCTAssertEqual(interval.startSnapshotID, "latest-unchanged")
        XCTAssertEqual(interval.startDayKey, "2026-11-01")
        XCTAssertEqual(interval.endDayKey, "2026-11-02")
        XCTAssertEqual(interval.totalMinutes, 720)
        let timeline = PlayTimelineBuilder.entries(snapshots: history, activities: [],
            includedGameIDs: [game.applicationID], calendar: utc)
        XCTAssertEqual(timeline.count, 1, "Do not display an empty +0 entry")
        XCTAssertEqual(timeline.first?.date, date("2026-11-02"))
    }

    func testInvalidDaysAndTotalsCannotWriteAnyChanges() throws {
        let store = try container()
        let (game, _, source) = try seed(store.mainContext)
        let invalidDays: [[AllocatedPlayDay]] = [
            [], [.init(dayKey: "2026-11-02", minutes: 719)],
            [.init(dayKey: "2026-11-02", minutes: -1)], [.init(dayKey: "2026-11-02", minutes: Int.max)],
            [.init(dayKey: "2026-11-03", minutes: 720)], [.init(dayKey: "2026-10-29", minutes: 720)],
            [.init(dayKey: "2026-02-30", minutes: 720)],
            [.init(dayKey: "2026-11-02", minutes: 360), .init(dayKey: "2026-11-02", minutes: 360)]
        ]
        for days in invalidDays {
            var invalid = source
            invalid.days = days
            XCTAssertThrowsError(try save(invalid, in: store.mainContext))
        }
        XCTAssertEqual(try values(store.mainContext).count, 0)
        XCTAssertEqual(game.totalMinutes, 1_320)
        XCTAssertFalse(store.mainContext.hasChanges)
    }

    func testOverlappingAllocationFailsAtomically() throws {
        let store = try container()
        let (game, snapshots, value) = try seed(store.mainContext)
        try save(value, in: store.mainContext)
        let middle = PlaySnapshot(snapshotID: "middle", gameID: game.applicationID, accountID: "a", platform: .playStation,
                                 date: date("2026-11-01", hour: 12), totalMinutes: 960, trophiesEarned: 3)
        store.mainContext.insert(middle)
        try store.mainContext.save()
        let overlapping = PlayTimeResolver.draft(from: snapshots[0], to: middle, calendar: utc)
        XCTAssertThrowsError(try save(overlapping, in: store.mainContext))
        XCTAssertEqual(try values(store.mainContext).count, 1)
    }

    func testResetSurvivesOlderBackupAndRoundTripsAsTombstone() throws {
        let store = try container()
        let (_, snapshots, value) = try seed(store.mainContext)
        try save(value, in: store.mainContext)
        let oldBackup = try ProductDataService.backupData(modelContext: store.mainContext)
        var reset = try XCTUnwrap(values(store.mainContext).first)
        let oldDate = reset.updatedAt
        reset.isDeleted = true
        reset.days = []
        try save(reset, in: store.mainContext, expected: oldDate, now: date("2026-11-04"))
        XCTAssertTrue(try XCTUnwrap(values(ModelContext(store)).first).isDeleted, "The reset must be durable before any import")
        XCTAssertTrue(try XCTUnwrap(values(store.mainContext).first).isDeleted, "The UI context must see the committed reset")
        _ = try ProductDataService.restore(data: oldBackup, modelContext: store.mainContext)
        XCTAssertTrue(try XCTUnwrap(values(store.mainContext).first).isDeleted)
        let events = PlayTimeResolver.events(snapshots: snapshots, allocations: try values(store.mainContext))
        XCTAssertEqual(events.reduce(0) { $0 + $1.minutes }, 720)
        XCTAssertFalse(events.contains { $0.hasDay })
        let target = try container()
        _ = try ProductDataService.restore(data: ProductDataService.backupData(modelContext: store.mainContext), modelContext: target.mainContext)
        _ = try ProductDataService.restore(data: oldBackup, modelContext: target.mainContext)
        XCTAssertTrue(try XCTUnwrap(values(target.mainContext).first).isDeleted)
    }

    func testVersionThreeBackupRoundTripAndLegacyImportPreserveLayer() throws {
        let source = try container()
        let (_, _, value) = try seed(source.mainContext)
        try save(value, in: source.mainContext)
        let data = try ProductDataService.backupData(modelContext: source.mainContext)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 3)
        let target = try container()
        for _ in 0..<2 { _ = try ProductDataService.restore(data: data, modelContext: target.mainContext) }
        XCTAssertEqual(try values(target.mainContext), try values(source.mainContext))
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<PlaySnapshot>()), 2)
        json["formatVersion"] = 2
        json.removeValue(forKey: "playTimeAllocations")
        _ = try ProductDataService.restore(data: JSONSerialization.data(withJSONObject: json), modelContext: target.mainContext)
        XCTAssertEqual(try values(target.mainContext).count, 1)
        XCTAssertFalse(try XCTUnwrap(values(target.mainContext).first).isDeleted)
    }

    func testMalformedBackupCannotOverwriteLocalData() throws {
        let store = try container()
        let (game, _, value) = try seed(store.mainContext)
        try save(value, in: store.mainContext)
        let before = try values(store.mainContext)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ProductDataService.backupData(modelContext: store.mainContext)) as? [String: Any])
        var items = try XCTUnwrap(json["playTimeAllocations"] as? [[String: Any]])
        items[0]["accountID"] = "another-account"
        json["playTimeAllocations"] = items
        XCTAssertThrowsError(try ProductDataService.restore(data: JSONSerialization.data(withJSONObject: json), modelContext: store.mainContext))
        XCTAssertEqual(try values(store.mainContext), before)
        XCTAssertEqual(game.totalMinutes, 1_320)
    }

    func testStaleEditorAndInvalidatedArchiveCannotWrite() throws {
        let store = try container()
        let (_, _, value) = try seed(store.mainContext)
        try save(value, in: store.mainContext)
        XCTAssertThrowsError(try save(value, in: store.mainContext), "A second editor cannot overwrite the first editor's save")
        let revision = LocalDataRevision.current
        LocalDataRevision.invalidate()
        XCTAssertThrowsError(try PlayTimeAllocationService.save(value, expectedUpdatedAt: nil, revision: revision, modelContext: store.mainContext))
        XCTAssertEqual(try values(store.mainContext).count, 1)
    }

    func testDailyKeysRemainStableAcrossTimeZonesAndSingleSnapshotIsNotEditable() throws {
        let store = try container()
        let (_, snapshots, value) = try seed(store.mainContext)
        var losAngeles = utc
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for calendar in [utc, losAngeles] {
            let dates = PlayTimeResolver.events(snapshots: snapshots, allocations: [value], calendar: calendar)
                .filter(\.hasDay).map { DailyPlayActivity.dayKey(for: $0.date, calendar: calendar) }.sorted()
            XCTAssertEqual(dates, value.days.map(\.dayKey).sorted())
        }
        XCTAssertTrue(PlayTimeResolver.editableIntervals(snapshots: [snapshots[0]], allocations: []).isEmpty)
    }

    func testAddingAllocationModelMigratesExistingSQLiteAndReadOnlySavePreservesData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("before-allocations.store")
        do {
            let oldSchema = Schema([GameRecord.self, PlaySnapshot.self, DailyPlayActivity.self,
                                    AIConversation.self, AIProfileResult.self, SavedGamePlan.self])
            let old = try ModelContainer(for: oldSchema, configurations: ModelConfiguration(url: url))
            _ = try seed(old.mainContext)
        }
        do {
            let migrated = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(url: url))
            XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<PlaySnapshot>()), 2)
            let snapshots = try migrated.mainContext.fetch(FetchDescriptor<PlaySnapshot>())
            let ordered = PlayTimeResolver.sorted(snapshots)
            var value = PlayTimeResolver.draft(from: ordered[0], to: ordered[1], calendar: utc)
            value.days = [.init(dayKey: "2026-11-01", minutes: 720)]
            try save(value, in: migrated.mainContext)
            XCTAssertEqual(try values(migrated.mainContext).count, 1)
        }
        let readOnly = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(url: url, allowsSave: false))
        let value = try XCTUnwrap(values(readOnly.mainContext).first)
        XCTAssertThrowsError(try save(value, in: readOnly.mainContext, expected: value.updatedAt))
        XCTAssertEqual(try values(readOnly.mainContext), [value])
    }

    func testDeletingAccountRemovesOnlyItsLayerAndDeleteAllClearsRemainder() async throws {
        let store = try container()
        let (_, _, first) = try seed(store.mainContext)
        let (_, _, other) = try seed(store.mainContext, account: "b")
        try save(first, in: store.mainContext)
        try save(other, in: store.mainContext)
        try ProductDataService.deleteArchive(platform: .playStation, accountID: "a", modelContext: store.mainContext)
        XCTAssertEqual(try values(store.mainContext).map(\.accountID), ["b"])
        try await ProductDataService.deleteAllLocalData(modelContext: store.mainContext)
        XCTAssertTrue(try values(store.mainContext).isEmpty)
    }
}
