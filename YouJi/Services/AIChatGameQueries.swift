import Foundation
import SwiftData

struct AIChatFunctionTool: Encodable, Sendable {
    struct Parameter: Encodable, Sendable {
        let type: String
        var description: String? = nil
        var nullable = false
        var choices: [String]? = nil
        var items: [String]? = nil

        private enum Key: String, CodingKey { case type, description, choices = "enum", items }
        private struct Items: Encodable {
            let type = "string"
            let choices: [String]
            enum CodingKeys: String, CodingKey { case type, choices = "enum" }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: Key.self)
            if nullable { try values.encode([type, "null"], forKey: .type) }
            else { try values.encode(type, forKey: .type) }
            try values.encodeIfPresent(description, forKey: .description)
            try values.encodeIfPresent(choices, forKey: .choices)
            try values.encodeIfPresent(items.map { Items(choices: $0) }, forKey: .items)
        }
    }

    struct Parameters: Encodable, Sendable {
        let type = "object"
        let additionalProperties = false
        let properties: [String: Parameter]
        let required: [String]
    }

    let type = "function"
    let strict = true
    let name: String
    let description: String
    let parameters: Parameters

    init(_ name: String, _ description: String, properties: [String: Parameter]) {
        self.name = name
        self.description = description
        self.parameters = Parameters(properties: properties, required: properties.keys.sorted())
    }
}

struct AIChatToolOutput: Sendable {
    let json: String
    let queriedRecords: Bool
}

/// Reads the conversation's local archive only when the model asks for a tool.
@MainActor
struct AIChatGameQueries {
    nonisolated static let maximumCalls = 4
    private static let maximumPageSize = 20

    static let tools = [
        AIChatFunctionTool("query_games", """
            筛选、查找、统计和排序游戏的生涯累计记录。奖杯数量、完成率和白金数是不同的排序。奖杯排序只包含有奖杯资料的 PS 游戏。按 `fields` 选择所需指标，limit=0 只取匹配总数和所选汇总。
            """, properties: [
                "platform": .init(type: "string", choices: Platform.allCases.map(\.rawValue)),
                "title_contains": .init(type: "string", description: "游戏名片段，null 表示不限。", nullable: true),
                "min_minutes_exclusive": .init(type: "integer", description: "累计分钟数严格大于此值，例如超过 2 小时用 120。", nullable: true),
                "max_minutes_inclusive": .init(type: "integer", description: "累计分钟数小于等于此值。", nullable: true),
                "platinum_only": .init(type: "boolean", description: "只选已获白金的 PS 游戏。"),
                "sort_by": .init(type: "string", choices: GameSort.allCases.map(\.rawValue)),
                "ascending": .init(type: "boolean", description: "false 表示最大或最新优先。"),
                "fields": .init(type: "array", description: "只选回答需要的字段。游戏名称和平台总是随列表返回。", items: GameField.allCases.map(\.rawValue)),
                "limit": .init(type: "integer", description: "0–20，取所需最小数量。"),
                "offset": .init(type: "integer", description: "从 0 开始。仅在需要更多时用上次结果的 nextOffset。")
            ]),
        AIChatFunctionTool("query_play_activity", """
            按游迹时间线的最终记录日期查询自然日范围内的游玩。minutes 是当前范围或分组内的游玩分钟合计。knownPlayedGameCount 是期间有游玩记录的游戏数。只有 lastPlayedDay 的游戏可能缺少时长。
            """, properties: [
                "platform": .init(type: "string", choices: Platform.allCases.map(\.rawValue)),
                "title_contains": .init(type: "string", description: "游戏名片段，null 表示不限。", nullable: true),
                "start_day": .init(type: "string", description: "本机自然日 YYYY-MM-DD，包含该日。"),
                "end_day": .init(type: "string", description: "本机自然日 YYYY-MM-DD，包含该日，至多到今天。"),
                "group_by": .init(type: "string", description: "summary 只取汇总，game 按游戏汇总，day 按记录日期汇总，game_day 列出每天各游戏的时长。", choices: ActivityGrouping.allCases.map(\.rawValue)),
                "sort_by": .init(type: "string", description: "降序，recent 按最近记录日期。", choices: ActivitySort.allCases.map(\.rawValue)),
                "include_trophies": .init(type: "boolean", description: "问题涉及期间奖杯时才用 true。奖杯净变化按 PS 档案的记录日期汇总。"),
                "limit": .init(type: "integer", description: "0–20，0 只取汇总。"),
                "offset": .init(type: "integer", description: "从 0 开始。仅在需要更多时用上次结果的 nextOffset。")
            ])
    ]

