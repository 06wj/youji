#if DEBUG
import SwiftData
import SwiftUI

enum ScreenshotRoute: String, CaseIterable {
    case overview
    case firstRun = "first-run"
    case weeklyReview = "weekly-review"
    case aiDraft = "ai-draft"
    case aiSettings = "ai-settings"
    case planDetail = "plan-detail"
    case playStation = "playstation"
    case switchConsole = "switch"
    case playCalendar = "play-calendar"
    case gameDetailSwitch = "game-detail-switch"
    case gameDetailPlayStation = "game-detail-playstation"
    case gameDetailPlayStationTrophies = "game-detail-playstation-trophies"
    case accountSync = "account-sync"
    case insights
    case plans
    case aiAnalysis = "ai-analysis"
    case aiProfileHistory = "ai-profile-history"
    case aiChatList = "ai-chat-list"
    case aiChat = "ai-chat"
    case dataManagement = "data-management"
    case privacy

    static var launchRoute: ScreenshotRoute? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let marker = arguments.firstIndex(of: "--youji-screenshot-route"),
              arguments.indices.contains(marker + 1)
        else { return nil }
        return ScreenshotRoute(rawValue: arguments[marker + 1])
    }
}

struct ScreenshotRouteView: View {
    @Query(sort: \GameRecord.lastPlayedAt, order: .reverse) private var games: [GameRecord]
    @Query(sort: \AIConversation.updatedAt, order: .reverse) private var conversations: [AIConversation]
    @Query private var snapshots: [PlaySnapshot]
    @Query private var playTimeAllocations: [PlayTimeAllocation]
    @Query private var activities: [DailyPlayActivity]
    @Query private var plans: [SavedGamePlan]
    @StateObject private var sync = SyncCoordinator()
    @State private var selectedArchive: AccountArchiveSelection?

    let route: ScreenshotRoute

    private var currentGames: [GameRecord] {
        AccountScope.visibleLibraryGames(
            games,
            playStationAccountID: sync.currentPlayStationAccountID,
            nintendoAccountID: sync.currentNintendoAccountID
        )
    }

    private var accountScopeKey: String {
        AccountScope.visibleScopeKey(for: games, playStationAccountID: sync.currentPlayStationAccountID,
                                     nintendoAccountID: sync.currentNintendoAccountID)
    }

    private var switchGame: GameRecord? {
        currentGames
            .filter { $0.platform == .switchConsole }
            .max { $0.totalMinutes < $1.totalMinutes }
    }

    private var playStationGame: GameRecord? {
        currentGames.first { $0.platform == .playStation && $0.title.contains("艾尔登法环") }
            ?? currentGames
                .filter { $0.platform == .playStation }
                .max { $0.totalMinutes < $1.totalMinutes }
    }

    private var currentConversation: AIConversation? {
        conversations.first { $0.accountScopeKey == accountScopeKey }
    }

