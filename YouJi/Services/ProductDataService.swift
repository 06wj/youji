import Foundation
import SwiftData
import UIKit
import UserNotifications

struct YouJiBackup: Codable {
    let formatVersion: Int
    let createdAt: Date
    let games: [BackupGame]
    let snapshots: [BackupSnapshot]
    let dailyActivities: [BackupDailyActivity]
    let conversations: [BackupConversation]
    let profiles: [BackupProfile]
    let plans: [BackupPlan]
}

struct BackupGame: Codable {
    let applicationID: String
    let accountID: String
    let titleID: String
    let platform: GamePlatform
    let title: String
    let totalMinutes: Int
    let imageURL: String
    let firstPlayedAt: Date?
    let lastPlayedAt: Date?
    let weeklyMinutes: [Int]
    let trophiesEarned: Int
    let trophiesDefined: Int
    let platinumTrophiesEarned: Int
    let trophiesSyncedAt: Date?
    let updatedAt: Date
    let userEditedAt: Date?
    let isFavorite: Bool
    let isManuallyHidden: Bool
    let isPinnedVisible: Bool
    let personalNote: String
    let playStatus: GamePlayStatus
}

struct BackupSnapshot: Codable {
    let snapshotID: String
    let gameID: String
    let accountID: String
    let platform: GamePlatform
    let date: Date
    let totalMinutes: Int
    let trophiesEarned: Int
}

struct BackupDailyActivity: Codable {
    let activityID: String
    let gameID: String
    let accountID: String
    let titleID: String
    let platform: GamePlatform
    let dayKey: String?
    let day: Date
    let totalMinutes: Int
    let updatedAt: Date
}

struct BackupConversation: Codable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let titleGeneratedAt: Date?
    let accountScopeKey: String
    let messages: [AIChatMessage]
    let games: [AIAnalysisGame]
    var rawMessagesData: Data? = nil
    var rawGameContextData: Data? = nil
}

struct BackupProfile: Codable {
    let id: UUID
    let accountScopeKey: String
    let platformFilter: String
    let minimumHours: Int
    let generatedAt: Date
    let text: String
    let gameCount: Int
    let totalMinutes: Int
}

struct BackupPlan: Codable {
    let id: UUID
    let accountScopeKey: String
    let title: String
    let note: String
    let createdAt: Date
    let updatedAt: Date?
    let isCompleted: Bool
}

struct ProductRestoreSummary: Equatable {
    let gameCount: Int
    let snapshotCount: Int
    let dailyActivityCount: Int
}

@MainActor
enum ProductDataService {
    static func makeBackup(modelContext: ModelContext) throws -> YouJiBackup {
        let games = try modelContext.fetch(FetchDescriptor<GameRecord>()).map {
            BackupGame(
                applicationID: $0.applicationID,
                accountID: $0.accountID,
                titleID: $0.titleID,
                platform: $0.platform,
                title: $0.title,
                totalMinutes: $0.totalMinutes,
                imageURL: $0.imageURL,
                firstPlayedAt: $0.firstPlayedAt,
                lastPlayedAt: $0.lastPlayedAt,
                weeklyMinutes: $0.weeklyMinutes,
                trophiesEarned: $0.trophiesEarned,
                trophiesDefined: $0.trophiesDefined,
                platinumTrophiesEarned: $0.platinumTrophiesEarned,
                trophiesSyncedAt: $0.trophiesSyncedAt,
                updatedAt: $0.updatedAt,
                userEditedAt: $0.resolvedUserEditedAt,
                isFavorite: $0.isFavorite,
                isManuallyHidden: $0.isManuallyHidden,
                isPinnedVisible: $0.isPinnedVisible,
                personalNote: $0.personalNote,
                playStatus: $0.playStatus
            )
        }
        let snapshots = try modelContext.fetch(FetchDescriptor<PlaySnapshot>()).map {
            BackupSnapshot(
                snapshotID: $0.snapshotID,
                gameID: $0.gameID,
                accountID: $0.accountID,
                platform: $0.platform,
                date: $0.date,
                totalMinutes: $0.totalMinutes,
                trophiesEarned: $0.trophiesEarned
            )
        }
        let activities = try modelContext.fetch(FetchDescriptor<DailyPlayActivity>()).map {
            BackupDailyActivity(
                activityID: $0.activityID,
                gameID: $0.gameID,
                accountID: $0.accountID,
                titleID: $0.titleID,
                platform: $0.platform,
                dayKey: $0.resolvedDayKey,
                day: $0.day,
                totalMinutes: $0.totalMinutes,
                updatedAt: $0.updatedAt
            )
        }
        let conversations = try modelContext.fetch(FetchDescriptor<AIConversation>()).map {
            BackupConversation(
                id: $0.id,
                title: $0.title,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                titleGeneratedAt: $0.titleGeneratedAt,
                accountScopeKey: $0.accountScopeKey,
                messages: $0.messages,
                games: $0.games,
                rawMessagesData: (try? $0.readMessages()) == nil ? $0.messagesData : nil,
                rawGameContextData: (try? $0.readGames()) == nil ? $0.gameContextData : nil
            )
        }
        let profiles = try modelContext.fetch(FetchDescriptor<AIProfileResult>()).map {
            BackupProfile(
                id: $0.id,
                accountScopeKey: $0.accountScopeKey,
                platformFilter: $0.platformFilter,
                minimumHours: $0.minimumHours,
                generatedAt: $0.generatedAt,
                text: $0.text,
                gameCount: $0.gameCount,
                totalMinutes: $0.totalMinutes
            )
        }
        let plans = try modelContext.fetch(FetchDescriptor<SavedGamePlan>()).map {
            BackupPlan(
                id: $0.id,
                accountScopeKey: $0.accountScopeKey,
                title: $0.title,
                note: $0.note,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                isCompleted: $0.isCompleted
            )
        }
        return YouJiBackup(
            formatVersion: 2,
            createdAt: .now,
            games: games,
            snapshots: snapshots,
            dailyActivities: activities,
            conversations: conversations,
            profiles: profiles,
            plans: plans
        )
    }