    let today: String
    private let accountScope: String
    private let context: ModelContext
    private let revision: UUID
    private let now: Date
    private let calendar: Calendar

    init(accountScope: String, in context: ModelContext, revision: UUID = LocalDataRevision.current,
         now: Date = .now, calendar: Calendar = .current) {
        self.accountScope = accountScope
        self.context = context
        self.revision = revision
        self.now = now
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        self.calendar = gregorian
        today = DailyPlayActivity.dayKey(for: now, calendar: gregorian)
    }

    func checkAccess() throws {
        try LocalDataRevision.check(revision)
    }

    func execute(name: String, arguments: String) throws -> AIChatToolOutput {
        try checkAccess()
        guard let tool = Self.tools.first(where: { $0.name == name }) else {
            return Self.failure("unknown_tool", "请使用已提供的本机游戏查询工具。")
        }
        let data = Data(arguments.utf8)
        guard data.count <= 4_096,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object.keys.allSatisfy({ tool.parameters.properties[$0] != nil }) else {
            return Self.failure("invalid_arguments", "参数应为工具支持的查询字段。")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            if name == "query_games" {
                return try Self.output(listGames(decoder.decode(GameArguments.self, from: data)))
            }
            return try Self.output(playActivity(decoder.decode(ActivityArguments.self, from: data)))
        } catch let error as QueryError {
            return Self.failure("invalid_arguments", error.message)
        } catch is DecodingError {
            return Self.failure("invalid_arguments", "请检查查询参数的类型和选项。")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Self.failure("records_unavailable", "本机游戏记录暂时无法读取。")
        }
    }

    private func listGames(_ args: GameArguments) throws -> GameResult {
        try Self.validatePage(limit: args.limit, offset: args.offset)
        let trophyRanking = args.sortBy.isTrophySort || args.platinumOnly
        if trophyRanking && args.platform == .ns {
            throw QueryError("奖杯排行和白金筛选只支持 PlayStation。")
        }
        guard args.minMinutesExclusive.map(DataValidation.minutes) ?? true,
              args.maxMinutesInclusive.map(DataValidation.minutes) ?? true,
              (args.minMinutesExclusive ?? -1) < (args.maxMinutesInclusive ?? Int.max) else {
            throw QueryError("累计时长范围不正确，请用非负整分钟。")
        }
        let games = try matchingGames(platform: trophyRanking ? .ps : args.platform, title: args.titleContains).filter { game in
            game.totalMinutes > (args.minMinutesExclusive ?? -1)
                && game.totalMinutes <= (args.maxMinutesInclusive ?? Int.max)
                && (!args.platinumOnly || game.platinumTrophiesEarned > 0)
                && (!args.sortBy.isTrophySort || Self.hasTrophyCount(game))
                && (args.sortBy != .trophyCompletion || game.trophiesDefined > 0)
        }
        let sorted = args.limit == 0 ? [] : games.sorted { left, right in
            let l = args.sortBy.value(left)
            let r = args.sortBy.value(right)
            if let l, let r, l != r { return args.ascending ? l < r : l > r }
            if (l == nil) != (r == nil) { return r == nil }
            let leftDate = left.lastPlayedAt ?? .distantPast
            let rightDate = right.lastPlayedAt ?? .distantPast
            return leftDate == rightDate ? left.applicationID < right.applicationID : leftDate > rightDate
        }
        let page = sorted.dropFirst(args.offset).prefix(args.limit)
        let fields = Set(args.fields)
        let includeTrophies = fields.contains(.trophies) && args.platform != .ns
        let psWithTrophies = includeTrophies && args.limit == 0 ? games.filter(Self.hasTrophyCount) : []
        return GameResult(matchingCount: games.count, nextOffset: Self.nextOffset(args.offset, page.count, games.count),
            matchingTotalMinutes: args.limit == 0 && fields.contains(.totalMinutes) ? games.reduce(0) { $0 + $1.totalMinutes } : nil,
            matchingPSTrophies: psWithTrophies.isEmpty ? nil : psWithTrophies.reduce(0) { $0 + $1.trophiesEarned },
            gamesWithTrophyData: includeTrophies && args.limit == 0 ? psWithTrophies.count : nil,
            games: page.map { game in
                let trophies = includeTrophies && Self.hasTrophyCount(game)
                return GameResult.Row(title: Self.exportedTitle(game), platform: game.platform.shortName,
                    totalMinutes: fields.contains(.totalMinutes) ? game.totalMinutes : nil,
                    lastPlayedDay: fields.contains(.lastPlayed) ? game.lastPlayedAt.map(dayKey) : nil,
                    trophiesEarned: trophies ? game.trophiesEarned : nil,
                    trophiesDefined: trophies && game.trophiesDefined > 0 ? game.trophiesDefined : nil,
                    platinumCount: trophies ? game.platinumTrophiesEarned : nil)
            })
    }

