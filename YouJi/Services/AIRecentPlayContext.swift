import Foundation
import SwiftData

/// A request snapshot containing only dates, game names, platforms and activity
/// values. Local game/account identifiers never leave the builder.
struct AIRecentPlayContext: Codable, Sendable, Equatable {
    let capturedAt: Date
    let timeZoneIdentifier: String
    let startDayKey: String
    let endDayKey: String
    let lastObservedAt: Date?
    let records: [AIRecentPlayRecord]

    var dailyMinutes: Int { records.filter { $0.timing == .day }.reduce(0) { $0 + $1.minutes } }
    var intervalMinutes: Int { records.filter { $0.timing == .syncInterval }.reduce(0) { $0 + $1.minutes } }

    func validate() throws {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier), records.count <= 20_000,
              capturedAt.timeIntervalSinceReferenceDate.isFinite else { throw AIRecentPlayError.invalidContext }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let end = DailyPlayActivity.date(fromDayKey: endDayKey, calendar: calendar),
              DailyPlayActivity.dayKey(for: capturedAt, calendar: calendar) == endDayKey,
              let start = calendar.date(byAdding: .day, value: -29, to: end),
              DailyPlayActivity.dayKey(for: start, calendar: calendar) == startDayKey,
              lastObservedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 <= capturedAt }) ?? true else {
            throw AIRecentPlayError.invalidContext
        }
        for record in records {
            guard ["PS", "NS"].contains(record.platform), !record.title.isEmpty,
                  DailyPlayActivity.date(fromDayKey: record.dayKey, calendar: calendar) != nil,
                  record.dayKey >= startDayKey && record.dayKey <= endDayKey,
                  (-DataValidation.maximumMinutes...DataValidation.maximumMinutes).contains(record.minutes),
                  (-DataValidation.maximumTrophies...DataValidation.maximumTrophies).contains(record.trophyChange) else {
                throw AIRecentPlayError.invalidContext
            }
            switch record.timing {
            case .day:
                guard record.minutes >= 0, record.observedFrom == nil, record.observedTo == nil else { throw AIRecentPlayError.invalidContext }
            case .syncInterval:
                guard record.platform == "PS", let from = record.observedFrom, let to = record.observedTo,
                      from.timeIntervalSinceReferenceDate.isFinite, to.timeIntervalSinceReferenceDate.isFinite,
                      from <= to, to <= capturedAt,
                      DailyPlayActivity.dayKey(for: to, calendar: calendar) == record.dayKey else { throw AIRecentPlayError.invalidContext }
            }
        }
    }

    func encoded() throws -> Data {
        try validate()
        return try JSONEncoder().encode(self)
    }

    func promptText() throws -> String {
        try validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let grouped = Dictionary(grouping: records) { "\($0.platform)\u{0}\($0.title)" }
        var games: [AIRecentGameSummary] = grouped.values.map { values in
            let daily = values.filter { $0.timing == .day }.reduce(0) { $0 + $1.minutes }
            let interval = values.filter { $0.timing == .syncInterval }.reduce(0) { $0 + $1.minutes }
            let trophies = values.reduce(0) { $0 + $1.trophyChange }
            return AIRecentGameSummary(platform: values[0].platform, title: values[0].title,
                dailyRecordedMinutes: daily, intervalMinuteChange: interval, trophyChange: trophies)
        }
        games.sort { $0.platform == $1.platform ? $0.title < $1.title : $0.platform < $1.platform }
        let payload = AIRecentPlayPrompt(context: self, dailyRecordedMinutes: dailyMinutes,
            intervalMinuteChange: intervalMinutes, trophyChange: records.reduce(0) { $0 + $1.trophyChange }, games: games)
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}

private struct AIRecentPlayPrompt: Encodable {
    let context: AIRecentPlayContext
    let dailyRecordedMinutes: Int
    let intervalMinuteChange: Int
    let trophyChange: Int
    let games: [AIRecentGameSummary]
}

private struct AIRecentGameSummary: Encodable {
    let platform: String
    let title: String
    let dailyRecordedMinutes: Int
    let intervalMinuteChange: Int
    let trophyChange: Int
}

struct AIRecentPlayRecord: Codable, Sendable, Equatable {
    enum Timing: String, Codable, Sendable { case day, syncInterval }
    let platform: String
    let title: String
    let dayKey: String
    let minutes: Int
    let trophyChange: Int
    let timing: Timing
    var observedFrom: Date? = nil
    var observedTo: Date? = nil
}

enum AIRecentPlayError: LocalizedError {
    case invalidContext
    var errorDescription: String? { "这次保存的近期游玩背景暂时无法读取。请发送一条新消息，使用本机最新记录继续。" }
}

@MainActor
enum AIRecentPlayContextBuilder {
    private static func observationTime(_ date: Date) -> Date {
        // Seconds are enough for observation boundaries and avoid a submillisecond
        // timestamp rounding into the next day during a JSON backup round trip.
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }
    static func capture(accountScope: String, in context: ModelContext,
                        now: Date = .now, calendar: Calendar = .current) throws -> AIRecentPlayContext {
        let games = AIGameContext.games(in: accountScope, from: try context.fetch(FetchDescriptor<GameRecord>()))
        return try make(games: games, snapshots: context.fetch(FetchDescriptor<PlaySnapshot>()),
                        activities: context.fetch(FetchDescriptor<DailyPlayActivity>()),
                        allocations: PlayTimeResolver.values(context.fetch(FetchDescriptor<PlayTimeAllocation>())),
                        now: now, calendar: calendar)
    }