    static func backupData(modelContext: ModelContext) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.ISO8601Format(.init(includingFractionalSeconds: true)))
        }
        return try encoder.encode(makeBackup(modelContext: modelContext))
    }

    @discardableResult
    static func restore(data: Data, modelContext: ModelContext) throws -> ProductRestoreSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = NintendoAPIClient.parseDate(value) else {
                throw ProductDataError.invalidBackup("日期格式无法读取")
            }
            return date
        }
        let backup = try decoder.decode(YouJiBackup.self, from: data)
        guard (1...2).contains(backup.formatVersion) else { throw ProductDataError.unsupportedBackup }
        try validate(backup, modelContext: modelContext)
        LocalDataRevision.invalidate()
        return try LocalPersistence.transaction(modelContext) { modelContext in

            let existingGames = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<GameRecord>()).map { ($0.applicationID, $0) })
            for item in backup.games {
                let local = existingGames[item.applicationID]
                let game = local ?? GameRecord(
                    applicationID: item.applicationID,
                    accountID: item.accountID,
                    titleID: item.titleID,
                    platform: item.platform,
                    title: item.title
                )
                let localUserEditedAt = game.resolvedUserEditedAt
                if local == nil || game.updatedAt <= item.updatedAt {
                    game.accountID = item.accountID
                    game.titleID = item.titleID
                    game.platform = item.platform
                    game.title = item.title
                    game.totalMinutes = item.totalMinutes
                    game.imageURL = item.imageURL
                    game.firstPlayedAt = item.firstPlayedAt
                    game.lastPlayedAt = item.lastPlayedAt
                    game.weeklyMinutes = item.weeklyMinutes
                    game.trophiesEarned = item.trophiesEarned
                    game.trophiesDefined = item.trophiesDefined
                    game.platinumTrophiesEarned = item.platinumTrophiesEarned
                    game.trophiesSyncedAt = item.trophiesSyncedAt
                    game.updatedAt = item.updatedAt
                }
                let backupHasCustomization = item.isFavorite
                    || item.isManuallyHidden
                    || item.isPinnedVisible
                    || !item.personalNote.isEmpty
                    || item.playStatus != .played
                let importedUserEditedAt = item.userEditedAt
                    ?? (backupHasCustomization ? item.updatedAt : .distantPast)
                if local == nil || localUserEditedAt <= importedUserEditedAt {
                    game.isFavorite = item.isFavorite
                    game.isManuallyHidden = item.isManuallyHidden
                    game.isPinnedVisible = item.isPinnedVisible
                    game.personalNote = item.personalNote
                    game.playStatus = item.playStatus
                    game.userEditedAt = importedUserEditedAt
                }
                if local == nil { modelContext.insert(game) }
            }

            let snapshotIDs = Set(try modelContext.fetch(FetchDescriptor<PlaySnapshot>()).map(\.snapshotID))
            for item in backup.snapshots where !snapshotIDs.contains(item.snapshotID) {
                modelContext.insert(PlaySnapshot(
                    snapshotID: item.snapshotID,
                    gameID: item.gameID,
                    accountID: item.accountID,
                    platform: item.platform,
                    date: item.date,
                    totalMinutes: item.totalMinutes,
                    trophiesEarned: item.trophiesEarned
                ))
            }

            let existingActivities = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<DailyPlayActivity>()).map { ($0.activityID, $0) })
            for item in backup.dailyActivities {
                if let local = existingActivities[item.activityID], local.updatedAt > item.updatedAt {
                    continue
                }
                let activity = existingActivities[item.activityID] ?? DailyPlayActivity(
                    activityID: item.activityID,
                    gameID: item.gameID,
                    accountID: item.accountID,
                    titleID: item.titleID,
                    platform: item.platform,
                    day: item.day,
                    totalMinutes: item.totalMinutes
                )
                activity.gameID = item.gameID
                activity.accountID = item.accountID
                activity.titleID = item.titleID
                activity.platformRaw = item.platform.rawValue
                activity.dayKey = item.dayKey
                    ?? DailyPlayActivity.dayKey(fromActivityID: item.activityID)
                    ?? DailyPlayActivity.dayKey(for: item.day)
                activity.day = DailyPlayActivity.date(fromDayKey: activity.dayKey) ?? item.day
                activity.totalMinutes = item.totalMinutes
                activity.updatedAt = item.updatedAt
                if existingActivities[item.activityID] == nil { modelContext.insert(activity) }
            }

            let existingConversations = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<AIConversation>()).map { ($0.id, $0) })
            for item in backup.conversations {
                let local = existingConversations[item.id]
                let imported = AIConversation(id: item.id, title: item.title, createdAt: item.createdAt,
                                              accountScopeKey: item.accountScopeKey, games: item.games)
                imported.messages = item.messages
                if let raw = item.rawMessagesData { imported.messagesData = raw }
                if let raw = item.rawGameContextData { imported.gameContextData = raw }
                imported.updatedAt = item.updatedAt
                imported.titleGeneratedAt = item.titleGeneratedAt
                guard let local else {
                    modelContext.insert(imported)
                    continue
                }
                let oldDate = local.updatedAt
                let isNewer = item.updatedAt >= oldDate
                // A readable component always wins over an unreadable one. An older
                // backup can repair damage without truncating a newer readable thread.
                if (try? imported.readMessages()) != nil,
                   isNewer || (try? local.readMessages()) == nil {
                    local.messagesData = imported.messagesData
                }
                if (try? imported.readGames()) != nil,
                   isNewer || (try? local.readGames()) == nil {
                    local.gameContextData = imported.gameContextData
                }
                if isNewer && !imported.hasUnreadableContent {
                    local.title = item.title
                    local.createdAt = item.createdAt
                    local.titleGeneratedAt = item.titleGeneratedAt
                    local.accountScopeKey = item.accountScopeKey
                }
                local.updatedAt = max(oldDate, item.updatedAt)
            }

            let existingProfiles = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<AIProfileResult>()).map { ($0.id, $0) })
            for item in backup.profiles {
                let profile = existingProfiles[item.id] ?? AIProfileResult(
                    id: item.id,
                    accountScopeKey: item.accountScopeKey,
                    platformFilter: item.platformFilter,
                    minimumHours: item.minimumHours,
                    generatedAt: item.generatedAt,
                    text: item.text,
                    gameCount: item.gameCount,
                    totalMinutes: item.totalMinutes
                )
                profile.accountScopeKey = item.accountScopeKey
                profile.platformFilter = item.platformFilter
                profile.minimumHours = item.minimumHours
                profile.generatedAt = item.generatedAt
                profile.text = item.text
                profile.gameCount = item.gameCount
                profile.totalMinutes = item.totalMinutes
                if existingProfiles[item.id] == nil { modelContext.insert(profile) }
            }

            let existingPlans = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<SavedGamePlan>()).map { ($0.id, $0) })
            for item in backup.plans {
                let importedUpdatedAt = item.updatedAt ?? item.createdAt
                if let local = existingPlans[item.id], local.updatedAt > importedUpdatedAt {
                    continue
                }
                let plan = existingPlans[item.id] ?? SavedGamePlan(
                    id: item.id,
                    accountScopeKey: item.accountScopeKey,
                    title: item.title,
                    note: item.note,
                    createdAt: item.createdAt,
                    isCompleted: item.isCompleted
                )
                plan.accountScopeKey = item.accountScopeKey
                plan.title = item.title
                plan.note = item.note
                plan.createdAt = item.createdAt
                plan.updatedAt = importedUpdatedAt
                plan.isCompleted = item.isCompleted
                if existingPlans[item.id] == nil { modelContext.insert(plan) }
            }
            return ProductRestoreSummary(
                gameCount: backup.games.count,
                snapshotCount: backup.snapshots.count,
                dailyActivityCount: backup.dailyActivities.count
            )
        }
    }

    static func libraryCSV(games: [GameRecord]) -> String {
        let header = "平台,游戏名称,总分钟,最近游玩,奖杯,收藏,状态,备注"
        let rows = games.sorted { $0.totalMinutes > $1.totalMinutes }.map { game in
            [
                game.platform.rawValue,
                game.title,
                String(game.totalMinutes),
                game.lastPlayedAt?.ISO8601Format() ?? "",
                game.platform == .playStation && game.trophiesDefined > 0 ? "\(game.trophiesEarned)/\(game.trophiesDefined)" : "",
                game.isFavorite ? "是" : "否",
                game.playStatus.rawValue,
                game.personalNote,
            ]
            .map(csvEscape)
            .joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    static func diagnostics(modelContext: ModelContext) -> String {
        let gameCount = (try? modelContext.fetchCount(FetchDescriptor<GameRecord>())) ?? 0
        let snapshotCount = (try? modelContext.fetchCount(FetchDescriptor<PlaySnapshot>())) ?? 0
        let activityCount = (try? modelContext.fetchCount(FetchDescriptor<DailyPlayActivity>())) ?? 0
        let conversationCount = (try? modelContext.fetchCount(FetchDescriptor<AIConversation>())) ?? 0
        return """
        游迹诊断摘要
        App 版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
        系统：\(ProcessInfo.processInfo.operatingSystemVersionString)
        游戏：\(gameCount)
        同步快照：\(snapshotCount)
        每日记录：\(activityCount)
        AI 会话：\(conversationCount)
        说明：此摘要不包含账号 ID、令牌、API Key、游戏名称或聊天内容。
        """
    }

    static func deleteArchive(
        platform: GamePlatform,
        accountID: String,
        modelContext: ModelContext
    ) throws {
        LocalDataRevision.invalidate()
        try LocalPersistence.transaction(modelContext) { modelContext in
            let platformRaw = platform.rawValue
            let games = try modelContext.fetch(FetchDescriptor<GameRecord>(predicate: #Predicate {
                $0.platformRaw == platformRaw && $0.accountID == accountID
            }))
            for game in games { modelContext.delete(game) }
            for snapshot in try modelContext.fetch(FetchDescriptor<PlaySnapshot>())
                where snapshot.platform == platform && snapshot.accountID == accountID {
                modelContext.delete(snapshot)
            }
            for activity in try modelContext.fetch(FetchDescriptor<DailyPlayActivity>())
                where activity.platform == platform && activity.accountID == accountID {
                modelContext.delete(activity)
            }
            for conversation in try modelContext.fetch(FetchDescriptor<AIConversation>())
                where AccountScope.contains(conversation.accountScopeKey, platform: platform, accountID: accountID) {
                modelContext.delete(conversation)
            }
            for profile in try modelContext.fetch(FetchDescriptor<AIProfileResult>())
                where AccountScope.contains(profile.accountScopeKey, platform: platform, accountID: accountID) {
                modelContext.delete(profile)
            }
            for plan in try modelContext.fetch(FetchDescriptor<SavedGamePlan>())
                where AccountScope.contains(plan.accountScopeKey, platform: platform, accountID: accountID) {
                modelContext.delete(plan)
            }
        }
    }

    static func deleteAllLocalData(modelContext: ModelContext) async throws {
        LocalDataRevision.invalidate()
        try LocalPersistence.transaction(modelContext) { modelContext in
            for item in try modelContext.fetch(FetchDescriptor<GameRecord>()) { modelContext.delete(item) }
            for item in try modelContext.fetch(FetchDescriptor<PlaySnapshot>()) { modelContext.delete(item) }
            for item in try modelContext.fetch(FetchDescriptor<DailyPlayActivity>()) { modelContext.delete(item) }
            for item in try modelContext.fetch(FetchDescriptor<AIConversation>()) { modelContext.delete(item) }
            for item in try modelContext.fetch(FetchDescriptor<AIProfileResult>()) { modelContext.delete(item) }
            for item in try modelContext.fetch(FetchDescriptor<SavedGamePlan>()) { modelContext.delete(item) }
        }
        SyncCoordinator.clearStoredNonCredentialState()
        NotificationCenter.default.post(name: .youJiLocalDataDidReset, object: nil)
        try? await CoverImageStore.shared.removeAllCachedImages()
    }

    private static func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

extension Notification.Name {
    static let youJiLocalDataDidReset = Notification.Name("YouJiLocalDataDidReset")
}

enum ProductDataError: LocalizedError {
    case unsupportedBackup
    case invalidBackup(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedBackup: "这个备份版本暂不支持，请使用较新版本的游迹。"
        case .invalidBackup(let reason): "备份暂时无法恢复：\(reason)。本地记录未更改，请保留原备份。"
        }
    }
}

