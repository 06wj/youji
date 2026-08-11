import Foundation
import os

actor PlayStationAPIClient {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let logger = Logger(subsystem: "com.youji.playlog", category: "PlayStation")

    private static let authBase = "https://ca.account.sony.com/api/authz/v3/oauth"
    private static let clientID = "09515159-7237-4370-9b40-3806e67c0891"
    private static let redirectURI = "com.scee.psxandroid.scecompcall://redirect"
    private static let scope = "psn:mobile.v2.core psn:clientapp"
    private static let basicAuthorization = "Basic MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A="

    init(session: URLSession = .shared) {
        self.session = session
    }

    func authorize(npsso: String) async throws -> PlayStationAuthTokens {
        logger.info("Starting PlayStation token exchange")
        let code = try await exchangeNPSSOForCode(npsso)
        return try await exchangeCodeForTokens(code)
    }

    func refresh(refreshToken: String) async throws -> PlayStationAuthTokens {
        try await tokenRequest([
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "token_format": "jwt",
            "scope": Self.scope,
        ])
    }

    func loadLibrary(
        accessToken: String,
        trophyCache: [String: PlayStationTrophyCacheEntry] = [:],
        cachedTrophySummary: PlayStationTrophySummary? = nil
    ) async throws -> PlayStationSyncPayload {
        logger.info("Loading PlayStation games with incremental trophy cache")
        let titles = try await loadAllPlayedGames(accessToken: accessToken)
        var trophyByTitleID: [String: PlayStationMappedTrophies] = [:]
        var staleTitleIDs = Set<String>()

        for title in titles {
            let lastPlayedAt = Self.parseDate(title.lastPlayedDateTime)
            if let cached = trophyCache[title.titleID],
               lastPlayedAt == nil || cached.syncedAt >= lastPlayedAt! {
                trophyByTitleID[title.titleID] = PlayStationMappedTrophies(
                    defined: cached.defined,
                    earned: cached.earned,
                    platinum: cached.platinum,
                    syncedAt: cached.syncedAt
                )
            } else {
                staleTitleIDs.insert(title.titleID)
            }
        }

        if !staleTitleIDs.isEmpty {
            let refreshed = try await loadTrophiesForTitles(
                titleIDs: Array(staleTitleIDs),
                accessToken: accessToken
            )
            let refreshedAt = Date.now
            for titleID in staleTitleIDs {
                trophyByTitleID[titleID] = refreshed[titleID] ?? .empty(syncedAt: refreshedAt)
            }
        }

        let trophies: PlayStationTrophySummary
        if staleTitleIDs.isEmpty, let cachedTrophySummary {
            trophies = cachedTrophySummary
        } else {
            trophies = try await authorizedGET(
                "https://m.np.playstation.com/api/trophy/v1/users/me/trophySummary",
                accessToken: accessToken,
                stage: "读取 PSN 奖杯统计"
            )
        }
        logger.info("Trophy cache hit \(titles.count - staleTitleIDs.count)/\(titles.count); refreshed \(staleTitleIDs.count)")

        return PlayStationSyncPayload(
            accountName: "PlayStation Network",
            games: normalize(titles, trophyByTitleID: trophyByTitleID),
            trophies: trophies
        )
    }

    private func exchangeNPSSOForCode(_ npsso: String) async throws -> String {
        var components = URLComponents(string: "\(Self.authBase)/authorize")!
        components.queryItems = [
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("npsso=\(npsso)", forHTTPHeaderField: "Cookie")

        let delegate = RedirectBlocker()
        let (_, response) = try await session.data(for: request, delegate: delegate)
        guard
            let http = response as? HTTPURLResponse,
            let location = http.value(forHTTPHeaderField: "Location"),
            let redirect = URLComponents(string: location),
            let code = redirect.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            logger.error("NPSSO exchange did not return an authorization code")
            throw PlayStationSyncError.invalidNPSSO
        }
        return code
    }

    private func exchangeCodeForTokens(_ code: String) async throws -> PlayStationAuthTokens {
        try await tokenRequest([
            "code": code,
            "redirect_uri": Self.redirectURI,
            "grant_type": "authorization_code",
            "token_format": "jwt",
        ])
    }

    private func tokenRequest(_ body: [String: String]) async throws -> PlayStationAuthTokens {
        var request = URLRequest(url: URL(string: "\(Self.authBase)/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.basicAuthorization, forHTTPHeaderField: "Authorization")
        request.httpBody = formData(body)
        return try await send(request, stage: "交换 PSN 访问令牌")
    }

    private func authorizedGET<T: Decodable>(_ url: String, accessToken: String, stage: String) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh-Hans;q=0.95,zh-TW;q=0.85,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        return try await send(request, stage: stage)
    }

    private func send<T: Decodable>(_ request: URLRequest, stage: String) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = body?["error"] as? [String: Any]
            let detail = error?["message"] as? String ?? body?["error_description"] as? String
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.error("\(stage, privacy: .public) failed with HTTP \(code)")
            throw PlayStationSyncError.http(code, detail.map { "\(stage)：\($0)" } ?? stage)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.error("\(stage, privacy: .public) response decoding failed: \(error.localizedDescription, privacy: .public)")
            throw PlayStationSyncError.decode("\(stage)：\(error.localizedDescription)")
        }
    }

    private func loadAllPlayedGames(accessToken: String) async throws -> [PlayStationTitle] {
        var offset = 0
        var allTitles: [PlayStationTitle] = []
        var seenIDs = Set<String>()

        while offset < 5_000 {
            var components = URLComponents(string: "https://m.np.playstation.com/api/gamelist/v2/users/me/titles")!
            components.queryItems = [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
            let page: PlayStationPlayedGamesResponse = try await authorizedGET(
                components.url!.absoluteString,
                accessToken: accessToken,
                stage: "读取 PSN 游戏列表（第 \(offset / 100 + 1) 页）"
            )

            for title in page.titles where seenIDs.insert(title.titleID).inserted {
                allTitles.append(title)
            }
            logger.info("Loaded \(allTitles.count) unique PlayStation titles")

            guard !page.titles.isEmpty else { break }
            if let total = page.totalItemCount, allTitles.count >= total { break }
            let next = page.nextOffset ?? (offset + page.titles.count)
            guard next > offset else { break }
            offset = next
        }
        return allTitles
    }

    private func loadTrophiesForTitles(
        titleIDs: [String],
        accessToken: String
    ) async throws -> [String: PlayStationMappedTrophies] {
        var result: [String: PlayStationMappedTrophies] = [:]
        var skipped = 0

        for (index, titleID) in titleIDs.enumerated() {
            var components = URLComponents(string: "https://m.np.playstation.com/api/trophy/v1/users/me/titles/trophyTitles")!
            components.queryItems = [
                URLQueryItem(name: "npTitleIds", value: titleID),
            ]
            do {
                let response: PlayStationTrophyTitlesForIDsResponse = try await authorizedGET(
                    components.url!.absoluteString,
                    accessToken: accessToken,
                    stage: "按游戏 ID 读取奖杯（\(index + 1)/\(titleIDs.count)）"
                )
                for title in response.titles {
                    let defined = title.trophyTitles.reduce(PlayStationTrophyCounts.zero) { $0.adding($1.definedTrophies) }
                    let earned = title.trophyTitles.reduce(PlayStationTrophyCounts.zero) { $0.adding($1.earnedTrophies) }
                    result[title.npTitleID] = PlayStationMappedTrophies(
                        defined: defined.total,
                        earned: earned.total,
                        platinum: earned.platinum,
                        syncedAt: .now
                    )
                }
            } catch PlayStationSyncError.http(let code, _) where code == 400 || code == 404 {
                skipped += 1
                logger.info("No ID-based trophy set for title \(titleID, privacy: .public)")
            }
        }
        logger.info("Mapped trophies by title ID for \(result.count) games; skipped \(skipped)")
        return result
    }

    private func formData(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private func normalize(
        _ titles: [PlayStationTitle],
        trophyByTitleID: [String: PlayStationMappedTrophies]
    ) -> [SyncedGame] {
        return titles.map { item in
            let trophy = trophyByTitleID[item.titleID]
            return SyncedGame(
                applicationID: "ps:\(item.titleID)",
                platform: .playStation,
                title: item.localizedName ?? item.name,
                totalMinutes: Self.minutes(from: item.playDuration),
                imageURL: item.localizedImageURL ?? item.imageURL ?? "",
                firstPlayedAt: Self.parseDate(item.firstPlayedDateTime),
                lastPlayedAt: Self.parseDate(item.lastPlayedDateTime),
                weeklyMinutes: Array(repeating: 0, count: 7),
                trophiesEarned: trophy?.earned ?? 0,
                trophiesDefined: trophy?.defined ?? 0,
                platinumTrophiesEarned: trophy?.platinum ?? 0,
                trophiesSyncedAt: trophy?.syncedAt
            )
        }
    }

    private static func minutes(from duration: String) -> Int {
        let pattern = #"^P(?:(\d+)D)?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: duration, range: NSRange(duration.startIndex..., in: duration)) else { return 0 }
        func value(_ index: Int) -> Double {
            guard let range = Range(match.range(at: index), in: duration) else { return 0 }
            return Double(duration[range]) ?? 0
        }
        return Int((value(1) * 1_440) + (value(2) * 60) + value(3) + (value(4) / 60))
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct PlayStationSyncPayload: Sendable {
    let accountName: String
    let games: [SyncedGame]
    let trophies: PlayStationTrophySummary
}

struct PlayStationTrophySummary: Codable, Sendable {
    let trophyLevel: String
    let progress: Int
    let tier: Int
    let earnedTrophies: PlayStationTrophyCounts

    enum CodingKeys: String, CodingKey { case trophyLevel, progress, tier, earnedTrophies }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trophyLevel = values.flexibleString(forKey: .trophyLevel, default: "0")
        progress = values.flexibleInt(forKey: .progress)
        tier = values.flexibleInt(forKey: .tier)
        earnedTrophies = (try? values.decode(PlayStationTrophyCounts.self, forKey: .earnedTrophies)) ?? .zero
    }

    var total: Int {
        earnedTrophies.platinum + earnedTrophies.gold + earnedTrophies.silver + earnedTrophies.bronze
    }
}

struct PlayStationTrophyCounts: Codable, Sendable {
    let bronze: Int
    let silver: Int
    let gold: Int
    let platinum: Int

    var total: Int { bronze + silver + gold + platinum }

    func adding(_ other: PlayStationTrophyCounts) -> PlayStationTrophyCounts {
        PlayStationTrophyCounts(
            bronze: bronze + other.bronze,
            silver: silver + other.silver,
            gold: gold + other.gold,
            platinum: platinum + other.platinum
        )
    }

    static let zero = PlayStationTrophyCounts(bronze: 0, silver: 0, gold: 0, platinum: 0)

    enum CodingKeys: String, CodingKey { case bronze, silver, gold, platinum }

    init(bronze: Int, silver: Int, gold: Int, platinum: Int) {
        self.bronze = bronze
        self.silver = silver
        self.gold = gold
        self.platinum = platinum
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bronze = values.flexibleInt(forKey: .bronze)
        silver = values.flexibleInt(forKey: .silver)
        gold = values.flexibleInt(forKey: .gold)
        platinum = values.flexibleInt(forKey: .platinum)
    }
}

private extension KeyedDecodingContainer {
    func flexibleInt(forKey key: Key, default defaultValue: Int = 0) -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int(value) }
        if let value = try? decode(String.self, forKey: key) { return Int(value) ?? defaultValue }
        return defaultValue
    }

    func flexibleString(forKey key: Key, default defaultValue: String) -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        return defaultValue
    }
}

