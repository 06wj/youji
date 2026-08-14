import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct GameDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var game: GameRecord
    @Query private var snapshots: [PlaySnapshot]
    @Query private var activities: [DailyPlayActivity]

    init(game: GameRecord) {
        self.game = game
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
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    personalCard
                    historyCard
                    if game.platform == .playStation { trophyCard }
                    if game.platform == .switchConsole, !activities.isEmpty { dailyCard }
                    sourceCard
                }
                .padding(18)
                .padding(.bottom, 30)
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

    @ViewBuilder
    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("HISTORY / 时间线").eyebrowStyle()
            HStack {
                dateMetric("首次游玩", game.firstPlayedAt)
                Divider()
                dateMetric("最近游玩", game.lastPlayedAt)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("同步快照").font(.caption2).foregroundStyle(YJColor.muted)
                    Text("\(snapshots.count) 次").font(.subheadline.bold())
                }
            }
            if snapshots.count >= 2 {
                Chart(snapshots) { snapshot in
                    LineMark(
                        x: .value("日期", snapshot.date),
                        y: .value("累计小时", Double(snapshot.totalMinutes) / 60)
                    )
                    .foregroundStyle(YJColor.purple)
                    PointMark(
                        x: .value("日期", snapshot.date),
                        y: .value("累计小时", Double(snapshot.totalMinutes) / 60)
                    )
                    .foregroundStyle(YJColor.purple)
                }
                .frame(height: 150)
            } else {
                Text("再完成一次同步后，这里会开始显示累计时长变化。")
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
            Text("已在本机保存 \(Set(activities.map { Calendar.current.startOfDay(for: $0.day) }).count) 个游玩日")
                .font(.caption).foregroundStyle(YJColor.muted)
        }
        .padding(17)
        .youjiCard()
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("记录由 \(game.platform.rawValue) 同步并保存在本机。自定义收藏、隐藏、状态和备注不会上传到游戏平台。")
                .font(.caption).foregroundStyle(YJColor.muted).lineSpacing(3)
            Text("档案标识：\(game.titleID.isEmpty ? game.resolvedTitleID : game.titleID)")
                .font(.caption2.monospaced()).foregroundStyle(YJColor.muted)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 15))
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
                        Text("本地历史档案")
                    } footer: {
                        Text("断开账号不会删除这些记录。可以离线查看，也可以单独清除不再需要的档案。")
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
                Text("凭据和当前显示身份会移除，本机游戏历史不会删除。")
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
                Text("会删除该账号的游戏、同步快照、每日记录和关联 AI 内容，无法撤销。")
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
            if let date {
                Text("最后成功同步：\(date.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(YJColor.muted)
            }
            if let receipt { receiptLine(receipt) }
        }
        .padding(.vertical, 5)
    }

    private func receiptLine(_ receipt: PlatformSyncReceipt) -> some View {
        let change = "新增 \(receipt.addedGames) 款 · 更新 \(receipt.changedGames) 款 · +\(format(minutes: receipt.addedMinutes))"
        return VStack(alignment: .leading, spacing: 3) {
            Text(change).font(.caption.bold())
            if receipt.platform == .playStation {
                Text("新增 \(receipt.addedTrophies) 个奖杯\(receipt.trophyFailures > 0 ? " · \(receipt.trophyFailures) 项待重试" : " · 奖杯同步完整")")
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
                Text("\(archive.platform.rawValue) · \(count) 款").font(.subheadline.bold())
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
    let games: [GameRecord]
    let accountScopeKey: String
    @State private var showPlans = false

    private var relevantSnapshots: [PlaySnapshot] {
        let ids = Set(games.map(\.applicationID))
        return snapshots.filter { ids.contains($0.gameID) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    intro
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showPlans) {
                SavedPlansView(accountScopeKey: accountScopeKey)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("让每次同步留下变化").font(.title2.bold())
            Text("趋势来自平台返回的累计值差异；只有两个及以上同步时间点后才会产生增量。")
                .font(.caption).foregroundStyle(YJColor.muted).lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18).youjiCard()
    }

    private func periodCard(_ title: String, days: Int, color: Color) -> some View {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        let insight = PlayInsightCalculator.insight(snapshots: relevantSnapshots, since: start)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(color)
            }
            HStack {
                insightMetric(format(minutes: insight.addedMinutes), "新增时长")
                insightMetric("\(insight.activeGames)", "活跃游戏")
                insightMetric("\(insight.addedTrophies)", "新增奖杯")
            }
        }
        .padding(17).youjiCard()
    }

    private var yearCard: some View {
        let start = Calendar.current.dateInterval(of: .year, for: .now)?.start ?? .distantPast
        let insight = PlayInsightCalculator.insight(snapshots: relevantSnapshots, since: start)
        let year = Calendar.current.component(.year, from: .now)
        return VStack(alignment: .leading, spacing: 14) {
            Text("\(year) 年度回顾").font(.headline)
            Text(format(minutes: insight.addedMinutes)).font(.system(size: 34, weight: .bold, design: .rounded))
            Text("\(insight.activeGames) 款游戏有变化 · 新增 \(insight.addedTrophies) 个奖杯")
                .font(.caption).foregroundStyle(YJColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(LinearGradient(colors: [YJColor.ink, YJColor.purple], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
        .foregroundStyle(.white)
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

struct SavedPlansView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedGamePlan.createdAt, order: .reverse) private var allPlans: [SavedGamePlan]
    let accountScopeKey: String
    @State private var showNewPlan = false
    @State private var newTitle = ""
    @State private var newNote = ""

    private var plans: [SavedGamePlan] { allPlans.filter { $0.accountScopeKey == accountScopeKey } }

    var body: some View {
        NavigationStack {
            List {
                if plans.isEmpty {
                    ContentUnavailableView("清单还是空的", systemImage: "bookmark", description: Text("保存 AI 灵感，或手动加入准备游玩和重温的游戏。"))
                } else {
                    ForEach(plans) { plan in
                        Button {
                            plan.isCompleted.toggle()
                            try? modelContext.save()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: plan.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(plan.isCompleted ? YJColor.purple : YJColor.muted)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(plan.title).font(.subheadline.bold()).strikethrough(plan.isCompleted)
                                    if !plan.note.isEmpty { Text(plan.note).font(.caption).foregroundStyle(YJColor.muted).lineLimit(3) }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("删除", role: .destructive) { modelContext.delete(plan); try? modelContext.save() }
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
                        TextField("游戏名称或计划", text: $newTitle)
                        TextField("备注（可选）", text: $newNote, axis: .vertical)
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
}

struct AIProfileHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AIProfileResult.generatedAt, order: .reverse) private var allProfiles: [AIProfileResult]
    let accountScopeKey: String
    @State private var shareURL: URL?
    @State private var shareError: String?

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
                                .font(.subheadline).lineLimit(8)
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
                Button("导出完整 JSON 备份", action: exportBackup)
                Button("导出游戏库 CSV", action: exportCSV)
                ShareLink(item: ProductDataService.diagnostics(modelContext: modelContext)) {
                    Label("分享安全诊断摘要", systemImage: "stethoscope")
                }
            } header: {
                Text("导出")
            } footer: {
                Text("完整备份包含本地游戏、同步历史、每日活动和 AI 内容；不包含平台凭据、账号密码或 AI API Key。")
            }
            Section {
                Button("从 JSON 备份恢复") { isImporting = true }
            } header: {
                Text("恢复")
            } footer: {
                Text("恢复采用合并方式：同一记录会更新，备份外的本地记录不会被删除。")
            }
            Section {
                Button("删除全部本地数据", role: .destructive) { confirmDeleteAll = true }
            } footer: {
                Text("会同时清除封面缓存与本地同步状态，但不会自动断开游戏平台凭据。建议先导出完整备份。")
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
                message = "已合并恢复 \(summary.gameCount) 款游戏、\(summary.snapshotCount) 条同步快照。"
            } catch { message = error.localizedDescription }
        }
        .alert("数据管理", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(message ?? "") }
        .confirmationDialog("删除全部本地数据？", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("永久删除", role: .destructive) {
                Task {
                    do {
                        try await ProductDataService.deleteAllLocalData(modelContext: modelContext)
                        sync?.resetNonCredentialState()
                        message = "本地数据与封面缓存已删除。平台凭据仍保留，可再次主动同步。"
                    } catch { message = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("游戏、封面缓存、历史快照、每日记录、AI 会话、清单和同步显示状态都会删除，无法撤销。") }
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
                Label("游戏、同步快照、Switch 每日记录", systemImage: "externaldrive.fill")
                Label("AI 会话、人格历史、待玩清单和私人备注", systemImage: "iphone")
                Label("平台令牌与 AI API Key 保存在 Keychain", systemImage: "key.fill")
            }
            Section("何时联网") {
                Text("只有你点击连接或同步时才请求游戏平台。只有你点击生成或发送消息时才请求模型服务。游迹不会自动同步，也不会在后台上传游戏库。")
            }
            Section("发送给 AI") {
                Text("人格分析仅发送当前筛选游戏的名称、平台、累计时长和已有奖杯比例。聊天发送创建会话时冻结的同类游戏信息及当前对话。不会发送游戏平台凭据、账号 ID、封面、私人备注或完整数据库。")
            }
            Section("用户控制") {
                Text("你可以导出完整本地备份、恢复备份、清除单个历史账号档案、删除全部本地内容、断开平台连接或清除 AI API Key。断开平台默认保留游戏历史。")
            }
            Section("第三方服务") {
                Text("PlayStation 和 Nintendo 接口并非稳定的公开第三方 API。AI 默认使用策量智算的 OpenAI 兼容接口，也可以在设置中改为你信任的 HTTPS 接口。第三方如何处理请求受其各自条款约束。")
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
