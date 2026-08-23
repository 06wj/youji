import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum GameDetailInitialSection: String {
    case history
    case personal
}

struct GameDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var game: GameRecord
    @Query private var snapshots: [PlaySnapshot]
    @Query private var activities: [DailyPlayActivity]
    @Query(sort: \SavedGamePlan.createdAt, order: .reverse) private var plans: [SavedGamePlan]
    let accountScopeKey: String
    let initialSection: GameDetailInitialSection?
    @State private var showingHistoryInfo = false

    init(
        game: GameRecord,
        accountScopeKey: String,
        initialSection: GameDetailInitialSection? = nil
    ) {
        self.game = game
        self.accountScopeKey = accountScopeKey
        self.initialSection = initialSection
        let gameID = game.applicationID
        _snapshots = Query(
            filter: #Predicate<PlaySnapshot> { $0.gameID == gameID },
            sort: \PlaySnapshot.date
        )
        _activities = Query(
            filter: #Predicate<DailyPlayActivity> { $0.gameID == gameID },
            sort: \DailyPlayActivity.day,
            order: .reverse
        )
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 18) {
                        hero
                        historyCard.id(GameDetailInitialSection.history.rawValue)
                        if game.platform == .playStation { trophyCard }
                        if game.platform == .switchConsole, !activities.isEmpty { dailyCard }
                        personalCard.id(GameDetailInitialSection.personal.rawValue)
                        planCard
                    }
                    .padding(18)
                    .padding(.bottom, 30)
                }
                .task {
                    guard let initialSection else { return }
                    try? await Task.sleep(for: .milliseconds(800))
                    withAnimation(nil) {
                        proxy.scrollTo(initialSection.rawValue, anchor: .top)
                    }
                }
            }
            .background(YJColor.paper.ignoresSafeArea())
            .navigationTitle("游戏档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
            .alert("时间线说明", isPresented: $showingHistoryInfo) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("同一天只保留最后一次时长记录；图表会放大实际变化范围，每个圆点代表一个有记录的日期。")
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 16) {
            CachedCoverImage(urlString: game.imageURL)
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text(game.platform.rawValue.uppercased())
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(game.platform == .playStation ? Color.blue : Color.red)
                Text(game.title).font(.title3.bold()).lineLimit(3)
                Label(format(minutes: game.totalMinutes), systemImage: "clock.fill")
                    .font(.headline).foregroundStyle(YJColor.purple)
                if game.isFavorite {
                    Label("已收藏", systemImage: "heart.fill")
                        .font(.caption.bold()).foregroundStyle(YJColor.coral)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .youjiCard()
        .accessibilityElement(children: .combine)
    }

    private var personalCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("MY ARCHIVE / 我的档案").eyebrowStyle()
            Toggle("收藏这款游戏", isOn: $game.isFavorite)
            Toggle("从游戏库隐藏", isOn: $game.isManuallyHidden)
            if game.totalMinutes < 60,
               let lastPlayedAt = game.lastPlayedAt,
               lastPlayedAt < (Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .distantPast) {
                Toggle("即使低时长且较久未玩也始终显示", isOn: $game.isPinnedVisible)
            }
            Picker("游玩状态", selection: Binding(
                get: { game.playStatus },
                set: { game.playStatus = $0 }
            )) {
                ForEach(GamePlayStatus.allCases, id: \.self) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            .pickerStyle(.menu)
            VStack(alignment: .leading, spacing: 7) {
                Text("私人备注").font(.caption.bold()).foregroundStyle(YJColor.muted)
                TextEditor(text: $game.personalNote)
                    .frame(minHeight: 90)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(17)
        .youjiCard()
    }

    private var existingPlan: SavedGamePlan? {
        plans.first {
            $0.accountScopeKey == accountScopeKey
                && !$0.isCompleted
                && $0.title.compare(game.title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NEXT / 下一步").eyebrowStyle()
            HStack(spacing: 12) {
                Image(systemName: existingPlan == nil ? "bookmark" : "bookmark.fill")
                    .font(.headline.bold())
                    .foregroundStyle(existingPlan == nil ? YJColor.ink : YJColor.purple)
                    .frame(width: 42, height: 42)
                    .background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(existingPlan == nil ? "想以后继续这段冒险？" : "已加入待玩与重温")
                        .font(.subheadline.bold())
                    Text(existingPlan == nil ? "把这款游戏加入行动清单，回到首页也能继续。" : "可以在首页的“接下来”或清单中找到它。")
                        .font(.caption)
                        .foregroundStyle(YJColor.muted)
                }
                Spacer(minLength: 0)
            }
            if existingPlan == nil {
                Button(action: addToPlans) {
                    Label("加入待玩与重温", systemImage: "plus")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .tint(YJColor.ink)
            }
        }
        .padding(17)
        .youjiCard()
    }

    private func addToPlans() {
        modelContext.insert(SavedGamePlan(
            accountScopeKey: accountScopeKey,
            title: game.title,
            note: "来自 \(game.platform.rawValue) 游戏档案"
        ))
        try? modelContext.save()
    }

    private var dailySnapshots: [PlaySnapshot] {
        PlayHistoryChartBuilder.dailySnapshots(snapshots)
    }

    private var historyYDomain: ClosedRange<Double> {
        PlayHistoryChartBuilder.yDomain(totalMinutes: dailySnapshots.map(\.totalMinutes))
    }

    @ViewBuilder
    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("HISTORY / 时间线").eyebrowStyle()
            HStack(spacing: 16) {
                dateMetric("首次游玩", game.firstPlayedAt)
                Divider()
                dateMetric("最近游玩", game.lastPlayedAt)
            }
            HStack(spacing: 8) {
                Label(format(minutes: game.totalMinutes), systemImage: "clock.fill")
                    .font(.caption.bold())
                    .foregroundStyle(YJColor.purple)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(YJColor.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            if dailySnapshots.count >= 2 {
                HStack(alignment: .firstTextBaseline) {
                    Text("累计游玩时长").font(.subheadline.bold())
                    Spacer()
                    Text("小时").font(.caption2).foregroundStyle(YJColor.muted)
                    Button {
                        showingHistoryInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("时间线说明")
                }
                Chart(dailySnapshots) { snapshot in
                    LineMark(
                        x: .value("日期", Calendar.current.startOfDay(for: snapshot.date)),
                        y: .value("累计小时", Double(snapshot.totalMinutes) / 60)
                    )
                    .foregroundStyle(YJColor.purple)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    PointMark(
                        x: .value("日期", Calendar.current.startOfDay(for: snapshot.date)),
                        y: .value("累计小时", Double(snapshot.totalMinutes) / 60)
                    )
                    .foregroundStyle(YJColor.purple)
                    .symbolSize(38)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            .foregroundStyle(YJColor.muted.opacity(0.25))
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(YJColor.muted.opacity(0.2))
                        AxisValueLabel {
                            if let hours = value.as(Double.self) {
                                Text("\(hours, format: .number.precision(.fractionLength(0...1)))h")
                            }
                        }
                    }
                }
                .chartYScale(domain: historyYDomain)
                .frame(height: 170)
            } else {
                Text("再同步一次后，这里会开始显示时长变化。")
                    .font(.caption).foregroundStyle(YJColor.muted)
            }
        }
        .padding(17)
        .youjiCard()
    }

    private var trophyCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("TROPHIES / 奖杯").eyebrowStyle()
            HStack {
                Text(game.trophiesDefined > 0 ? "\(game.trophiesEarned)/\(game.trophiesDefined)" : "暂无数据")
                    .font(.title2.bold())
                Spacer()
                if game.platinumTrophiesEarned > 0 {
                    Label("已白金", systemImage: "sparkles")
                        .font(.caption.bold()).foregroundStyle(YJColor.purple)
                }
            }
            if game.trophiesDefined > 0 {
                ProgressView(value: Double(game.trophiesEarned), total: Double(game.trophiesDefined))
                    .tint(YJColor.purple)
            }
            Text(game.trophiesSyncedAt.map { "奖杯更新于 \($0.formatted(.relative(presentation: .named)))" } ?? "奖杯尚未成功同步")
                .font(.caption).foregroundStyle(YJColor.muted)
        }
        .padding(17)
        .youjiCard()
    }

    private var dailyCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("PLAY DAYS / 每日游玩").eyebrowStyle()
            Chart(Array(activities.prefix(30))) { item in
                BarMark(x: .value("日期", item.day), y: .value("分钟", item.totalMinutes))
                    .foregroundStyle(YJColor.coral)
            }
            .frame(height: 150)
            Text("共 \(Set(activities.map { Calendar.current.startOfDay(for: $0.day) }).count) 个游玩日")
                .font(.caption).foregroundStyle(YJColor.muted)
        }
        .padding(17)
        .youjiCard()
    }

    private func dateMetric(_ label: String, _ date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(YJColor.muted)
            Text(date?.formatted(.dateTime.year().month().day()) ?? "—")
                .font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

struct AccountCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var sync: SyncCoordinator
    let games: [GameRecord]
    @Binding var selectedArchive: AccountArchiveSelection?
    @State private var disconnectingPlatform: GamePlatform?
    @State private var archiveToDelete: AccountArchiveSelection?

    private var archives: [AccountArchiveSelection] {
        Set(games.compactMap { game -> AccountArchiveSelection? in
            guard !game.accountID.isEmpty else { return nil }
            return AccountArchiveSelection(platform: game.platform, accountID: game.accountID)
        })
        .sorted { $0.id < $1.id }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("当前连接") {
                    platformRow(.playStation)
                    platformRow(.switchConsole)
                }
                if !archives.isEmpty {
                    Section {
                        ForEach(archives) { archive in archiveRow(archive) }
                    } header: {
                        Text("本地账号档案")
                    } footer: {
                        Text("这里也会保留已断开连接的历史账号。")
                    }
                }
            }
            .navigationTitle("账号与同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .confirmationDialog("断开这个平台？", isPresented: Binding(
                get: { disconnectingPlatform != nil },
                set: { if !$0 { disconnectingPlatform = nil } }
            )) {
                Button("断开连接", role: .destructive) {
                    guard let platform = disconnectingPlatform else { return }
                    if platform == .playStation { sync.disconnectPlayStation() } else { sync.disconnectNintendo() }
                    disconnectingPlatform = nil
                }
                Button("取消", role: .cancel) { disconnectingPlatform = nil }
            } message: {
                Text("登录信息和当前账号会移除，这台设备上的游戏历史不会删除。")
            }
            .confirmationDialog("删除本地档案？", isPresented: Binding(
                get: { archiveToDelete != nil },
                set: { if !$0 { archiveToDelete = nil } }
            )) {
                Button("永久删除", role: .destructive) {
                    guard let archive = archiveToDelete else { return }
                    try? ProductDataService.deleteArchive(platform: archive.platform, accountID: archive.accountID, modelContext: modelContext)
                    if selectedArchive == archive { selectedArchive = nil }
                    archiveToDelete = nil
                }
                Button("取消", role: .cancel) { archiveToDelete = nil }
            } message: {
                Text("会删除该账号的游戏记录、每日活动和相关 AI 内容，无法撤销。")
            }
        }
    }

    private func platformRow(_ platform: GamePlatform) -> some View {
        let connected = platform == .playStation ? sync.isPlayStationConnected : sync.isNintendoConnected
        let name = platform == .playStation ? sync.playStationAccountName : sync.nintendoAccountName
        let date = platform == .playStation ? sync.lastPlayStationSyncAt : sync.lastNintendoSyncAt
        let receipt = platform == .playStation ? sync.playStationReceipt : sync.nintendoReceipt
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: platform == .playStation ? "playstation.logo" : "gamecontroller.fill")
                    .foregroundStyle(platform == .playStation ? Color.blue : Color.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(platform.rawValue).font(.headline)
                    Text(connected ? (name.isEmpty ? "已连接" : name) : "未连接")
                        .font(.caption).foregroundStyle(YJColor.muted)
                }
                Spacer()
                if connected {
                    Button("断开", role: .destructive) { disconnectingPlatform = platform }
                        .font(.caption.bold())
                }
            }
            Text(date.map { "最后成功同步：\($0.formatted(.relative(presentation: .named)))" } ?? "尚未完成过同步")
                .font(.caption).foregroundStyle(YJColor.muted)
            if let receipt { receiptLine(receipt) }
        }
        .padding(.vertical, 5)
    }

    private func receiptLine(_ receipt: PlatformSyncReceipt) -> some View {
        let highlights = [
            receipt.addedMinutes > 0 ? "+\(format(minutes: receipt.addedMinutes))" : nil,
            receipt.addedGames > 0 ? "新收录 \(receipt.addedGames) 款" : nil
        ].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 3) {
            Text(highlights.isEmpty ? "当前记录已是最新" : highlights.joined(separator: " · "))
                .font(.caption.bold())
            if receipt.platform == .playStation,
               receipt.addedTrophies > 0 || receipt.trophyFailures > 0 {
                Text("新增 \(receipt.addedTrophies) 个奖杯\(receipt.trophyFailures > 0 ? " · \(receipt.trophyFailures) 项待下次重试" : "")")
                    .font(.caption2)
                    .foregroundStyle(receipt.trophyFailures > 0 ? YJColor.coral : YJColor.muted)
            }
        }
    }

    private func archiveRow(_ archive: AccountArchiveSelection) -> some View {
        let count = games.filter { $0.platform == archive.platform && $0.accountID == archive.accountID }.count
        let isCurrent = archive.platform == .playStation
            ? archive.accountID == sync.currentPlayStationAccountID
            : archive.accountID == sync.currentNintendoAccountID
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(archive.platform.rawValue) · \(count) 款本地记录").font(.subheadline.bold())
                Text(isCurrent ? "当前账号" : "账号尾号 …\(archive.accountID.suffix(6))")
                    .font(.caption).foregroundStyle(YJColor.muted)
            }
            Spacer()
            Button("查看") {
                selectedArchive = archive
                dismiss()
            }
            .buttonStyle(.bordered)
            if !isCurrent {
                Button(role: .destructive) { archiveToDelete = archive } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("删除这个本地档案")
            }
        }
    }

    private func format(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

struct InsightsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PlaySnapshot.date) private var snapshots: [PlaySnapshot]
    @Query(sort: \DailyPlayActivity.day) private var activities: [DailyPlayActivity]
    let games: [GameRecord]
    let accountScopeKey: String
    @State private var showPlans = false
    @State private var showingInsightsInfo = false

    private var relevantSnapshots: [PlaySnapshot] {
        let ids = Set(games.map(\.applicationID))
        return snapshots.filter { ids.contains($0.gameID) }
    }
    private var snapshotDays: [Date] {
        Array(Set(relevantSnapshots.map { Calendar.current.startOfDay(for: $0.date) })).sorted()
    }
    private var timelineEntries: [PlayTimelineEntry] {
        PlayTimelineBuilder.entries(
            snapshots: relevantSnapshots,
            activities: activities,
            includedGameIDs: Set(games.map(\.applicationID))
        )
    }
    private var timelineDays: [PlayTimelineDay] {
        PlayTimelineDay.grouped(entries: timelineEntries)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    intro
                    timelineCard
                    periodCard("最近 7 天", days: 7, color: YJColor.purple)
                    periodCard("最近 30 天", days: 30, color: YJColor.coral)
                    yearCard
                    Button { showPlans = true } label: {
                        Label("打开待玩与重温清单", systemImage: "bookmark.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(15)
                    }
                    .buttonStyle(.plain).foregroundStyle(.white).background(YJColor.ink, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(18)
            }
            .background(YJColor.paper.ignoresSafeArea())
            .navigationTitle("游玩洞察")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingInsightsInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("洞察说明")
                    Button("完成") { dismiss() }
                }
            }
            .alert("洞察说明", isPresented: $showingInsightsInfo) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(insightsInfoText)
            }
            .sheet(isPresented: $showPlans) {
                SavedPlansView(accountScopeKey: accountScopeKey)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("让每次同步留下变化").font(.title2.bold())
            Text("回看最近一周、一个月和今年的游玩足迹。")
                .font(.caption).foregroundStyle(YJColor.muted).lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18).youjiCard()
    }

    private var insightsInfoText: String {
        let method = "游迹根据每次主动同步时的游戏总时长计算变化；两次同步之间的游玩会归入后一次同步日期。Switch 有每日活动时会优先使用每日记录。"
        guard let first = snapshotDays.first, let last = snapshotDays.last else {
            return "完成同步后，这里会开始记录游玩变化。\n\n\(method)"
        }
        guard snapshotDays.count >= 2 else {
            return "已从 \(first.formatted(.dateTime.month().day())) 开始记录。再次同步后即可看到变化。\n\n\(method)"
        }
        return "当前记录范围为 \(first.formatted(.dateTime.year().month().day())) 至 \(last.formatted(.dateTime.month().day()))。\n\n\(method)"
    }

    private var timelineCard: some View {
        NavigationLink {
            PlayTimelineView(
                entries: timelineEntries,
                games: games,
                accountScopeKey: accountScopeKey
            )
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PLAY LOG / 总时间线").eyebrowStyle()
                        Text(timelineDays.isEmpty ? "还没有可确认的游玩变化" : "已留下 \(timelineDays.count) 个游玩日")
                            .font(.headline)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(YJColor.muted)
                }

                if timelineDays.isEmpty {
                    Text("完成后续同步后，这里会按日期汇总各游戏的新增时长。")
                        .font(.caption)
                        .foregroundStyle(YJColor.muted)
                } else {
                    ForEach(Array(timelineDays.suffix(3).reversed())) { day in
                        timelinePreviewRow(day: day)
                    }
                    Text("查看全部记录，可切换最新或最早优先")
                        .font(.caption2)
                        .foregroundStyle(YJColor.muted)
                }
            }
            .padding(17)
            .youjiCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看按时间排列的全部游玩记录")
    }

    private func timelinePreviewRow(day: PlayTimelineDay) -> some View {
        let dayGames = day.entries.compactMap { entry in
            games.first(where: { $0.applicationID == entry.gameID })
        }
        return HStack(spacing: 11) {
            Circle()
                .fill(YJColor.purple)
                .frame(width: 7, height: 7)
            if let game = dayGames.first {
                CachedCoverImage(urlString: game.imageURL)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(day.date.formatted(.dateTime.year().month().day()))
                    .font(.subheadline.bold())
                Text(dayGames.count == 1 ? (dayGames.first?.title ?? "1 款游戏") : "\(dayGames.count) 款游戏")
                    .font(.caption2).foregroundStyle(YJColor.muted)
            }
            Spacer(minLength: 8)
            Text(day.addedMinutes > 0 ? "+\(format(minutes: day.addedMinutes))" : "+\(day.addedTrophies) 奖杯")
                .font(.caption.bold()).monospacedDigit()
                .foregroundStyle(YJColor.purple)
        }
    }

    private func periodCard(_ title: String, days: Int, color: Color) -> some View {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        let insight = PlayInsightCalculator.insight(snapshots: relevantSnapshots, since: start)
        return NavigationLink {
            InsightPeriodDetailView(
                title: title,
                start: start,
                color: color,
                snapshots: relevantSnapshots,
                games: games,
                accountScopeKey: accountScopeKey,
                showsMonthlyBreakdown: false
            )
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(color)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(YJColor.muted)
                }
                HStack {
                    insightMetric(format(minutes: insight.addedMinutes), "新增时长")
                    insightMetric("\(insight.activeGames)", "活跃游戏")
                    insightMetric("\(insight.addedTrophies)", "新增奖杯")
                }
            }
            .padding(17).youjiCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看游戏贡献明细")
    }

    private var yearCard: some View {
        let start = Calendar.current.dateInterval(of: .year, for: .now)?.start ?? .distantPast
        let insight = PlayInsightCalculator.insight(snapshots: relevantSnapshots, since: start)
        let year = Calendar.current.component(.year, from: .now)
        return NavigationLink {
            InsightPeriodDetailView(
                title: "\(year) 年度回顾",
                start: start,
                color: YJColor.purple,
                snapshots: relevantSnapshots,
                games: games,
                accountScopeKey: accountScopeKey,
                showsMonthlyBreakdown: true
            )
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("\(year) 年度回顾").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.72))
                }
                Text(format(minutes: insight.addedMinutes)).font(.system(size: 34, weight: .bold, design: .rounded))
                Text("\(insight.activeGames) 款游戏有变化 · 新增 \(insight.addedTrophies) 个奖杯")
                    .font(.caption).foregroundStyle(.white.opacity(0.72))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(LinearGradient(colors: [YJColor.ink, YJColor.purple], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看月度和游戏贡献明细")
    }

    private func insightMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.headline.bold())
            Text(label).font(.caption2).foregroundStyle(YJColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

private struct PlayTimelineDay: Identifiable {
    let date: Date
    let entries: [PlayTimelineEntry]

    var id: Date { date }
    var addedMinutes: Int { entries.reduce(0) { $0 + $1.addedMinutes } }
    var addedTrophies: Int { entries.reduce(0) { $0 + $1.addedTrophies } }

    static func grouped(entries: [PlayTimelineEntry], calendar: Calendar = .current) -> [PlayTimelineDay] {
        Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
            .map { day, entries in
                PlayTimelineDay(
                    date: day,
                    entries: entries.sorted {
                        if $0.addedMinutes != $1.addedMinutes { return $0.addedMinutes > $1.addedMinutes }
                        return $0.gameID < $1.gameID
                    }
                )
            }
            .sorted { $0.date < $1.date }
    }
}

private struct PlayTimelineView: View {
    let entries: [PlayTimelineEntry]
    let games: [GameRecord]
    let accountScopeKey: String
    @State private var newestFirst = true
    @State private var selectedGame: GameRecord?
    @State private var showingTimelineInfo = false

    private var gamesByID: [String: GameRecord] {
        Dictionary(uniqueKeysWithValues: games.map { ($0.applicationID, $0) })
    }

    private var orderedDays: [PlayTimelineDay] {
        let days = PlayTimelineDay.grouped(entries: entries)
        return newestFirst ? days.reversed() : days
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                introCard
                    .padding(.bottom, 18)
                if entries.isEmpty {
                    ContentUnavailableView(
                        "还没有游玩记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("至少同步两次后，才能看到游玩时长的变化。")
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(orderedDays) { day in
                        dayCard(day)
                    }
                }
            }
            .padding(18)
            .padding(.bottom, 30)
        }
        .background(YJColor.paper.ignoresSafeArea())
        .navigationTitle("全部游玩时间线")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingTimelineInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("时间线说明")
            }
        }
        .alert("时间线说明", isPresented: $showingTimelineInfo) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("同一天的记录会合并为一个游玩日。Switch 有每日活动时会优先使用；其他记录按两次同步之间增加的时长整理。")
        }
        .sheet(item: $selectedGame) { game in
            GameDetailView(game: game, accountScopeKey: accountScopeKey)
                .presentationDetents([.large])
        }
    }

    private var introCard: some View {
        Picker("时间顺序", selection: $newestFirst) {
            Text("最新优先").tag(true)
            Text("最早优先").tag(false)
        }
        .pickerStyle(.segmented)
        .padding(16)
        .youjiCard()
    }

    private func dayCard(_ day: PlayTimelineDay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.date.formatted(.dateTime.year().month().day()))
                    .font(.headline.bold()).monospacedDigit()
                Spacer()
                if day.addedMinutes > 0 {
                    Text("共 +\(format(minutes: day.addedMinutes))")
                        .font(.caption.bold()).foregroundStyle(YJColor.purple)
                } else if day.addedTrophies > 0 {
                    Text("新增 \(day.addedTrophies) 奖杯")
                        .font(.caption.bold()).foregroundStyle(YJColor.purple)
                }
            }
            ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                if let game = gamesByID[entry.gameID] {
                    Button { selectedGame = game } label: {
                        HStack(spacing: 11) {
                            CachedCoverImage(urlString: game.imageURL)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(game.title).font(.subheadline.bold()).lineLimit(2)
                                HStack(spacing: 9) {
                                    if entry.addedMinutes > 0 {
                                        Label("+\(format(minutes: entry.addedMinutes))", systemImage: "clock.fill")
                                    }
                                    if entry.addedTrophies > 0 {
                                        Label("+\(entry.addedTrophies)", systemImage: "trophy.fill")
                                    }
                                }
                                .font(.caption.bold())
                                .foregroundStyle(YJColor.purple)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(YJColor.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < day.entries.count - 1 { Divider() }
                }
            }
        }
        .padding(16)
        .youjiCard()
        .padding(.bottom, 12)
    }

    private func format(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

private struct InsightMonthBreakdown: Identifiable {
    let start: Date
    let insight: PlayPeriodInsight

    var id: Date { start }
}

private struct InsightPeriodDetailView: View {
    let title: String
    let start: Date
    let color: Color
    let snapshots: [PlaySnapshot]
    let games: [GameRecord]
    let accountScopeKey: String
    let showsMonthlyBreakdown: Bool
    @State private var selectedGame: GameRecord?
    @State private var showingMethodologyInfo = false

    private var insight: PlayPeriodInsight {
        PlayInsightCalculator.insight(snapshots: snapshots, since: start)
    }

    private var contributions: [PlayGameContribution] {
        PlayInsightCalculator.contributions(snapshots: snapshots, since: start)
    }

    private var gamesByID: [String: GameRecord] {
        Dictionary(uniqueKeysWithValues: games.map { ($0.applicationID, $0) })
    }

    private var periodSnapshotDays: [Date] {
        Array(Set(snapshots.lazy
            .filter { $0.date >= start && $0.date <= .now }
            .map { Calendar.current.startOfDay(for: $0.date) }))
            .sorted()
    }

    private var monthBreakdowns: [InsightMonthBreakdown] {
        guard showsMonthlyBreakdown else { return [] }
        let calendar = Calendar.current
        let currentMonth = calendar.dateInterval(of: .month, for: .now)?.start ?? .now
        var month = calendar.dateInterval(of: .month, for: start)?.start ?? start
        var result: [InsightMonthBreakdown] = []
        while month <= currentMonth {
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            let monthEnd = min(.now, next.addingTimeInterval(-1))
            result.append(InsightMonthBreakdown(
                start: month,
                insight: PlayInsightCalculator.insight(snapshots: snapshots, since: month, now: monthEnd)
            ))
            month = next
        }
        return result.reversed()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                summaryCard
                if showsMonthlyBreakdown { monthlyCard }
                contributionCard
            }
            .padding(18)
            .padding(.bottom, 30)
        }
        .background(YJColor.paper.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingMethodologyInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("数据说明")
            }
        }
        .alert("数据说明", isPresented: $showingMethodologyInfo) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("游迹根据每次主动同步时的游戏总时长计算变化，因此两次同步之间的游玩会归入后一次同步日期，不等同于游戏平台的逐日记录。")
        }
        .sheet(item: $selectedGame) { game in
            GameDetailView(game: game, accountScopeKey: accountScopeKey)
                .presentationDetents([.large])
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("PERIOD / 周期总览").eyebrowStyle()
            HStack {
                detailMetric(format(minutes: insight.addedMinutes), "新增时长")
                detailMetric("\(insight.activeGames)", "活跃游戏")
                detailMetric("\(insight.addedTrophies)", "新增奖杯")
            }
            Label(coverageText, systemImage: periodSnapshotDays.count >= 2 ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(periodSnapshotDays.count >= 2 ? color : YJColor.coral)
        }
        .padding(17)
        .youjiCard()
    }

    private var monthlyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MONTHLY / 月度变化").eyebrowStyle()
            ForEach(monthBreakdowns) { item in
                HStack(spacing: 12) {
                    Text(item.start.formatted(.dateTime.month(.abbreviated)))
                        .font(.subheadline.bold())
                        .frame(width: 48, alignment: .leading)
                    GeometryReader { proxy in
                        let maximum = max(monthBreakdowns.map(\.insight.addedMinutes).max() ?? 0, 1)
                        Capsule()
                            .fill(color.opacity(item.insight.addedMinutes > 0 ? 0.82 : 0.12))
                            .frame(width: max(4, proxy.size.width * Double(item.insight.addedMinutes) / Double(maximum)), height: 8)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 20)
                    Text(format(minutes: item.insight.addedMinutes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(item.insight.addedMinutes > 0 ? YJColor.ink : YJColor.muted)
                        .frame(minWidth: 54, alignment: .trailing)
                }
            }
        }
        .padding(17)
        .youjiCard()
    }

    private var contributionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GAMES / 游戏贡献").eyebrowStyle()
            if contributions.isEmpty {
                ContentUnavailableView("这个周期还没有变化", systemImage: "chart.bar.xaxis", description: Text("完成下一次同步后再回来查看。"))
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(contributions.enumerated()), id: \.element.id) { index, contribution in
                    if let game = gamesByID[contribution.gameID] {
                        Button { selectedGame = game } label: {
                            contributionRow(game: game, contribution: contribution)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("打开游戏档案")
                        if index < contributions.count - 1 { Divider() }
                    }
                }
            }
        }
        .padding(17)
        .youjiCard()
    }

    private func contributionRow(game: GameRecord, contribution: PlayGameContribution) -> some View {
        HStack(spacing: 12) {
            CachedCoverImage(urlString: game.imageURL)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title).font(.subheadline.bold()).lineLimit(2)
                Text(game.platform.rawValue.uppercased())
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(game.platform == .playStation ? Color.blue : Color.red)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text("+\(format(minutes: contribution.addedMinutes))")
                    .font(.subheadline.bold()).monospacedDigit()
                if contribution.addedTrophies > 0 {
                    Text("+\(contribution.addedTrophies) 奖杯")
                        .font(.caption2).foregroundStyle(YJColor.muted)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(YJColor.muted)
        }
        .contentShape(Rectangle())
    }

    private var coverageText: String {
        guard let first = periodSnapshotDays.first, let last = periodSnapshotDays.last else {
            return "同步后开始记录这个周期"
        }
        guard periodSnapshotDays.count >= 2 else {
            return "已从 \(first.formatted(.dateTime.month().day())) 开始记录，再同步一次即可看到变化"
        }
        return "记录范围：\(first.formatted(.dateTime.month().day())) 至 \(last.formatted(.dateTime.month().day()))"
    }

    private func detailMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.headline.bold()).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(YJColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

struct SavedPlansView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedGamePlan.createdAt, order: .reverse) private var allPlans: [SavedGamePlan]
    let accountScopeKey: String
    @State private var showNewPlan = false
    @State private var newTitle = ""
    @State private var newNote = ""
    @State private var showCompleted = false

    private var plans: [SavedGamePlan] { allPlans.filter { $0.accountScopeKey == accountScopeKey } }
    private var activePlans: [SavedGamePlan] { plans.filter { !$0.isCompleted } }
    private var completedPlans: [SavedGamePlan] { plans.filter(\.isCompleted) }

    var body: some View {
        NavigationStack {
            List {
                if plans.isEmpty {
                    VStack(spacing: 18) {
                        ContentUnavailableView("清单还是空的", systemImage: "bookmark", description: Text("从游戏档案加入作品、保存 AI 灵感，或手动写下一段计划。"))
                        Button("加入第一条计划") { showNewPlan = true }
                            .buttonStyle(.borderedProminent)
                            .tint(YJColor.ink)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        HStack {
                            Label("\(activePlans.count) 条待行动", systemImage: "bookmark.fill")
                                .font(.subheadline.bold())
                            Spacer()
                            Text("已完成 \(completedPlans.count)")
                                .font(.caption)
                                .foregroundStyle(YJColor.muted)
                        }
                    } footer: {
                        Text("只有点按左侧圆圈才会标记完成，打开页面或查看文字不会误操作。")
                    }

                    if activePlans.isEmpty {
                        Section {
                            ContentUnavailableView("当前计划都完成了", systemImage: "checkmark.circle", description: Text("可以加入下一款想玩或重温的游戏。"))
                        }
                    } else {
                        Section("接下来") {
                            ForEach(activePlans) { plan in planRow(plan) }
                        }
                    }

                    if !completedPlans.isEmpty {
                        Section {
                            DisclosureGroup("已完成 \(completedPlans.count) 条", isExpanded: $showCompleted) {
                                ForEach(completedPlans) { plan in planRow(plan) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("待玩与重温")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button { showNewPlan = true } label: { Image(systemName: "plus") } }
            }
            .sheet(isPresented: $showNewPlan) {
                NavigationStack {
                    Form {
                        Section("准备做什么") {
                            TextField("游戏名称或计划", text: $newTitle)
                        }
                        Section("补充说明（可选）") {
                            TextField("为什么想玩、准备何时开始…", text: $newNote, axis: .vertical)
                                .lineLimit(3...6)
                        }
                    }
                    .navigationTitle("加入清单")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("取消") { showNewPlan = false } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("保存") {
                                modelContext.insert(SavedGamePlan(accountScopeKey: accountScopeKey, title: newTitle.trimmingCharacters(in: .whitespacesAndNewlines), note: newNote))
                                try? modelContext.save()
                                newTitle = ""; newNote = ""; showNewPlan = false
                            }
                            .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func planRow(_ plan: SavedGamePlan) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                plan.isCompleted.toggle()
                try? modelContext.save()
            } label: {
                Image(systemName: plan.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(plan.isCompleted ? YJColor.purple : YJColor.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(plan.isCompleted ? "标记为未完成" : "标记为已完成")

            VStack(alignment: .leading, spacing: 4) {
                Text(plan.title)
                    .font(.subheadline.bold())
                    .strikethrough(plan.isCompleted)
                if !plan.note.isEmpty {
                    Text(plan.note)
                        .font(.caption)
                        .foregroundStyle(YJColor.muted)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .swipeActions {
            Button("删除", role: .destructive) {
                modelContext.delete(plan)
                try? modelContext.save()
            }
        }
    }
}

struct AIProfileHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AIProfileResult.generatedAt, order: .reverse) private var allProfiles: [AIProfileResult]
    let accountScopeKey: String
    @State private var shareURL: URL?
    @State private var shareError: String?
    @State private var expandedProfileIDs: Set<UUID> = []

    private var profiles: [AIProfileResult] { allProfiles.filter { $0.accountScopeKey == accountScopeKey } }

    var body: some View {
        NavigationStack {
            List {
                if profiles.isEmpty {
                    ContentUnavailableView("还没有历史人格", systemImage: "sparkles", description: Text("每次成功生成人格后都会保存在这里。"))
                } else {
                    ForEach(profiles) { profile in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(profile.generatedAt.formatted(.dateTime.year().month().day().hour().minute()))
                                    .font(.caption.bold())
                                Spacer()
                                Button {
                                    do {
                                        shareURL = try ProfileShareCardService.makeCard(
                                            text: profile.text,
                                            subtitle: "\(profile.platformFilter) · \(profile.gameCount) 款 · > \(profile.minimumHours)h"
                                        )
                                    } catch { shareError = error.localizedDescription }
                                } label: { Image(systemName: "photo.badge.arrow.down") }
                                .accessibilityLabel("生成分享图片")
                            }
                            Text("\(profile.platformFilter) · > \(profile.minimumHours)h · \(profile.gameCount) 款")
                                .font(.caption2).foregroundStyle(YJColor.muted)
                            Text((try? AttributedString(markdown: profile.text)) ?? AttributedString(profile.text))
                                .font(.subheadline)
                                .lineLimit(expandedProfileIDs.contains(profile.id) ? nil : 6)
                            Button(expandedProfileIDs.contains(profile.id) ? "收起" : "查看全文") {
                                if expandedProfileIDs.contains(profile.id) {
                                    expandedProfileIDs.remove(profile.id)
                                } else {
                                    expandedProfileIDs.insert(profile.id)
                                }
                            }
                            .font(.caption.bold())
                        }
                        .padding(.vertical, 6)
                        .swipeActions {
                            Button("删除", role: .destructive) { modelContext.delete(profile); try? modelContext.save() }
                        }
                    }
                }
            }
            .navigationTitle("历史游戏人格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
                if let shareURL {
                    SharePreviewView(url: shareURL)
                }
            }
            .alert("生成失败", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(shareError ?? "") }
        }
    }
}

private struct SharePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 20))
                }
                ShareLink(item: url) {
                    Label("分享人格图片", systemImage: "square.and.arrow.up")
                        .font(.headline).frame(maxWidth: .infinity).padding(14)
                }
                .buttonStyle(.plain).foregroundStyle(.white).background(YJColor.ink, in: RoundedRectangle(cornerRadius: 15))
            }
            .padding(18)
            .background(YJColor.paper.ignoresSafeArea())
            .navigationTitle("分享预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

struct DataManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var games: [GameRecord]
    @State private var document: YouJiTextDocument?
    @State private var exportName = "游迹备份"
    @State private var exportType: UTType = .json
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var message: String?
    @State private var confirmDeleteAll = false
    let sync: SyncCoordinator?

    init(sync: SyncCoordinator? = nil) {
        self.sync = sync
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(YJColor.purple)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("这台设备共有 \(games.count) 款游戏记录").font(.subheadline.bold())
                        Text("完整备份还会包含同步历史、每日活动和 AI 内容。")
                            .font(.caption).foregroundStyle(YJColor.muted)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Button("导出完整备份", action: exportBackup)
                Button("导出游戏库表格", action: exportCSV)
                ShareLink(item: ProductDataService.diagnostics(modelContext: modelContext)) {
                    Label("分享安全诊断摘要", systemImage: "stethoscope")
                }
            } header: {
                Text("导出")
            } footer: {
                Text("完整备份包含游戏、同步历史、每日活动和 AI 内容；不包含游戏平台登录信息、账号密码或 AI API Key。")
            }
            Section {
                Button("从备份恢复") { isImporting = true }
            } header: {
                Text("恢复")
            } footer: {
                Text("恢复会合并现有内容：重复的游戏会更新，设备上独有的内容会保留。")
            }
            Section {
                Button("删除全部本地档案", role: .destructive) { confirmDeleteAll = true }
            } footer: {
                Text("会删除这台设备上的所有游迹内容，但不会断开游戏平台账号。建议先导出完整备份。")
            }
        }
        .navigationTitle("数据管理")
        .fileExporter(
            isPresented: $isExporting,
            document: document,
            contentType: exportType,
            defaultFilename: exportName
        ) { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccessSecurityScope { url.stopAccessingSecurityScopedResource() }
                }
                let summary = try ProductDataService.restore(
                    data: Data(contentsOf: url),
                    modelContext: modelContext
                )
                message = "已恢复 \(summary.gameCount) 款游戏及相关游玩记录。"
            } catch { message = error.localizedDescription }
        }
        .alert("数据管理", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(message ?? "") }
        .confirmationDialog("删除全部本地档案？", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("永久删除", role: .destructive) {
                Task {
                    do {
                        try await ProductDataService.deleteAllLocalData(modelContext: modelContext)
                        sync?.resetNonCredentialState()
                        message = "这台设备上的游迹内容已删除。游戏平台仍保持连接，可再次主动同步。"
                    } catch { message = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("游戏记录、每日活动、AI 会话、人格、清单和私人备注都会删除，无法撤销。") }
    }

    private func exportBackup() {
        do {
            document = YouJiTextDocument(data: try ProductDataService.backupData(modelContext: modelContext))
            exportType = .json
            exportName = "游迹完整备份-\(Date.now.formatted(.iso8601.year().month().day()))"
            isExporting = true
        } catch { message = error.localizedDescription }
    }

    private func exportCSV() {
        document = YouJiTextDocument(text: ProductDataService.libraryCSV(games: games))
        exportType = .commaSeparatedText
        exportName = "游迹游戏库-\(Date.now.formatted(.iso8601.year().month().day()))"
        isExporting = true
    }
}

struct PrivacyInfoView: View {
    var body: some View {
        List {
            Section("本机保存") {
                Label("游戏记录与 Switch 每日活动", systemImage: "externaldrive.fill")
                Label("AI 会话、人格历史、待玩清单和私人备注", systemImage: "iphone")
                Label("平台登录信息与 AI API Key 仅保存在这台设备", systemImage: "key.fill")
            }
            Section("何时联网") {
                Text("只有你点击连接或同步时才请求游戏平台。只有你点击生成或发送消息时才请求模型服务。游迹不会自动同步，也不会在后台上传游戏库。")
            }
            Section("发送给 AI") {
                Text("人格分析仅发送当前筛选游戏的名称、平台、游玩时长和奖杯比例。聊天会发送开始对话时选用的游戏信息及当前对话。不会发送平台登录信息、账号标识、封面或私人备注。")
            }
            Section("用户控制") {
                Text("你可以导出完整本地备份、恢复备份、清除单个历史账号档案、删除全部本地内容、断开平台连接或清除 AI API Key。断开平台默认保留游戏历史。")
            }
            Section("第三方服务") {
                Text("游戏平台服务调整时，连接或同步功能可能暂时不可用。AI 服务可在设置中更换；第三方如何处理请求受其各自条款约束。")
                Link("查看完整隐私政策", destination: URL(string: "https://github.com/06wj/youji-ios/blob/main/docs/PRIVACY_POLICY.md")!)
            }
        }
        .navigationTitle("数据与隐私")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct YouJiTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, .plainText] }
    let data: Data

    init(data: Data) { self.data = data }
    init(text: String) { data = Data(text.utf8) }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private extension View {
    func eyebrowStyle() -> some View {
        self.font(.system(size: 9, weight: .black, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(YJColor.muted)
    }
}