    private func playActivity(_ args: ActivityArguments) throws -> ActivityResult {
        try Self.validatePage(limit: args.limit, offset: args.offset)
        guard let start = DailyPlayActivity.date(fromDayKey: args.startDay, calendar: calendar),
              let end = DailyPlayActivity.date(fromDayKey: args.endDay, calendar: calendar),
              start <= end, args.endDay <= today,
              let endExclusive = calendar.date(byAdding: .day, value: 1, to: end) else {
            throw QueryError("请选择有效的 YYYY-MM-DD 日期范围，结束日期应不晚于今天。")
        }
        let includeTrophies = args.includeTrophies && args.platform != .ns
        if args.sortBy == .trophies && (!includeTrophies || args.groupBy != .game) {
            throw QueryError("奖杯变化排行需包含 PS 奖杯并按游戏分组。")
        }
        let games = try matchingGames(platform: args.sortBy == .trophies ? .ps : args.platform, title: args.titleContains)
        let ps = games.filter { $0.platform == .playStation }
        let nintendo = games.filter { $0.platform == .switchConsole }
        var activity = ActivityProjection(collectGameDays: args.groupBy == .gameDay && args.limit > 0)
        var latestObservation = games.lazy.map(\.updatedAt).filter { $0 <= now }.max()
        for game in games {
            if let last = game.lastPlayedAt, last >= start, last < endExclusive, last <= now {
                activity.games[game.applicationID, default: .init()].lastPlayedDay = dayKey(last)
            }
        }

        if let account = ps.first?.accountID {
            let platform = GamePlatform.playStation.rawValue
            let cutoff = now
            let ids = Set(ps.map(\.applicationID))
            let snapshots = try context.fetch(FetchDescriptor<PlaySnapshot>(predicate: #Predicate {
                $0.accountID == account && $0.platformRaw == platform && $0.date <= cutoff
            })).filter { ids.contains($0.gameID) }
            let allocations = try context.fetch(FetchDescriptor<PlayTimeAllocation>(predicate: #Predicate {
                $0.accountID == account
            })).filter { ids.contains($0.gameID) }
            latestObservation = ([latestObservation].compactMap { $0 } + snapshots.map(\.date)).max()
            let events = PlayTimeResolver.events(snapshots: snapshots, allocations: PlayTimeResolver.values(allocations), calendar: calendar)
            for event in events where event.date >= start && event.date < endExclusive && event.date <= now {
                let trophies = includeTrophies ? event.trophies : 0
                guard event.minutes != 0 || trophies != 0 else { continue }
                activity.record(id: event.gameID, day: dayKey(event.date), minutes: event.minutes, trophies: trophies)
            }
        }
        if let account = nintendo.first?.accountID {
            let platform = GamePlatform.switchConsole.rawValue
            let cutoff = now
            let byID = Dictionary(uniqueKeysWithValues: nintendo.map { ($0.applicationID, $0) })
            let records = try context.fetch(FetchDescriptor<DailyPlayActivity>(predicate: #Predicate {
                $0.accountID == account && $0.platformRaw == platform && $0.updatedAt <= cutoff
            })).filter { record in
                guard let game = byID[record.gameID], record.titleID == game.resolvedTitleID else { return false }
                return record.resolvedDayKey >= args.startDay && record.resolvedDayKey <= args.endDay
                    && DailyPlayActivity.date(fromDayKey: record.resolvedDayKey, calendar: calendar) != nil
            }
            latestObservation = ([latestObservation].compactMap { $0 } + records.map(\.updatedAt)).max()
            let exact = Dictionary(grouping: records) { "\($0.gameID):\($0.resolvedDayKey)" }
                .compactMapValues { $0.max { $0.updatedAt < $1.updatedAt } }
            for record in exact.values where record.totalMinutes > 0 {
                activity.record(id: record.gameID, day: record.resolvedDayKey, minutes: record.totalMinutes)
            }
            // The stored seven-day array remains anchored to the sync that produced it.
            for game in nintendo where game.updatedAt <= now {
                let week = game.weeklyMinutes
                guard week.count == 7,
                      let anchor = DailyPlayActivity.date(fromDayKey: game.weeklyEndingDayKey, calendar: calendar) else { continue }
                for (index, minutes) in week.enumerated() where minutes > 0 {
                    guard let date = calendar.date(byAdding: .day, value: index - 6, to: anchor) else { continue }
                    let day = dayKey(date)
                    guard day >= args.startDay, day <= args.endDay, exact["\(game.applicationID):\(day)"] == nil else { continue }
                    activity.record(id: game.applicationID, day: day, minutes: minutes)
                }
            }
        }
        return activity.result(args, games: games, lastObservedDay: latestObservation.map(dayKey))
    }

    private func matchingGames(platform: Platform, title: String?) throws -> [GameRecord] {
        let fragment = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard fragment.utf8.count <= 512 else { throw QueryError("请提供较短的游戏名片段。") }
        return try platform.gamePlatforms.flatMap { selected -> [GameRecord] in
            let prefix = AccountScope.token(platform: selected, accountID: "")
            let tokens = accountScope.split(separator: "|").filter { $0.hasPrefix(prefix) && $0.count > prefix.count }
            if !accountScope.isEmpty && tokens.count != 1 { return [] }
            let account = tokens.first.map { String($0.dropFirst(prefix.count)) } ?? ""
            let name = selected.rawValue
            return try context.fetch(FetchDescriptor<GameRecord>(predicate: #Predicate {
                $0.accountID == account && $0.platformRaw == name
            })).filter { game in
                fragment.isEmpty || game.title.range(of: fragment, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
            }
        }
    }

    private func dayKey(_ date: Date) -> String {
        DailyPlayActivity.dayKey(for: date, calendar: calendar)
    }

    private static func hasTrophyCount(_ game: GameRecord) -> Bool {
        game.platform == .playStation && (game.trophiesDefined > 0 || game.trophiesEarned > 0 || game.platinumTrophiesEarned > 0)
    }

    private static func exportedTitle(_ game: GameRecord) -> String {
        String(decoding: game.title.utf8.prefix(512), as: UTF8.self)
    }

    private static func validatePage(limit: Int, offset: Int) throws {
        guard (0...maximumPageSize).contains(limit), offset >= 0 else {
            throw QueryError("limit 应在 0 至 \(maximumPageSize) 之间，offset 应为非负整数。")
        }
    }

    private static func nextOffset(_ offset: Int, _ returned: Int, _ count: Int) -> Int? {
        returned > 0 && offset + returned < count ? offset + returned : nil
    }

    private static func output(_ result: some Encodable) throws -> AIChatToolOutput {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return AIChatToolOutput(json: String(decoding: try encoder.encode(result), as: UTF8.self), queriedRecords: true)
    }

    private static func failure(_ code: String, _ message: String) -> AIChatToolOutput {
        let data = (try? JSONEncoder().encode(["error": code, "message": message])) ?? Data()
        return AIChatToolOutput(json: String(decoding: data, as: UTF8.self), queriedRecords: false)
    }

    private struct QueryError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private enum Platform: String, Decodable, CaseIterable {
        case all, ps, ns
        var gamePlatforms: [GamePlatform] {
            switch self {
            case .all: GamePlatform.allCases
            case .ps: [.playStation]
            case .ns: [.switchConsole]
            }
        }
    }

    private enum GameField: String, Decodable, CaseIterable {
        case totalMinutes = "total_minutes"
        case lastPlayed = "last_played"
        case trophies
    }

    private enum GameSort: String, Decodable, CaseIterable {
        case totalMinutes = "total_minutes"
        case lastPlayed = "last_played"
        case trophiesEarned = "trophies_earned"
        case trophyCompletion = "trophy_completion"
        case platinumCount = "platinum_count"

        var isTrophySort: Bool { self != .totalMinutes && self != .lastPlayed }

        func value(_ game: GameRecord) -> Double? {
            switch self {
            case .totalMinutes: Double(game.totalMinutes)
            case .lastPlayed: game.lastPlayedAt?.timeIntervalSinceReferenceDate
            case .trophiesEarned: Double(game.trophiesEarned)
            case .trophyCompletion: Double(game.trophiesEarned) / Double(game.trophiesDefined)
            case .platinumCount: Double(game.platinumTrophiesEarned)
            }
        }
    }

    private struct GameArguments: Decodable {
        let platform: Platform
        let titleContains: String?
        let minMinutesExclusive: Int?
        let maxMinutesInclusive: Int?
        let platinumOnly: Bool
        let sortBy: GameSort
        let ascending: Bool
        let fields: [GameField]
        let limit: Int
        let offset: Int
    }

    private struct GameResult: Encodable {
        struct Row: Encodable {
            let title: String
            let platform: String
            let totalMinutes: Int?
            let lastPlayedDay: String?
            let trophiesEarned: Int?
            let trophiesDefined: Int?
            let platinumCount: Int?
        }
        let matchingCount: Int
        let nextOffset: Int?
        let matchingTotalMinutes: Int?
        let matchingPSTrophies: Int?
        let gamesWithTrophyData: Int?
        let games: [Row]
    }

    private enum ActivityGrouping: String, Decodable, CaseIterable {
        case summary, game, day
        case gameDay = "game_day"
    }
    private enum ActivitySort: String, Decodable, CaseIterable { case minutes, recent, trophies }

    private struct ActivityArguments: Decodable {
        let platform: Platform
        let titleContains: String?
        let startDay: String
        let endDay: String
        let groupBy: ActivityGrouping
        let sortBy: ActivitySort
        let includeTrophies: Bool
        let limit: Int
        let offset: Int
    }

    private struct ActivityTotals: Encodable {
        var minutes: Int?
        var psTrophyChange: Int?

        mutating func add(_ other: ActivityTotals) {
            if let duration = other.minutes { minutes = (minutes ?? 0) + duration }
            if let change = other.psTrophyChange { psTrophyChange = (psTrophyChange ?? 0) + change }
        }
    }

    private struct ActivityResult: Encodable {
        struct Game: Encodable {
            let title: String
            let platform: String
            let lastPlayedDay: String?
            let lastRecordedDay: String?
            let totals: ActivityTotals

            var recentDay: String { max(lastPlayedDay ?? "", lastRecordedDay ?? "") }
        }
        struct Day: Encodable {
            let day: String
            let minutes: Int
        }
        struct GameDay: Encodable {
            let day: String
            let title: String
            let platform: String
            let minutes: Int
        }
        let startDay: String
        let endDay: String
        let lastObservedDay: String?
        let totals: ActivityTotals
        let matchingGameCount: Int
        let knownPlayedGameCount: Int
        let recordedDayCount: Int
        let nextOffset: Int?
        var games: [Game]? = nil
        var days: [Day]? = nil
        var gameDays: [GameDay]? = nil
    }

    @MainActor
    private struct ActivityProjection {
        struct GameActivity {
            var lastPlayedDay: String?
            var lastRecordedDay: String?
            var totals = ActivityTotals()
            var hasPlayEvidence: Bool { lastPlayedDay != nil || lastRecordedDay != nil }
        }
        let collectGameDays: Bool
        var games: [String: GameActivity] = [:]
        var days: [String: Int] = [:]
        private var minutesByGameDay: [String: [String: Int]] = [:]

        init(collectGameDays: Bool) {
            self.collectGameDays = collectGameDays
        }

        mutating func record(id: String, day: String, minutes: Int, trophies: Int = 0) {
            let totals = ActivityTotals(minutes: minutes == 0 ? nil : minutes, psTrophyChange: trophies == 0 ? nil : trophies)
            var game = games[id, default: .init()]
            game.totals.add(totals)
            if minutes > 0 { game.lastRecordedDay = max(day, game.lastRecordedDay ?? "") }
            games[id] = game
            guard minutes != 0 else { return }
            days[day, default: 0] += minutes
            if collectGameDays { minutesByGameDay[id, default: [:]][day, default: 0] += minutes }
        }

        func result(_ args: ActivityArguments, games records: [GameRecord], lastObservedDay: String?) -> ActivityResult {
            let totals = games.values.reduce(into: ActivityTotals()) { $0.add($1.totals) }
            var gameRows: [ActivityResult.Game]?
            var dayRows: [ActivityResult.Day]?
            var gameDayRows: [ActivityResult.GameDay]?
            var next: Int?
            if args.limit > 0 && args.groupBy == .game {
                // Stable order for matching titles is inherited from the local ID.
                let rows = records.sorted { $0.applicationID < $1.applicationID }.compactMap { game -> ActivityResult.Game? in
                    guard let item = games[game.applicationID] else { return nil }
                    return ActivityResult.Game(title: AIChatGameQueries.exportedTitle(game), platform: game.platform.shortName,
                        lastPlayedDay: item.lastPlayedDay, lastRecordedDay: item.lastRecordedDay, totals: item.totals)
                }.sorted {
                    switch args.sortBy {
                    case .minutes:
                        let l = $0.totals.minutes ?? 0
                        let r = $1.totals.minutes ?? 0
                        if l != r { return l > r }
                    case .trophies:
                        let l = $0.totals.psTrophyChange ?? 0
                        let r = $1.totals.psTrophyChange ?? 0
                        if l != r { return l > r }
                    case .recent: break
                    }
                    return $0.recentDay > $1.recentDay
                }
                gameRows = Array(rows.dropFirst(args.offset).prefix(args.limit))
                next = AIChatGameQueries.nextOffset(args.offset, gameRows?.count ?? 0, rows.count)
            } else if args.limit > 0 && args.groupBy == .day {
                let rows = days.map { ActivityResult.Day(day: $0.key, minutes: $0.value) }.sorted {
                    if args.sortBy == .minutes && $0.minutes != $1.minutes { return $0.minutes > $1.minutes }
                    return $0.day > $1.day
                }
                dayRows = Array(rows.dropFirst(args.offset).prefix(args.limit))
                next = AIChatGameQueries.nextOffset(args.offset, dayRows?.count ?? 0, rows.count)
            } else if collectGameDays {
                let rows = records.sorted { $0.applicationID < $1.applicationID }.flatMap { game in
                    let title = AIChatGameQueries.exportedTitle(game)
                    return (minutesByGameDay[game.applicationID] ?? [:]).map {
                        ActivityResult.GameDay(day: $0.key, title: title, platform: game.platform.shortName, minutes: $0.value)
                    }
                }.sorted {
                    if args.sortBy == .minutes && $0.minutes != $1.minutes { return $0.minutes > $1.minutes }
                    return $0.day > $1.day
                }
                gameDayRows = Array(rows.dropFirst(args.offset).prefix(args.limit))
                next = AIChatGameQueries.nextOffset(args.offset, gameDayRows?.count ?? 0, rows.count)
            }
            return ActivityResult(startDay: args.startDay, endDay: args.endDay, lastObservedDay: lastObservedDay,
                totals: totals, matchingGameCount: games.count, knownPlayedGameCount: games.values.filter(\.hasPlayEvidence).count,
                recordedDayCount: days.count, nextOffset: next, games: gameRows, days: dayRows, gameDays: gameDayRows)
        }
    }
}