struct PlayPeriodInsight: Equatable {
    let addedMinutes: Int
    let addedTrophies: Int
    let activeGames: Int
}

struct PlayGameContribution: Identifiable, Equatable {
    let gameID: String
    let addedMinutes: Int
    let addedTrophies: Int

    var id: String { gameID }
}

enum PlayTimelineSource: Equatable {
    case dailyActivity
    case snapshotChange
}

struct PlayTimelineEntry: Identifiable, Equatable {
    let id: String
    let gameID: String
    let date: Date
    let addedMinutes: Int
    let addedTrophies: Int
    let source: PlayTimelineSource
}

enum PlayHistoryChartBuilder {
    static func dailySnapshots(
        _ snapshots: [PlaySnapshot],
        calendar: Calendar = .current
    ) -> [PlaySnapshot] {
        Dictionary(grouping: snapshots) { calendar.startOfDay(for: $0.date) }
            .compactMap { _, values in values.max { $0.date < $1.date } }
            .sorted { $0.date < $1.date }
    }

    static func yDomain(totalMinutes: [Int]) -> ClosedRange<Double> {
        let hours = totalMinutes.map { Double($0) / 60 }
        guard let minimum = hours.min(), let maximum = hours.max() else { return 0...1 }
        let change = maximum - minimum
        let padding = change > 0 ? max(change * 0.18, 0.5) : max(minimum * 0.01, 1)
        let lower = max(0, floor((minimum - padding) * 2) / 2)
        let upper = max(lower + 1, ceil((maximum + padding) * 2) / 2)
        return lower...upper
    }
}

