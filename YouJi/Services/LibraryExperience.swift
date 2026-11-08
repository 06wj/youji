import Foundation
import SwiftUI

struct NintendoActivityDay: Identifiable, Equatable {
    let day: Date
    let dayKey: String
    let recordedMinutes: Int?
    let missingGames: Int
    var id: String { dayKey }
    var isPartial: Bool { recordedMinutes != nil && missingGames > 0 }
}

struct NintendoActivityWindow {
    let days: [NintendoActivityDay]
    let latestObservation: Date?
    let gameMinutes: [String: Int]
    var totalMinutes: Int { days.compactMap(\.recordedMinutes).reduce(0, +) }
    var activeDays: Int { days.filter { ($0.recordedMinutes ?? 0) > 0 }.count }
    var incompleteDays: Int { days.filter { $0.recordedMinutes == nil || $0.isPartial }.count }
    var hasRecords: Bool { days.contains { $0.recordedMinutes != nil } }

    /// Each stored seven-day array belongs to that game's sync date, never to the date the view opens.
    /// Exact daily records take precedence. Missing coverage is distinct from observed zero activity.
    static func make(games: [GameRecord], activities: [DailyPlayActivity], now: Date = .now,
                     calendar: Calendar = .current) -> NintendoActivityWindow {
        let games = games.filter { $0.platform == .switchConsole }
        let byID = Dictionary(games.map { ($0.applicationID, $0) }, uniquingKeysWith: { first, _ in first })
        let relevant = activities.filter { activity in
            guard activity.platform == .switchConsole, let game = byID[activity.gameID] else { return false }
            return activity.accountID == game.accountID && activity.titleID == game.resolvedTitleID
                && activity.displayDay <= now && activity.updatedAt <= now
        }
        let exact = Dictionary(grouping: relevant) { "\($0.gameID):\($0.resolvedDayKey)" }
            .compactMapValues { $0.max { $0.updatedAt < $1.updatedAt } }
        let today = calendar.startOfDay(for: now)
        var gameMinutes: [String: Int] = [:]
        let days = (-6...0).compactMap { offset -> NintendoActivityDay? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let key = DailyPlayActivity.dayKey(for: day, calendar: calendar)
            var total = 0
            var observed = 0
            for game in games {
                let minutes: Int?
                if let activity = exact["\(game.applicationID):\(key)"] {
                    minutes = max(0, activity.totalMinutes)
                } else if game.updatedAt <= now,
                          let anchor = DailyPlayActivity.date(fromDayKey: game.weeklyEndingDayKey, calendar: calendar) {
                    let distance = calendar.dateComponents([.day], from: day, to: anchor).day ?? -1
                    let week = game.weeklyMinutes
                    minutes = (0...6).contains(distance) && week.count == 7 ? max(0, week[6 - distance]) : nil
                } else {
                    minutes = nil
                }
                if let minutes {
                    observed += 1
                    total += minutes
                    gameMinutes[game.applicationID, default: 0] += minutes
                }
            }
            return NintendoActivityDay(day: day, dayKey: key,
                                       recordedMinutes: observed > 0 ? total : nil,
                                       missingGames: games.count - observed)
        }
        let observations = games.map(\.updatedAt).filter { $0 <= now } + relevant.map(\.updatedAt)
        return NintendoActivityWindow(days: days, latestObservation: observations.max(), gameMinutes: gameMinutes)
    }
}

enum LibraryEmptyReason: Equatable {
    case disconnected, awaitingSync, noRecords, hidden(Int), failed

    static func resolve(isConnected: Bool, hasSynced: Bool, recordCount: Int,
                        visibleCount: Int, hasIssue: Bool) -> LibraryEmptyReason {
        if recordCount > 0 && visibleCount == 0 { return .hidden(recordCount) }
        if hasIssue { return .failed }
        if !isConnected { return .disconnected }
        return hasSynced ? .noRecords : .awaitingSync
    }
}

struct WeeklyReviewGame: Identifiable {
    let game: GameRecord
    let minutes: Int
    let trophies: Int
    var id: String { game.applicationID }
}

struct LocalWeeklyReview {
    let start: Date
    let end: Date
    let games: [WeeklyReviewGame]
    let hasBaseline: Bool
    let latestRecord: Date?
    var totalMinutes: Int { games.reduce(0) { $0 + $1.minutes } }
    var totalTrophies: Int { games.reduce(0) { $0 + $1.trophies } }

