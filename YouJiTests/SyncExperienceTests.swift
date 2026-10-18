import XCTest
import SwiftData
@testable import YouJi

final class SyncExperienceTests: XCTestCase {
    func testExpiredSessionsOfferReconnectWithoutExposingServerDetails() {
        let ps = PlatformSyncIssue.from(PlayStationSyncError.http(403, "private server detail"), platform: .playStation)
        let ns = PlatformSyncIssue.from(NintendoSyncError.authenticationExpired("private server detail"), platform: .switchConsole)
        XCTAssertEqual(ps.recovery, .reconnect)
        XCTAssertEqual(ns.recovery, .reconnect)
        XCTAssertFalse(ps.message.contains("private server detail"))
        XCTAssertFalse(ns.message.contains("private server detail"))
        XCTAssertFalse(ps.isPartialSuccess)
    }

    func testRetryableErrorsKeepSafeCopyAndExplainSavedGames() {
        let errors: [Error] = [
            PlayStationSyncError.http(503, "private response"),
            PlayStationSyncError.decode("private response"),
            NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "private response"]),
            URLError(.notConnectedToInternet)
        ]
        for error in errors {
            let issue = PlatformSyncIssue.from(error, platform: .playStation, gameListSaved: true)
            XCTAssertEqual(issue.recovery, .retry)
            XCTAssertTrue(issue.isPartialSuccess)
            XCTAssertTrue(issue.message.contains("已保存"))
            XCTAssertFalse(issue.message.contains("private response"))
        }
    }

    @MainActor
    func testPlatformIssuesRemainIndependent() {
        let previousError = UserDefaults.standard.object(forKey: "last-sync-error")
        defer { UserDefaults.standard.set(previousError, forKey: "last-sync-error") }
        let coordinator = SyncCoordinator()
        coordinator.reportConnectionError(PlayStationSyncError.authenticationExpired, platform: .playStation)
        coordinator.reportConnectionError(URLError(.notConnectedToInternet), platform: .switchConsole)
        coordinator.clearIssue(for: .switchConsole)
        XCTAssertEqual(coordinator.issue(for: .playStation)?.recovery, .reconnect)
        XCTAssertNil(coordinator.issue(for: .switchConsole))
    }

    @MainActor
    func testBackfillUsesStableWindowDayAndPreservesExactRecords() throws {
        let flag = UserDefaults.standard.object(forKey: "did-backfill-nintendo-daily-activities-v1")
        defer { UserDefaults.standard.set(flag, forKey: "did-backfill-nintendo-daily-activities-v1") }
        let container = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let game = GameRecord(applicationID: "switch:stable:game", accountID: "stable", titleID: "game", platform: .switchConsole, title: "Game", weeklyMinutes: [0, 0, 0, 0, 0, 30, 45])
        game.weeklyEndingDayKey = "2026-10-19"
        // A timestamp on another calendar day must not shift the persisted window.
        game.updatedAt = try XCTUnwrap(DailyPlayActivity.date(fromDayKey: "2026-10-18"))
        container.mainContext.insert(game)
        let exact = DailyPlayActivity(activityID: "switch:stable:game:2026-10-19", gameID: game.applicationID, accountID: "stable", titleID: "game", platform: .switchConsole, day: try XCTUnwrap(DailyPlayActivity.date(fromDayKey: "2026-10-19")), totalMinutes: 60)
        container.mainContext.insert(exact)
        try container.mainContext.save()
        let coordinator = SyncCoordinator()
        coordinator.backfillNintendoDailyActivities(modelContext: container.mainContext, force: true)
        coordinator.backfillNintendoDailyActivities(modelContext: container.mainContext, force: true)
        let days = try container.mainContext.fetch(FetchDescriptor<DailyPlayActivity>())
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.first(where: { $0.resolvedDayKey == "2026-10-18" })?.totalMinutes, 30)
        XCTAssertEqual(days.first(where: { $0.resolvedDayKey == "2026-10-19" })?.totalMinutes, 60)
    }

    @MainActor
    func testLegacyArrayWithoutWindowDayDoesNotInventDailyDates() throws {
        let flag = UserDefaults.standard.object(forKey: "did-backfill-nintendo-daily-activities-v1")
        defer { UserDefaults.standard.set(flag, forKey: "did-backfill-nintendo-daily-activities-v1") }
        let container = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let game = GameRecord(applicationID: "switch:legacy:game", accountID: "legacy", titleID: "game", platform: .switchConsole, title: "Game", weeklyMinutes: [0, 0, 0, 0, 0, 30, 45])
        container.mainContext.insert(game)
        let exact = DailyPlayActivity(activityID: "switch:legacy:game:2026-10-19", gameID: game.applicationID, accountID: "legacy", titleID: "game", platform: .switchConsole, day: try XCTUnwrap(DailyPlayActivity.date(fromDayKey: "2026-10-19")), totalMinutes: 60)
        container.mainContext.insert(exact)
        try container.mainContext.save()
        SyncCoordinator().backfillNintendoDailyActivities(modelContext: container.mainContext, force: true)
        let days = try container.mainContext.fetch(FetchDescriptor<DailyPlayActivity>())
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.resolvedDayKey, "2026-10-19")
        XCTAssertEqual(days.first?.totalMinutes, 60)
    }

    @MainActor
    func testNintendoSyncPersistsStableWindowDay() async throws {
        let defaults = UserDefaults.standard
        let keys = ["nintendo-account-id", "nintendo-account-name", "last-sync-at", "last-sync-error",
                    "sync-date.switch.anchor-test-account", "sync-receipt.switch.anchor-test-account"]
        let oldDefaults = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys { defaults.set(oldDefaults[key] ?? nil, forKey: key) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncProgressProtocol.self]
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var savedCredentialAccounts: [String] = []
        let coordinator = SyncCoordinator(nintendoAPI: NintendoAPIClient(session: session), credentialWriter: { _, account in
            savedCredentialAccounts.append(account)
        })
        let container = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let startDay = DailyPlayActivity.dayKey(for: .now)
        await coordinator.finishAuthorization(code: "test-placeholder", verifier: "test-placeholder", modelContext: container.mainContext)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(savedCredentialAccounts, ["store-session-token"])
        let game = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<GameRecord>()).first)
        XCTAssertEqual(game.accountID, "anchor-test-account")
        XCTAssertTrue([startDay, DailyPlayActivity.dayKey(for: .now)].contains(game.weeklyEndingDayKey))
        XCTAssertEqual(game.weeklyMinutes, [0, 0, 0, 0, 0, 0, 0])
    }

    @MainActor
    func testPlayStationSavesGamesBeforeTrophiesAndKeepsPartialFailureRetryable() async throws {
        let defaults = UserDefaults.standard
        let keys = ["playstation-account-id", "playstation-account-name", "last-sync-at", "last-sync-error",
                    "playstation-trophies.progress-test-account", "sync-date.ps.progress-test-account", "sync-receipt.ps.progress-test-account"]
        let oldDefaults = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys { defaults.set(oldDefaults[key] ?? nil, forKey: key) }
        }
        let gate = SyncProgressGate()
        SyncProgressProtocol.gate = gate
        defer { gate.release(); SyncProgressProtocol.gate = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncProgressProtocol.self]
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var savedCredentialAccounts: [String] = []
        let coordinator = SyncCoordinator(playStationAPI: PlayStationAPIClient(session: session), credentialWriter: { _, account in
            savedCredentialAccounts.append(account)
        })
        let container = try ModelContainer(for: LocalDatabaseState.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let cached = GameRecord(applicationID: "ps:progress-test-account:cached", accountID: "progress-test-account", titleID: "cached", platform: .playStation, title: "Cached", totalMinutes: 120)
        cached.trophiesSyncedAt = Date(timeIntervalSince1970: 1_800_000_000)
        cached.trophiesEarned = 3
        cached.trophiesDefined = 10
        container.mainContext.insert(cached)
        try container.mainContext.save()
        let operation = Task {
            await coordinator.finishPlayStationAuthorization(npsso: "test-placeholder", modelContext: container.mainContext)
        }
        for _ in 0..<300 {
            if gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard gate.isWaiting else {
            operation.cancel()
            XCTFail("The trophy request did not reach the gate: \(coordinator.errorMessage ?? "no issue")")
            return
        }
        XCTAssertTrue(coordinator.isSyncing)
        XCTAssertEqual(coordinator.syncProgress?.platform, .playStation)
        XCTAssertEqual(coordinator.syncProgress?.gameListSaved, true)
        XCTAssertEqual(coordinator.syncProgress?.completed, 0)
        XCTAssertEqual(coordinator.syncProgress?.total, 1, "Fresh cached trophies should not become network work")
        XCTAssertEqual(savedCredentialAccounts, ["psn-refresh-token"])
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<GameRecord>()), 2)
        gate.release()
        await operation.value
        XCTAssertFalse(coordinator.isSyncing)
        XCTAssertNil(coordinator.syncProgress)
        XCTAssertNil(coordinator.errorMessage, "A partial trophy failure should not present the whole import as failed")
        XCTAssertEqual(coordinator.issue(for: .playStation)?.recovery, .retry)
        XCTAssertEqual(coordinator.issue(for: .playStation)?.isPartialSuccess, true)
        XCTAssertEqual(coordinator.playStationReceipt?.trophyFailures, 1)
        let games = try container.mainContext.fetch(FetchDescriptor<GameRecord>())
        XCTAssertEqual(games.first(where: { $0.titleID == "cached" })?.trophiesEarned, 3)
        XCTAssertNil(games.first(where: { $0.titleID == "pending" })?.trophiesSyncedAt)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<PlaySnapshot>()), 2)
    }
}