enum PlayTimelineBuilder {
    static func entries(
        snapshots: [PlaySnapshot],
        activities: [DailyPlayActivity],
        includedGameIDs: Set<String>
    ) -> [PlayTimelineEntry] {
        let relevantActivities = activities.filter {
            includedGameIDs.contains($0.gameID) && $0.totalMinutes > 0
        }
        let gamesWithDailyActivity = Set(relevantActivities.map(\.gameID))

        var result = relevantActivities.map { activity in
            PlayTimelineEntry(
                id: "daily:\(activity.activityID)",
                gameID: activity.gameID,
                date: activity.displayDay,
                addedMinutes: activity.totalMinutes,
                addedTrophies: 0,
                source: .dailyActivity
            )
        }

        let relevantSnapshots = snapshots.filter {
            includedGameIDs.contains($0.gameID)
                && ($0.platform == .playStation || !gamesWithDailyActivity.contains($0.gameID))
        }
        for (gameID, values) in Dictionary(grouping: relevantSnapshots, by: \.gameID) {
            let sorted = values.sorted { $0.date < $1.date }
            guard sorted.count >= 2 else { continue }
            for index in sorted.indices.dropFirst() {
                let previous = sorted[sorted.index(before: index)]
                let current = sorted[index]
                let addedMinutes = max(0, current.totalMinutes - previous.totalMinutes)
                let addedTrophies = max(0, current.trophiesEarned - previous.trophiesEarned)
                guard addedMinutes > 0 || addedTrophies > 0 else { continue }
                result.append(PlayTimelineEntry(
                    id: "snapshot:\(current.snapshotID)",
                    gameID: gameID,
                    date: current.date,
                    addedMinutes: addedMinutes,
                    addedTrophies: addedTrophies,
                    source: .snapshotChange
                ))
            }
        }

        let calendar = Calendar.current
        let dailyResult = Dictionary(grouping: result) { entry in
            "\(entry.gameID):\(Int(calendar.startOfDay(for: entry.date).timeIntervalSinceReferenceDate))"
        }
        .compactMap { _, values -> PlayTimelineEntry? in
            guard let first = values.first else { return nil }
            let day = calendar.startOfDay(for: first.date)
            return PlayTimelineEntry(
                id: "day:\(Int(day.timeIntervalSinceReferenceDate)):\(first.gameID)",
                gameID: first.gameID,
                date: day,
                addedMinutes: values.reduce(0) { $0 + $1.addedMinutes },
                addedTrophies: values.reduce(0) { $0 + $1.addedTrophies },
                source: values.contains { $0.source == .dailyActivity } ? .dailyActivity : .snapshotChange
            )
        }

        return dailyResult.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.gameID != $1.gameID { return $0.gameID < $1.gameID }
            return $0.id < $1.id
        }
    }
}