    @ViewBuilder
    var body: some View {
        switch route {
        case .overview, .firstRun:
            DashboardView(initialFilter: .all)
        case .weeklyReview:
            WeeklyReviewView(review: .make(games: currentGames, snapshots: snapshots, activities: activities,
                allocations: PlayTimeResolver.values(playTimeAllocations)), accountScopeKey: accountScopeKey)
        case .aiDraft:
            AIChatListView(games: currentGames, accountScopeKey: accountScopeKey,
                           initialDraft: DesignPreviewData.isEnabled ? AIPrompts.shortSessionDraft : nil)
        case .aiSettings:
            SettingsView(prioritizesAIConfiguration: true)
        case .planDetail:
            if let plan = plans.first(where: { $0.accountScopeKey == accountScopeKey }) {
                SavedPlanDetailView(plan: plan, accountScopeKey: accountScopeKey)
            } else { missingData("没有可截图的计划") }
        case .playStation:
            DashboardView(initialFilter: .playStation)
        case .switchConsole:
            DashboardView(initialFilter: .switchConsole)
        case .playCalendar:
            PlayCalendarView(accountID: AccountScope.displayAccountID(for: .switchConsole,
                currentAccountID: sync.currentNintendoAccountID, games: games) ?? "", games: currentGames)
        case .gameDetailSwitch:
            if let switchGame {
                GameDetailView(
                    game: switchGame,
                    accountScopeKey: accountScopeKey,
                    initialSection: DesignPreviewData.isEnabled ? nil : .personal
                )
            } else {
                missingData("没有可截图的 Switch 游戏")
            }
        case .gameDetailPlayStation:
            if let playStationGame {
                GameDetailView(
                    game: playStationGame,
                    accountScopeKey: accountScopeKey,
                    initialSection: DesignPreviewData.isEnabled ? nil : .personal
                )
            } else {
                missingData("没有可截图的 PlayStation 游戏")
            }
        case .gameDetailPlayStationTrophies:
            if let playStationGame {
                GameDetailView(
                    game: playStationGame,
                    accountScopeKey: accountScopeKey,
                    initialSection: .history
                )
            } else {
                missingData("没有可截图的 PlayStation 游戏")
            }
        case .accountSync:
            AccountCenterView(
                sync: sync,
                games: games,
                selectedArchive: $selectedArchive
            )
        case .insights:
            InsightsView(games: currentGames, accountScopeKey: accountScopeKey)
        case .plans:
            SavedPlansView(accountScopeKey: accountScopeKey)
        case .aiAnalysis:
            AIAnalysisView(games: currentGames, accountScopeKey: accountScopeKey)
        case .aiProfileHistory:
            AIProfileHistoryView(accountScopeKey: accountScopeKey)
        case .aiChatList:
            AIChatListView(games: currentGames, accountScopeKey: accountScopeKey)
        case .aiChat:
            if let currentConversation {
                NavigationStack {
                    AIChatView(conversation: currentConversation)
                }
            } else {
                AIChatListView(games: currentGames, accountScopeKey: accountScopeKey)
            }
        case .dataManagement:
            NavigationStack {
                DataManagementView(sync: sync)
            }
        case .privacy:
            NavigationStack {
                PrivacyInfoView()
            }
        }
    }

    private func missingData(_ message: String) -> some View {
        ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
    }
}

