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
                games: $0.games
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
                isCompleted: $0.isCompleted
            )
        }
        return YouJiBackup(
            formatVersion: 1,
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
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(makeBackup(modelContext: modelContext))
    }

    @discardableResult
    static func restore(data: Data, modelContext: ModelContext) throws -> ProductRestoreSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(YouJiBackup.self, from: data)
        guard backup.formatVersion == 1 else { throw ProductDataError.unsupportedBackup }

        let existingGames = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<GameRecord>()).map { ($0.applicationID, $0) })
        for item in backup.games {
            let game = existingGames[item.applicationID] ?? GameRecord(
                applicationID: item.applicationID,
                accountID: item.accountID,
                titleID: item.titleID,
                platform: item.platform,
                title: item.title
            )
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
            game.isFavorite = item.isFavorite
            game.isManuallyHidden = item.isManuallyHidden
            game.isPinnedVisible = item.isPinnedVisible
            game.personalNote = item.personalNote
            game.playStatus = item.playStatus
            if existingGames[item.applicationID] == nil { modelContext.insert(game) }
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
            activity.day = item.day
            activity.totalMinutes = item.totalMinutes
            activity.updatedAt = item.updatedAt
            if existingActivities[item.activityID] == nil { modelContext.insert(activity) }
        }

        let existingConversations = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<AIConversation>()).map { ($0.id, $0) })
        for item in backup.conversations {
            let conversation = existingConversations[item.id] ?? AIConversation(
                id: item.id,
                title: item.title,
                createdAt: item.createdAt,
                accountScopeKey: item.accountScopeKey,
                games: item.games
            )
            conversation.title = item.title
            conversation.createdAt = item.createdAt
            conversation.messages = item.messages
            conversation.games = item.games
            conversation.updatedAt = item.updatedAt
            conversation.titleGeneratedAt = item.titleGeneratedAt
            conversation.accountScopeKey = item.accountScopeKey
            if existingConversations[item.id] == nil { modelContext.insert(conversation) }
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
            plan.isCompleted = item.isCompleted
            if existingPlans[item.id] == nil { modelContext.insert(plan) }
        }
        try modelContext.save()
        return ProductRestoreSummary(
            gameCount: backup.games.count,
            snapshotCount: backup.snapshots.count,
            dailyActivityCount: backup.dailyActivities.count
        )
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
        if !games.isEmpty {
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
        try modelContext.save()
    }

    static func deleteAllLocalData(modelContext: ModelContext) async throws {
        for item in try modelContext.fetch(FetchDescriptor<GameRecord>()) { modelContext.delete(item) }
        for item in try modelContext.fetch(FetchDescriptor<PlaySnapshot>()) { modelContext.delete(item) }
        for item in try modelContext.fetch(FetchDescriptor<DailyPlayActivity>()) { modelContext.delete(item) }
        for item in try modelContext.fetch(FetchDescriptor<AIConversation>()) { modelContext.delete(item) }
        for item in try modelContext.fetch(FetchDescriptor<AIProfileResult>()) { modelContext.delete(item) }
        for item in try modelContext.fetch(FetchDescriptor<SavedGamePlan>()) { modelContext.delete(item) }
        try modelContext.save()
        SyncCoordinator.clearStoredNonCredentialState()
        NotificationCenter.default.post(name: .youJiLocalDataDidReset, object: nil)
        try await CoverImageStore.shared.removeAllCachedImages()
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

    var errorDescription: String? {
        switch self {
        case .unsupportedBackup: "这个备份版本暂不支持。"
        }
    }
}

struct PlayPeriodInsight: Equatable {
    let addedMinutes: Int
    let addedTrophies: Int
    let activeGames: Int
}

enum PlayInsightCalculator {
    static func insight(snapshots: [PlaySnapshot], since start: Date, now: Date = .now) -> PlayPeriodInsight {
        let grouped = Dictionary(grouping: snapshots.filter { $0.date <= now }, by: \.gameID)
        var minutes = 0
        var trophies = 0
        var activeGames = 0
        for values in grouped.values {
            let sorted = values.sorted { $0.date < $1.date }
            guard let latest = sorted.last else { continue }
            let baseline = sorted.last(where: { $0.date <= start }) ?? sorted.first
            guard let baseline else { continue }
            let minuteDelta = max(0, latest.totalMinutes - baseline.totalMinutes)
            let trophyDelta = max(0, latest.trophiesEarned - baseline.trophiesEarned)
            if minuteDelta > 0 || trophyDelta > 0 { activeGames += 1 }
            minutes += minuteDelta
            trophies += trophyDelta
        }
        return PlayPeriodInsight(addedMinutes: minutes, addedTrophies: trophies, activeGames: activeGames)
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