enum PlayInsightCalculator {
    static func insight(snapshots: [PlaySnapshot], since start: Date, now: Date = .now) -> PlayPeriodInsight {
        let values = contributions(snapshots: snapshots, since: start, now: now)
        return PlayPeriodInsight(
            addedMinutes: values.reduce(0) { $0 + $1.addedMinutes },
            addedTrophies: values.reduce(0) { $0 + $1.addedTrophies },
            activeGames: values.count
        )
    }

    static func contributions(
        snapshots: [PlaySnapshot],
        since start: Date,
        now: Date = .now
    ) -> [PlayGameContribution] {
        let grouped = Dictionary(grouping: snapshots.filter { $0.date <= now }, by: \.gameID)
        return grouped.compactMap { gameID, values in
            let sorted = values.sorted { $0.date < $1.date }
            guard let latest = sorted.last else { return nil }
            let baseline = sorted.last(where: { $0.date <= start }) ?? sorted.first
            guard let baseline else { return nil }
            let minuteDelta = max(0, latest.totalMinutes - baseline.totalMinutes)
            let trophyDelta = max(0, latest.trophiesEarned - baseline.trophiesEarned)
            guard minuteDelta > 0 || trophyDelta > 0 else { return nil }
            return PlayGameContribution(
                gameID: gameID,
                addedMinutes: minuteDelta,
                addedTrophies: trophyDelta
            )
        }
        .sorted {
            if $0.addedMinutes != $1.addedMinutes { return $0.addedMinutes > $1.addedMinutes }
            if $0.addedTrophies != $1.addedTrophies { return $0.addedTrophies > $1.addedTrophies }
            return $0.gameID < $1.gameID
        }
    }
}