/// Opt-in, simulator-only artwork review. Never writes sample records to the user's archive.
@MainActor
enum DesignPreviewData {
    static var isEnabled: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--youji-design-preview")
        #else
        false
        #endif
    }

    static func makeContainer() throws -> ModelContainer {
        let container = try ModelContainer(for: LocalDatabaseState.schema,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        if ScreenshotRoute.launchRoute == .firstRun { return container }
        let samples: [(String, String, GamePlatform, Int, Int, Int)] = [
            ("1245620", "艾尔登法环", .playStation, 13558, 42, 42),
            ("413150", "星露谷物语", .switchConsole, 10832, 0, 0),
            ("814380", "只狼：影逝二度", .playStation, 6438, 34, 34),
            ("1145360", "哈迪斯", .switchConsole, 4862, 0, 0),
            ("367520", "空洞骑士", .playStation, 4030, 28, 35),
            ("588650", "死亡细胞", .switchConsole, 2947, 0, 0)
        ]
        var games: [GameRecord] = []
        for (index, sample) in samples.enumerated() {
            let (id, title, platform, minutes, earned, defined) = sample
            let game = GameRecord(
                applicationID: GameRecord.recordID(platform: platform, accountID: "preview", titleID: id),
                accountID: "preview", titleID: id, platform: platform, title: title, totalMinutes: minutes,
                imageURL: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/library_600x900.jpg",
                firstPlayedAt: Calendar.current.date(byAdding: .day, value: -180, to: .now),
                lastPlayedAt: Calendar.current.date(byAdding: .day, value: -index, to: .now),
                weeklyMinutes: platform == .switchConsole ? [110, 0, 0, 120, 0, 0, 130] : Array(repeating: 0, count: 7),
                trophiesEarned: earned, trophiesDefined: defined,
                platinumTrophiesEarned: defined > 0 && earned == defined ? 1 : 0
            )
            if platform == .switchConsole { game.weeklyEndingDayKey = DailyPlayActivity.dayKey(for: .now) }
            game.isFavorite = index == 0
            game.playStatus = index < 2 ? .playing : .completed
            container.mainContext.insert(game)
            games.append(game)
            for offset in 0..<10 {
                let day = Calendar.current.date(byAdding: .day, value: (offset - 9) * 3, to: .now) ?? .now
                container.mainContext.insert(PlaySnapshot(gameID: game.applicationID, accountID: "preview",
                    platform: platform, date: day, totalMinutes: minutes - (9 - offset) * 80,
                    trophiesEarned: max(0, earned - (9 - offset))))
                if platform == .switchConsole {
                    container.mainContext.insert(DailyPlayActivity(
                        activityID: DailyPlayActivity.recordID(platform: platform, accountID: "preview", titleID: id, day: day),
                        gameID: game.applicationID, accountID: "preview", titleID: id, platform: platform,
                        day: day, totalMinutes: 40 + offset * 10))
                }
            }
        }
        let scope = AccountScope.key(playStationAccountID: "preview", nintendoAccountID: "preview")
        let conversation = AIConversation(title: "下一场冒险，去哪里？", accountScopeKey: scope,
            games: AIGameContext.snapshot(games))
        conversation.messages = [
            AIChatMessage(role: .user, content: "为什么我总是想回到交界地？"),
            AIChatMessage(role: .assistant, content: "你喜欢的，是自己找到答案的那一刻。\n\n从《艾尔登法环》到《空洞骑士》，你的记录里总有一条共同的线索：愿意为了好奇心，走进一个陌生的世界。\n\n下一次重温，不妨放下攻略，选一条从没走过的小路。")
        ]
        container.mainContext.insert(conversation)
        let profile = AIProfileResult(accountScopeKey: scope, platformFilter: "全部", minimumHours: 1,
            text: "好奇心驱动的世界探索者\n\n你偏爱有秘密的世界，也愿意为一次真正的突破反复尝试。\n\n深度投入\n从交界地到像素农场，你总会给喜欢的作品留出足够的时间。\n\n下一场冒险\n试着放下目标，走一条从没走过的小路。", gameCount: games.count,
            totalMinutes: games.reduce(0) { $0 + $1.totalMinutes })
        container.mainContext.insert(profile)
        // Optional UI-only fixture reuses bundled artwork; no API request or real
        // account data is used and the container is always in memory.
        if ProcessInfo.processInfo.arguments.contains("--youji-image-preview"),
           let data = UIImage(named: "ArchiveWorld")?.pngData() {
            container.mainContext.insert(AIGeneratedImage(accountScopeKey: scope, ownerID: profile.id, origin: .profile,
                prompt: "界面预览用示例图片", modelName: "preview", pngData: data))
            let image = AIGeneratedImage(accountScopeKey: scope, ownerID: conversation.id, origin: .conversation,
                prompt: "界面预览用示例图片", modelName: "preview", pngData: data)
            container.mainContext.insert(image)
            conversation.messages += [
                AIChatMessage(role: .user, content: "画一个充满探索感的冒险世界", requestsImage: true),
                AIChatMessage(role: .assistant, content: "画像示例", imageID: image.id, imageDescription: "探索与冒险的游戏世界")
            ]
        }
        container.mainContext.insert(SavedGamePlan(accountScopeKey: scope, title: "重返交界地", note: "这次不看攻略，跟着好奇心走。\n\n先选一条没走过的小路，给自己半小时探索。遇到喜欢的风景就停下来，不急着追赶进度。\n\n如果想挑战一下，再试试以前没用过的武器。", gameID: games.first?.applicationID ?? "", sourceConversationID: conversation.id.uuidString))
        try container.mainContext.save()
        return container
    }
}

struct DesignPreviewRoot: View {
    private let container = try? DesignPreviewData.makeContainer()

    var body: some View {
        if let container {
            ScreenshotRouteView(route: ScreenshotRoute.launchRoute ?? .overview)
                .modelContainer(container)
        } else {
            ContentUnavailableView("预览数据未能加载", systemImage: "photo")
        }
    }
}
#endif