    static func make(games: [GameRecord], snapshots: [PlaySnapshot], activities: [DailyPlayActivity],
                     now: Date = .now, calendar: Calendar = .current,
                     allocations: [PlayTimeAllocationValue] = []) -> LocalWeeklyReview {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let byID = Dictionary(games.map { ($0.applicationID, $0) }, uniquingKeysWith: { first, _ in first })
        let snapshots = snapshots.filter { snapshot in
            guard let game = byID[snapshot.gameID] else { return false }
            return snapshot.accountID == game.accountID && snapshot.platform == game.platform && snapshot.date <= now
        }
        let activities = activities.filter { activity in
            guard let game = byID[activity.gameID] else { return false }
            return activity.platform == .switchConsole && activity.accountID == game.accountID
                && activity.platform == game.platform && activity.displayDay <= now
        }
        let entries = PlayTimelineBuilder.entries(snapshots: snapshots.filter { $0.platform == .playStation }, activities: activities,
                                                  includedGameIDs: Set(byID.keys), allocations: allocations, calendar: calendar)
            .filter { $0.date >= start && $0.date <= now }
        let reviewGames = Dictionary(grouping: entries, by: \.gameID).compactMap { id, entries -> WeeklyReviewGame? in
            guard let game = byID[id] else { return nil }
            return WeeklyReviewGame(game: game, minutes: entries.reduce(0) { $0 + $1.addedMinutes },
                                    trophies: entries.reduce(0) { $0 + $1.addedTrophies })
        }.sorted {
            if $0.minutes != $1.minutes { return $0.minutes > $1.minutes }
            if $0.trophies != $1.trophies { return $0.trophies > $1.trophies }
            return $0.id < $1.id
        }
        return LocalWeeklyReview(start: start, end: now, games: reviewGames,
                                 hasBaseline: !snapshots.isEmpty || !activities.isEmpty,
                                 latestRecord: (snapshots.map(\.date) + activities.map(\.displayDay)).max())
    }

    var narrative: String {
        guard let top = games.first else {
            return hasBaseline ? "这 7 天还没有新的游玩变化记录。下次主动同步后，再回来看看。"
                : "第一份档案正在起步。保存游玩记录后，这里会串起你这一周的冒险。"
        }
        var text = "近 7 天记录了 \(games.count) 款游戏的变化。"
        if top.minutes > 0 { text += "投入最多的是《\(top.game.title)》。" }
        if totalTrophies > 0 { text += "还收获了 \(totalTrophies) 个奖杯。" }
        return text
    }
}

struct WeeklyReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let review: LocalWeeklyReview
    let accountScopeKey: String
    @State private var selectedGame: GameRecord?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("YOUR WEEK IN PLAY").font(.system(.caption2, design: .monospaced, weight: .bold))
                            .tracking(2).foregroundStyle(YJColor.lime)
                        Text("这一周，留下了什么？").font(.title2.bold())
                        Text("\(review.start.formatted(.dateTime.month().day())) — \(review.end.formatted(.dateTime.month().day()))")
                            .font(.caption).foregroundStyle(YJColor.muted)
                        Text(review.narrative).font(.subheadline).lineSpacing(5)
                    }
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(YJArtwork(name: "ArchiveWorld", shade: 0.65)).youjiCard()
                    if !review.games.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("已记录的时长变化").font(.caption).foregroundStyle(YJColor.muted)
                            Text(Self.format(review.totalMinutes)).font(.system(.largeTitle, design: .rounded, weight: .bold))
                                .foregroundStyle(YJColor.lime)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).youjiCard()
                        ForEach(review.games) { item in
                            Button { selectedGame = item.game } label: {
                                HStack(spacing: 12) {
                                    CachedCoverImage(urlString: item.game.imageURL).frame(width: 52, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 9))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.game.title).font(.subheadline.bold()).foregroundStyle(YJColor.ink)
                                        Text("\(item.game.platform.shortName) · \(Self.format(item.minutes))")
                                            .font(.caption).foregroundStyle(YJColor.muted)
                                        if item.game.platform == .playStation && item.trophies > 0 {
                                            Label("新增 \(item.trophies) 个奖杯", systemImage: "trophy")
                                                .font(.caption2).foregroundStyle(YJColor.playStation)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").foregroundStyle(YJColor.muted)
                                }.padding(14).youjiCard()
                            }.buttonStyle(.plain)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if let latest = review.latestRecord {
                            Text("最近记录：\(latest.formatted(.dateTime.year().month().day()))").font(.caption.bold())
                        }
                        Text("仅整理本机已有记录，不会联网。Switch 使用每日活动；PS 时长优先按已记录的游玩日期呈现；缺少每日记录时，时长与奖杯变化归入后一次同步日期。没有记录的日期不代表没有玩。")
                            .font(.caption).foregroundStyle(YJColor.muted).lineSpacing(4)
                    }.padding(16)
                }.padding(18)
            }
            .background(YJBackground()).navigationTitle("近 7 天回顾").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .sheet(item: $selectedGame) { GameDetailView(game: $0, accountScopeKey: accountScopeKey) }
        }
    }

    private static func format(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