enum SyncReminderService {
    static let identifier = "youji.weekly-sync-reminder"

    static func scheduleWeekly() async throws {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            throw SyncReminderError.denied
        }
        let content = UNMutableNotificationContent()
        content.title = "该更新游迹了"
        content.body = "主动同步一次，留住这一周的 Switch 每日记录和游戏平台变化。"
        content.sound = .default
        var components = DateComponents()
        components.weekday = 1
        components.hour = 20
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        try await center.add(request)
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

enum SyncReminderError: LocalizedError {
    case denied

    var errorDescription: String? { "通知权限未开启，可以稍后在系统设置中允许游迹通知。" }
}

@MainActor
enum ProfileShareCardService {
    static func makeCard(text: String, subtitle: String) throws -> URL {
        let size = CGSize(width: 1080, height: 1440)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext
            let colors = [
                UIColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1).cgColor,
                UIColor(red: 0.91, green: 0.87, blue: 0.98, alpha: 1).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }

            let card = UIBezierPath(roundedRect: CGRect(x: 70, y: 70, width: 940, height: 1300), cornerRadius: 48)
            UIColor.white.withAlphaComponent(0.9).setFill()
            card.fill()

            ("游迹 · 游戏人格" as NSString).draw(
                in: CGRect(x: 120, y: 125, width: 840, height: 80),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 48, weight: .black),
                    .foregroundColor: UIColor(red: 0.29, green: 0.18, blue: 0.66, alpha: 1),
                ]
            )
            (subtitle as NSString).draw(
                in: CGRect(x: 120, y: 205, width: 840, height: 52),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
                    .foregroundColor: UIColor.secondaryLabel,
                ]
            )

            let cleaned = text
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 13
            (cleaned as NSString).draw(
                with: CGRect(x: 120, y: 300, width: 840, height: 930),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: UIFont.systemFont(ofSize: 30, weight: .regular),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: paragraph,
                ],
                context: nil
            )
            ("YOUR GAME BRAIN · 只包含本次分析文本" as NSString).draw(
                in: CGRect(x: 120, y: 1280, width: 840, height: 40),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 18, weight: .bold),
                    .foregroundColor: UIColor.tertiaryLabel,
                ]
            )
        }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("游迹游戏人格-\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic)
        return url
    }
}

