import Foundation
import SwiftData

enum PlayTimeAllocationError: LocalizedError {
    case invalid(String)
    case changed

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .changed: "这段记录已发生变化，请重新打开后调整。"
        }
    }
}

struct PlayTimeEvent {
    let id: String
    let gameID: String
    let date: Date
    let minutes: Int
    let trophies: Int
    var hasDay: Bool = false
}

struct PlayHistoryPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let totalMinutes: Int
}

enum PlayTimeResolver {
    static func sorted(_ snapshots: [PlaySnapshot]) -> [PlaySnapshot] {
        snapshots.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.totalMinutes != $1.totalMinutes { return $0.totalMinutes < $1.totalMinutes }
            return $0.snapshotID < $1.snapshotID
        }
    }

    static func values(_ allocations: [PlayTimeAllocation]) -> [PlayTimeAllocationValue] {
        // An unreadable layer cannot erase raw history. Backup still throws rather
        // than silently dropping it, and the editor explains the read failure.
        allocations.compactMap { try? $0.readValue() }
    }

    static func draft(from start: PlaySnapshot, to end: PlaySnapshot,
                      calendar: Calendar = .current) -> PlayTimeAllocationValue {
        let endDay = DailyPlayActivity.dayKey(for: end.date, calendar: calendar)
        return PlayTimeAllocationValue(
            gameID: end.gameID, accountID: end.accountID,
            startSnapshotID: start.snapshotID, endSnapshotID: end.snapshotID,
            startTotalMinutes: start.totalMinutes, endTotalMinutes: end.totalMinutes,
            startDayKey: DailyPlayActivity.dayKey(for: start.date, calendar: calendar), endDayKey: endDay,
            days: [AllocatedPlayDay(dayKey: endDay, minutes: end.totalMinutes - start.totalMinutes)],
            updatedAt: .now
        )
    }

    /// Validate against *all* source snapshots. Imported intermediate observations
    /// may split a range, but its original allocation still replaces the whole range.
    static func coveredIDs(_ value: PlayTimeAllocationValue, snapshots: [PlaySnapshot]) throws -> Set<String> {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw PlayTimeAllocationError.invalid(message) }
        }
        let parts = value.gameID.split(separator: ":", omittingEmptySubsequences: false)
        try require(parts.count == 3 && parts.first == "ps" && !value.accountID.isEmpty
                    && parts[1] == Substring(value.accountID) && !parts[2].isEmpty, "游玩日期只能关联同一 PS 账号的游戏")
        try require(DataValidation.minutes(value.startTotalMinutes) && DataValidation.minutes(value.endTotalMinutes)
                    && value.endTotalMinutes > value.startTotalMinutes, "新增时长不正确")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let firstDay = DailyPlayActivity.date(fromDayKey: value.startDayKey, calendar: utc),
              let lastDay = DailyPlayActivity.date(fromDayKey: value.endDayKey, calendar: utc), firstDay <= lastDay else {
            throw PlayTimeAllocationError.invalid("日期范围不正确")
        }
        let sorted = sorted(snapshots.filter { $0.gameID == value.gameID })
        guard let start = sorted.firstIndex(where: { $0.snapshotID == value.startSnapshotID }),
              let end = sorted.firstIndex(where: { $0.snapshotID == value.endSnapshotID }), start < end else {
            throw PlayTimeAllocationError.invalid("找不到这段时长对应的原始记录")
        }
        try require(sorted[start].totalMinutes == value.startTotalMinutes && sorted[end].totalMinutes == value.endTotalMinutes,
                    "分配时长与原始记录不一致")
        // Day keys retain the editor's time zone. Allow the valid UTC offset range
        // instead of reinterpreting the saved dates in the importing device's zone.
        for (day, date) in [(firstDay, sorted[start].date), (lastDay, sorted[end].date)] {
            let distance = date.timeIntervalSince(day)
            try require((-14 * 3_600...38 * 3_600).contains(distance), "分配日期范围与原始记录不一致")
        }
        for index in start...end {
            try require(sorted[index].platform == .playStation && sorted[index].accountID == value.accountID,
                        "原始记录的账号归属不一致")
            if index > start && !value.isDeleted {
                try require(sorted[index].totalMinutes >= sorted[index - 1].totalMinutes,
                            "这段时长包含平台时长回退，请先恢复原来的日期分布")
            }
        }
        try require(value.updatedAt.timeIntervalSinceReferenceDate.isFinite, "记录时间不正确")
        if value.isDeleted {
            try require(value.days.isEmpty, "已恢复的日期分布不能包含每日时长")
        } else {
            try require(!value.days.isEmpty && value.days.count <= 3_660, "请至少分配一个日期，最多支持 3660 天")
            try require(Set(value.days.map(\.dayKey)).count == value.days.count, "同一个日期只能填写一次")
            for day in value.days {
                try require(DailyPlayActivity.date(fromDayKey: day.dayKey, calendar: utc) != nil
                            && day.dayKey >= value.startDayKey && day.dayKey <= value.endDayKey,
                            "日期需在这两次记录之间")
                try require((1...1_440).contains(day.minutes), "每天需填写 1 分钟到 24 小时")
            }
            try require(value.days.reduce(0) { $0 + $1.minutes } == value.totalMinutes, "每天的时长合计需等于本次新增时长")
        }
        return Set(sorted[(start + 1)...end].map(\.snapshotID))
    }

    static func validate(_ allocations: [PlayTimeAllocationValue], snapshots: [PlaySnapshot]) throws {
        var covered = Set<String>()
        var ids = Set<String>()
        var dailyTotals: [String: Int] = [:]
        for value in allocations {
            guard ids.insert(value.id).inserted else { throw PlayTimeAllocationError.invalid("存在重复的日期分配") }
            let range = try coveredIDs(value, snapshots: snapshots)
            guard !value.isDeleted else { continue }
            guard covered.isDisjoint(with: range) else {
                throw PlayTimeAllocationError.invalid("两份日期分配覆盖了同一段时长，请先恢复其中一份的日期分布")
            }
            covered.formUnion(range)
            for day in value.days {
                let key = "\(value.gameID):\(day.dayKey)"
                dailyTotals[key, default: 0] += day.minutes
                guard dailyTotals[key, default: 0] <= 1_440 else {
                    throw PlayTimeAllocationError.invalid("同一游戏在同一天的分配合计不能超过 24 小时")
                }
            }
        }
    }

    static func active(_ allocations: [PlayTimeAllocationValue], snapshots: [PlaySnapshot]) -> [(PlayTimeAllocationValue, Set<String>)] {
        var covered = Set<String>()
        var result: [(PlayTimeAllocationValue, Set<String>)] = []
        // Deterministic fallback for damaged local data; valid writes/imports reject overlaps.
        for value in allocations.sorted(by: { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }) {
            guard !value.isDeleted, let range = try? coveredIDs(value, snapshots: snapshots),
                  covered.isDisjoint(with: range) else { continue }
            covered.formUnion(range)
            result.append((value, range))
        }
        return result
    }

    static func editableIntervals(snapshots: [PlaySnapshot], allocations: [PlayTimeAllocationValue],
                                  calendar: Calendar = .current) -> [PlayTimeAllocationValue] {
        let active = active(allocations, snapshots: snapshots)
        let covered = active.reduce(into: Set<String>()) { $0.formUnion($1.1) }
        var result = active.map(\.0)
        for group in Dictionary(grouping: snapshots, by: \.gameID).values {
            let ordered = sorted(group)
            for (start, end) in zip(ordered, ordered.dropFirst()) where end.platform == .playStation
                && start.accountID == end.accountID && end.totalMinutes > start.totalMinutes && !covered.contains(end.snapshotID) {
                result.append(draft(from: start, to: end, calendar: calendar))
            }
        }
        return result.sorted { $0.endDayKey == $1.endDayKey ? $0.endTotalMinutes > $1.endTotalMinutes : $0.endDayKey > $1.endDayKey }
    }

    static func events(snapshots: [PlaySnapshot], allocations: [PlayTimeAllocationValue] = [],
                       calendar: Calendar = .current) -> [PlayTimeEvent] {
        let active = active(allocations, snapshots: snapshots)
        let covered = active.reduce(into: Set<String>()) { $0.formUnion($1.1) }
        var result: [PlayTimeEvent] = []
        for group in Dictionary(grouping: snapshots, by: \.gameID).values {
            let ordered = sorted(group)
            for (start, end) in zip(ordered, ordered.dropFirst()) where start.accountID == end.accountID && start.platform == end.platform {
                result.append(PlayTimeEvent(id: end.snapshotID, gameID: end.gameID, date: end.date,
                    minutes: covered.contains(end.snapshotID) ? 0 : end.totalMinutes - start.totalMinutes,
                    trophies: end.trophiesEarned - start.trophiesEarned))
            }
        }
        for (value, _) in active {
            for day in value.days {
                guard let date = DailyPlayActivity.date(fromDayKey: day.dayKey, calendar: calendar) else { continue }
                result.append(PlayTimeEvent(id: "\(value.id):\(day.dayKey)", gameID: value.gameID,
                                           date: date, minutes: day.minutes, trophies: 0, hasDay: true))
            }
        }
        return result
    }

    static func historyPoints(snapshots: [PlaySnapshot], allocations: [PlayTimeAllocationValue],
                              calendar: Calendar = .current) -> [PlayHistoryPoint] {
        guard let first = sorted(snapshots).first else { return [] }
        let events = events(snapshots: snapshots, allocations: allocations, calendar: calendar)
        var byDay = Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
            .mapValues { $0.reduce(0) { $0 + $1.minutes } }
        byDay[calendar.startOfDay(for: first.date), default: 0] += first.totalMinutes
        var total = 0
        return byDay.keys.sorted().map { day in
            total += byDay[day] ?? 0
            return PlayHistoryPoint(date: day, totalMinutes: max(0, total))
        }
    }
}

