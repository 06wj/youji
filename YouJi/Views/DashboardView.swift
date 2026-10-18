import Charts
import SwiftData
import SwiftUI

enum LibraryFilter: String, CaseIterable {
    case all = "总览"
    case playStation = "PlayStation"
    case switchConsole = "Switch"

    var platform: GamePlatform? {
        switch self {
        case .all: nil
        case .playStation: .playStation
        case .switchConsole: .switchConsole
        }
    }
}

private enum ConnectionSheet: String, Identifiable {
    case playStation
    case switchConsole
    var id: String { rawValue }
}

private enum GameSort: String, CaseIterable {
    case recentlyPlayed = "最近游玩"
    case playTime = "游玩时间"
    case trophies = "奖杯"

    var isPlayStationOnly: Bool {
        self == .trophies
    }
}

private enum LibraryScope: String, CaseIterable {
    case all = "全部"
    case favorites = "收藏"
    case active = "进行中"
    case hidden = "已隐藏"
}

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GameRecord.lastPlayedAt, order: .reverse) private var games: [GameRecord]
    @Query private var dailyActivities: [DailyPlayActivity]
    @Query private var snapshots: [PlaySnapshot]
    @StateObject private var sync = SyncCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @State private var referenceDate = Date.now
    @State private var showWeeklyReview = false
    @State private var connectionSheet: ConnectionSheet?
    @State private var showConnectionOptions = false
    @State private var filter: LibraryFilter = .all
    @State private var gameSort: GameSort = .playTime
	@State private var showAIAnalysis = false
	@State private var showSettings = false
    @State private var showAccountCenter = false
    @State private var showInsights = false
    @State private var showPlans = false
    @State private var selectedArchive: AccountArchiveSelection?
    @State private var selectedGame: GameRecord?
    @State private var searchText = ""
    @State private var libraryScope: LibraryScope = .all
    @AppStorage("library-cover-layout") private var usesCoverLayout = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(initialFilter: LibraryFilter = .all) {
        _filter = State(initialValue: initialFilter)
    }

    private var currentAccountGames: [GameRecord] {
        if let selectedArchive {
            return games.filter { $0.platform == selectedArchive.platform && $0.accountID == selectedArchive.accountID }
        }
        return AccountScope.visibleLibraryGames(
            games,
            playStationAccountID: sync.currentPlayStationAccountID,
            nintendoAccountID: sync.currentNintendoAccountID
        )
    }
    private var summaryGames: [GameRecord] {
        currentAccountGames.filter { !$0.shouldHideFromLibrary }
    }

    private var libraryScopedGames: [GameRecord] {
        switch libraryScope {
        case .all:
            return summaryGames
        case .favorites:
            return currentAccountGames.filter { $0.isFavorite && !$0.isManuallyHidden }
        case .active:
            return currentAccountGames.filter {
                ($0.playStatus == .playing || $0.playStatus == .replay) && !$0.isManuallyHidden
            }
        case .hidden:
            return currentAccountGames.filter(\.shouldHideFromLibrary)
        }
    }

    private var visibleGames: [GameRecord] {
        let filtered: [GameRecord]
        if let platform = filter.platform {
            filtered = libraryScopedGames.filter { $0.platform == platform }
        } else {
            filtered = libraryScopedGames
        }
        let searched = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? filtered
            : filtered.filter {
                $0.title.localizedCaseInsensitiveContains(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
                    || $0.personalNote.localizedCaseInsensitiveContains(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        switch gameSort {
        case .recentlyPlayed:
            return searched.sorted {
                ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
            }
        case .playTime:
            return searched.sorted {
                if $0.totalMinutes == $1.totalMinutes {
                    return ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
                }
                return $0.totalMinutes > $1.totalMinutes
            }
        case .trophies:
            return searched.sorted {
                let lhsPlatinum = $0.platinumTrophiesEarned > 0
                let rhsPlatinum = $1.platinumTrophiesEarned > 0
                if lhsPlatinum != rhsPlatinum {
                    return lhsPlatinum && !rhsPlatinum
                }
                let lhsProgress = trophyProgress(for: $0)
                let rhsProgress = trophyProgress(for: $1)
                if lhsProgress != rhsProgress { return lhsProgress > rhsProgress }
                return $0.totalMinutes > $1.totalMinutes
            }
        }
    }

    private func trophyProgress(for game: GameRecord) -> Double {
        guard game.trophiesDefined > 0 else { return -1 }
        return Double(game.trophiesEarned) / Double(game.trophiesDefined)
    }

    private var activityWindow: NintendoActivityWindow {
        NintendoActivityWindow.make(games: switchGames, activities: dailyActivities, now: referenceDate)
    }
    private var weeklyReview: LocalWeeklyReview {
        LocalWeeklyReview.make(games: currentAccountGames, snapshots: snapshots,
                               activities: dailyActivities, now: referenceDate)
    }
    private var isFirstUse: Bool {
        games.isEmpty && !sync.isPlayStationConnected && !sync.isNintendoConnected
    }
    private var recentGames: [GameRecord] {
        Array(summaryGames.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }.prefix(2))
    }

    private var playStationGames: [GameRecord] { summaryGames.filter { $0.platform == .playStation } }
    private var switchGames: [GameRecord] { summaryGames.filter { $0.platform == .switchConsole } }
    private var playStationMinutes: Int { playStationGames.reduce(0) { $0 + $1.totalMinutes } }
    private var switchMinutes: Int { switchGames.reduce(0) { $0 + $1.totalMinutes } }
    private var platinumGameCount: Int { playStationGames.filter { $0.platinumTrophiesEarned > 0 }.count }
    private var latestVisibleGame: GameRecord? {
        let platformGames = filter.platform.map { platform in
            summaryGames.filter { $0.platform == platform }
        } ?? summaryGames
        return platformGames.max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }
    }
    private var switchTopThisWeek: GameRecord? {
        let totals = activityWindow.gameMinutes
        return switchGames.filter { (totals[$0.applicationID] ?? 0) > 0 }
            .max { (totals[$0.applicationID] ?? 0) < (totals[$1.applicationID] ?? 0) }
    }
    private var displayedNintendoAccountID: String {
        if let selectedArchive { return selectedArchive.platform == .switchConsole ? selectedArchive.accountID : "" }
        return AccountScope.displayAccountID(for: .switchConsole, currentAccountID: sync.currentNintendoAccountID,
                                            games: currentAccountGames) ?? ""
    }
    private var activeAccountScopeKey: String {
        if let selectedArchive {
            return AccountScope.token(platform: selectedArchive.platform, accountID: selectedArchive.accountID)
        }
        return AccountScope.visibleScopeKey(
            for: games,
            playStationAccountID: sync.currentPlayStationAccountID,
            nintendoAccountID: sync.currentNintendoAccountID
        )
    }
    private var visiblePlayStationTrophies: PlayStationTrophySummary? {
        selectedArchive == nil ? sync.playStationTrophies : nil
    }
    private var hasLibraryRefinement: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || libraryScope != .all
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    header
                    if isFirstUse {
                        welcomeCard
                        syncStatus
                    } else {
                        platformPicker
                        if selectedArchive != nil { archiveBanner }
                        syncStatus
                        insightCard
                        if filter == .all, !recentGames.isEmpty {
                            recentGamesCard
                            weeklyReviewShortcut
                        }
                        if let receipt = visibleReceipt { syncReceiptCard(receipt) }
                        if filter == .switchConsole, selectedArchive == nil || selectedArchive?.platform == .switchConsole {
                            PlayCalendarSection(accountID: displayedNintendoAccountID, games: currentAccountGames)
                        }
                        if filter == .playStation, visiblePlayStationTrophies != nil { trophyCard }
                        library
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 38)
            }
            .background(appBackground)
            .foregroundStyle(YJColor.ink)
            .tint(YJColor.lime)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $connectionSheet) { sheet in
                switch sheet {
                case .playStation: ConnectPlayStationView(coordinator: sync)
                case .switchConsole: ConnectNintendoView(coordinator: sync)
                }
            }
			.sheet(isPresented: $showAIAnalysis) {
				AIAnalysisView(games: currentAccountGames, accountScopeKey: activeAccountScopeKey)
                    .presentationDetents([.large])
            }
			.sheet(isPresented: $showSettings) {
				SettingsView(sync: sync)
                    .presentationDetents([.large])
			}
            .sheet(isPresented: $showAccountCenter) {
                AccountCenterView(sync: sync, games: games, selectedArchive: $selectedArchive)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showInsights) {
                InsightsView(games: currentAccountGames, accountScopeKey: activeAccountScopeKey)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showPlans) {
                SavedPlansView(accountScopeKey: activeAccountScopeKey)
                    .presentationDetents([.large])
            }
            .sheet(item: $selectedGame) { game in
                GameDetailView(game: game, accountScopeKey: activeAccountScopeKey)
                    .presentationDetents([.large])
            }
            .confirmationDialog("连接游戏平台", isPresented: $showConnectionOptions, titleVisibility: .visible) {
                Button(sync.isPlayStationConnected ? "PlayStation 已连接" : "连接 PlayStation") { connectionSheet = .playStation }
                Button(sync.isNintendoConnected ? "Switch 已连接" : "连接 Nintendo Switch") { connectionSheet = .switchConsole }
                Button("取消", role: .cancel) {}
            }
            .alert("本地记录未能保存", isPresented: Binding(
                get: { sync.errorMessage != nil && sync.syncIssue == nil && connectionSheet == nil },
                set: { if !$0 { sync.errorMessage = nil } }
            )) {
                Button("重试保存") { sync.backfillNintendoDailyActivities(modelContext: modelContext, force: true) }
                Button("稍后", role: .cancel) { sync.errorMessage = nil }
            } message: { Text("已有记录仍保留，请稍后重试。") }
            .sheet(isPresented: $showWeeklyReview) {
                WeeklyReviewView(review: weeklyReview, accountScopeKey: activeAccountScopeKey)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { referenceDate = .now }
            }
            .onChange(of: sync.isSyncing) { _, isSyncing in
                if !isSyncing { referenceDate = .now }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in referenceDate = .now }
            .task {
                sync.backfillNintendoDailyActivities(modelContext: modelContext)
            }
            .onReceive(NotificationCenter.default.publisher(for: .youJiLocalDataDidReset)) { _ in
                sync.resetNonCredentialState()
                selectedArchive = nil
            }
            .onChange(of: selectedArchive) { _, archive in
                guard let archive else { return }
                filter = archive.platform == .playStation ? .playStation : .switchConsole
                searchText = ""
                libraryScope = .all
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("BrandIcon")
                .resizable().scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(YJColor.line))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("游迹").font(.title3.bold()).tracking(2)
                Text("PLAYLOG / 玩家档案")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(1.2).foregroundStyle(YJColor.muted)
            }
            Spacer(minLength: 4)
            platformSyncButton(.playStation)
            platformSyncButton(.switchConsole)
            Menu {
                Button { showAccountCenter = true } label: { Label("账号与同步", systemImage: "person.crop.circle") }
                Button { showPlans = true } label: { Label("待玩与重温", systemImage: "bookmark") }
                Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(YJColor.ink)
                    .frame(width: 44, height: 44)
                    .background(YJColor.card, in: Circle())
                    .overlay(Circle().strokeBorder(YJColor.line))
            }
            .accessibilityLabel("更多功能")
        }.padding(.top, 8)
    }

    private var visibleReceipt: PlatformSyncReceipt? {
        guard selectedArchive == nil else { return nil }
        return switch filter {
        case .playStation: sync.playStationReceipt
        case .switchConsole: sync.nintendoReceipt
        case .all: nil
        }
    }

    private var archiveBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill").foregroundStyle(YJColor.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在查看本地历史档案").font(.caption.bold())
                if let selectedArchive {
                    Text("\(selectedArchive.platform.rawValue) · 账号尾号 …\(selectedArchive.accountID.suffix(6))")
                        .font(.caption2).foregroundStyle(YJColor.muted)
                }
            }
            Spacer()
            Button("返回当前") { selectedArchive = nil }
                .font(.caption.bold()).buttonStyle(.bordered)
        }
        .padding(13)
        .background(YJColor.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
    }

    private func syncReceiptCard(_ receipt: PlatformSyncReceipt) -> some View {
        let highlights = [
            receipt.addedMinutes > 0 ? "+\(format(minutes: receipt.addedMinutes))" : nil,
            receipt.addedGames > 0 ? "新收录 \(receipt.addedGames) 款" : nil,
            receipt.platform == .playStation && receipt.addedTrophies > 0 ? "新增 \(receipt.addedTrophies) 个奖杯" : nil
        ].compactMap { $0 }
        return HStack(spacing: 12) {
            Image(systemName: receipt.trophyFailures > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(receipt.trophyFailures > 0 ? YJColor.coral : YJColor.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(receipt.platform.shortName) 上次同步结果").font(.caption.bold())
                Text(receipt.syncedAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption2).foregroundStyle(YJColor.muted)
                Text(highlights.isEmpty ? "上次同步未发现变化" : highlights.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(YJColor.muted)
                if receipt.trophyFailures > 0 {
                    Text("\(receipt.trophyFailures) 项奖杯数据将在下次同步重试")
                        .font(.caption2).foregroundStyle(YJColor.coral)
                }
            }
            Spacer()
            Button("同步详情") { showAccountCenter = true }.font(.caption.bold())
        }
        .padding(14)
        .youjiCard()
    }

    private func platformSyncButton(_ platform: GamePlatform) -> some View {
        let connected = platform == .playStation ? sync.isPlayStationConnected : sync.isNintendoConnected
        let color = YJColor.platform(platform)
        return Button {
            startSyncOrConnect(platform)
        } label: {
            HStack(spacing: 5) {
                if sync.syncProgress?.platform == platform {
                    ProgressView().tint(.white).controlSize(.mini)
                } else {
                    Text(platform.shortName)
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                    Image(systemName: connected ? "arrow.triangle.2.circlepath" : "link")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(color)
            .frame(width: 45, height: 44)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.2)))
        }
        .accessibilityLabel("\(connected ? "同步" : "连接") \(platform.rawValue)")
        .disabled(sync.isSyncing)
        .buttonStyle(.plain)
        .opacity(sync.isSyncing && sync.syncProgress?.platform != platform ? 0.48 : 1)
    }

    private var platformPicker: some View {
        HStack(spacing: 4) {
            ForEach(LibraryFilter.allCases, id: \.self) { item in
                Button {
                    withAnimation(.snappy(duration: 0.24)) {
                        filter = item
                        if item != .playStation, gameSort.isPlayStationOnly { gameSort = .playTime }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: platformIcon(item)).font(.caption.bold())
                        Text(dynamicTypeSize.isAccessibilitySize ? (item.platform?.shortName ?? item.rawValue) : item.rawValue)
                            .font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(filter == item ? activeTabColor(item) : YJColor.muted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(filter == item ? activeTabColor(item).opacity(0.11) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottom) {
                        if filter == item { Capsule().fill(activeTabColor(item)).frame(width: 22, height: 2) }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(filter == item ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(YJColor.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(YJColor.line))
    }

    @ViewBuilder
    private var insightCard: some View {
        switch filter {
        case .all: overviewInsightCard
        case .playStation: playStationInsightCard
        case .switchConsole: switchInsightCard
        }
    }

    private var overviewInsightCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("你的游戏档案").font(.caption).foregroundStyle(YJColor.muted)
                    Text(format(minutes: playStationMinutes + switchMinutes))
                        .font(.system(.title2, design: .rounded, weight: .bold))
                }
                Spacer(minLength: 0)
                Text("\(summaryGames.count) 款").font(.subheadline.bold()).foregroundStyle(YJColor.lime)
            }
            adaptiveHeroLayout {
                freshnessButton(.playStation)
                freshnessButton(.switchConsole)
            }
            adaptiveHeroLayout {
                overviewHeroShortcut("洞察", icon: "chart.xyaxis.line") { showInsights = true }
                overviewHeroShortcut("游戏大脑", icon: "sparkles") { showAIAnalysis = true }
                overviewHeroShortcut("待玩", icon: "bookmark") { showPlans = true }
            }
        }
        .padding(18)
        .background(YJArtwork(name: "ArchiveWorld", shade: 0.66))
        .youjiCard()
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("YOUR ADVENTURE STARTS HERE")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .tracking(1).foregroundStyle(YJColor.lime)
                Text("把玩过的世界，\n收进自己的档案。")
                    .font(.system(.title, design: .rounded, weight: .bold))
                Text("连接一个平台，就能看到游戏时长、最近活动和属于你的收藏墙。")
                    .font(.subheadline).foregroundStyle(YJColor.ink.opacity(0.8)).lineSpacing(4)
            }
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
            .padding(20).background(YJArtwork(name: "ArchiveWorld", shade: 0.3))
            VStack(spacing: 12) {
                welcomeConnection(.playStation)
                welcomeConnection(.switchConsole)
                Label("记录保存在本机，连接与同步由你决定。", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(YJColor.muted)
            }.padding(.horizontal, 20).padding(.bottom, 20)
        }.youjiCard()
    }

    private func welcomeConnection(_ platform: GamePlatform) -> some View {
        Button { startSyncOrConnect(platform) } label: {
            Label("连接 \(platform.rawValue)", systemImage: platform == .playStation ? "playstation.logo" : "gamecontroller")
                .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(YJColor.platform(platform))
                .background(YJColor.platform(platform).opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).disabled(sync.isSyncing)
    }

    @ViewBuilder
    private var syncStatus: some View {
        if let progress = sync.syncProgress {
            PlatformSyncProgressCard(progress: progress)
        } else {
            ForEach(GamePlatform.allCases, id: \.self) { platform in
                if let issue = sync.issue(for: platform), selectedArchive == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(issue.isPartialSuccess ? "\(platform.shortName) 记录已保存，部分内容待补全" : "\(platform.shortName) 需要你处理一下",
                              systemImage: "exclamationmark.circle")
                            .font(.subheadline.bold()).foregroundStyle(YJColor.coral)
                        Text(issue.message).font(.caption).foregroundStyle(YJColor.muted)
                        HStack {
                            Button(issue.actionTitle) { recover(issue) }.font(.caption.bold())
                            Spacer(minLength: 0)
                            Button("稍后") { sync.clearIssue(for: platform) }.font(.caption).foregroundStyle(YJColor.muted)
                        }
                    }.padding(16).youjiCard()
                }
            }
        }
    }

    private func recover(_ issue: PlatformSyncIssue) {
        if issue.recovery == .reconnect {
            connectionSheet = issue.platform == .playStation ? .playStation : .switchConsole
        } else {
            startSyncOrConnect(issue.platform)
        }
    }

    private func startSyncOrConnect(_ platform: GamePlatform) {
        guard !sync.isSyncing else { return }
        let connected = platform == .playStation ? sync.isPlayStationConnected : sync.isNintendoConnected
        guard connected else {
            connectionSheet = platform == .playStation ? .playStation : .switchConsole
            return
        }
        Task {
            if platform == .playStation { try? await sync.syncPlayStation(modelContext: modelContext) }
            else { try? await sync.syncNintendo(modelContext: modelContext) }
        }
    }

    private func freshnessDate(_ platform: GamePlatform) -> Date? {
        let stored = currentAccountGames.filter { $0.platform == platform }.map(\.updatedAt).max()
        guard selectedArchive == nil else { return stored }
        return (platform == .playStation ? sync.lastPlayStationSyncAt : sync.lastNintendoSyncAt) ?? stored
    }

    private func freshnessButton(_ platform: GamePlatform) -> some View {
        Button { showAccountCenter = true } label: {
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(YJColor.platform(platform)).frame(width: 5, height: 5).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(platform.rawValue).font(.caption.bold()).foregroundStyle(YJColor.ink)
                    if let date = freshnessDate(platform) {
                        Text("\(selectedArchive == nil && (platform == .playStation ? sync.isPlayStationConnected : sync.isNintendoConnected) ? "更新于" : "本机记录") \(date.formatted(.dateTime.year().month().day().hour().minute()))")
                            .font(.caption2).foregroundStyle(YJColor.muted)
                    } else {
                        Text((platform == .playStation ? sync.isPlayStationConnected : sync.isNintendoConnected) ? "等待首次同步" : "尚未连接")
                            .font(.caption2).foregroundStyle(YJColor.muted)
                    }
                }
                Spacer(minLength: 0)
            }
        }.buttonStyle(.plain)
    }

    private var recentGamesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近游玩").font(.headline)
            ForEach(recentGames, id: \.applicationID) { game in
                recentGameLine(game, eyebrow: game.lastPlayedAt?.formatted(.dateTime.month().day()) ?? "已收录")
            }
        }.padding(16).youjiCard()
    }

    private var weeklyReviewShortcut: some View {
        Button { showWeeklyReview = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar").foregroundStyle(YJColor.lime)
                VStack(alignment: .leading, spacing: 4) {
                    Text("近 7 天回顾").font(.subheadline.bold()).foregroundStyle(YJColor.ink)
                    Text(weeklyReview.games.isEmpty ? "回看本机记录，积累每一段冒险" : "\(weeklyReview.games.count) 款游戏 · 已记录 \(format(minutes: weeklyReview.totalMinutes))")
                        .font(.caption).foregroundStyle(YJColor.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(YJColor.muted)
            }.padding(16).youjiCard()
        }.buttonStyle(.plain)
    }

    private var adaptiveHeroLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    private func overviewHeroShortcut(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(YJColor.lime)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.caption.bold())
            .foregroundStyle(YJColor.ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(YJColor.elevated, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var playStationInsightCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroTitle("PLAYSTATION / 最近游玩", value: compactHours(playStationMinutes))
            freshnessButton(.playStation)
            if let latestVisibleGame {
                recentGameLine(
                    latestVisibleGame,
                    eyebrow: latestVisibleGame.lastPlayedAt?.formatted(.relative(presentation: .named)) ?? "最近同步"
                )
            } else {
                Text("同步 PlayStation 后显示最近游玩的游戏")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            adaptiveHeroLayout {
                heroMiniStat(value: "\(playStationGames.count)", label: "游戏")
                heroMiniStat(value: "\(platinumGameCount)", label: "白金")
                heroMiniStat(value: visiblePlayStationTrophies.map { "\($0.total)" } ?? "—", label: "奖杯")
            }
        }
        .padding(22)
        .background {
            YJArtwork(name: "ArchiveWorld", shade: 0.55)
                .overlay(YJColor.playStation.opacity(0.10))
        }
        .youjiCard()
    }

    private var switchInsightCard: some View {
        let window = activityWindow
        return VStack(alignment: .leading, spacing: 14) {
            heroTitle("SWITCH / 近 7 天已记录", value: window.hasRecords ? format(minutes: window.totalMinutes) : "等待同步")
            freshnessButton(.switchConsole)
            if let first = window.days.first, let last = window.days.last {
                Text("\(first.day.formatted(.dateTime.month().day())) — \(last.day.formatted(.dateTime.month().day())) · 有游玩记录 \(window.activeDays) 天")
                    .font(.caption2).foregroundStyle(YJColor.muted)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(window.days) { day in
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            Color.clear.frame(height: 65)
                            if let minutes = day.recordedMinutes {
                                if minutes > 0 {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(YJColor.nintendo.opacity(day.isPartial ? 0.45 : 0.85))
                                        .frame(height: max(3, 65 * Double(minutes) / Double(max(window.days.compactMap(\.recordedMinutes).max() ?? 1, 1))))
                                } else {
                                    Text("0").font(.caption2).foregroundStyle(YJColor.muted)
                                }
                            } else {
                                Text("—").font(.caption).foregroundStyle(YJColor.muted)
                            }
                        }
                        Text(day.day.formatted(.dateTime.month(.defaultDigits).day()))
                            .font(.caption2).foregroundStyle(YJColor.muted).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.day.formatted(.dateTime.month().day()))，\(day.recordedMinutes.map { format(minutes: $0) } ?? "缺少记录")\(day.isPartial ? "，部分游戏待同步" : "")")
                }
            }
            if window.incompleteDays > 0 {
                Text("\(window.incompleteDays) 天记录尚不完整；— 表示未记录，不等于没有玩。")
                    .font(.caption2).foregroundStyle(YJColor.muted)
            }
            if let game = switchTopThisWeek {
                recentGameLine(game, eyebrow: "近 7 天最常玩 · \(format(minutes: window.gameMinutes[game.applicationID] ?? 0))")
            }
        }
        .padding(20).background(YJArtwork(name: "TwilightCamp", shade: 0.55)).youjiCard()
    }

    private func heroTitle(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(1.1).foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private func platformMetric(name: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(name).font(.caption).foregroundStyle(YJColor.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(.title3, design: .rounded, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
                Text(detail).font(.caption2).foregroundStyle(YJColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentGameLine(_ game: GameRecord, eyebrow: String) -> some View {
        Button { selectedGame = game } label: {
            HStack(spacing: 11) {
                CachedCoverImage(urlString: game.imageURL)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(eyebrow).font(.caption2).foregroundStyle(.white.opacity(0.55))
                    Text(game.title).font(.subheadline.bold()).foregroundStyle(.white).lineLimit(1)
                }
                Spacer()
                Text(compactHours(game.totalMinutes)).font(.caption.bold()).foregroundStyle(.white.opacity(0.72))
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 2)
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开游戏档案")
    }

    private func heroMiniStat(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.headline.bold()).foregroundStyle(.white)
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var trophyCard: some View {
        Group {
            if let trophies = visiblePlayStationTrophies {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TROPHIES / 奖杯")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .tracking(1.2).foregroundStyle(YJColor.muted)
                            Text("等级 \(trophies.trophyLevel)").font(.title.bold())
                        }
                        Spacer()
                        Image(systemName: "trophy.fill")
                            .font(.title2).foregroundStyle(.yellow)
                            .frame(width: 46, height: 46)
                            .background(YJColor.elevated, in: RoundedRectangle(cornerRadius: 14))
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("距离下一等级").font(.caption).foregroundStyle(YJColor.muted)
                            Spacer()
                            Text("\(trophies.progress)%").font(.caption.bold())
                        }
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(YJColor.line)
                                Capsule().fill(YJColor.purple)
                                    .frame(width: proxy.size.width * min(CGFloat(trophies.progress) / 100, 1))
                            }
                        }.frame(height: 7)
                    }

                    HStack(spacing: 8) {
                        trophyCount("白金", value: trophies.earnedTrophies.platinum, color: Color(red: 0.63, green: 0.82, blue: 0.93))
                        trophyCount("金", value: trophies.earnedTrophies.gold, color: .yellow)
                        trophyCount("银", value: trophies.earnedTrophies.silver, color: Color(red: 0.70, green: 0.72, blue: 0.76))
                        trophyCount("铜", value: trophies.earnedTrophies.bronze, color: Color(red: 0.72, green: 0.40, blue: 0.20))
                    }
                }
                .padding(18)
                .youjiCard()
            }
        }
    }

    private func trophyCount(_ label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: "trophy.fill").font(.caption).foregroundStyle(color)
            Text("\(value)").font(.headline.bold())
            Text(label).font(.caption2).foregroundStyle(YJColor.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12))
    }

    private var library: some View {
        let libraryGames = visibleGames

        return VStack(alignment: .leading, spacing: 14) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    libraryHeading(count: libraryGames.count)
                    HStack { Spacer(minLength: 0); libraryTools }
                }
            } else {
                HStack(spacing: 8) {
                    libraryHeading(count: libraryGames.count)
                    Spacer(minLength: 4)
                    libraryTools
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(YJColor.muted)
                TextField("搜索游戏或私人备注", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(YJColor.muted)
                        .accessibilityLabel("清除搜索")
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 14).padding(.vertical, 14)
            .background(YJColor.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(YJColor.line))

            if libraryGames.isEmpty {
                emptyLibrary
            } else {
                if usesCoverLayout && !dynamicTypeSize.isAccessibilitySize {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], spacing: 16) {
                        ForEach(libraryGames, id: \.applicationID) { game in
                            Button { selectedGame = game } label: { GameCoverCard(game: game) }
                                .buttonStyle(.plain)
                                .accessibilityHint("打开游戏档案")
                        }
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(libraryGames, id: \.applicationID) { game in
                            Button { selectedGame = game } label: { GameRow(game: game) }
                                .buttonStyle(.plain)
                                .accessibilityHint("打开游戏档案")
                        }
                    }
                }
            }
        }
    }

    private func libraryHeading(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("COLLECTION").font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(2).foregroundStyle(YJColor.muted)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("我的游戏库").font(.title3.bold())
                Text("\(count)").font(.caption.bold()).foregroundStyle(YJColor.muted)
            }
        }
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
    }

    private var libraryTools: some View {
        HStack(spacing: 8) {
                Button { usesCoverLayout.toggle() } label: {
                    Image(systemName: usesCoverLayout ? "list.bullet" : "square.grid.2x2")
                        .font(.subheadline).frame(width: 44, height: 44)
                        .foregroundStyle(YJColor.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(usesCoverLayout ? "切换列表" : "切换封面墙")
                Menu {
                    ForEach(LibraryScope.allCases, id: \.self) { scope in
                        Button {
                            libraryScope = scope
                        } label: {
                            if scope == libraryScope {
                                Label(scope.rawValue, systemImage: "checkmark")
                            } else {
                                Text(scope.rawValue)
                            }
                        }
                    }
                } label: {
                    Label(libraryScope.rawValue, systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption.bold())
                        .foregroundStyle(YJColor.ink)
                }
                Menu {
                    ForEach(GameSort.allCases.filter { filter == .playStation || !$0.isPlayStationOnly }, id: \.self) { option in
                        Button {
                            gameSort = option
                        } label: {
                            if option == gameSort {
                                Label(option.rawValue, systemImage: "checkmark")
                            } else {
                                Text(option.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption.bold())
                        .foregroundStyle(YJColor.ink)
                        .frame(width: 44, height: 44)
                        .background(YJColor.card, in: Circle())
                        .overlay(Circle().stroke(YJColor.line))
                }
                .accessibilityLabel("排序：\(gameSort.rawValue)")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Image("BrandIcon")
                .resizable().scaledToFill()
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .shadow(color: YJColor.purple.opacity(0.2), radius: 12, y: 6)
            Text(emptyTitle).font(.headline)
            Text(emptyMessage).font(.caption).foregroundStyle(YJColor.muted).multilineTextAlignment(.center)
            Button(emptyButtonTitle, action: resolveEmptyState)
            .buttonStyle(YJPrimaryButtonStyle())
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .youjiCard()
    }

    private var emptyPlatform: GamePlatform? {
        if let platform = filter.platform { return platform }
        if sync.isPlayStationConnected { return .playStation }
        if sync.isNintendoConnected { return .switchConsole }
        return nil
    }
    private var emptyReason: LibraryEmptyReason {
        let platformGames = currentAccountGames.filter { filter.platform == nil || $0.platform == filter.platform }
        let connected = emptyPlatform.map { $0 == .playStation ? sync.isPlayStationConnected : sync.isNintendoConnected } ?? false
        let synced = emptyPlatform.flatMap { $0 == .playStation ? sync.lastPlayStationSyncAt : sync.lastNintendoSyncAt }
        let hasIssue = emptyPlatform.flatMap { sync.issue(for: $0) } != nil
        return LibraryEmptyReason.resolve(isConnected: connected, hasSynced: synced != nil,
                                          recordCount: platformGames.count, visibleCount: platformGames.filter { !$0.shouldHideFromLibrary }.count,
                                          hasIssue: hasIssue)
    }
    private var hasOtherArchives: Bool {
        currentAccountGames.isEmpty && games.contains { filter.platform == nil || $0.platform == filter.platform }
    }
    private var emptyTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "没有找到匹配的游戏" }
        switch libraryScope {
        case .favorites: return "还没有收藏游戏"
        case .active: return "还没有进行中的游戏"
        case .hidden: return "没有已隐藏的游戏"
        case .all: break
        }
        if hasOtherArchives { return "本机还有历史档案" }
        if let archive = selectedArchive, filter.platform != archive.platform { return "这个档案没有该平台的记录" }
        switch emptyReason {
        case .disconnected: return "先连接一个游戏平台"
        case .awaitingSync: return "账号已连接，等待首次同步"
        case .noRecords: return "同步完成，还没有读到游戏"
        case .hidden(let count): return "\(count) 款游戏已被隐藏"
        case .failed: return "这次读取还未完成"
        }
    }
    private var emptyMessage: String {
        if hasLibraryRefinement { return "调整关键词或清除筛选，继续浏览游戏库。" }
        if hasOtherArchives { return "选择要查看的账号档案，已有记录仍保留在这台设备。" }
        if let archive = selectedArchive, filter.platform != archive.platform { return "历史档案只包含原账号所在平台的本地记录。" }
        switch emptyReason {
        case .disconnected: return "连接后，游戏时间和最近冒险会收进你的本地档案。"
        case .awaitingSync: return "点按同步，读取这个账号的游玩记录。"
        case .noRecords: return "请确认连接的是游玩所用账号；Switch 账号需要关联主机用户。也可以稍后重试。"
        case .hidden: return "隐藏不会删除记录，你可以查看并恢复展示。"
        case .failed: return "已有记录仍保留，请根据上方提示重试或重新连接。"
        }
    }
    private var emptyButtonTitle: String {
        if hasLibraryRefinement { return "清除搜索与筛选" }
        if hasOtherArchives { return "选择历史档案" }
        if let archive = selectedArchive, filter.platform != archive.platform { return "查看档案平台" }
        switch emptyReason {
        case .disconnected: return emptyPlatform.map { "连接 \($0.rawValue)" } ?? "连接游戏平台"
        case .awaitingSync: return "立即同步"
        case .noRecords: return "检查账号与同步"
        case .hidden: return "查看已隐藏游戏"
        case .failed: return emptyPlatform.flatMap { sync.issue(for: $0)?.actionTitle } ?? "重试同步"
        }
    }
    private func resolveEmptyState() {
        if hasLibraryRefinement { searchText = ""; libraryScope = .all; return }
        if hasOtherArchives { showAccountCenter = true; return }
        if let archive = selectedArchive, filter.platform != archive.platform {
            filter = archive.platform == .playStation ? .playStation : .switchConsole
            return
        }
        switch emptyReason {
        case .hidden: libraryScope = .hidden
        case .noRecords: showAccountCenter = true
        case .failed:
            if let platform = emptyPlatform, let issue = sync.issue(for: platform) { recover(issue) }
            else { showAccountCenter = true }
        case .disconnected, .awaitingSync:
            if let platform = emptyPlatform { startSyncOrConnect(platform) }
            else { showConnectionOptions = true }
        }
    }

    private func format(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func compactHours(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
    }

    private var appBackground: some View { YJBackground() }

    private func platformIcon(_ item: LibraryFilter) -> String {
        switch item {
        case .all: "square.grid.2x2.fill"
        case .playStation: "playstation.logo"
        case .switchConsole: "gamecontroller.fill"
        }
    }

    private func activeTabColor(_ item: LibraryFilter) -> Color {
        switch item {
        case .all: YJColor.lime
        case .playStation: YJColor.playStation
        case .switchConsole: YJColor.nintendo
        }
    }

}

private struct GameCoverCard: View {
    let game: GameRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1.08, contentMode: .fit)
                .overlay { CachedCoverImage(urlString: game.imageURL) }
                .clipped()
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .topLeading) {
                    PlatformBadge(platform: game.platform)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                }
                .overlay(alignment: .bottomTrailing) {
                    if game.platform == .playStation, game.platinumTrophiesEarned > 0 {
                        PlatinumBadge().padding(8)
                    } else if game.isFavorite {
                        Image(systemName: "heart.fill").foregroundStyle(YJColor.coral).padding(10)
                    }
                }
            VStack(alignment: .leading, spacing: 9) {
                Text(game.title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(YJColor.ink).lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(game.totalMinutes < 60 ? game.totalMinutes : game.totalMinutes / 60)")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(YJColor.ink)
                    Text(game.totalMinutes < 60 ? "分钟" : "小时").font(.caption2).foregroundStyle(YJColor.muted)
                    Spacer(minLength: 0)
                    if game.playStatus != .played {
                        Text(game.playStatus.rawValue).font(.system(size: 9, weight: .medium))
                            .foregroundStyle(YJColor.lime)
                    }
                }
                if game.platform == .playStation, game.trophiesDefined > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "trophy").foregroundStyle(YJColor.playStation)
                        Text("\(game.trophiesEarned) / \(game.trophiesDefined)")
                        Spacer(minLength: 0)
                        Text("\(Int((Double(game.trophiesEarned) / Double(game.trophiesDefined) * 100).rounded()))%")
                    }
                    .font(.caption2).foregroundStyle(YJColor.muted)
                    ProgressView(value: min(Double(game.trophiesEarned) / Double(game.trophiesDefined), 1))
                        .tint(game.platinumTrophiesEarned > 0 ? YJColor.lime : YJColor.playStation)
                } else {
                    Text(game.lastPlayedAt?.formatted(.relative(presentation: .named)) ?? "已收录")
                        .font(.caption2).foregroundStyle(YJColor.muted)
                        .padding(.bottom, 13)
                }
            }
            .padding(12)
        }
        .youjiCard()
        .accessibilityElement(children: .combine)
    }
}