extension YouJiBackup {
    enum CodingKeys: String, CodingKey {
        case formatVersion, createdAt, games, snapshots, dailyActivities, conversations, profiles, plans
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        games = try values.decode([BackupGame].self, forKey: .games)
        snapshots = try values.decodeIfPresent([BackupSnapshot].self, forKey: .snapshots) ?? []
        dailyActivities = try values.decodeIfPresent([BackupDailyActivity].self, forKey: .dailyActivities) ?? []
        conversations = try values.decodeIfPresent([BackupConversation].self, forKey: .conversations) ?? []
        profiles = try values.decodeIfPresent([BackupProfile].self, forKey: .profiles) ?? []
        plans = try values.decodeIfPresent([BackupPlan].self, forKey: .plans) ?? []
    }
}

extension BackupGame {
    enum CodingKeys: String, CodingKey {
        case applicationID, accountID, titleID, platform, title, totalMinutes, imageURL
        case firstPlayedAt, lastPlayedAt, weeklyMinutes, trophiesEarned, trophiesDefined
        case platinumTrophiesEarned, trophiesSyncedAt, updatedAt, userEditedAt
        case isFavorite, isManuallyHidden, isPinnedVisible, personalNote, playStatus
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        applicationID = try values.decode(String.self, forKey: .applicationID)
        accountID = try values.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        platform = try values.decode(GamePlatform.self, forKey: .platform)
        let prefix = platform == .playStation ? "ps:" : "switch:"
        let identityPrefix = prefix + (accountID.isEmpty ? "" : "\(accountID):")
        let inferredTitleID = applicationID.hasPrefix(identityPrefix)
            ? String(applicationID.dropFirst(identityPrefix.count)) : applicationID
        let storedTitleID = try values.decodeIfPresent(String.self, forKey: .titleID) ?? ""
        titleID = storedTitleID.isEmpty ? inferredTitleID : storedTitleID
        title = try values.decode(String.self, forKey: .title)
        totalMinutes = try values.decode(Int.self, forKey: .totalMinutes)
        imageURL = try values.decodeIfPresent(String.self, forKey: .imageURL) ?? ""
        firstPlayedAt = try values.decodeIfPresent(Date.self, forKey: .firstPlayedAt)
        lastPlayedAt = try values.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        weeklyMinutes = try values.decodeIfPresent([Int].self, forKey: .weeklyMinutes) ?? Array(repeating: 0, count: 7)
        trophiesEarned = try values.decodeIfPresent(Int.self, forKey: .trophiesEarned) ?? 0
        trophiesDefined = try values.decodeIfPresent(Int.self, forKey: .trophiesDefined) ?? 0
        platinumTrophiesEarned = try values.decodeIfPresent(Int.self, forKey: .platinumTrophiesEarned) ?? 0
        trophiesSyncedAt = try values.decodeIfPresent(Date.self, forKey: .trophiesSyncedAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        userEditedAt = try values.decodeIfPresent(Date.self, forKey: .userEditedAt)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isManuallyHidden = try values.decodeIfPresent(Bool.self, forKey: .isManuallyHidden) ?? false
        isPinnedVisible = try values.decodeIfPresent(Bool.self, forKey: .isPinnedVisible) ?? false
        personalNote = try values.decodeIfPresent(String.self, forKey: .personalNote) ?? ""
        playStatus = try values.decodeIfPresent(GamePlayStatus.self, forKey: .playStatus) ?? .played
    }
}

extension ProductDataService {
    private struct BackupIdentity: Equatable {
        let platform: GamePlatform
        let accountID: String
        let titleID: String
    }

