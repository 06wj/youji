import Foundation
import SwiftData

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
    @Published var errorMessage: String?

    private let nintendoAPI = NintendoAPIClient()
    private let playStationAPI = PlayStationAPIClient()

    var connectedPlatformCount: Int {
        (isNintendoConnected ? 1 : 0) + (isPlayStationConnected ? 1 : 0)
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
        await performSync {
            let token = try await nintendoAPI.exchangeSessionToken(code: code, verifier: verifier)
            try KeychainStore.save(token, account: Keys.nintendoToken)
            isNintendoConnected = true
            try await loadNintendo(modelContext: modelContext, token: token)
        }
    }

    func finishPlayStationAuthorization(npsso: String, modelContext: ModelContext) async {
        await performSync {
            let tokens = try await playStationAPI.authorize(npsso: npsso)
            try KeychainStore.save(tokens.refreshToken, account: Keys.playStationRefreshToken)
            isPlayStationConnected = true
            try await loadPlayStation(modelContext: modelContext, accessToken: tokens.accessToken)
        }
    }

    func syncNintendo(modelContext: ModelContext) async throws {
        guard let token = KeychainStore.read(account: Keys.nintendoToken) else {
            isNintendoConnected = false
            throw NintendoAuthError.missingCode
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await loadNintendo(modelContext: modelContext, token: token)
            errorMessage = nil
            UserDefaults.standard.removeObject(forKey: Keys.lastSyncError)
        } catch {
            handle(error, platform: .switchConsole)
            throw error
        }
    }

    func syncPlayStation(modelContext: ModelContext) async throws {
        guard let refreshToken = KeychainStore.read(account: Keys.playStationRefreshToken) else {
            isPlayStationConnected = false
            throw PlayStationSyncError.invalidNPSSO
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let tokens = try await playStationAPI.refresh(refreshToken: refreshToken)
            try KeychainStore.save(tokens.refreshToken, account: Keys.playStationRefreshToken)
            try await loadPlayStation(modelContext: modelContext, accessToken: tokens.accessToken)
            errorMessage = nil
            UserDefaults.standard.removeObject(forKey: Keys.lastSyncError)
        } catch {
            handle(error, platform: .playStation)
            throw error
        }
    }

    func syncAll(modelContext: ModelContext) async {
        guard !isSyncing else { return }
        let shouldSyncNintendo = isNintendoConnected
        let shouldSyncPlayStation = isPlayStationConnected
        var failures: [String] = []

        if shouldSyncNintendo {
            do { try await syncNintendo(modelContext: modelContext) }
            catch { failures.append("Switch：\(error.localizedDescription)") }
        }
        if shouldSyncPlayStation {
            do { try await syncPlayStation(modelContext: modelContext) }
            catch { failures.append("PlayStation：\(error.localizedDescription)") }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func disconnectNintendo() {
        KeychainStore.delete(account: Keys.nintendoToken)
        isNintendoConnected = false
        nintendoAccountName = ""
        currentNintendoAccountID = ""
        UserDefaults.standard.removeObject(forKey: Keys.nintendoAccountName)
        UserDefaults.standard.removeObject(forKey: Keys.nintendoAccountID)
    }

    func disconnectPlayStation() {
        KeychainStore.delete(account: Keys.playStationRefreshToken)
        isPlayStationConnected = false
        playStationAccountName = ""
        currentPlayStationAccountID = ""
        playStationTrophies = nil
        UserDefaults.standard.removeObject(forKey: Keys.playStationAccountName)
        UserDefaults.standard.removeObject(forKey: Keys.playStationAccountID)
    }

    private func performSync(_ operation: () async throws -> Void) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await operation()
            errorMessage = nil
            UserDefaults.standard.removeObject(forKey: Keys.lastSyncError)
        } catch {
            errorMessage = error.localizedDescription
            UserDefaults.standard.set(errorMessage, forKey: Keys.lastSyncError)
        }
    }

    private func loadNintendo(modelContext: ModelContext, token: String) async throws {
        do {
            let payload = try await nintendoAPI.loadLibrary(sessionToken: token)
            try upsert(payload.games, platform: .switchConsole, accountID: payload.user.id, preserveTrophies: false, modelContext: modelContext)
            try recordSnapshots(platform: .switchConsole, accountID: payload.user.id, modelContext: modelContext)
            nintendoAccountName = payload.user.nickname
            currentNintendoAccountID = payload.user.id
            isNintendoConnected = true
            UserDefaults.standard.set(nintendoAccountName, forKey: Keys.nintendoAccountName)
            UserDefaults.standard.set(currentNintendoAccountID, forKey: Keys.nintendoAccountID)
            markSynced()
        } catch {
            handle(error, platform: .switchConsole)
            throw error
        }
    }

    private func loadPlayStation(modelContext: ModelContext, accessToken: String) async throws {
        do {
            let payload = try await playStationAPI.loadGames(accessToken: accessToken)
            try upsert(payload.games, platform: .playStation, accountID: payload.accountID, preserveTrophies: true, modelContext: modelContext)

            if payload.accountID != currentPlayStationAccountID {
                if let data = UserDefaults.standard.data(forKey: Keys.playStationTrophies(accountID: payload.accountID)) {
                    playStationTrophies = try? JSONDecoder().decode(PlayStationTrophySummary.self, from: data)
                } else {
                    playStationTrophies = nil
                }
            }
            playStationAccountName = payload.accountName
            currentPlayStationAccountID = payload.accountID
            isPlayStationConnected = true
            UserDefaults.standard.set(playStationAccountName, forKey: Keys.playStationAccountName)
            UserDefaults.standard.set(currentPlayStationAccountID, forKey: Keys.playStationAccountID)

            let existing = try modelContext.fetch(FetchDescriptor<GameRecord>())
            let trophyCache = Dictionary(uniqueKeysWithValues: existing.compactMap { record -> (String, PlayStationTrophyCacheEntry)? in
                guard record.platform == .playStation,
                      record.accountID == payload.accountID,
                      let syncedAt = record.trophiesSyncedAt else { return nil }
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

            for title in payload.titles {
                if let cached = trophyCache[title.titleID],
                   title.lastPlayedAt == nil || cached.syncedAt >= title.lastPlayedAt! {
                    continue
                }
                do {
                    if let update = try await playStationAPI.loadTrophy(
                        titleID: title.titleID,
                        accessToken: accessToken
                    ) {
                        try applyTrophies([update], accountID: payload.accountID, modelContext: modelContext)
                    }
                } catch PlayStationSyncError.authenticationExpired {
                    throw PlayStationSyncError.authenticationExpired
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Keep the previous value, leave trophiesSyncedAt stale, and retry next sync.
                    continue
                }
            }

            do {
                let summary = try await playStationAPI.loadTrophySummary(accessToken: accessToken)
                playStationTrophies = summary
                if let data = try? JSONEncoder().encode(summary) {
                    UserDefaults.standard.set(data, forKey: Keys.playStationTrophies(accountID: payload.accountID))
                }
            } catch PlayStationSyncError.authenticationExpired {
                throw PlayStationSyncError.authenticationExpired
            } catch {
                // Game and per-title trophy data are already durable. Retry the summary next sync.
            }

            try recordSnapshots(platform: .playStation, accountID: payload.accountID, modelContext: modelContext)
            markSynced()
        } catch {
            handle(error, platform: .playStation)
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
        let existing = try modelContext.fetch(FetchDescriptor<GameRecord>())
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.applicationID, $0) })

        for item in games {
            let recordID = GameRecord.recordID(platform: item.platform, accountID: accountID, titleID: item.titleID)
            let record = byID[recordID] ?? GameRecord(
                applicationID: recordID,
                accountID: accountID,
                titleID: item.titleID,
                platform: item.platform,
                title: item.title
            )
            record.accountID = accountID
            record.titleID = item.titleID
            record.platform = item.platform
            record.title = item.title
            record.totalMinutes = item.totalMinutes
            record.imageURL = item.imageURL
            record.firstPlayedAt = item.firstPlayedAt
            record.lastPlayedAt = item.lastPlayedAt
            record.weeklyMinutes = item.weeklyMinutes
            if !preserveTrophies {
                record.trophiesEarned = item.trophiesEarned
                record.trophiesDefined = item.trophiesDefined
                record.platinumTrophiesEarned = item.platinumTrophiesEarned
                record.trophiesSyncedAt = item.trophiesSyncedAt
            }
            record.updatedAt = .now
            if byID[recordID] == nil { modelContext.insert(record) }
        }
        try modelContext.save()
    }

    private func applyTrophies(
        _ updates: [PlayStationTrophyUpdate],
        accountID: String,
        modelContext: ModelContext
    ) throws {
        let records = try modelContext.fetch(FetchDescriptor<GameRecord>())
        let byTitleID = Dictionary(uniqueKeysWithValues: records
            .filter { $0.platform == .playStation && $0.accountID == accountID }
            .map { ($0.resolvedTitleID, $0) })
        for update in updates {
            guard let record = byTitleID[update.titleID] else { continue }
            record.trophiesEarned = update.earned
            record.trophiesDefined = update.defined
            record.platinumTrophiesEarned = update.platinum
            record.trophiesSyncedAt = update.syncedAt
            record.updatedAt = .now
        }
        try modelContext.save()
    }

    private func migrateLegacyRecords(
        platform: GamePlatform,
        accountID: String,
        modelContext: ModelContext
    ) throws {
        guard !accountID.isEmpty else { return }
        let records = try modelContext.fetch(FetchDescriptor<GameRecord>())
        let existingIDs = Set(records.map(\.applicationID))
        for record in records where record.platform == platform && record.accountID.isEmpty {
            let titleID = record.resolvedTitleID
            let newID = GameRecord.recordID(platform: platform, accountID: accountID, titleID: titleID)
            if existingIDs.contains(newID) {
                modelContext.delete(record)
            } else {
                record.accountID = accountID
                record.titleID = titleID
                record.applicationID = newID
            }
        }
        try modelContext.save()
    }

    private func recordSnapshots(
        platform: GamePlatform,
        accountID: String,
        modelContext: ModelContext
    ) throws {
        let records = try modelContext.fetch(FetchDescriptor<GameRecord>())
        let date = Date.now
        for record in records where record.platform == platform && record.accountID == accountID {
            modelContext.insert(PlaySnapshot(
                gameID: record.applicationID,
                accountID: accountID,
                platform: platform,
                date: date,
                totalMinutes: record.totalMinutes,
                trophiesEarned: record.trophiesEarned
            ))
        }
        try modelContext.save()
    }

    private func markSynced() {
        lastSyncAt = .now
        UserDefaults.standard.set(lastSyncAt, forKey: Keys.lastSyncAt)
    }

    private func handle(_ error: Error, platform: GamePlatform) {
        switch platform {
        case .switchConsole:
            if case NintendoSyncError.authenticationExpired = error {
                KeychainStore.delete(account: Keys.nintendoToken)
                isNintendoConnected = false
            }
        case .playStation:
            if case PlayStationSyncError.authenticationExpired = error {
                KeychainStore.delete(account: Keys.playStationRefreshToken)
                isPlayStationConnected = false
            }
        }
        errorMessage = error.localizedDescription
        UserDefaults.standard.set(errorMessage, forKey: Keys.lastSyncError)
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
        static let lastSyncError = "last-sync-error"
    }
}
