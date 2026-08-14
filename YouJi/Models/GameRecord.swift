import Foundation
import SwiftData

enum GamePlatform: String, Codable, CaseIterable, Sendable {
    case playStation = "PlayStation"
    case switchConsole = "Switch"

    var displayName: String { rawValue }
    var shortName: String { self == .playStation ? "PS" : "NS" }
}

@Model
final class GameRecord {
    @Attribute(.unique) var applicationID: String
    var accountID: String = ""
    var titleID: String = ""
    var platformRaw: String = GamePlatform.switchConsole.rawValue
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
    var playStatusRaw: String = GamePlayStatus.played.rawValue

    init(
        applicationID: String,
        accountID: String = "",
        titleID: String = "",
        platform: GamePlatform,
        title: String,
        totalMinutes: Int = 0,
        imageURL: String = "",
        firstPlayedAt: Date? = nil,
        lastPlayedAt: Date? = nil,
        weeklyMinutes: [Int] = Array(repeating: 0, count: 7),
        trophiesEarned: Int = 0,
        trophiesDefined: Int = 0,
        platinumTrophiesEarned: Int = 0,
        trophiesSyncedAt: Date? = nil
    ) {
        self.applicationID = applicationID
        self.accountID = accountID
        self.titleID = titleID
        self.platformRaw = platform.rawValue
        self.title = title
        self.totalMinutes = totalMinutes
        self.imageURL = imageURL
        self.firstPlayedAt = firstPlayedAt
        self.lastPlayedAt = lastPlayedAt
        self.weeklyMinutesData = (try? JSONEncoder().encode(weeklyMinutes)) ?? Data()
        self.trophiesEarned = trophiesEarned
        self.trophiesDefined = trophiesDefined
        self.platinumTrophiesEarned = platinumTrophiesEarned
        self.trophiesSyncedAt = trophiesSyncedAt
        self.updatedAt = .now
    }

    var weeklyMinutes: [Int] {
        get { (try? JSONDecoder().decode([Int].self, from: weeklyMinutesData)) ?? Array(repeating: 0, count: 7) }
        set { weeklyMinutesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var platform: GamePlatform {
        get { GamePlatform(rawValue: platformRaw) ?? .switchConsole }
        set { platformRaw = newValue.rawValue }
    }

    var shouldHideFromLibrary: Bool {
        if isManuallyHidden { return true }
        if isPinnedVisible { return false }
        guard totalMinutes < 60,
              let lastPlayedAt,
              let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: .now) else {
            return false
        }
        return lastPlayedAt < cutoff
    }

    var playStatus: GamePlayStatus {
        get { GamePlayStatus(rawValue: playStatusRaw) ?? .played }
        set { playStatusRaw = newValue.rawValue }
    }

    static func recordID(platform: GamePlatform, accountID: String, titleID: String) -> String {
        "\(platform == .playStation ? "ps" : "switch"):\(accountID):\(titleID)"
    }

    var resolvedTitleID: String {
        if !titleID.isEmpty { return titleID }
        if applicationID.hasPrefix("ps:") { return String(applicationID.dropFirst(3)) }
        if applicationID.hasPrefix("switch:") { return String(applicationID.dropFirst(7)) }
        return applicationID
    }
}

enum GamePlayStatus: String, Codable, CaseIterable, Sendable {
    case played = "玩过"
    case playing = "正在玩"
    case replay = "准备重温"
    case completed = "已完成"
    case paused = "暂时搁置"
}

enum AccountScope {
    static func token(platform: GamePlatform, accountID: String) -> String {
        "\(platform == .playStation ? "ps" : "switch"):\(accountID)"
    }

    static func key(playStationAccountID: String, nintendoAccountID: String) -> String {
        [
            playStationAccountID.isEmpty ? nil : token(platform: .playStation, accountID: playStationAccountID),
            nintendoAccountID.isEmpty ? nil : token(platform: .switchConsole, accountID: nintendoAccountID),
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }

    static func contains(_ scopeKey: String, platform: GamePlatform, accountID: String) -> Bool {
        guard !accountID.isEmpty else { return false }
        let expected = token(platform: platform, accountID: accountID)
        return scopeKey.split(separator: "|", omittingEmptySubsequences: true).contains {
            $0 == expected
        }
    }

    static func visibleLibraryGames(
        _ games: [GameRecord],
        playStationAccountID: String,
        nintendoAccountID: String
    ) -> [GameRecord] {
        let playStationDisplayID = displayAccountID(
            for: .playStation,
            currentAccountID: playStationAccountID,
            games: games
        )
        let nintendoDisplayID = displayAccountID(
            for: .switchConsole,
            currentAccountID: nintendoAccountID,
            games: games
        )
        return games.filter { game in
            let displayID = game.platform == .playStation ? playStationDisplayID : nintendoDisplayID
            return displayID.map { game.accountID == $0 } ?? game.accountID.isEmpty
        }
    }

    private static func displayAccountID(
        for platform: GamePlatform,
        currentAccountID: String,
        games: [GameRecord]
    ) -> String? {
        if !currentAccountID.isEmpty { return currentAccountID }
        let archivedAccountIDs = Set(games.lazy
            .filter { $0.platform == platform && !$0.accountID.isEmpty }
            .map(\.accountID))
        return archivedAccountIDs.count == 1 ? archivedAccountIDs.first : nil
    }
}

struct AccountArchiveSelection: Identifiable, Hashable {
    let platform: GamePlatform
    let accountID: String

