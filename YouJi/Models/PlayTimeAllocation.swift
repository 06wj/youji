import Foundation
import SwiftData

struct AllocatedPlayDay: Codable, Equatable, Sendable {
    let dayKey: String
    let minutes: Int
}

/// An independent distribution of one observed increase. Snapshot IDs and totals
/// freeze its scope; later syncs must never expand or overwrite that scope.
struct PlayTimeAllocationValue: Codable, Equatable, Sendable, Identifiable {
    var id: String { endSnapshotID }
    let gameID: String
    let accountID: String
    let startSnapshotID: String
    let endSnapshotID: String
    let startTotalMinutes: Int
    let endTotalMinutes: Int
    let startDayKey: String
    let endDayKey: String
    var days: [AllocatedPlayDay]
    var updatedAt: Date
    var isDeleted: Bool = false

    var totalMinutes: Int { endTotalMinutes - startTotalMinutes }
}

@Model
final class PlayTimeAllocation {
    @Attribute(.unique) var allocationID: String
    var gameID: String
    var accountID: String
    var valueData: Data

    init(_ value: PlayTimeAllocationValue) throws {
        allocationID = value.id
        gameID = value.gameID
        accountID = value.accountID
        valueData = try JSONEncoder().encode(value)
    }

    func readValue() throws -> PlayTimeAllocationValue {
        let value = try JSONDecoder().decode(PlayTimeAllocationValue.self, from: valueData)
        guard value.id == allocationID, value.gameID == gameID, value.accountID == accountID else {
            throw PlayTimeAllocationError.invalid("游玩日期记录的归属不一致")
        }
        return value
    }

    func replace(with value: PlayTimeAllocationValue) throws {
        guard value.id == allocationID, value.gameID == gameID, value.accountID == accountID else {
            throw PlayTimeAllocationError.invalid("游玩日期记录的归属不一致")
        }
        valueData = try JSONEncoder().encode(value)
    }
}