@MainActor
enum PlayTimeAllocationService {
    static func save(_ draft: PlayTimeAllocationValue, expectedUpdatedAt: Date?, revision: UUID,
                     modelContext: ModelContext, now: Date = .now) throws {
        try LocalDataRevision.check(revision)
        try LocalPersistence.transaction(modelContext) { writer in
            let gameID = draft.gameID
            guard let game = try writer.fetch(FetchDescriptor<GameRecord>(predicate: #Predicate { $0.applicationID == gameID })).first,
                  game.platform == .playStation, game.accountID == draft.accountID else { throw PlayTimeAllocationError.changed }
            let models = try writer.fetch(FetchDescriptor<PlayTimeAllocation>())
            let existing = models.first { $0.allocationID == draft.id }
            guard try existing?.readValue().updatedAt == expectedUpdatedAt else { throw PlayTimeAllocationError.changed }
            var value = draft
            value.days.sort { $0.dayKey < $1.dayKey }
            value.updatedAt = max(now, (expectedUpdatedAt ?? .distantPast).addingTimeInterval(0.001))
            let allValues = try models.filter { $0.allocationID != value.id }.map { try $0.readValue() } + [value]
            let snapshots = try writer.fetch(FetchDescriptor<PlaySnapshot>())
            try PlayTimeResolver.validate(allValues, snapshots: snapshots)
            if let existing { try existing.replace(with: value) }
            else { writer.insert(try PlayTimeAllocation(value)) }
        }
    }
}