    static func make(games: [GameRecord], snapshots: [PlaySnapshot], activities: [DailyPlayActivity],
                     allocations: [PlayTimeAllocationValue], now: Date = .now,
                     calendar: Calendar = .current) throws -> AIRecentPlayContext {
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: end) ?? end
        let startKey = DailyPlayActivity.dayKey(for: start, calendar: calendar)
        let endKey = DailyPlayActivity.dayKey(for: end, calendar: calendar)
        let byID = Dictionary(games.map { ($0.applicationID, $0) }, uniquingKeysWith: { first, _ in first })
        let observations = snapshots.filter {
            guard let game = byID[$0.gameID] else { return false }
            return $0.accountID == game.accountID && $0.platform == game.platform && $0.date <= now
        }
        let ps = observations.filter { $0.platform == .playStation }
        var bounds: [String: (Date, Date)] = [:]
        for group in Dictionary(grouping: ps, by: \.gameID).values {
            let ordered = PlayTimeResolver.sorted(group)
            for (first, last) in zip(ordered, ordered.dropFirst()) {
                bounds[last.snapshotID] = (first.date, last.date)
            }
        }
        var records: [AIRecentPlayRecord] = []
        for event in PlayTimeResolver.events(snapshots: ps, allocations: allocations, calendar: calendar) {
            guard event.date >= start, event.date <= now, let game = byID[event.gameID],
                  event.minutes != 0 || event.trophies != 0 else { continue }
            let dayKey = DailyPlayActivity.dayKey(for: event.date, calendar: calendar)
            if event.hasDay {
                records.append(AIRecentPlayRecord(platform: "PS", title: game.title, dayKey: dayKey,
                    minutes: event.minutes, trophyChange: event.trophies, timing: .day))
            } else if let range = bounds[event.id] {
                records.append(AIRecentPlayRecord(platform: "PS", title: game.title, dayKey: dayKey,
                    minutes: event.minutes, trophyChange: event.trophies, timing: .syncInterval,
                    observedFrom: observationTime(range.0), observedTo: observationTime(range.1)))
            }
        }

        let daily = activities.filter {
            guard let game = byID[$0.gameID] else { return false }
            return game.platform == .switchConsole && $0.platform == .switchConsole && $0.accountID == game.accountID
                && $0.titleID == game.resolvedTitleID && $0.updatedAt <= now
                && DailyPlayActivity.date(fromDayKey: $0.resolvedDayKey, calendar: calendar) != nil
                && $0.resolvedDayKey >= startKey && $0.resolvedDayKey <= endKey
        }
        let exact = Dictionary(grouping: daily) { "\($0.gameID):\($0.resolvedDayKey)" }
            .compactMapValues { $0.max { $0.updatedAt < $1.updatedAt } }
        for activity in exact.values where activity.totalMinutes > 0 {
            guard let game = byID[activity.gameID] else { continue }
            records.append(AIRecentPlayRecord(platform: "NS", title: game.title, dayKey: activity.resolvedDayKey,
                minutes: activity.totalMinutes, trophyChange: 0, timing: .day))
        }
        // Retain the same stable seven-day fallback used by the library, including
        // short sessions. An exact zero overrides an older nonzero array value.
        for game in games where game.platform == .switchConsole && game.updatedAt <= now {
            guard game.weeklyMinutes.count == 7,
                  let anchor = DailyPlayActivity.date(fromDayKey: game.weeklyEndingDayKey, calendar: calendar) else { continue }
            for (index, minutes) in game.weeklyMinutes.enumerated() where minutes > 0 {
                guard let day = calendar.date(byAdding: .day, value: index - 6, to: anchor) else { continue }
                let key = DailyPlayActivity.dayKey(for: day, calendar: calendar)
                guard key >= startKey, key <= endKey, exact["\(game.applicationID):\(key)"] == nil else { continue }
                records.append(AIRecentPlayRecord(platform: "NS", title: game.title, dayKey: key,
                    minutes: minutes, trophyChange: 0, timing: .day))
            }
        }
        records.sort {
            if $0.dayKey != $1.dayKey { return $0.dayKey < $1.dayKey }
            if $0.platform != $1.platform { return $0.platform < $1.platform }
            if $0.title != $1.title { return $0.title < $1.title }
            if $0.timing != $1.timing { return $0.timing.rawValue < $1.timing.rawValue }
            if $0.minutes != $1.minutes { return $0.minutes < $1.minutes }
            if $0.trophyChange != $1.trophyChange { return $0.trophyChange < $1.trophyChange }
            return ($0.observedTo ?? .distantPast) < ($1.observedTo ?? .distantPast)
        }
        let updated = games.map(\.updatedAt).filter { $0 <= now }
        let result = AIRecentPlayContext(capturedAt: observationTime(now), timeZoneIdentifier: calendar.timeZone.identifier,
            startDayKey: startKey, endDayKey: endKey,
            lastObservedAt: (observations.map(\.date) + daily.map(\.updatedAt) + updated).max().map(observationTime), records: records)
        try result.validate()
        return result
    }
}
