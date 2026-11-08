import Foundation
import SwiftData

struct PlatformSyncReceipt: Codable, Equatable, Identifiable {
    var id: String { "\(platform.rawValue)-\(syncedAt.timeIntervalSince1970)" }
    let platform: GamePlatform
    let syncedAt: Date
    let addedGames: Int
    let changedGames: Int
    let addedMinutes: Int
    let addedTrophies: Int
    let trophyFailures: Int
}

struct PlatformSyncProgress: Equatable {
    let platform: GamePlatform
    let title: String
    let detail: String
    var completed: Int? = nil
    var total: Int? = nil
    var gameListSaved = false
}

struct PlatformSyncIssue: Equatable, Identifiable {
    enum Recovery: Equatable { case reconnect, retry }

    var id: String { "\(platform.rawValue)-\(message)" }
    let platform: GamePlatform
    let message: String
    let recovery: Recovery
    var isPartialSuccess = false

    var actionTitle: String {
        recovery == .reconnect ? "重新连接 \(platform.shortName)" : "重试 \(platform.shortName) 同步"
    }

    /// Only controlled copy reaches UI and diagnostics; server payloads may contain credentials.
    static func from(_ error: Error, platform: GamePlatform, gameListSaved: Bool = false) -> PlatformSyncIssue {
        var recovery: Recovery = .retry
        let reason: String
        switch error {
        case PlayStationSyncError.invalidNPSSO, PlayStationSyncError.missingAccountIdentity:
            recovery = .reconnect
            reason = "未能确认 PlayStation 登录，请重新完成连接。"
        case PlayStationSyncError.authenticationExpired, PlayStationSyncError.http(401, _), PlayStationSyncError.http(403, _):
            recovery = .reconnect
            reason = "PlayStation 登录已过期，请重新连接。"
        case NintendoSyncError.authenticationExpired, NintendoSyncError.http(401, _), NintendoSyncError.http(403, _):
            recovery = .reconnect
            reason = "Nintendo 登录已过期，请重新连接。"
        case is NintendoAuthError:
            recovery = .reconnect
            reason = "未能完成 Nintendo 登录，请重新连接。"
        case PlayStationSyncError.decode, NintendoSyncError.decode, PlayStationSyncError.incompletePagination:
            reason = "平台暂未返回完整记录，请稍后重试。"
        case is URLError:
            reason = "暂时无法连接 \(platform.shortName)，请检查网络后重试。"
        case is KeychainError:
            reason = "登录信息未能保存到这台设备，请稍后重试连接。"
            recovery = .reconnect
        default:
            reason = "\(platform.shortName) 暂时无法完成同步，请稍后重试。"
        }
        let retained = gameListSaved ? "已读取的游戏记录已保存。" : "本机已有的游戏记录会保留。"
        return PlatformSyncIssue(platform: platform, message: reason + retained, recovery: recovery, isPartialSuccess: gameListSaved)
    }
}

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published var isSyncing = false
    @Published var isNintendoConnected = KeychainStore.read(account: Keys.nintendoToken) != nil
    @Published var isPlayStationConnected = KeychainStore.read(account: Keys.playStationRefreshToken) != nil
    @Published var currentNintendoAccountID = UserDefaults.standard.string(forKey: Keys.nintendoAccountID) ?? ""
    @Published var currentPlayStationAccountID = UserDefaults.standard.string(forKey: Keys.playStationAccountID) ?? ""
    @Published var nintendoAccountName = UserDefaults.standard.string(forKey: Keys.nintendoAccountName) ?? ""
    @Published var playStationAccountName = UserDefaults.standard.string(forKey: Keys.playStationAccountName) ?? ""
    @Published var playStationTrophies: PlayStationTrophySummary? = {
        let accountID = UserDefaults.standard.string(forKey: Keys.playStationAccountID) ?? ""
        guard !accountID.isEmpty,
              let data = UserDefaults.standard.data(forKey: Keys.playStationTrophies(accountID: accountID)) else { return nil }
        return try? JSONDecoder().decode(PlayStationTrophySummary.self, from: data)
    }()
    @Published var lastSyncAt = UserDefaults.standard.object(forKey: Keys.lastSyncAt) as? Date
    @Published var lastNintendoSyncAt = SyncCoordinator.loadSyncDate(
        platform: .switchConsole,
        accountID: UserDefaults.standard.string(forKey: Keys.nintendoAccountID) ?? "",
        allowLegacy: true
    )
    @Published var lastPlayStationSyncAt = SyncCoordinator.loadSyncDate(
        platform: .playStation,
        accountID: UserDefaults.standard.string(forKey: Keys.playStationAccountID) ?? "",
        allowLegacy: true
    )
    @Published var nintendoReceipt = SyncCoordinator.loadReceipt(
        platform: .switchConsole,
        accountID: UserDefaults.standard.string(forKey: Keys.nintendoAccountID) ?? "",
        allowLegacy: true
    )
    @Published var playStationReceipt = SyncCoordinator.loadReceipt(
        platform: .playStation,
        accountID: UserDefaults.standard.string(forKey: Keys.playStationAccountID) ?? "",
        allowLegacy: true
    )
    @Published var errorMessage: String?
    @Published private(set) var syncProgress: PlatformSyncProgress?
    @Published private(set) var syncIssue: PlatformSyncIssue?
    @Published private var platformIssues: [GamePlatform: PlatformSyncIssue] = [:]

    private let nintendoAPI: NintendoAPIClient
    private let playStationAPI: PlayStationAPIClient
    private let credentialWriter: (String, String) throws -> Void
    private var activeRevision: UUID?

    init(
        nintendoAPI: NintendoAPIClient = NintendoAPIClient(),
        playStationAPI: PlayStationAPIClient = PlayStationAPIClient(),
        credentialWriter: @escaping (String, String) throws -> Void = { try KeychainStore.save($0, account: $1) }
    ) {
        self.nintendoAPI = nintendoAPI
        self.playStationAPI = playStationAPI
        self.credentialWriter = credentialWriter
    }

    func issue(for platform: GamePlatform) -> PlatformSyncIssue? { platformIssues[platform] }

    func clearIssue(for platform: GamePlatform) {
        platformIssues[platform] = nil
        if syncIssue?.platform == platform { syncIssue = nil }
        errorMessage = nil
    }

    private func setIssue(_ issue: PlatformSyncIssue, presentsAlert: Bool = true) {
        platformIssues[issue.platform] = issue
        syncIssue = issue
        errorMessage = presentsAlert ? issue.message : nil
        UserDefaults.standard.set(issue.message, forKey: Keys.lastSyncError)
    }

    private func beginSync(platform: GamePlatform, authorizing: Bool = false) throws -> UUID {
        guard !isSyncing || activeRevision != LocalDataRevision.current else { throw SyncStateError.alreadySyncing }
        clearIssue(for: platform)
        activeRevision = LocalDataRevision.current
        isSyncing = true
        syncProgress = PlatformSyncProgress(
            platform: platform,
            title: authorizing ? "正在确认登录" : "正在连接 \(platform.shortName)",
            detail: "本机已有的游戏记录会保留。"
        )
        return LocalDataRevision.current
    }

    private func finishSync(_ revision: UUID) {
        guard activeRevision == revision else { return }
        activeRevision = nil
        isSyncing = false
        syncProgress = nil
    }

    var connectedPlatformCount: Int {
        (isNintendoConnected ? 1 : 0) + (isPlayStationConnected ? 1 : 0)
    }

    var currentAccountScopeKey: String {
        AccountScope.key(
            playStationAccountID: currentPlayStationAccountID,
            nintendoAccountID: currentNintendoAccountID
        )
    }

    func owns(_ record: GameRecord) -> Bool {
        switch record.platform {
        case .playStation:
            return currentPlayStationAccountID.isEmpty
                ? record.accountID.isEmpty
                : record.accountID == currentPlayStationAccountID
        case .switchConsole:
            return currentNintendoAccountID.isEmpty
                ? record.accountID.isEmpty
                : record.accountID == currentNintendoAccountID
        }
    }

    func finishAuthorization(code: String, verifier: String, modelContext: ModelContext) async {
        await performSync(platform: .switchConsole) { revision in
            let statesBeforeAuthorization = libraryStates(platform: .switchConsole, modelContext: modelContext)
            let token = try await nintendoAPI.exchangeSessionToken(code: code, verifier: verifier)
            try LocalDataRevision.check(revision)
            syncProgress = PlatformSyncProgress(platform: .switchConsole, title: "正在读取游戏库", detail: "正在读取总时长和最近 7 天的游玩记录。")
            let payload = try await nintendoAPI.loadLibrary(sessionToken: token)
            try LocalDataRevision.check(revision)
            try credentialWriter(token, Keys.nintendoToken)
            isNintendoConnected = true
            selectNintendoIdentity(payload.user)
            try await loadNintendo(modelContext: modelContext, token: token, loadedPayload: payload, revision: revision)
            let before = statesBeforeAuthorization[currentNintendoAccountID] ?? [:]
            try LocalDataRevision.check(revision)
            completeReceipt(platform: .switchConsole, before: before, trophyFailures: 0, modelContext: modelContext)
        }
    }

    func finishPlayStationAuthorization(npsso: String, modelContext: ModelContext) async {
        await performSync(platform: .playStation) { revision in
            let statesBeforeAuthorization = libraryStates(platform: .playStation, modelContext: modelContext)
            let tokens = try await playStationAPI.authorize(npsso: npsso)
            try LocalDataRevision.check(revision)
            syncProgress = PlatformSyncProgress(platform: .playStation, title: "正在读取游戏库", detail: "游戏较多时需要稍等片刻，之后会补全奖杯。")
            let payload = try await playStationAPI.loadGames(accessToken: tokens.accessToken)
            try LocalDataRevision.check(revision)
            try credentialWriter(tokens.refreshToken, Keys.playStationRefreshToken)
            isPlayStationConnected = true
            selectPlayStationIdentity(payload)
            let trophyFailures = try await loadPlayStation(
                modelContext: modelContext,
                accessToken: tokens.accessToken,
                loadedPayload: payload,
                revision: revision
            )
            let before = statesBeforeAuthorization[currentPlayStationAccountID] ?? [:]
            try LocalDataRevision.check(revision)
            completeReceipt(platform: .playStation, before: before, trophyFailures: trophyFailures, modelContext: modelContext)
        }
    }

    func syncNintendo(modelContext: ModelContext) async throws {
        guard let token = KeychainStore.read(account: Keys.nintendoToken) else {
            isNintendoConnected = false
            reportConnectionError(NintendoAuthError.missingCode, platform: .switchConsole)
            throw NintendoAuthError.missingCode
        }
        let revision = try beginSync(platform: .switchConsole)
        defer { finishSync(revision) }
        do {
            let before = libraryState(platform: .switchConsole, accountID: currentNintendoAccountID, modelContext: modelContext)
            try await loadNintendo(modelContext: modelContext, token: token, revision: revision)
            try LocalDataRevision.check(revision)
            completeReceipt(platform: .switchConsole, before: before, trophyFailures: 0, modelContext: modelContext)
            errorMessage = nil
            UserDefaults.standard.removeObject(forKey: Keys.lastSyncError)
        } catch {
            try LocalDataRevision.check(revision)
            if error is CancellationError { throw error }
            handle(error, platform: .switchConsole)
            throw error
        }
    }

    func syncPlayStation(modelContext: ModelContext) async throws {
        guard let refreshToken = KeychainStore.read(account: Keys.playStationRefreshToken) else {
            isPlayStationConnected = false
            reportConnectionError(PlayStationSyncError.invalidNPSSO, platform: .playStation)
            throw PlayStationSyncError.invalidNPSSO
        }
        let revision = try beginSync(platform: .playStation)
        defer { finishSync(revision) }
        do {
            let before = libraryState(platform: .playStation, accountID: currentPlayStationAccountID, modelContext: modelContext)
            let tokens = try await playStationAPI.refresh(refreshToken: refreshToken)
            try LocalDataRevision.check(revision)
            syncProgress = PlatformSyncProgress(platform: .playStation, title: "正在读取游戏库", detail: "正在更新游戏名称、时长和最近游玩。")
            let payload = try await playStationAPI.loadGames(accessToken: tokens.accessToken)
            try LocalDataRevision.check(revision)
            try credentialWriter(tokens.refreshToken, Keys.playStationRefreshToken)
            selectPlayStationIdentity(payload)
            let trophyFailures = try await loadPlayStation(
                modelContext: modelContext,
                accessToken: tokens.accessToken,
                loadedPayload: payload,
                revision: revision
            )
            try LocalDataRevision.check(revision)
            completeReceipt(platform: .playStation, before: before, trophyFailures: trophyFailures, modelContext: modelContext)
            errorMessage = nil
            if issue(for: .playStation) == nil { UserDefaults.standard.removeObject(forKey: Keys.lastSyncError) }
        } catch {
            try LocalDataRevision.check(revision)
            if error is CancellationError { throw error }
            handle(error, platform: .playStation)
            throw error
        }
    }

    func syncAll(modelContext: ModelContext) async {
        guard !isSyncing else { return }
        let revision = LocalDataRevision.current
        let shouldSyncNintendo = isNintendoConnected
        let shouldSyncPlayStation = isPlayStationConnected
        var failures: [String] = []

        if shouldSyncNintendo {
            do { try await syncNintendo(modelContext: modelContext) }
            catch { failures.append(issue(for: .switchConsole)?.message ?? "Switch 暂时无法同步，请重试。") }
        }
        guard revision == LocalDataRevision.current else { return }
        if shouldSyncPlayStation {
            do { try await syncPlayStation(modelContext: modelContext) }
            catch { failures.append(issue(for: .playStation)?.message ?? "PlayStation 暂时无法同步，请重试。") }
        }
        guard revision == LocalDataRevision.current else { return }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func disconnectNintendo(invalidatePendingWork: Bool = true) {
        if invalidatePendingWork {
            LocalDataRevision.invalidate()
            clearIssue(for: .switchConsole)
        }
        activeRevision = nil
        isSyncing = false
        syncProgress = nil
        KeychainStore.delete(account: Keys.nintendoToken)
        isNintendoConnected = false
        nintendoAccountName = ""
        currentNintendoAccountID = ""
        lastNintendoSyncAt = nil
        nintendoReceipt = nil
        UserDefaults.standard.removeObject(forKey: Keys.nintendoAccountName)
        UserDefaults.standard.removeObject(forKey: Keys.nintendoAccountID)
    }

    func disconnectPlayStation(invalidatePendingWork: Bool = true) {
        if invalidatePendingWork {
            LocalDataRevision.invalidate()
            clearIssue(for: .playStation)
        }
        activeRevision = nil
        isSyncing = false
        syncProgress = nil
        KeychainStore.delete(account: Keys.playStationRefreshToken)
        isPlayStationConnected = false
        playStationAccountName = ""
        currentPlayStationAccountID = ""
        playStationTrophies = nil
        lastPlayStationSyncAt = nil
        playStationReceipt = nil
        UserDefaults.standard.removeObject(forKey: Keys.playStationAccountName)
        UserDefaults.standard.removeObject(forKey: Keys.playStationAccountID)
    }

    func resetNonCredentialState() {
        activeRevision = nil
        isSyncing = false
        syncProgress = nil
        syncIssue = nil
        platformIssues = [:]
        Self.clearStoredNonCredentialState()
        currentNintendoAccountID = ""
        currentPlayStationAccountID = ""
        nintendoAccountName = ""
        playStationAccountName = ""
        playStationTrophies = nil
        lastSyncAt = nil
        lastNintendoSyncAt = nil
        lastPlayStationSyncAt = nil
        nintendoReceipt = nil
        playStationReceipt = nil
        errorMessage = nil
    }

    static func clearStoredNonCredentialState() {
        let defaults = UserDefaults.standard
        [
            Keys.nintendoAccountName,
            Keys.nintendoAccountID,
            Keys.playStationAccountName,
            Keys.playStationAccountID,
            Keys.lastSyncAt,
            Keys.legacyLastNintendoSyncAt,
            Keys.legacyLastPlayStationSyncAt,
            Keys.legacyNintendoReceipt,
            Keys.legacyPlayStationReceipt,
            Keys.lastSyncError,
            Keys.didBackfillNintendoDailyActivities,
        ].forEach(defaults.removeObject(forKey:))
        for key in defaults.dictionaryRepresentation().keys where
            key.hasPrefix("playstation-trophies.")
                || key.hasPrefix("sync-date.")
                || key.hasPrefix("sync-receipt.") {
            defaults.removeObject(forKey: key)
        }
    }

    func backfillNintendoDailyActivities(modelContext: ModelContext, force: Bool = false) {
        guard force || !UserDefaults.standard.bool(forKey: Keys.didBackfillNintendoDailyActivities) else {
            return
        }
        do {
            try LocalPersistence.transaction(modelContext) { modelContext in
                let platformRaw = GamePlatform.switchConsole.rawValue
                let gameDescriptor = FetchDescriptor<GameRecord>(predicate: #Predicate {
                    $0.platformRaw == platformRaw
                })
                let activityDescriptor = FetchDescriptor<DailyPlayActivity>(predicate: #Predicate {
                    $0.platformRaw == platformRaw
                })
                let switchGames = try modelContext.fetch(gameDescriptor)
                var existingIDs = Set(try modelContext.fetch(activityDescriptor).map(\.activityID))

                for game in switchGames {
                    // Legacy arrays do not identify their original time zone or calendar day.
                    // Keep existing daily records, but never guess dates from updatedAt.
                    guard let referenceDay = DailyPlayActivity.date(fromDayKey: game.weeklyEndingDayKey) else { continue }
                    for (index, minutes) in game.weeklyMinutes.prefix(7).enumerated() where minutes > 0 {
                        guard let day = Calendar.current.date(
                            byAdding: .day,
                            value: index - 6,
                            to: referenceDay
                        ) else { continue }
                        let activityID = DailyPlayActivity.recordID(
                            platform: .switchConsole,
                            accountID: game.accountID,
                            titleID: game.resolvedTitleID,
                            day: day
                        )
                        guard existingIDs.insert(activityID).inserted else { continue }
                        modelContext.insert(DailyPlayActivity(
                            activityID: activityID,
                            gameID: game.applicationID,
                            accountID: game.accountID,
                            titleID: game.resolvedTitleID,
                            platform: .switchConsole,
                            day: day,
                            totalMinutes: minutes
                        ))
                    }
                }
            }
            UserDefaults.standard.set(true, forKey: Keys.didBackfillNintendoDailyActivities)
        } catch {
            errorMessage = "每日记录未能保存：\(error.localizedDescription)"
        }
    }

    private func performSync(platform: GamePlatform, _ operation: (UUID) async throws -> Void) async {
        guard !isSyncing || activeRevision != LocalDataRevision.current else { return }
        // A newly authorized account supersedes pending AI requests for the old scope.
        LocalDataRevision.invalidate()
        guard let revision = try? beginSync(platform: platform, authorizing: true) else { return }
        defer { finishSync(revision) }
        do {
            try await operation(revision)
            try LocalDataRevision.check(revision)
            errorMessage = nil
            if issue(for: platform) == nil { UserDefaults.standard.removeObject(forKey: Keys.lastSyncError) }
        } catch {
            guard revision == LocalDataRevision.current, !(error is CancellationError) else { return }
            // A failed new sign-in must not discard the previously working credential.
            handle(error, platform: platform, invalidatesCredential: syncProgress?.gameListSaved == true)
        }
    }

    private func loadNintendo(
        modelContext: ModelContext,
        token: String,
        loadedPayload: NintendoSyncPayload? = nil,
        revision: UUID
    ) async throws {
        do {
            let payload: NintendoSyncPayload
            if let loadedPayload {
                payload = loadedPayload
            } else {
                syncProgress = PlatformSyncProgress(platform: .switchConsole, title: "正在读取游戏库", detail: "正在读取总时长和最近 7 天的游玩记录。")
                payload = try await nintendoAPI.loadLibrary(sessionToken: token)
            }
            try LocalDataRevision.check(revision)
            guard !payload.user.id.isEmpty else { throw NintendoSyncError.decode("缺少账号身份") }
            selectNintendoIdentity(payload.user)
            syncProgress = PlatformSyncProgress(platform: .switchConsole, title: "正在保存游玩记录", detail: "已读取 \(payload.games.count) 款游戏，正在保存到这台设备。")
            try upsert(payload.games, platform: .switchConsole, accountID: payload.user.id, preserveTrophies: false, modelContext: modelContext)
            syncProgress = PlatformSyncProgress(platform: .switchConsole, title: "正在保存每日活动", detail: "已保存 \(payload.games.count) 款游戏，正在整理最近游玩的日期。", gameListSaved: true)
            try upsertDailyActivities(
                payload.dailyActivities,
                accountID: payload.user.id,
                modelContext: modelContext
            )
            try recordSnapshots(platform: .switchConsole, accountID: payload.user.id, modelContext: modelContext)
            markSynced(platform: .switchConsole, accountID: payload.user.id)
        } catch {
            try LocalDataRevision.check(revision)
            if error is CancellationError { throw error }
            throw error
        }
    }

    private func loadPlayStation(
        modelContext: ModelContext,
        accessToken: String,
        loadedPayload: PlayStationGamesPayload? = nil,
        revision: UUID
    ) async throws -> Int {
        do {
            var trophyFailures = 0
            let payload: PlayStationGamesPayload
            if let loadedPayload {
                payload = loadedPayload
            } else {
                payload = try await playStationAPI.loadGames(accessToken: accessToken)
            }
            try LocalDataRevision.check(revision)
            selectPlayStationIdentity(payload)
            syncProgress = PlatformSyncProgress(platform: .playStation, title: "正在保存游戏库", detail: "已读取 \(payload.games.count) 款游戏，正在保存到这台设备。")
            try upsert(payload.games, platform: .playStation, accountID: payload.accountID, preserveTrophies: true, modelContext: modelContext)
            syncProgress = PlatformSyncProgress(platform: .playStation, title: "游戏库已保存", detail: "已收录 \(payload.games.count) 款游戏，正在准备奖杯。", gameListSaved: true)

            let trophyRecords = try records(
                platform: .playStation,
                accountID: payload.accountID,
                modelContext: modelContext
            )
            let recordsByTitleID = Dictionary(uniqueKeysWithValues: trophyRecords.map { ($0.resolvedTitleID, $0) })
            let trophyCache = Dictionary(uniqueKeysWithValues: trophyRecords.compactMap { record -> (String, PlayStationTrophyCacheEntry)? in
                guard let syncedAt = record.trophiesSyncedAt else { return nil }
                return (
                    record.resolvedTitleID,
                    PlayStationTrophyCacheEntry(
                        earned: record.trophiesEarned,
                        defined: record.trophiesDefined,
                        platinum: record.platinumTrophiesEarned,
                        syncedAt: syncedAt
                    )
                )
            })

            let pendingTitles = payload.titles.filter { title in
                guard let cached = trophyCache[title.titleID] else { return true }
                return title.lastPlayedAt.map { cached.syncedAt < $0 } ?? false
            }
            var completedTitles = 0
            syncProgress = PlatformSyncProgress(platform: .playStation, title: "正在补全奖杯", detail: "已保存 \(payload.games.count) 款游戏，可以先浏览。", completed: 0, total: pendingTitles.count, gameListSaved: true)
            for title in pendingTitles {
                try LocalDataRevision.check(revision)
                defer {
                    if revision == LocalDataRevision.current, activeRevision == revision {
                        completedTitles += 1
                        syncProgress = PlatformSyncProgress(platform: .playStation, title: "正在补全奖杯", detail: "已保存 \(payload.games.count) 款游戏，可以先浏览。", completed: completedTitles, total: pendingTitles.count, gameListSaved: true)
                    }
                }
                do {
                    let update = try await playStationAPI.loadTrophy(
                        titleID: title.titleID,
                        accessToken: accessToken
                    )
                    try LocalDataRevision.check(revision)
                    guard let record = recordsByTitleID[title.titleID] else {
                        trophyFailures += 1
                        continue
                    }
                    if let update {
                        try applyTrophy(update, to: record, modelContext: modelContext)
                    } else if record.trophiesDefined > 0 {
                        // Previously known trophies unexpectedly disappeared. Preserve them
                        // and report this as retryable, unlike a title with no trophy record.
                        trophyFailures += 1
                    }
                } catch PlayStationSyncError.authenticationExpired {
                    throw PlayStationSyncError.authenticationExpired
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Keep the previous value, leave trophiesSyncedAt stale, and retry next sync.
                    trophyFailures += 1
                    continue
                }
            }

            syncProgress = PlatformSyncProgress(platform: .playStation, title: "正在读取奖杯总览", detail: "游戏库已保存，正在完成最后一步。", completed: completedTitles, total: pendingTitles.count, gameListSaved: true)
            do {
                let summary = try await playStationAPI.loadTrophySummary(accessToken: accessToken)
                try LocalDataRevision.check(revision)
                playStationTrophies = summary
                if let data = try? JSONEncoder().encode(summary) {
                    UserDefaults.standard.set(data, forKey: Keys.playStationTrophies(accountID: payload.accountID))
                }
            } catch PlayStationSyncError.authenticationExpired {
                throw PlayStationSyncError.authenticationExpired
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Game and per-title trophy data are already durable. Retry the summary next sync.
                trophyFailures += 1
            }

            try LocalDataRevision.check(revision)
            try recordSnapshots(platform: .playStation, accountID: payload.accountID, modelContext: modelContext)
            markSynced(platform: .playStation, accountID: payload.accountID)
            if trophyFailures > 0 {
                setIssue(PlatformSyncIssue(platform: .playStation, message: "游戏记录已保存，\(trophyFailures) 项奖杯数据暂未更新。重试会保留已完成的结果。", recovery: .retry, isPartialSuccess: true), presentsAlert: false)
            }
            return trophyFailures
        } catch {
            try LocalDataRevision.check(revision)
            if error is CancellationError { throw error }
            throw error
        }
    }

    private func upsert(
        _ games: [SyncedGame],
        platform: GamePlatform,
        accountID: String,
        preserveTrophies: Bool,
        modelContext: ModelContext
    ) throws {
        try migrateLegacyRecords(platform: platform, accountID: accountID, modelContext: modelContext)
        try LocalPersistence.transaction(modelContext) { modelContext in
            let existing = try records(platform: platform, accountID: accountID, modelContext: modelContext)
            var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.applicationID, $0) })

            for item in games {
                let recordID = GameRecord.recordID(platform: item.platform, accountID: accountID, titleID: item.titleID)
                let record = byID[recordID] ?? GameRecord(
                    applicationID: recordID,
                    accountID: accountID,
                    titleID: item.titleID,
                    platform: item.platform,
                    title: item.title
                )
                guard item.platform == platform, !item.titleID.isEmpty,
                      DataValidation.minutes(item.totalMinutes), item.weeklyMinutes.count == 7,
                      item.weeklyMinutes.allSatisfy(DataValidation.minutes),
                      item.weeklyEndingDayKey.map({ DailyPlayActivity.date(fromDayKey: $0) != nil }) ?? true else {
                    throw ProductDataError.invalidBackup("平台游戏数据不完整")
                }
                // Freeze a legacy customization timestamp before advancing platform freshness.
                if record.userEditedAt == .distantPast { record.userEditedAt = record.resolvedUserEditedAt }
                record.accountID = accountID
                record.titleID = item.titleID
                record.platform = item.platform
                if !item.title.isEmpty { record.title = item.title }
                record.totalMinutes = item.totalMinutes
                if !item.imageURL.isEmpty { record.imageURL = item.imageURL }
                record.firstPlayedAt = item.firstPlayedAt ?? record.firstPlayedAt
                record.lastPlayedAt = item.lastPlayedAt ?? record.lastPlayedAt
                record.weeklyMinutes = item.weeklyMinutes
                record.weeklyEndingDayKey = item.platform == .switchConsole ? item.weeklyEndingDayKey ?? "" : ""
                if !preserveTrophies {
                    record.trophiesEarned = item.trophiesEarned
                    record.trophiesDefined = item.trophiesDefined
                    record.platinumTrophiesEarned = item.platinumTrophiesEarned
                    record.trophiesSyncedAt = item.trophiesSyncedAt
                }
                record.updatedAt = .now
                if byID[recordID] == nil { modelContext.insert(record) }
                byID[recordID] = record
            }
        }
    }

    private func upsertDailyActivities(
        _ activities: [SyncedDailyActivity],
        accountID: String,
        modelContext: ModelContext
    ) throws {
        try LocalPersistence.transaction(modelContext) { modelContext in
            guard !activities.isEmpty else { return }
            let platformRaw = GamePlatform.switchConsole.rawValue
            let descriptor = FetchDescriptor<DailyPlayActivity>(predicate: #Predicate {
                $0.platformRaw == platformRaw
                    && $0.accountID == accountID
            })
            let existing = try modelContext.fetch(descriptor)
            var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.activityID, $0) })

            for item in activities {
                guard DataValidation.minutes(item.totalMinutes), DailyPlayActivity.date(fromDayKey: item.dayKey) != nil else {
                    throw ProductDataError.invalidBackup("平台每日记录不完整")
                }
                let activityID = DailyPlayActivity.recordID(
                    platform: .switchConsole,
                    accountID: accountID,
                    titleID: item.titleID,
                    dayKey: item.dayKey
                )
                let activity = byID[activityID] ?? DailyPlayActivity(
                    activityID: activityID,
                    gameID: GameRecord.recordID(
                        platform: .switchConsole,
                        accountID: accountID,
                        titleID: item.titleID
                    ),
                    accountID: accountID,
                    titleID: item.titleID,
                    platform: .switchConsole,
                    day: item.day,
                    totalMinutes: item.totalMinutes
                )
                activity.dayKey = item.dayKey
                activity.day = DailyPlayActivity.date(fromDayKey: item.dayKey) ?? Calendar.current.startOfDay(for: item.day)
                activity.totalMinutes = item.totalMinutes
                activity.updatedAt = .now
                if byID[activityID] == nil { modelContext.insert(activity) }
                byID[activityID] = activity
            }
        }
    }

    private func applyTrophy(
        _ update: PlayStationTrophyUpdate,
        to record: GameRecord,
        modelContext: ModelContext
    ) throws {
        let applicationID = record.applicationID
        try LocalPersistence.transaction(modelContext) { modelContext in
            guard let record = try modelContext.fetch(FetchDescriptor<GameRecord>(predicate: #Predicate {
                $0.applicationID == applicationID
            })).first else { throw CancellationError() }
            if record.userEditedAt == .distantPast { record.userEditedAt = record.resolvedUserEditedAt }
            record.trophiesEarned = update.earned
            record.trophiesDefined = update.defined
            record.platinumTrophiesEarned = update.platinum
            record.trophiesSyncedAt = update.syncedAt
            record.updatedAt = .now
        }
    }

    private func migrateLegacyRecords(
        platform: GamePlatform,
        accountID: String,
        modelContext: ModelContext
    ) throws {
        try LegacyRecordMigrator.migrate(
            platform: platform,
            accountID: accountID,
            modelContext: modelContext
        )
    }

    private func recordSnapshots(
        platform: GamePlatform,
        accountID: String,
        modelContext: ModelContext
    ) throws {
        try LocalPersistence.transaction(modelContext) { modelContext in
            let records = try records(platform: platform, accountID: accountID, modelContext: modelContext)
            let date = Date.now
            for record in records {
                modelContext.insert(PlaySnapshot(
                    gameID: record.applicationID,
                    accountID: accountID,
                    platform: platform,
                    date: date,
                    totalMinutes: record.totalMinutes,
                    trophiesEarned: record.trophiesEarned
                ))
            }
        }
    }

    private func records(
        platform: GamePlatform,
        accountID: String,
        modelContext: ModelContext
    ) throws -> [GameRecord] {
        let platformRaw = platform.rawValue
        let descriptor = FetchDescriptor<GameRecord>(predicate: #Predicate {
            $0.platformRaw == platformRaw && $0.accountID == accountID
        })
        return try modelContext.fetch(descriptor)
    }

    private func selectNintendoIdentity(_ user: NintendoUser) {
        let changedAccount = currentNintendoAccountID != user.id
        currentNintendoAccountID = user.id
        nintendoAccountName = user.nickname
        isNintendoConnected = true
        UserDefaults.standard.set(user.id, forKey: Keys.nintendoAccountID)
        UserDefaults.standard.set(user.nickname, forKey: Keys.nintendoAccountName)
        if changedAccount {
            lastNintendoSyncAt = Self.loadSyncDate(platform: .switchConsole, accountID: user.id)
            nintendoReceipt = Self.loadReceipt(platform: .switchConsole, accountID: user.id)
        }
    }

    private func selectPlayStationIdentity(_ payload: PlayStationGamesPayload) {
        let changedAccount = currentPlayStationAccountID != payload.accountID
        currentPlayStationAccountID = payload.accountID
        playStationAccountName = payload.accountName
        isPlayStationConnected = true
        UserDefaults.standard.set(payload.accountID, forKey: Keys.playStationAccountID)
        UserDefaults.standard.set(payload.accountName, forKey: Keys.playStationAccountName)
        if changedAccount {
            lastPlayStationSyncAt = Self.loadSyncDate(platform: .playStation, accountID: payload.accountID)
            playStationReceipt = Self.loadReceipt(platform: .playStation, accountID: payload.accountID)
            if let data = UserDefaults.standard.data(forKey: Keys.playStationTrophies(accountID: payload.accountID)) {
                playStationTrophies = try? JSONDecoder().decode(PlayStationTrophySummary.self, from: data)
            } else {
                playStationTrophies = nil
            }
        }
    }

    private func markSynced(platform: GamePlatform, accountID: String) {
        lastSyncAt = .now
        UserDefaults.standard.set(lastSyncAt, forKey: Keys.lastSyncAt)
        switch platform {
        case .playStation:
            lastPlayStationSyncAt = lastSyncAt
            UserDefaults.standard.set(lastSyncAt, forKey: Keys.syncDate(platform: platform, accountID: accountID))
        case .switchConsole:
            lastNintendoSyncAt = lastSyncAt
            UserDefaults.standard.set(lastSyncAt, forKey: Keys.syncDate(platform: platform, accountID: accountID))
        }
    }

    private struct LibraryValue {
        let minutes: Int
        let trophies: Int
    }

    private func libraryState(
        platform: GamePlatform,
        accountID: String,
        modelContext: ModelContext
    ) -> [String: LibraryValue] {
        guard !accountID.isEmpty,
              let records = try? records(platform: platform, accountID: accountID, modelContext: modelContext) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: records.map {
            ($0.applicationID, LibraryValue(minutes: $0.totalMinutes, trophies: $0.trophiesEarned))
        })
    }

    private func libraryStates(
        platform: GamePlatform,
        modelContext: ModelContext
    ) -> [String: [String: LibraryValue]] {
        let platformRaw = platform.rawValue
        let descriptor = FetchDescriptor<GameRecord>(predicate: #Predicate {
            $0.platformRaw == platformRaw
        })
        guard let allRecords = try? modelContext.fetch(descriptor) else { return [:] }
        return Dictionary(grouping: allRecords.filter { !$0.accountID.isEmpty }, by: \.accountID)
            .mapValues { records in
                Dictionary(uniqueKeysWithValues: records.map {
                    ($0.applicationID, LibraryValue(minutes: $0.totalMinutes, trophies: $0.trophiesEarned))
                })
            }
    }

    private func completeReceipt(
        platform: GamePlatform,
        before: [String: LibraryValue],
        trophyFailures: Int,
        modelContext: ModelContext
    ) {
        let accountID = platform == .playStation ? currentPlayStationAccountID : currentNintendoAccountID
        let after = libraryState(platform: platform, accountID: accountID, modelContext: modelContext)
        let receipt = PlatformSyncReceipt(
            platform: platform,
            syncedAt: .now,
            addedGames: after.keys.filter { before[$0] == nil }.count,
            changedGames: after.filter { id, value in
                guard let old = before[id] else { return false }
                return old.minutes != value.minutes || old.trophies != value.trophies
            }.count,
            addedMinutes: max(0, after.values.reduce(0) { $0 + $1.minutes } - before.values.reduce(0) { $0 + $1.minutes }),
            addedTrophies: max(0, after.values.reduce(0) { $0 + $1.trophies } - before.values.reduce(0) { $0 + $1.trophies }),
            trophyFailures: trophyFailures
        )
        let key: String
        switch platform {
        case .playStation:
            playStationReceipt = receipt
            key = Keys.receipt(platform: platform, accountID: accountID)
        case .switchConsole:
            nintendoReceipt = receipt
            key = Keys.receipt(platform: platform, accountID: accountID)
        }
        if let data = try? JSONEncoder().encode(receipt) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadReceipt(forKey key: String) -> PlatformSyncReceipt? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PlatformSyncReceipt.self, from: data)
    }

    private static func loadReceipt(
        platform: GamePlatform,
        accountID: String,
        allowLegacy: Bool = false
    ) -> PlatformSyncReceipt? {
        guard !accountID.isEmpty else { return nil }
        let scopedKey = Keys.receipt(platform: platform, accountID: accountID)
        if let scoped = loadReceipt(forKey: scopedKey) { return scoped }
        guard allowLegacy,
              let legacy = loadReceipt(
                forKey: platform == .playStation ? Keys.legacyPlayStationReceipt : Keys.legacyNintendoReceipt
              ) else { return nil }
        if let data = try? JSONEncoder().encode(legacy) {
            UserDefaults.standard.set(data, forKey: scopedKey)
        }
        return legacy
    }

    private static func loadSyncDate(
        platform: GamePlatform,
        accountID: String,
        allowLegacy: Bool = false
    ) -> Date? {
        guard !accountID.isEmpty else { return nil }
        let scopedKey = Keys.syncDate(platform: platform, accountID: accountID)
        if let scoped = UserDefaults.standard.object(forKey: scopedKey) as? Date { return scoped }
        guard allowLegacy,
              let legacy = UserDefaults.standard.object(
                forKey: platform == .playStation ? Keys.legacyLastPlayStationSyncAt : Keys.legacyLastNintendoSyncAt
              ) as? Date else { return nil }
        UserDefaults.standard.set(legacy, forKey: scopedKey)
        return legacy
    }

    func reportConnectionError(_ error: Error, platform: GamePlatform) {
        setIssue(PlatformSyncIssue.from(error, platform: platform))
    }

    private func handle(_ error: Error, platform: GamePlatform, invalidatesCredential: Bool = true) {
        let issue = PlatformSyncIssue.from(error, platform: platform, gameListSaved: syncProgress?.gameListSaved == true)
        let authenticationExpired: Bool
        switch error {
        case PlayStationSyncError.authenticationExpired, PlayStationSyncError.http(401, _), PlayStationSyncError.http(403, _),
             NintendoSyncError.authenticationExpired, NintendoSyncError.http(401, _), NintendoSyncError.http(403, _):
            authenticationExpired = true
        default:
            authenticationExpired = false
        }
        if authenticationExpired && invalidatesCredential {
            switch platform {
            case .switchConsole:
                disconnectNintendo(invalidatePendingWork: false)
            case .playStation:
                disconnectPlayStation(invalidatePendingWork: false)
            }
        }
        setIssue(issue)
    }

    private enum Keys {
        static let nintendoToken = "store-session-token"
        static let playStationRefreshToken = "psn-refresh-token"
        static let nintendoAccountName = "nintendo-account-name"
        static let nintendoAccountID = "nintendo-account-id"
        static let playStationAccountName = "playstation-account-name"
        static let playStationAccountID = "playstation-account-id"
        static func playStationTrophies(accountID: String) -> String { "playstation-trophies.\(accountID)" }
        static let lastSyncAt = "last-sync-at"
        static let legacyLastNintendoSyncAt = "last-nintendo-sync-at"
        static let legacyLastPlayStationSyncAt = "last-playstation-sync-at"
        static let legacyNintendoReceipt = "nintendo-sync-receipt"
        static let legacyPlayStationReceipt = "playstation-sync-receipt"
        static func syncDate(platform: GamePlatform, accountID: String) -> String {
            "sync-date.\(platform == .playStation ? "ps" : "switch").\(accountID)"
        }
        static func receipt(platform: GamePlatform, accountID: String) -> String {
            "sync-receipt.\(platform == .playStation ? "ps" : "switch").\(accountID)"
        }
        static let lastSyncError = "last-sync-error"
        static let didBackfillNintendoDailyActivities = "did-backfill-nintendo-daily-activities-v1"
    }
}

