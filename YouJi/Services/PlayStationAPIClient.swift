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

    func loadGames(accessToken: String) async throws -> PlayStationGamesPayload {
        let accountID = try Self.accountID(from: accessToken)
        let titles = try await loadAllPlayedGames(accessToken: accessToken)
        return PlayStationGamesPayload(
            accountID: accountID,
            accountName: "PlayStation Network",
            games: try normalizeGames(titles),
            titles: titles.map { PlayStationTitleIdentity(titleID: $0.titleID, lastPlayedAt: Self.parseDate($0.lastPlayedDateTime)) }
        )
    }

    func loadTrophy(titleID: String, accessToken: String) async throws -> PlayStationTrophyUpdate? {
        var components = URLComponents(string: "https://m.np.playstation.com/api/trophy/v1/users/me/titles/trophyTitles")!
        components.queryItems = [URLQueryItem(name: "npTitleIds", value: titleID)]
        let response: PlayStationTrophyTitlesForIDsResponse = try await authorizedGET(
            components.url!.absoluteString,
            accessToken: accessToken,
            stage: "按游戏 ID 读取奖杯"
        )
        guard !response.titles.isEmpty else { return nil }
        let trophyTitles = response.titles.filter { $0.npTitleID == titleID }.flatMap(\.trophyTitles)
        guard !trophyTitles.isEmpty else { return nil }
        let defined = trophyTitles.reduce(PlayStationTrophyCounts.zero) { $0.adding($1.definedTrophies) }
        let earned = trophyTitles.reduce(PlayStationTrophyCounts.zero) { $0.adding($1.earnedTrophies) }
        guard earned.bronze <= defined.bronze, earned.silver <= defined.silver,
              earned.gold <= defined.gold, earned.platinum <= defined.platinum,
              defined.total > 0 else { throw PlayStationSyncError.decode("奖杯计数不完整") }
        return PlayStationTrophyUpdate(
            titleID: titleID,
            earned: earned.total,
            defined: defined.total,
            platinum: earned.platinum,
            syncedAt: .now
        )
    }

    func loadTrophySummary(accessToken: String) async throws -> PlayStationTrophySummary {
        try await authorizedGET(
            "https://m.np.playstation.com/api/trophy/v1/users/me/trophySummary",
            accessToken: accessToken,
            stage: "读取 PSN 奖杯统计"
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
            let errorCode = error?["code"] as? String ?? body?["error"] as? String
            let detail = error?["message"] as? String ?? body?["error_description"] as? String
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.error("\(stage, privacy: .public) failed with HTTP \(code)")
            if code == 401 || code == 403 || ["invalid_grant", "invalid_token"].contains(errorCode ?? "") {
                throw PlayStationSyncError.authenticationExpired
            }
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

            if page.titles.isEmpty {
                if let total = page.totalItemCount, allTitles.count < total {
                    throw PlayStationSyncError.incompletePagination
                }
                break
            }
            if let total = page.totalItemCount, allTitles.count >= total { break }
            let next = page.nextOffset ?? (offset + page.titles.count)
            guard next > offset else {
                throw PlayStationSyncError.incompletePagination
            }
            offset = next
        }
        guard offset < 5_000 else {
            throw PlayStationSyncError.incompletePagination
        }
        return allTitles
    }

    private func formData(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private func normalizeGames(_ titles: [PlayStationTitle]) throws -> [SyncedGame] {
        return try titles.map { item in
            return SyncedGame(
                titleID: item.titleID,
                platform: .playStation,
                title: item.localizedName ?? item.name,
                totalMinutes: try Self.minutes(from: item.playDuration),
                imageURL: item.localizedImageURL ?? item.imageURL ?? "",
                firstPlayedAt: Self.parseDate(item.firstPlayedDateTime),
                lastPlayedAt: Self.parseDate(item.lastPlayedDateTime),
                weeklyMinutes: Array(repeating: 0, count: 7)
            )
        }
    }

    static func accountID(from accessToken: String) throws -> String {
        let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { throw PlayStationSyncError.missingAccountIdentity }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlayStationSyncError.missingAccountIdentity
        }
        for key in ["sub", "account_id", "accountId", "user_id"] {
            if let value = claims[key] as? String, !value.isEmpty { return value }
            if let value = claims[key] as? NSNumber { return value.stringValue }
        }
        throw PlayStationSyncError.missingAccountIdentity
    }

    static func minutes(from duration: String) throws -> Int {
        // Accept ISO day-only durations and fractional units as well as PS's usual PT form.
        let pattern = #"^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#
        let value = duration.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              (1...4).contains(where: { match.range(at: $0).location != NSNotFound }),
              !value.hasSuffix("T") else { throw PlayStationSyncError.decode("无法读取游玩时长，已保留本地记录") }
        func component(_ index: Int) -> Double {
            guard let range = Range(match.range(at: index), in: value) else { return 0 }
            return Double(value[range]) ?? .infinity
        }
        let minutes = component(1) * 1_440 + component(2) * 60 + component(3) + component(4) / 60
        guard minutes.isFinite, minutes >= 0, minutes <= Double(DataValidation.maximumMinutes) else {
            throw PlayStationSyncError.decode("游玩时长超出可读取范围，已保留本地记录")
        }
        return Int(minutes)
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

struct PlayStationGamesPayload: Sendable {
    let accountID: String
    let accountName: String
    let games: [SyncedGame]
    let titles: [PlayStationTitleIdentity]
}

struct PlayStationTitleIdentity: Sendable {
    let titleID: String
    let lastPlayedAt: Date?
}

struct PlayStationTrophyUpdate: Sendable {
    let titleID: String
    let earned: Int
    let defined: Int
    let platinum: Int
    let syncedAt: Date
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
        earnedTrophies = try values.decode(PlayStationTrophyCounts.self, forKey: .earnedTrophies)
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
        bronze = try values.requiredCount(forKey: .bronze)
        silver = try values.requiredCount(forKey: .silver)
        gold = try values.requiredCount(forKey: .gold)
        platinum = try values.requiredCount(forKey: .platinum)
    }
}

private extension KeyedDecodingContainer {
    func requiredCount(forKey key: Key) throws -> Int {
        if let value = try? decode(Int.self, forKey: key), (0...1_000_000).contains(value) { return value }
        if let text = try? decode(String.self, forKey: key),
           let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           (0...1_000_000).contains(value) { return value }
        if let value = try? decode(Double.self, forKey: key), value.isFinite,
           value.rounded(.towardZero) == value, (0...1_000_000).contains(value) { return Int(value) }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Invalid trophy count")
    }

    func flexibleInt(forKey key: Key, default defaultValue: Int = 0) -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key), value.isFinite, value >= 0, value < Double(Int.max) { return Int(value) }
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
    case authenticationExpired
    case missingAccountIdentity
    case incompletePagination
    case http(Int, String?)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .invalidNPSSO:
            "未读取到 PlayStation 登录状态，请确认已在页面中登录后重试。"
        case .authenticationExpired:
            "PlayStation 登录已过期，请重新连接。"
        case .missingAccountIdentity:
            "无法识别 PlayStation 账号，请重新登录后再试。"
        case .incompletePagination:
            "PlayStation 游戏列表超过当前可安全读取的范围，本次未标记为完整同步。"
        case .http(401, _):
            "PlayStation 登录已过期，请重新连接。"
        case .http(let code, let message):
            message ?? "PlayStation 服务返回错误（\(code)）"
        case .decode(let message):
            "PlayStation 数据格式已变化：\(message)"
        }
    }
}