    /// Validate the whole graph before touching live records. Unknown fields remain
    /// compatible; contradictory identities and broken references are never guessed.
    private static func validate(_ backup: YouJiBackup, modelContext: ModelContext) throws {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw ProductDataError.invalidBackup(reason) }
        }
        func unique<T: Hashable>(_ ids: [T]) throws {
            try require(Set(ids).count == ids.count, "存在重复的记录标识")
        }
        try unique(backup.games.map(\.applicationID))
        try unique(backup.snapshots.map(\.snapshotID))
        try unique(backup.dailyActivities.map(\.activityID))
        try unique(backup.conversations.map(\.id))
        try unique(backup.profiles.map(\.id))
        try unique(backup.plans.map(\.id))

        var identities: [String: BackupIdentity] = [:]
        for game in try modelContext.fetch(FetchDescriptor<GameRecord>()) {
            identities[game.applicationID] = BackupIdentity(platform: game.platform, accountID: game.accountID, titleID: game.resolvedTitleID)
        }
        for game in backup.games {
            let canonicalID = GameRecord.recordID(platform: game.platform, accountID: game.accountID, titleID: game.titleID)
            let legacyPrefix = game.platform == .playStation ? "ps:" : "switch:"
            let isLegacy = game.accountID.isEmpty && [game.titleID, legacyPrefix + game.titleID].contains(game.applicationID)
            try require(!game.titleID.isEmpty && !game.titleID.contains(":") && !game.accountID.contains(":"), "游戏身份格式不正确")
            try require(game.applicationID == canonicalID || isLegacy, "游戏标识与账号不一致")
            let identity = BackupIdentity(platform: game.platform, accountID: game.accountID, titleID: game.titleID)
            if let local = identities[game.applicationID] {
                try require(local == identity, "游戏归属与本地记录冲突")
            }
            identities[game.applicationID] = identity
            try require(DataValidation.minutes(game.totalMinutes), "游玩时长超出范围")
            try require(game.weeklyMinutes.count == 7 && game.weeklyMinutes.allSatisfy(DataValidation.minutes), "七日游玩数据不完整")
            try require([game.trophiesEarned, game.trophiesDefined, game.platinumTrophiesEarned].allSatisfy(DataValidation.trophies), "奖杯数量超出范围")
            // Old records can have unknown defined counts; preserve them without inventing a ratio.
            try require(game.trophiesDefined == 0 || game.trophiesEarned <= game.trophiesDefined, "奖杯数量不一致")
        }
        for item in backup.snapshots {
            let prefix = GameRecord.recordID(platform: item.platform, accountID: item.accountID, titleID: "")
            let hasValidReference: Bool
            if let game = identities[item.gameID] {
                hasValidReference = game.platform == item.platform && game.accountID == item.accountID
            } else {
                hasValidReference = item.gameID.hasPrefix(prefix) && item.gameID.count > prefix.count
                    && !item.gameID.dropFirst(prefix.count).contains(":")
            }
            try require(!item.snapshotID.isEmpty && hasValidReference, "同步历史的账号归属不一致")
            try require(DataValidation.minutes(item.totalMinutes) && DataValidation.trophies(item.trophiesEarned), "同步历史数值超出范围")
        }
        for item in backup.dailyActivities {
            let identity = BackupIdentity(platform: item.platform, accountID: item.accountID, titleID: item.titleID)
            let expectedID = GameRecord.recordID(platform: item.platform, accountID: item.accountID, titleID: item.titleID)
            try require(identities[item.gameID].map { $0 == identity } ?? (item.gameID == expectedID && !item.titleID.isEmpty), "每日记录的账号归属不一致")
            let dayKey = item.dayKey ?? DailyPlayActivity.dayKey(fromActivityID: item.activityID) ?? DailyPlayActivity.dayKey(for: item.day)
            try require(DailyPlayActivity.date(fromDayKey: dayKey) != nil && item.activityID == "\(item.gameID):\(dayKey)", "每日记录的日期标识不一致")
            try require(DataValidation.minutes(item.totalMinutes), "每日记录时长超出范围")
        }
        for item in backup.conversations {
            try unique(item.messages.map(\.id))
            try require(item.games.allSatisfy { DataValidation.minutes($0.totalMinutes) }, "对话中的时长超出范围")
        }
        for item in backup.profiles {
            try require(item.minimumHours >= 0 && item.minimumHours <= DataValidation.maximumMinutes / 60 && item.gameCount >= 0 && DataValidation.minutes(item.totalMinutes), "人格记录数值超出范围")
        }
    }
}