private final class SyncProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (@Sendable () -> Void)?
    var isWaiting: Bool { lock.withLock { pending != nil } }
    func enqueue(_ response: @escaping @Sendable () -> Void) { lock.withLock { pending = response } }
    func release() {
        let response = lock.withLock { let value = pending; pending = nil; return value }
        response?()
    }
}

private final class SyncProgressProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var gate: SyncProgressGate?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var status = 200
        var headers: [String: String] = [:]
        let body: String
        switch request.url?.path {
        case "/connect/1.0.0/api/session_token":
            body = #"{"session_token":"test-placeholder"}"#
        case "/connect/1.0.0/api/token":
            body = #"{"access_token":"test-placeholder","expires_in":900}"#
        case "/2.0.0/users/me":
            body = #"{"id":"anchor-test-account","nickname":"Test"}"#
        case "/api/v2.0/users/me/play_histories":
            body = #"{"playHistories":[{"titleId":"anchor-game","titleName":"Game","imageUrl":"","firstPlayedAt":"2026-01-01","lastPlayedAt":"2026-01-01","totalPlayedMinutes":120}],"recentPlayHistories":[]}"#
        case "/api/authz/v3/oauth/authorize":
            headers["Location"] = "com.scee.psxandroid.scecompcall://redirect?code=test-placeholder"
            body = "{}"
        case "/api/authz/v3/oauth/token":
            let payload = Data(#"{"sub":"progress-test-account"}"#.utf8).base64EncodedString()
            body = "{\"access_token\":\"header.\(payload).signature\",\"refresh_token\":\"test-placeholder\",\"expires_in\":900}"
        case "/api/gamelist/v2/users/me/titles":
            body = #"{"titles":[{"titleId":"cached","name":"Cached","playDuration":"PT2H","lastPlayedDateTime":"2026-01-01T00:00:00Z"},{"titleId":"pending","name":"Pending","playDuration":"PT3H","lastPlayedDateTime":"2026-01-01T00:00:00Z"}],"totalItemCount":2}"#
        case "/api/trophy/v1/users/me/titles/trophyTitles":
            status = 503
            body = #"{"error":{"message":"private response"}}"#
        case "/api/trophy/v1/users/me/trophySummary":
            body = #"{"trophyLevel":"2","progress":10,"tier":1,"earnedTrophies":{"bronze":3,"silver":0,"gold":0,"platinum":0}}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        let respond: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if request.url?.path == "/api/trophy/v1/users/me/titles/trophyTitles", let gate = Self.gate { gate.enqueue(respond) }
        else { respond() }
    }
    override func stopLoading() {}
}
