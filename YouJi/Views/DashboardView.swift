import Charts
import SwiftData
import SwiftUI

private enum LibraryFilter: String, CaseIterable {
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
    @StateObject private var sync = SyncCoordinator()
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
    @State private var syncingPlatform: GamePlatform?

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

    private var week: [Int] {
        switchGames.reduce(Array(repeating: 0, count: 7)) { result, game in
            zip(result, game.weeklyMinutes).map(+)
        }
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
        switchGames.max { $0.weeklyMinutes.reduce(0, +) < $1.weeklyMinutes.reduce(0, +) }
    }
    private var activeAccountScopeKey: String {
        if let selectedArchive {
            return AccountScope.token(platform: selectedArchive.platform, accountID: selectedArchive.accountID)
        }
        return sync.currentAccountScopeKey
    }
    private var visiblePlayStationTrophies: PlayStationTrophySummary? {
        selectedArchive == nil ? sync.playStationTrophies : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 22) {
                    header
                    platformPicker
                    if selectedArchive != nil { archiveBanner }
                    insightCard
                    if let receipt = visibleReceipt { syncReceiptCard(receipt) }
                    if filter != .playStation {
                        PlayCalendarSection(
                            accountID: selectedArchive?.platform == .switchConsole
                                ? selectedArchive?.accountID ?? ""
                                : (selectedArchive == nil ? sync.currentNintendoAccountID : ""),
                            games: currentAccountGames
                        )
                    }
                    if filter == .playStation, visiblePlayStationTrophies != nil { trophyCard }
                    library
                    privacyNote
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 38)
            }
            .background(appBackground)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $connectionSheet) { sheet in
                switch sheet {
                case .playStation: ConnectPlayStationView(coordinator: sync)
                case .switchConsole: ConnectNintendoView(coordinator: sync)
                }
            }
			.sheet(isPresented: $showAIAnalysis) {
				AIAnalysisView(games: currentAccountGames, accountScopeKey: activeAccountScopeKey)
            }
			.sheet(isPresented: $showSettings) {
				SettingsView(sync: sync)
			}
            .sheet(isPresented: $showAccountCenter) {
                AccountCenterView(sync: sync, games: games, selectedArchive: $selectedArchive)
            }
            .sheet(isPresented: $showInsights) {
                InsightsView(games: currentAccountGames, accountScopeKey: activeAccountScopeKey)
            }
            .sheet(isPresented: $showPlans) {
                SavedPlansView(accountScopeKey: activeAccountScopeKey)
            }
            .sheet(item: $selectedGame) { game in
                GameDetailView(game: game)
            }
            .confirmationDialog("连接游戏平台", isPresented: $showConnectionOptions, titleVisibility: .visible) {
                Button(sync.isPlayStationConnected ? "PlayStation 已连接" : "连接 PlayStation") { connectionSheet = .playStation }
                Button(sync.isNintendoConnected ? "Switch 已连接" : "连接 Nintendo Switch") { connectionSheet = .switchConsole }
                Button("取消", role: .cancel) {}
            }
            .alert("同步失败", isPresented: Binding(
                get: { sync.errorMessage != nil && connectionSheet == nil },
                set: { if !$0 { sync.errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(sync.errorMessage ?? "未知错误")
            }
            .task {
                sync.backfillNintendoDailyActivities(modelContext: modelContext)
            }
            .onReceive(NotificationCenter.default.publisher(for: .youJiLocalDataDidReset)) { _ in
                sync.resetNonCredentialState()
                selectedArchive = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image("BrandIcon")
                .resizable().scaledToFill()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.65), lineWidth: 1))
                .shadow(color: YJColor.purple.opacity(0.18), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text("游迹").font(.headline.bold())
                Text("PLAYLOG").font(.system(size: 8, weight: .black, design: .monospaced)).tracking(2).foregroundStyle(YJColor.muted)
            }
            Spacer()
            platformSyncButton(.playStation)
            platformSyncButton(.switchConsole)
			Button { showAIAnalysis = true } label: {
				HStack(spacing: 4) {
					Image(systemName: "sparkles")
					Text("AI")
				}
				.font(.system(size: 9, weight: .black, design: .rounded))
				.foregroundStyle(.white)
				.frame(width: 45, height: 36)
				.background(YJColor.purple, in: Capsule())
			}
			.buttonStyle(.plain)
			.accessibilityLabel("AI 游戏分析")
			Menu {
                Button { showAccountCenter = true } label: { Label("账号与同步", systemImage: "person.crop.circle") }
                Button { showInsights = true } label: { Label("游玩洞察", systemImage: "chart.line.uptrend.xyaxis") }
                Button { showPlans = true } label: { Label("待玩与重温", systemImage: "bookmark") }
                Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
            } label: {
				Image(systemName: "ellipsis")
					.font(.caption.bold())
					.foregroundStyle(YJColor.ink)
					.frame(width: 36, height: 36)
					.background(Color.white.opacity(0.72), in: Circle())
					.overlay(Circle().stroke(Color.white.opacity(0.85)))
			}
			.accessibilityLabel("更多功能")
        }.padding(.top, 8)
    }

    private var visibleReceipt: PlatformSyncReceipt? {
        guard selectedArchive == nil else { return nil }
        return switch filter {
        case .playStation: sync.playStationReceipt
        case .switchConsole: sync.nintendoReceipt
        case .all:
            [sync.playStationReceipt, sync.nintendoReceipt]
                .compactMap { $0 }
                .max { $0.syncedAt < $1.syncedAt }
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
        HStack(spacing: 12) {
            Image(systemName: receipt.trophyFailures > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(receipt.trophyFailures > 0 ? YJColor.coral : YJColor.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text("上次 \(receipt.platform.shortName) 同步变化").font(.caption.bold())
                Text("新增 \(receipt.addedGames) 款 · 更新 \(receipt.changedGames) 款 · +\(format(minutes: receipt.addedMinutes))")
                    .font(.caption2).foregroundStyle(YJColor.muted)
                if receipt.trophyFailures > 0 {
                    Text("\(receipt.trophyFailures) 项奖杯数据将在下次同步重试")
                        .font(.caption2).foregroundStyle(YJColor.coral)
                }
            }
            Spacer()
            Button("详情") { showAccountCenter = true }.font(.caption.bold())
        }
        .padding(14)
        .youjiCard()
    }

    private func platformSyncButton(_ platform: GamePlatform) -> some View {
        let connected = platform == .playStation ? sync.isPlayStationConnected : sync.isNintendoConnected
        let color = platform == .playStation
            ? Color(red: 0.02, green: 0.28, blue: 0.72)
            : Color(red: 0.89, green: 0.08, blue: 0.13)
        return Button {
            guard connected else {
                connectionSheet = platform == .playStation ? .playStation : .switchConsole
                return
            }
            Task {
                syncingPlatform = platform
                defer { syncingPlatform = nil }
                if platform == .playStation {
                    try? await sync.syncPlayStation(modelContext: modelContext)
                } else {
                    try? await sync.syncNintendo(modelContext: modelContext)
                }
            }
        } label: {
            HStack(spacing: 5) {
                if syncingPlatform == platform {
                    ProgressView().tint(.white).controlSize(.mini)
                } else {
                    Text(platform.shortName)
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                    Image(systemName: connected ? "arrow.triangle.2.circlepath" : "link")
                        .font(.caption2.bold())
                }
            }
            .foregroundStyle(.white)
            .frame(width: 45, height: 36)
            .background(color, in: Capsule())
        }
        .disabled(sync.isSyncing)
        .buttonStyle(.plain)
        .opacity(sync.isSyncing && syncingPlatform != platform ? 0.48 : 1)
    }

    private var platformPicker: some View {
        HStack(spacing: 6) {
            ForEach(LibraryFilter.allCases, id: \.self) { item in
                Button {
                    withAnimation(.snappy(duration: 0.24)) {
                        filter = item
                        if item != .playStation, gameSort.isPlayStationOnly {
                            gameSort = .playTime
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: platformIcon(item)).font(.caption.bold())
                        Text(item.rawValue).font(.subheadline.bold()).lineLimit(1)
                    }
                    .foregroundStyle(filter == item ? Color.white : YJColor.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(filter == item ? activeTabColor(item) : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Color.white.opacity(0.64), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.8)))
        .shadow(color: YJColor.ink.opacity(0.05), radius: 12, y: 5)
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
        VStack(alignment: .leading, spacing: 16) {
            heroTitle("ALL GAMES / 总览", value: format(minutes: playStationMinutes + switchMinutes))
            HStack(spacing: 10) {
                platformMetric(
                    name: "PlayStation",
                    value: compactHours(playStationMinutes),
                    detail: "\(playStationGames.count) 款",
                    color: Color(red: 0.12, green: 0.42, blue: 0.95)
                )
                platformMetric(
                    name: "Switch",
                    value: compactHours(switchMinutes),
                    detail: "\(switchGames.count) 款",
                    color: Color(red: 0.95, green: 0.18, blue: 0.20)
                )
            }
            if let latestVisibleGame {
                recentGameLine(latestVisibleGame, eyebrow: "最近游玩")
            }
        }
        .heroCard(colors: [YJColor.ink, Color(red: 0.12, green: 0.10, blue: 0.20)])
    }

    private var playStationInsightCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroTitle("PLAYSTATION / 最近游玩", value: compactHours(playStationMinutes))
            if let latestVisibleGame {
                recentGameLine(
                    latestVisibleGame,
                    eyebrow: latestVisibleGame.lastPlayedAt?.formatted(.relative(presentation: .named)) ?? "最近同步"
                )
            } else {
                Text("同步 PlayStation 后显示最近游玩的游戏")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            HStack(spacing: 18) {
                heroMiniStat(value: "\(playStationGames.count)", label: "游戏")
                heroMiniStat(value: "\(platinumGameCount)", label: "白金")
                heroMiniStat(value: visiblePlayStationTrophies.map { "\($0.total)" } ?? "—", label: "奖杯")
            }
        }
        .heroCard(colors: [Color(red: 0.02, green: 0.16, blue: 0.43), Color(red: 0.02, green: 0.34, blue: 0.76)])
    }

    private var switchInsightCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                heroTitle("SWITCH / 近 7 天", value: format(minutes: week.reduce(0, +)))
                Spacer()
                Text("活跃 \(week.filter { $0 > 0 }.count) 天")
                    .font(.caption2.bold()).foregroundStyle(.white.opacity(0.72))
            }

            Chart(Array(week.enumerated()), id: \.offset) { index, minutes in
                BarMark(x: .value("日期", rollingDayLabel(index)), y: .value("分钟", max(minutes, 2)))
                    .foregroundStyle(index == 6 ? Color.white : Color.white.opacity(minutes > 0 ? 0.38 : 0.13))
                    .cornerRadius(5)
            }
            .chartYScale(domain: 0...max(week.max() ?? 0, 30))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { AxisValueLabel().foregroundStyle(.white.opacity(0.55)).font(.caption2) }
            }
            .frame(height: 76)

            if let game = switchTopThisWeek ?? latestVisibleGame {
                let playedThisWeek = game.weeklyMinutes.reduce(0, +)
                recentGameLine(
                    game,
                    eyebrow: playedThisWeek > 0 ? "本周最常玩 · \(format(minutes: playedThisWeek))" : "最近游玩"
                )
            }
        }
        .heroCard(colors: [Color(red: 0.31, green: 0.035, blue: 0.055), Color(red: 0.73, green: 0.055, blue: 0.08)])
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
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 5, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption2.bold()).foregroundStyle(.white.opacity(0.58))
                Text("\(value) · \(detail)").font(.caption.bold()).foregroundStyle(.white).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func recentGameLine(_ game: GameRecord, eyebrow: String) -> some View {
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
        }
        .padding(.top, 2)
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
                            .background(YJColor.ink, in: RoundedRectangle(cornerRadius: 14))
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
        let lastGameID = libraryGames.last?.applicationID

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIBRARY / 游戏库").font(.system(size: 9, weight: .black, design: .monospaced)).tracking(1.2).foregroundStyle(YJColor.muted)
                    Text(filter == .all ? "全部冒险" : "\(filter.rawValue) 冒险").font(.title.bold())
                }
                Spacer()
            }

            HStack {
                Text("共 \(libraryGames.count) 款游戏").font(.caption).foregroundStyle(YJColor.muted)
                Spacer()
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
                    Label(gameSort.rawValue, systemImage: "arrow.up.arrow.down")
                        .font(.caption.bold()).foregroundStyle(YJColor.ink)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(YJColor.card, in: Capsule())
                        .overlay(Capsule().stroke(YJColor.line))
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
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(YJColor.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(YJColor.line))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LibraryScope.allCases, id: \.self) { scope in
                        Button(scope.rawValue) { libraryScope = scope }
                            .font(.caption.bold())
                            .foregroundStyle(libraryScope == scope ? .white : YJColor.ink)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(libraryScope == scope ? YJColor.ink : YJColor.card, in: Capsule())
                            .overlay(Capsule().stroke(YJColor.line))
                    }
                }
            }

            if libraryGames.isEmpty {
                emptyLibrary
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(libraryGames, id: \.applicationID) { game in
                        Button { selectedGame = game } label: { GameRow(game: game) }
                            .buttonStyle(.plain)
                            .accessibilityHint("打开游戏档案")
                        if game.applicationID != lastGameID { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .youjiCard()
            }
        }
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
            Button(emptyButtonTitle) {
                if let platform = filter.platform {
                    connectionSheet = platform == .playStation ? .playStation : .switchConsole
                } else {
                    showConnectionOptions = true
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(YJColor.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .youjiCard()
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(YJColor.purple)
                Text("Nintendo 会话令牌与 PlayStation 刷新令牌只保存在这台 iPhone 的 Keychain。游迹不会保存账号密码。")
                    .font(.caption2).foregroundStyle(YJColor.muted).lineSpacing(3)
            }
            if sync.connectedPlatformCount > 0 {
                HStack(spacing: 16) {
                    if sync.isPlayStationConnected { Button("断开 PlayStation") { sync.disconnectPlayStation() } }
                    if sync.isNintendoConnected { Button("断开 Switch") { sync.disconnectNintendo() } }
                }
                .font(.caption2.bold()).foregroundStyle(YJColor.coral)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }

    private var emptyTitle: String {
        switch filter {
        case .all: "游戏记录还没进来"
        case .playStation: "PlayStation 记录还没进来"
        case .switchConsole: "Switch 记录还没进来"
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .all: "连接 PlayStation 或 Nintendo Account，统一查看游戏时间。"
        case .playStation: "登录 PlayStation Network 后同步 PS4 / PS5 游戏总时长。"
        case .switchConsole: "登录 Nintendo Account 后同步账号中的 Play Activity。"
        }
    }

    private var emptyButtonTitle: String {
        switch filter {
        case .all: "连接游戏平台"
        case .playStation: "连接 PlayStation"
        case .switchConsole: "连接 Switch"
        }
    }

    private func format(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func compactHours(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
    }

    private func rollingDayLabel(_ index: Int) -> String {
        if index == 6 { return "今" }
        guard let date = Calendar.current.date(byAdding: .day, value: index - 6, to: .now) else { return "—" }
        let weekday = Calendar.current.component(.weekday, from: date)
        return ["日", "一", "二", "三", "四", "五", "六"][weekday - 1]
    }

    private var appBackground: some View {
        ZStack {
            YJColor.paper
            Circle()
                .fill(YJColor.lime.opacity(0.10))
                .frame(width: 280, height: 280)
                .blur(radius: 12)
                .offset(x: 160, y: -310)
            Circle()
                .fill(YJColor.purple.opacity(0.08))
                .frame(width: 340, height: 340)
                .blur(radius: 18)
                .offset(x: -180, y: 420)
        }.ignoresSafeArea()
    }

    private func platformIcon(_ item: LibraryFilter) -> String {
        switch item {
        case .all: "square.grid.2x2.fill"
        case .playStation: "playstation.logo"
        case .switchConsole: "gamecontroller.fill"
        }
    }

    private func activeTabColor(_ item: LibraryFilter) -> Color {
        switch item {
        case .all: YJColor.ink
        case .playStation: Color(red: 0.02, green: 0.28, blue: 0.72)
        case .switchConsole: Color(red: 0.89, green: 0.08, blue: 0.13)
        }
    }

}

private struct GameRow: View {
    let game: GameRecord

    var body: some View {
        HStack(spacing: 14) {
            CachedCoverImage(urlString: game.imageURL)
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(game.platform.shortName)
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(game.platform == .playStation ? Color.blue : Color.red, in: Capsule())
                    Text(game.title).font(.subheadline.bold()).lineLimit(1)
                    if game.isFavorite {
                        Image(systemName: "heart.fill").font(.caption2).foregroundStyle(YJColor.coral)
                    }
                }
                HStack {
                    Text("\(game.totalMinutes / 60)h \(game.totalMinutes % 60)m").font(.title3.bold())
                    Spacer()
                    Text(game.lastPlayedAt?.formatted(.relative(presentation: .named)) ?? "—")
                        .font(.caption2).foregroundStyle(YJColor.muted)
                }
                if game.platform == .playStation, game.trophiesDefined > 0 {
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: "trophy.fill").foregroundStyle(.yellow)
                            Text("奖杯 \(game.trophiesEarned)/\(game.trophiesDefined)")
                            Spacer()
                            if game.platinumTrophiesEarned > 0 {
                                Text("已白金")
                                    .font(.system(size: 8, weight: .black))
                                    .foregroundStyle(YJColor.ink)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(
                                        LinearGradient(
                                            colors: [Color.white, Color(red: 0.62, green: 0.85, blue: 0.98)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        in: Capsule()
                                    )
                                    .overlay(Capsule().stroke(Color.white.opacity(0.9)))
                            }
                            Text("\(Int((Double(game.trophiesEarned) / Double(game.trophiesDefined) * 100).rounded()))%")
                        }
                        .font(.caption2.bold()).foregroundStyle(YJColor.muted)

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(YJColor.line)
                                Capsule().fill(YJColor.purple)
                                    .frame(width: proxy.size.width * rowProgress)
                            }
                        }.frame(height: 4)
                    }
                }
                if game.playStatus != .played {
                    Text(game.playStatus.rawValue)
                        .font(.caption2.bold())
                        .foregroundStyle(YJColor.purple)
                }
            }
        }.padding(.vertical, 13)
    }

    private var rowProgress: CGFloat {
        if game.platform == .playStation, game.trophiesDefined > 0 {
            return min(CGFloat(game.trophiesEarned) / CGFloat(game.trophiesDefined), 1)
        }
        return min(CGFloat(game.weeklyMinutes.reduce(0, +)) / 600, 1)
    }
}
