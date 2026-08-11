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

    init(
        applicationID: String,
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
        guard totalMinutes < 60,
              let lastPlayedAt,
              let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: .now) else {
            return false
        }
        return lastPlayedAt < cutoff
    }
}

struct SyncedGame: Sendable {
    let applicationID: String
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
