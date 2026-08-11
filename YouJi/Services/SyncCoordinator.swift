import Foundation
import SwiftData

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published var isSyncing = false
    @Published var isNintendoConnected = KeychainStore.read(account: Keys.nintendoToken) != nil
    @Published var isPlayStationConnected = KeychainStore.read(account: Keys.playStationRefreshToken) != nil
    @Published var nintendoAccountName = UserDefaults.standard.string(forKey: Keys.nintendoAccountName) ?? ""
    @Published var playStationAccountName = UserDefaults.standard.string(forKey: Keys.playStationAccountName) ?? ""
    @Published var playStationTrophies: PlayStationTrophySummary? = {
        guard let data = UserDefaults.standard.data(forKey: Keys.playStationTrophies) else { return nil }
        return try? JSONDecoder().decode(PlayStationTrophySummary.self, from: data)
    }()
    @Published var lastSyncAt = UserDefaults.standard.object(forKey: Keys.lastSyncAt) as? Date
    @Published var errorMessage: String?

    private let nintendoAPI = NintendoAPIClient()
    private let playStationAPI = PlayStationAPIClient()

    var connectedPlatformCount: Int {
        (isNintendoConnected ? 1 : 0) + (isPlayStationConnected ? 1 : 0)
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
        UserDefaults.standard.removeObject(forKey: Keys.nintendoAccountName)
    }

    func disconnectPlayStation() {
        KeychainStore.delete(account: Keys.playStationRefreshToken)
        isPlayStationConnected = false
        playStationAccountName = ""
        UserDefaults.standard.removeObject(forKey: Keys.playStationAccountName)
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
            try upsert(payload.games, modelContext: modelContext)
            nintendoAccountName = payload.user.nickname
            isNintendoConnected = true
            UserDefaults.standard.set(nintendoAccountName, forKey: Keys.nintendoAccountName)
            markSynced()
        } catch {
            handle(error, platform: .switchConsole)
            throw error
        }
    }

    private func loadPlayStation(modelContext: ModelContext, accessToken: String) async throws {
        do {
            let existing = try modelContext.fetch(FetchDescriptor<GameRecord>())
            let trophyCache = Dictionary(uniqueKeysWithValues: existing.compactMap { record -> (String, PlayStationTrophyCacheEntry)? in
                guard record.platform == .playStation, let syncedAt = record.trophiesSyncedAt else { return nil }
                let rawTitleID = record.applicationID.hasPrefix("ps:")
                    ? String(record.applicationID.dropFirst(3))
                    : record.applicationID
                return (
                    rawTitleID,
                    PlayStationTrophyCacheEntry(
                        earned: record.trophiesEarned,
                        defined: record.trophiesDefined,
                        platinum: record.platinumTrophiesEarned,
                        syncedAt: syncedAt
                    )
                )
            })
            let payload = try await playStationAPI.loadLibrary(
                accessToken: accessToken,
                trophyCache: trophyCache,
                cachedTrophySummary: playStationTrophies
            )
            try upsert(payload.games, modelContext: modelContext)
            playStationAccountName = payload.accountName
            playStationTrophies = payload.trophies
            isPlayStationConnected = true
            UserDefaults.standard.set(playStationAccountName, forKey: Keys.playStationAccountName)
            if let data = try? JSONEncoder().encode(payload.trophies) {
                UserDefaults.standard.set(data, forKey: Keys.playStationTrophies)
            }
            markSynced()
        } catch {
            handle(error, platform: .playStation)
            throw error
        }
    }

    private func upsert(_ games: [SyncedGame], modelContext: ModelContext) throws {
        let existing = try modelContext.fetch(FetchDescriptor<GameRecord>())
        for record in existing where !record.applicationID.contains(":") {
            record.applicationID = "switch:\(record.applicationID)"
            record.platform = .switchConsole
        }
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.applicationID, $0) })

        for item in games {
            let record = byID[item.applicationID] ?? GameRecord(
                applicationID: item.applicationID,
                platform: item.platform,
                title: item.title
            )
            record.platform = item.platform
            record.title = item.title
            record.totalMinutes = item.totalMinutes
            record.imageURL = item.imageURL
            record.firstPlayedAt = item.firstPlayedAt
            record.lastPlayedAt = item.lastPlayedAt
            record.weeklyMinutes = item.weeklyMinutes
            record.trophiesEarned = item.trophiesEarned
            record.trophiesDefined = item.trophiesDefined
            record.platinumTrophiesEarned = item.platinumTrophiesEarned
            record.trophiesSyncedAt = item.trophiesSyncedAt
            record.updatedAt = .now
            if byID[item.applicationID] == nil { modelContext.insert(record) }
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
            if case NintendoSyncError.http(401, _) = error {
                KeychainStore.delete(account: Keys.nintendoToken)
                isNintendoConnected = false
            }
        case .playStation:
            if case PlayStationSyncError.http(401, _) = error {
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
        static let playStationAccountName = "playstation-account-name"
        static let playStationTrophies = "playstation-trophies"
        static let lastSyncAt = "last-sync-at"
        static let lastSyncError = "last-sync-error"
    }
}