    var id: String { "\(platform.rawValue):\(accountID)" }
}

@Model
final class PlaySnapshot {
    @Attribute(.unique) var snapshotID: String
    var gameID: String
    var accountID: String
    var platformRaw: String
    var date: Date
    var totalMinutes: Int
    var trophiesEarned: Int

    init(
        snapshotID: String = UUID().uuidString,
        gameID: String,
        accountID: String,
        platform: GamePlatform,
        date: Date = .now,
        totalMinutes: Int,
        trophiesEarned: Int
    ) {
        self.snapshotID = snapshotID
        self.gameID = gameID
        self.accountID = accountID
        self.platformRaw = platform.rawValue
        self.date = date
        self.totalMinutes = totalMinutes
        self.trophiesEarned = trophiesEarned
    }

    var platform: GamePlatform {
        GamePlatform(rawValue: platformRaw) ?? .switchConsole
    }
}

@Model
final class DailyPlayActivity {
    @Attribute(.unique) var activityID: String
    var gameID: String
    var accountID: String
    var titleID: String
    var platformRaw: String
    var day: Date
    var totalMinutes: Int
    var updatedAt: Date

    init(
        activityID: String,
        gameID: String,
        accountID: String,
        titleID: String,
        platform: GamePlatform,
        day: Date,
        totalMinutes: Int
    ) {
        self.activityID = activityID
        self.gameID = gameID
        self.accountID = accountID
        self.titleID = titleID
        self.platformRaw = platform.rawValue
        self.day = Calendar.current.startOfDay(for: day)
        self.totalMinutes = totalMinutes
        self.updatedAt = .now
    }

    var platform: GamePlatform {
        GamePlatform(rawValue: platformRaw) ?? .switchConsole
    }

    static func recordID(
        platform: GamePlatform,
        accountID: String,
        titleID: String,
        day: Date,
        calendar: Calendar = .current
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let dayKey = String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
        return "\(GameRecord.recordID(platform: platform, accountID: accountID, titleID: titleID)):\(dayKey)"
    }
}

struct SyncedGame: Sendable {
    let titleID: String
    let platform: GamePlatform
    var title: String
    var totalMinutes: Int
    var imageURL: String
    var firstPlayedAt: Date?
    var lastPlayedAt: Date?
    var weeklyMinutes: [Int]
    var trophiesEarned: Int = 0
    var trophiesDefined: Int = 0
    var platinumTrophiesEarned: Int = 0
    var trophiesSyncedAt: Date?
}

struct SyncedDailyActivity: Sendable {
    let titleID: String
    let day: Date
    let totalMinutes: Int
}

@Model
final class AIProfileResult {
    @Attribute(.unique) var id: UUID
    var accountScopeKey: String
    var platformFilter: String
    var minimumHours: Int
    var generatedAt: Date
    var text: String
    var gameCount: Int
    var totalMinutes: Int

    init(
        id: UUID = UUID(),
        accountScopeKey: String,
        platformFilter: String,
        minimumHours: Int,
        generatedAt: Date = .now,
        text: String,
        gameCount: Int,
        totalMinutes: Int
    ) {
        self.id = id
        self.accountScopeKey = accountScopeKey
        self.platformFilter = platformFilter
        self.minimumHours = minimumHours
        self.generatedAt = generatedAt
        self.text = text
        self.gameCount = gameCount
        self.totalMinutes = totalMinutes
    }
}

@Model
final class SavedGamePlan {
    @Attribute(.unique) var id: UUID
    var accountScopeKey: String
    var title: String
    var note: String
    var createdAt: Date
    var isCompleted: Bool

    init(
        id: UUID = UUID(),
        accountScopeKey: String,
        title: String,
        note: String = "",
        createdAt: Date = .now,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.accountScopeKey = accountScopeKey
        self.title = title
        self.note = note
        self.createdAt = createdAt
        self.isCompleted = isCompleted
    }
}
