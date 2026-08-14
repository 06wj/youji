import SwiftData
import SwiftUI

struct PlayCalendarSection: View {
    @Query private var latestActivities: [DailyPlayActivity]
    @State private var isPresented = false

    private let accountID: String
    private let games: [GameRecord]

    init(accountID: String, games: [GameRecord]) {
        let platformRaw = GamePlatform.switchConsole.rawValue
        var descriptor = FetchDescriptor<DailyPlayActivity>(
            predicate: #Predicate {
                $0.platformRaw == platformRaw && $0.accountID == accountID
            },
            sortBy: [SortDescriptor(\.day, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        _latestActivities = Query(descriptor)
        self.accountID = accountID
        self.games = games
    }

    var body: some View {
        if let latestDay = latestActivities.first?.day {
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(YJColor.purple, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PLAY DAYS / 游玩日历")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(YJColor.muted)
                        Text("查看 Switch 每日游玩记录")
                            .font(.headline)
                        Text("最近记录 · \(latestDay.formatted(.dateTime.month().day().weekday(.wide)))")
                            .font(.caption)
                            .foregroundStyle(YJColor.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(YJColor.muted)
                }
                .padding(16)
                .youjiCard()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开 Switch 游玩日历")
            .sheet(isPresented: $isPresented) {
                PlayCalendarView(accountID: accountID, games: games)
            }
        }
    }
}

private struct PlayCalendarView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var activities: [DailyPlayActivity]

    private let gamesByID: [String: GameRecord]

    init(accountID: String, games: [GameRecord]) {
        let platformRaw = GamePlatform.switchConsole.rawValue
        _activities = Query(
            filter: #Predicate<DailyPlayActivity> {
                $0.platformRaw == platformRaw && $0.accountID == accountID
            },
            sort: \DailyPlayActivity.day,
            order: .reverse
        )
        self.gamesByID = Dictionary(uniqueKeysWithValues: games.map { ($0.applicationID, $0) })
    }

    private var days: [PlayCalendarDay] {
        Dictionary(grouping: activities) { Calendar.current.startOfDay(for: $0.day) }
            .map { day, activities in
                PlayCalendarDay(
                    day: day,
                    activities: activities.sorted { $0.totalMinutes > $1.totalMinutes }
                )
            }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(days) { day in
                    Section {
                        ForEach(day.activities, id: \.activityID) { activity in
                            activityRow(activity)
                        }
                    } header: {
                        HStack {
                            Text(day.day.formatted(.dateTime.year().month().day().weekday(.wide)))
                            Spacer()
                            Text(format(minutes: day.totalMinutes))
                        }
                    }
                }

                Section {
                    Label(
                        "Nintendo 提供最近 7 天的精确每日记录；每次同步后会长期保存在本机。PlayStation 暂无每日明细。",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(YJColor.muted)
                }
            }
            .navigationTitle("游玩日历")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func activityRow(_ activity: DailyPlayActivity) -> some View {
        HStack(spacing: 12) {
            if let game = gamesByID[activity.gameID] {
                CachedCoverImage(urlString: game.imageURL)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(game.title)
                    .font(.subheadline.bold())
                    .lineLimit(2)
            } else {
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(YJColor.muted)
                    .frame(width: 44, height: 44)
                    .background(YJColor.paper, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(activity.titleID)
                    .font(.subheadline.bold())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(format(minutes: activity.totalMinutes))
                .font(.caption.bold())
                .foregroundStyle(YJColor.muted)
        }
        .padding(.vertical, 3)
    }

    private func format(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

private struct PlayCalendarDay: Identifiable {
    let day: Date
    let activities: [DailyPlayActivity]

    var id: Date { day }
    var totalMinutes: Int { activities.reduce(0) { $0 + $1.totalMinutes } }
}