struct PlayStationAuthTokens: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct PlayStationPlayedGamesResponse: Decodable {
    let titles: [PlayStationTitle]
    let totalItemCount: Int?
    let nextOffset: Int?
}

private struct PlayStationTrophyTitlesForIDsResponse: Decodable {
    let titles: [PlayStationTrophyTitleContainer]
}

private struct PlayStationTrophyTitleContainer: Decodable {
    let npTitleID: String
    let trophyTitles: [PlayStationTrophyTitle]

    enum CodingKeys: String, CodingKey {
        case npTitleID = "npTitleId"
        case trophyTitles
    }
}

private struct PlayStationTrophyTitle: Decodable {
    let definedTrophies: PlayStationTrophyCounts
    let earnedTrophies: PlayStationTrophyCounts
}

private struct PlayStationMappedTrophies: Sendable {
    let defined: Int
    let earned: Int
    let platinum: Int
    let syncedAt: Date

    static func empty(syncedAt: Date) -> PlayStationMappedTrophies {
        PlayStationMappedTrophies(defined: 0, earned: 0, platinum: 0, syncedAt: syncedAt)
    }
}

struct PlayStationTrophyCacheEntry: Sendable {
    let earned: Int
    let defined: Int
    let platinum: Int
    let syncedAt: Date
}

private struct PlayStationTitle: Decodable {
    let titleID: String
    let name: String
    let localizedName: String?
    let imageURL: String?
    let localizedImageURL: String?
    let firstPlayedDateTime: String?
    let lastPlayedDateTime: String?
    let playDuration: String
    let category: String?

    enum CodingKeys: String, CodingKey {
        case titleID = "titleId"
        case name, localizedName
        case imageURL = "imageUrl"
        case localizedImageURL = "localizedImageUrl"
        case firstPlayedDateTime, lastPlayedDateTime, playDuration, category
    }
}

enum PlayStationSyncError: LocalizedError {
    case invalidNPSSO
    case http(Int, String?)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .invalidNPSSO:
            "未读取到 PlayStation 登录状态，请确认已在页面中登录后重试。"
        case .http(401, _):
            "PlayStation 登录已过期，请重新连接。"
        case .http(let code, let message):
            message ?? "PlayStation 服务返回错误（\(code)）"
        case .decode(let message):
            "PlayStation 数据格式已变化：\(message)"
        }
    }
}
