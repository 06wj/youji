import Foundation
import SwiftData

/// A request may only write into the local archive it started with.
/// All access is on the main actor, including validation immediately before a write.
@MainActor
enum LocalDataRevision {
    private(set) static var current = UUID()

    static func invalidate() { current = UUID() }

    static func check(_ revision: UUID) throws {
        try Task.checkCancellation()
        guard revision == current else { throw CancellationError() }
    }
}

@MainActor
enum LocalPersistence {
    /// Use a disposable writer so a failed SwiftData save cannot leave its registered
    /// models or pending deletes in the UI context. Flush unrelated edits first.
    static func transaction<T>(
        _ context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() },
        _ changes: (ModelContext) throws -> T
    ) throws -> T {
        guard context.container.configurations.allSatisfy(\.allowsSave) else { throw CocoaError(.fileWriteNoPermission) }
        if context.hasChanges { try context.save() }
        let writer = ModelContext(context.container)
        writer.autosaveEnabled = false
        do {
            let result = try changes(writer)
            writer.processPendingChanges()
            let affected = affectedEntities(writer)
            let updated = writer.changedModelsArray
            try save(writer)
            if #available(iOS 26, *) { } else {
                for model in updated { mirrorCommitted(model, into: context) }
                // These values are already durable. If this idempotent UI-cache
                // save fails, the matching pending values can safely retry later.
                if context.hasChanges { try? context.save() }
            }
            refresh(context, entities: affected)
            return result
        } catch {
            let affected = affectedEntities(writer)
            writer.rollback()
            refresh(context, entities: affected)
            throw error
        }
    }

    private static func affectedEntities(_ context: ModelContext) -> Set<String> {
        Set((context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray)
            .map { String(describing: type(of: $0)) })
    }

    private static func refresh(_ context: ModelContext, entities: Set<String>) {
        // Refetch only registered entity types. This also refreshes already-present
        // model instances after a successful write from another context.
        let names = entities
        if names.contains("GameRecord") { _ = try? context.fetch(FetchDescriptor<GameRecord>()) }
        if names.contains("PlaySnapshot") { _ = try? context.fetch(FetchDescriptor<PlaySnapshot>()) }
        if names.contains("DailyPlayActivity") { _ = try? context.fetch(FetchDescriptor<DailyPlayActivity>()) }
        if names.contains("AIConversation") { _ = try? context.fetch(FetchDescriptor<AIConversation>()) }
        if names.contains("AIProfileResult") { _ = try? context.fetch(FetchDescriptor<AIProfileResult>()) }
        if names.contains("SavedGamePlan") { _ = try? context.fetch(FetchDescriptor<SavedGamePlan>()) }
        context.processPendingChanges()
    }

    /// iOS 17's registered models stay stale across contexts, even after refetch.
    /// Copy only already-committed updates; failures never mutate the UI models.
    private static func mirrorCommitted(_ source: any PersistentModel, into context: ModelContext) {
        switch source {
        case let source as GameRecord:
            guard let target: GameRecord = context.registeredModel(for: source.persistentModelID) else { return }
            copy(source, target, [\.applicationID, \.accountID, \.titleID, \.platformRaw, \.title, \.imageURL, \.personalNote, \.playStatusRaw, \.weeklyEndingDayKey])
            copy(source, target, [\.totalMinutes, \.trophiesEarned, \.trophiesDefined, \.platinumTrophiesEarned])
            copy(source, target, [\.firstPlayedAt, \.lastPlayedAt, \.trophiesSyncedAt])
            copy(source, target, [\.updatedAt, \.userEditedAt])
            copy(source, target, [\.isFavorite, \.isManuallyHidden, \.isPinnedVisible])
            copy(source, target, [\.weeklyMinutesData])
        case let source as PlaySnapshot:
            guard let target: PlaySnapshot = context.registeredModel(for: source.persistentModelID) else { return }
            copy(source, target, [\.snapshotID, \.gameID, \.accountID, \.platformRaw])
            copy(source, target, [\.totalMinutes, \.trophiesEarned])
            copy(source, target, [\.date])
        case let source as DailyPlayActivity:
            guard let target: DailyPlayActivity = context.registeredModel(for: source.persistentModelID) else { return }
            copy(source, target, [\.activityID, \.gameID, \.accountID, \.titleID, \.platformRaw, \.dayKey])
            copy(source, target, [\.totalMinutes])
            copy(source, target, [\.day, \.updatedAt])
        case let source as AIConversation:
            guard let target: AIConversation = context.registeredModel(for: source.persistentModelID) else { return }
            copy(source, target, [\.id])
            copy(source, target, [\.title, \.accountScopeKey, \.draft])
            copy(source, target, [\.createdAt, \.updatedAt])
            copy(source, target, [\.titleGeneratedAt])
            copy(source, target, [\.messagesData, \.gameContextData])
        case let source as AIProfileResult:
            guard let target: AIProfileResult = context.registeredModel(for: source.persistentModelID) else { return }
            copy(source, target, [\.id])
            copy(source, target, [\.accountScopeKey, \.platformFilter, \.text, \.inputFingerprint])
            copy(source, target, [\.minimumHours, \.gameCount, \.totalMinutes])
            copy(source, target, [\.generatedAt])
        case let source as SavedGamePlan:
            guard let target: SavedGamePlan = context.registeredModel(for: source.persistentModelID) else { return }
            copy(source, target, [\.id])
            copy(source, target, [\.accountScopeKey, \.title, \.note, \.gameID, \.sourceConversationID])
            copy(source, target, [\.createdAt, \.updatedAt])
            copy(source, target, [\.isCompleted])
        default: break
        }
    }

    private static func copy<Model: AnyObject, Value: Equatable>(
        _ source: Model, _ target: Model, _ paths: [ReferenceWritableKeyPath<Model, Value>]
    ) {
        for path in paths where target[keyPath: path] != source[keyPath: path] {
            target[keyPath: path] = source[keyPath: path]
        }
    }

    static func conversation(_ id: UUID, in context: ModelContext) throws -> AIConversation {
        guard let conversation = try context.fetch(FetchDescriptor<AIConversation>(predicate: #Predicate { $0.id == id })).first else {
            throw CancellationError()
        }
        return conversation
    }
}

// Deliberately generous bounds; reject overflow/corruption rather than plausible long histories.
enum DataValidation {
    static let maximumMinutes = 100_000_000
    static let maximumTrophies = 1_000_000

    static func minutes(_ value: Int) -> Bool { (0...maximumMinutes).contains(value) }
    static func trophies(_ value: Int) -> Bool { (0...maximumTrophies).contains(value) }
}
