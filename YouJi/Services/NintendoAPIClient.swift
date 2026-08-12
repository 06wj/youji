import Foundation

actor NintendoAPIClient {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let clientID = NintendoOAuthSession.clientID
    private let storeBaseURL = URL(string: "https://app-api.znej.nintendo.com/api/v2.0")!
    private let sessionExchangeUserAgent = "NASDKAPI; Android"
    private let storeUserAgent = "com.nintendo.znej/3.2.0 (iOS/26.0.1)"

    init(session: URLSession = .shared) { self.session = session }

    func exchangeSessionToken(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://accounts.nintendo.com/connect/1.0.0/api/session_token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        request.setValue("Android", forHTTPHeaderField: "X-Platform")
        request.setValue("2.0.0", forHTTPHeaderField: "X-ProductVersion")
        request.setValue(sessionExchangeUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = formData([
            "client_id": clientID,
            "session_token_code": code,
            "session_token_code_verifier": verifier,
        ])
        let response: SessionTokenResponse = try await send(request, stage: "交换 Nintendo 会话令牌")
        return response.sessionToken
    }

    func loadLibrary(sessionToken: String) async throws -> NintendoSyncPayload {
        let token = try await accountToken(sessionToken: sessionToken)
        async let user: NintendoUser = authorizedRequest(
            url: URL(string: "https://api.accounts.nintendo.com/2.0.0/users/me")!,
            accessToken: token.accessToken,
            stage: "读取 Nintendo 账号"
        )
        async let history: StorePlayHistoryResponse = authorizedRequest(
            url: storeBaseURL.appending(path: "/users/me/play_histories"),
            accessToken: token.accessToken,
            stage: "读取 Switch 游戏记录"
        )
        return try await NintendoSyncPayload(user: user, games: normalize(history: history))
    }

    private func accountToken(sessionToken: String) async throws -> AccountTokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.nintendo.com/connect/1.0.0/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(storeUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "session_token": sessionToken,
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer-session-token",
        ])
        return try await send(request, stage: "获取 Nintendo 游戏记录令牌")
    }

    private func authorizedRequest<T: Decodable>(url: URL, accessToken: String, stage: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(storeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN", forHTTPHeaderField: "gentry-locale")
        request.setValue("zh-CN,zh-Hans;q=0.95,zh-TW;q=0.85,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        return try await send(request, stage: stage)
    }

    private func send<T: Decodable>(_ request: URLRequest, stage: String) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errorCode = body?["error"] as? String
            let serverMessage = body?["detail"] as? String
                ?? body?["error_description"] as? String
                ?? body?["message"] as? String
                ?? body?["error"] as? String
            let message = serverMessage.map { "\(stage)：\($0)" } ?? stage
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 401 || code == 403 || ["invalid_grant", "invalid_token"].contains(errorCode) {
                throw NintendoSyncError.authenticationExpired(message)
            }
            throw NintendoSyncError.http(code, message)
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw NintendoSyncError.decode("\(stage)：\(error.localizedDescription)") }
    }

    private func formData(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private func normalize(history: StorePlayHistoryResponse) -> [SyncedGame] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var weeklyByTitle: [String: [Int]] = [:]

        for day in history.recentPlayHistories {
            guard let date = Self.parsePlayedDay(day.playedDate) else { continue }
            let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 99
            guard (0...6).contains(offset) else { continue }
            for item in day.dailyPlayHistories {
                var week = weeklyByTitle[item.titleID] ?? Array(repeating: 0, count: 7)
                week[6 - offset] += item.totalPlayedMinutes
                weeklyByTitle[item.titleID] = week
            }
        }

        return history.playHistories.map { item in
            SyncedGame(
                titleID: item.titleID,
                platform: .switchConsole,
                title: item.titleName,
                totalMinutes: item.totalPlayedMinutes,
                imageURL: item.imageURL,
                firstPlayedAt: Self.parseDate(item.firstPlayedAt),
                lastPlayedAt: Self.parseDate(item.lastPlayedAt),
                weeklyMinutes: weeklyByTitle[item.titleID] ?? Array(repeating: 0, count: 7)
            )
        }
    }

    static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        if let date = ISO8601DateFormatter().date(from: value) { return date }

        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: value)
    }

    static func parsePlayedDay(_ value: String) -> Date? {
        guard value.count >= 10 else { return nil }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: String(value.prefix(10)))
    }
}

struct NintendoSyncPayload: Sendable {
    let user: NintendoUser
    let games: [SyncedGame]
}

struct SessionTokenResponse: Decodable {
    let sessionToken: String
    enum CodingKeys: String, CodingKey { case sessionToken = "session_token" }
}

struct AccountTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case expiresIn = "expires_in" }
}

struct NintendoUser: Decodable, Sendable { let id: String; let nickname: String }

struct StorePlayHistoryResponse: Decodable {
    let playHistories: [StorePlayHistory]
    let recentPlayHistories: [StoreRecentDay]
}

struct StorePlayHistory: Decodable {
    let titleID: String
    let titleName: String
    let imageURL: String
    let firstPlayedAt: String
    let lastPlayedAt: String
    let totalPlayedMinutes: Int
    enum CodingKeys: String, CodingKey {
        case titleID = "titleId", titleName, imageURL = "imageUrl", firstPlayedAt, lastPlayedAt, totalPlayedMinutes
    }
}

struct StoreRecentDay: Decodable {
    let playedDate: String
    let dailyPlayHistories: [StoreRecentTitle]
}

struct StoreRecentTitle: Decodable {
    let titleID: String
    let totalPlayedMinutes: Int
    enum CodingKeys: String, CodingKey { case titleID = "titleId", totalPlayedMinutes }
}

enum NintendoSyncError: LocalizedError {
    case authenticationExpired(String?)
    case http(Int, String?)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .authenticationExpired:
            "Nintendo 登录已过期，请重新连接。"
        case .http(401, _): "Nintendo 登录已过期，请重新连接。"
        case .http(let code, let message): message ?? "Nintendo Store 服务返回错误（\(code)）"
        case .decode(let message): "Nintendo Store 数据格式已变化：\(message)"
        }
    }
}
