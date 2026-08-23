#if DEBUG
import SwiftData
import SwiftUI

enum ScreenshotRoute: String, CaseIterable {
    case overview
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

    private var accountScopeKey: String { sync.currentAccountScopeKey }

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
        case .overview:
            DashboardView(initialFilter: .all)
        case .playStation:
            DashboardView(initialFilter: .playStation)
        case .switchConsole:
            DashboardView(initialFilter: .switchConsole)
        case .playCalendar:
            PlayCalendarView(accountID: sync.currentNintendoAccountID, games: currentGames)
        case .gameDetailSwitch:
            if let switchGame {
                GameDetailView(
                    game: switchGame,
                    accountScopeKey: accountScopeKey,
                    initialSection: .personal
                )
            } else {
                missingData("没有可截图的 Switch 游戏")
            }
        case .gameDetailPlayStation:
            if let playStationGame {
                GameDetailView(
                    game: playStationGame,
                    accountScopeKey: accountScopeKey,
                    initialSection: .personal
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
#endif