private struct GameRow: View {
    let game: GameRecord

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CachedCoverImage(urlString: game.imageURL)
                .frame(width: 80, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    PlatformBadge(platform: game.platform)
                    if game.isFavorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(YJColor.coral) }
                    Spacer(minLength: 0)
                    if game.platform == .playStation, game.platinumTrophiesEarned > 0 { PlatinumBadge() }
                }
                Text(game.title).font(.subheadline.bold()).foregroundStyle(YJColor.ink).fixedSize(horizontal: false, vertical: true)
                Text("\(game.totalMinutes / 60)h \(game.totalMinutes % 60)m")
                    .font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(YJColor.ink)
                if game.platform == .playStation, game.trophiesDefined > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "trophy").foregroundStyle(YJColor.playStation)
                        Text("\(game.trophiesEarned) / \(game.trophiesDefined)")
                        ProgressView(value: min(Double(game.trophiesEarned) / Double(game.trophiesDefined), 1))
                            .tint(YJColor.playStation)
                    }
                    .font(.caption2).foregroundStyle(YJColor.muted)
                }
                HStack {
                    Text(game.lastPlayedAt?.formatted(.relative(presentation: .named)) ?? "已收录")
                    if game.playStatus != .played { Text(game.playStatus.rawValue).foregroundStyle(YJColor.lime) }
                }
                .font(.caption2).foregroundStyle(YJColor.muted)
            }
        }
        .padding(14)
        .youjiCard()
        .accessibilityElement(children: .combine)
    }
}
