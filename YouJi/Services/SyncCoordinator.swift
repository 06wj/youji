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
    @Published var lastNintendoSyncAt = UserDefaults.standard.object(forKey: Keys.lastNintendoSyncAt) as? Date
    @Published var lastPlayStationSyncAt = UserDefaults.standard.object(forKey: Keys.lastPlayStationSyncAt) as? Date
    @Published var nintendoReceipt = SyncCoordinator.loadReceipt(forKey: Keys.nintendoReceipt)
    @Published var playStationReceipt = SyncCoordinator.loadReceipt(forKey: Keys.playStationReceipt)
    @Published var errorMessage: String?

    private let nintendoAPI = NintendoAPIClient()
    private let playStationAPI = PlayStationAPIClient()

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
        await performSync {
            let statesBeforeAuthorization = libraryStates(platform: .switchConsole, modelContext: modelContext)
            let token = try await nintendoAPI.exchangeSessionToken(code: code, verifier: verifier)
            try KeychainStore.save(token, account: Keys.nintendoToken)
            isNintendoConnected = true
            try await loadNintendo(modelContext: modelContext, token: token)
            let before = statesBeforeAuthorization[currentNintendoAccountID] ?? [:]
            completeReceipt(platform: .switchConsole, before: before, trophyFailures: 0, modelContext: modelContext)
        }
    }

    func finishPlayStationAuthorization(npsso: String, modelContext: ModelContext) async {
        await performSync {
            let statesBeforeAuthorization = libraryStates(platform: .playStation, modelContext: modelContext)
            let tokens = try await playStationAPI.authorize(npsso: npsso)
            try KeychainStore.save(tokens.refreshToken, account: Keys.playStationRefreshToken)
            isPlayStationConnected = true
            let trophyFailures = try await loadPlayStation(modelContext: modelContext, accessToken: tokens.accessToken)
            let before = statesBeforeAuthorization[currentPlayStationAccountID] ?? [:]
            completeReceipt(platform: .playStation, before: before, trophyFailures: trophyFailures, modelContext: modelContext)
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
            let before = libraryState(platform: .switchConsole, accountID: currentNintendoAccountID, modelContext: modelContext)
            try await loadNintendo(modelContext: modelContext, token: token)
            completeReceipt(platform: .switchConsole, before: before, trophyFailures: 0, modelContext: modelContext)
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
            let before = libraryState(platform: .playStation, accountID: currentPlayStationAccountID, modelContext: modelContext)
            let tokens = try await playStationAPI.refresh(refreshToken: refreshToken)
            try KeychainStore.save(tokens.refreshToken, account: Keys.playStationRefreshToken)
            let trophyFailures = try await loadPlayStation(modelContext: modelContext, accessToken: tokens.accessToken)
            completeReceipt(platform: .playStation, before: before, trophyFailures: trophyFailures, modelContext: modelContext)
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

    func resetNonCredentialState() {
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
            Keys.lastNintendoSyncAt,
            Keys.lastPlayStationSyncAt,
            Keys.nintendoReceipt,
            Keys.playStationReceipt,
            Keys.lastSyncError,
            Keys.didBackfillNintendoDailyActivities,
        ].forEach(defaults.removeObject(forKey:))
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("playstation-trophies.") {
            defaults.removeObject(forKey: key)
        }
    }

    func backfillNintendoDailyActivities(modelContext: ModelContext, force: Bool = false) {
        guard force || !UserDefaults.standard.bool(forKey: Keys.didBackfillNintendoDailyActivities) else {
            return
        }
        do {
            let platformRaw = GamePlatform.switchConsole.rawValue
            let gameDescriptor = FetchDescriptor<GameRecord>(predicate: #Predicate {
                $0.platformRaw == platformRaw
            })
            let activityDescriptor = FetchDescriptor<DailyPlayActivity>(predicate: #Predicate {
                $0.platformRaw == platformRaw
            })
            let switchGames = try modelContext.fetch(gameDescriptor)
            var existingIDs = Set(try modelContext.fetch(activityDescriptor).map(\.activityID))
            var insertedAny = false

            for game in switchGames {
                let referenceDay = Calendar.current.startOfDay(for: game.updatedAt)
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
                    insertedAny = true
                }
            }
            if insertedAny { try modelContext.save() }
            UserDefaults.standard.set(true, forKey: Keys.didBackfillNintendoDailyActivities)
        } catch {
            // A later Nintendo sync can rebuild the recent daily activity window.
        }
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
            try upsertDailyActivities(
                payload.dailyActivities,
                accountID: payload.user.id,
                modelContext: modelContext
            )
            try recordSnapshots(platform: .switchConsole, accountID: payload.user.id, modelContext: modelContext)
            nintendoAccountName = payload.user.nickname
            currentNintendoAccountID = payload.user.id
            isNintendoConnected = true
            UserDefaults.standard.set(nintendoAccountName, forKey: Keys.nintendoAccountName)
            UserDefaults.standard.set(currentNintendoAccountID, forKey: Keys.nintendoAccountID)
            markSynced(platform: .switchConsole)
        } catch {
            handle(error, platform: .switchConsole)
            throw error
        }
    }

    private func loadPlayStation(modelContext: ModelContext, accessToken: String) async throws -> Int {
        do {
            var trophyFailures = 0
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

            for title in payload.titles {
                if let cached = trophyCache[title.titleID],
                   title.lastPlayedAt == nil || cached.syncedAt >= title.lastPlayedAt! {
                    continue
                }
                do {
                    if let update = try await playStationAPI.loadTrophy(
                        titleID: title.titleID,
                        accessToken: accessToken
                    ), let record = recordsByTitleID[update.titleID] {
                        try applyTrophy(update, to: record, modelContext: modelContext)
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
                trophyFailures += 1
            }

            try recordSnapshots(platform: .playStation, accountID: payload.accountID, modelContext: modelContext)
            markSynced(platform: .playStation)
            return trophyFailures
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
        let existing = try records(platform: platform, accountID: accountID, modelContext: modelContext)
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

    private func upsertDailyActivities(
        _ activities: [SyncedDailyActivity],
        accountID: String,
        modelContext: ModelContext
    ) throws {
        guard let earliestDay = activities.map(\.day).min() else { return }
        let platformRaw = GamePlatform.switchConsole.rawValue
        let descriptor = FetchDescriptor<DailyPlayActivity>(predicate: #Predicate {
            $0.platformRaw == platformRaw
                && $0.accountID == accountID
                && $0.day >= earliestDay
        })
        let existing = try modelContext.fetch(descriptor)
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.activityID, $0) })

        for item in activities {
            let activityID = DailyPlayActivity.recordID(
                platform: .switchConsole,
                accountID: accountID,
                titleID: item.titleID,
                day: item.day
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
            activity.day = Calendar.current.startOfDay(for: item.day)
            activity.totalMinutes = item.totalMinutes
            activity.updatedAt = .now
            if byID[activityID] == nil { modelContext.insert(activity) }
        }
        try modelContext.save()
    }

    private func applyTrophy(
        _ update: PlayStationTrophyUpdate,
        to record: GameRecord,
        modelContext: ModelContext
    ) throws {
        record.trophiesEarned = update.earned
        record.trophiesDefined = update.defined
        record.platinumTrophiesEarned = update.platinum
        record.trophiesSyncedAt = update.syncedAt
        record.updatedAt = .now
        try modelContext.save()
    }

    private func migrateLegacyRecords(
        platform: GamePlatform,
        accountID: String,
        modelContext: ModelContext
    ) throws {
        guard !accountID.isEmpty else { return }
        let platformRaw = platform.rawValue
        let descriptor = FetchDescriptor<GameRecord>(predicate: #Predicate {
            $0.platformRaw == platformRaw
        })
        let records = try modelContext.fetch(descriptor)
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
        try modelContext.save()
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

    private func markSynced(platform: GamePlatform) {
        lastSyncAt = .now
        UserDefaults.standard.set(lastSyncAt, forKey: Keys.lastSyncAt)
        switch platform {
        case .playStation:
            lastPlayStationSyncAt = lastSyncAt
            UserDefaults.standard.set(lastSyncAt, forKey: Keys.lastPlayStationSyncAt)
        case .switchConsole:
            lastNintendoSyncAt = lastSyncAt
            UserDefaults.standard.set(lastSyncAt, forKey: Keys.lastNintendoSyncAt)
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
            key = Keys.playStationReceipt
        case .switchConsole:
            nintendoReceipt = receipt
            key = Keys.nintendoReceipt
        }
        if let data = try? JSONEncoder().encode(receipt) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadReceipt(forKey key: String) -> PlatformSyncReceipt? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PlatformSyncReceipt.self, from: data)
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
        static let lastNintendoSyncAt = "last-nintendo-sync-at"
        static let lastPlayStationSyncAt = "last-playstation-sync-at"
        static let nintendoReceipt = "nintendo-sync-receipt"
        static let playStationReceipt = "playstation-sync-receipt"
        static let lastSyncError = "last-sync-error"
        static let didBackfillNintendoDailyActivities = "did-backfill-nintendo-daily-activities-v1"
    }
}