@MainActor
enum LegacyRecordMigrator {
    static func migrate(
        platform: GamePlatform,
        accountID: String,
        modelContext: ModelContext
    ) throws {
        guard !accountID.isEmpty else { return }
        try LocalPersistence.transaction(modelContext) { modelContext in
            let platformRaw = platform.rawValue
            let descriptor = FetchDescriptor<GameRecord>(predicate: #Predicate {
                $0.platformRaw == platformRaw
            })
            let records = try modelContext.fetch(descriptor)
            var recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.applicationID, $0) })
            let snapshots = try modelContext.fetch(FetchDescriptor<PlaySnapshot>())
            let activities = try modelContext.fetch(FetchDescriptor<DailyPlayActivity>())
            var activitiesByID = Dictionary(uniqueKeysWithValues: activities.map { ($0.activityID, $0) })

            for legacy in records where legacy.platform == platform && legacy.accountID.isEmpty {
                let oldID = legacy.applicationID
                let titleID = legacy.resolvedTitleID
                let newID = GameRecord.recordID(platform: platform, accountID: accountID, titleID: titleID)

                for snapshot in snapshots where snapshot.gameID == oldID {
                    snapshot.gameID = newID
                    snapshot.accountID = accountID
                    snapshot.platformRaw = platform.rawValue
                }

                for activity in activities where activity.gameID == oldID {
                    let newActivityID = "\(newID):\(activity.resolvedDayKey)"
                    if let existing = activitiesByID[newActivityID], existing !== activity {
                        existing.totalMinutes = max(existing.totalMinutes, activity.totalMinutes)
                        existing.updatedAt = max(existing.updatedAt, activity.updatedAt)
                        modelContext.delete(activity)
                    } else {
                        activitiesByID.removeValue(forKey: activity.activityID)
                        activity.activityID = newActivityID
                        activity.gameID = newID
                        activity.accountID = accountID
                        activity.titleID = titleID
                        activity.platformRaw = platform.rawValue
                        activity.dayKey = activity.resolvedDayKey
                        activitiesByID[newActivityID] = activity
                    }
                }

                if let current = recordsByID[newID], current !== legacy {
                    mergeUserAndHistoryData(from: legacy, into: current)
                    modelContext.delete(legacy)
                } else {
                    recordsByID.removeValue(forKey: oldID)
                    legacy.userEditedAt = legacy.resolvedUserEditedAt
                    legacy.accountID = accountID
                    legacy.titleID = titleID
                    legacy.applicationID = newID
                    recordsByID[newID] = legacy
                }
            }
        }
    }

    private static func mergeUserAndHistoryData(from legacy: GameRecord, into current: GameRecord) {
        let actualUserEditedAt = max(current.resolvedUserEditedAt, legacy.resolvedUserEditedAt)
        current.totalMinutes = max(current.totalMinutes, legacy.totalMinutes)
        if current.title.isEmpty { current.title = legacy.title }
        if current.imageURL.isEmpty { current.imageURL = legacy.imageURL }
        current.firstPlayedAt = [current.firstPlayedAt, legacy.firstPlayedAt].compactMap { $0 }.min()
        current.lastPlayedAt = [current.lastPlayedAt, legacy.lastPlayedAt].compactMap { $0 }.max()
        if legacy.updatedAt > current.updatedAt { current.weeklyMinutes = legacy.weeklyMinutes }
        current.trophiesEarned = max(current.trophiesEarned, legacy.trophiesEarned)
        current.trophiesDefined = max(current.trophiesDefined, legacy.trophiesDefined)
        current.platinumTrophiesEarned = max(current.platinumTrophiesEarned, legacy.platinumTrophiesEarned)
        current.trophiesSyncedAt = [current.trophiesSyncedAt, legacy.trophiesSyncedAt].compactMap { $0 }.max()
        current.isFavorite = current.isFavorite || legacy.isFavorite
        current.isManuallyHidden = current.isManuallyHidden || legacy.isManuallyHidden
        current.isPinnedVisible = current.isPinnedVisible || legacy.isPinnedVisible
        if current.personalNote.isEmpty {
            current.personalNote = legacy.personalNote
        } else if !legacy.personalNote.isEmpty && !current.personalNote.contains(legacy.personalNote) {
            current.personalNote += "\n\(legacy.personalNote)"
        }
        if current.playStatus == .played && legacy.playStatus != .played {
            current.playStatus = legacy.playStatus
        }
        current.userEditedAt = actualUserEditedAt
        current.updatedAt = max(current.updatedAt, legacy.updatedAt)
    }
}

private enum SyncStateError: LocalizedError {
    case alreadySyncing
    var errorDescription: String? { "正在同步，请稍后再试。" }
}
