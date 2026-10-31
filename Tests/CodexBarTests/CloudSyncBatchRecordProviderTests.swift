import CloudKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CloudSyncBatchRecordProviderTests {
    private static let zoneID = CKRecordZone.ID(zoneName: "CodexBarSyncTests", ownerName: CKCurrentUserDefaultName)

    @Test
    func `delayed snapshot save results cannot confirm a newer payload`() throws {
        let (older, _) = try Self.snapshotRecord(used: 10, capturedAt: 1000.125)
        let (newer, newerHash) = try Self.snapshotRecord(used: 20, capturedAt: 2000.125)
        let name = newer.recordID.recordName
        var pending = [name: newerHash]
        var confirmed: [String: String] = [:]
        func finish(_ record: CKRecord) {
            let names = CloudSyncBatchRecordProvider.shouldApplySaveResult(record, pendingSaveHashes: pending)
                ? [record.recordID.recordName] : []
            CloudSyncSnapshotMigration.applyConfirmedSaveHashes(
                savedRecordNames: names, pendingSaveHashes: &pending, lastSnapshotHashes: &confirmed)
        }

        // The dropped old save completes after a replacement has already been queued.
        finish(older)
        #expect(pending[name] == newerHash)
        #expect(confirmed[name] == nil)
        finish(newer)
        #expect(pending[name] == nil)
        #expect(confirmed[name] == newerHash)
        #expect(!CloudSyncBatchRecordProvider.shouldApplySaveResult(older, pendingSaveHashes: pending))
        // A duplicate late result also cannot overwrite the already confirmed replacement.
        finish(older)
        #expect(confirmed[name] == newerHash)
    }

    private static func snapshotRecord(used: Double, capturedAt: TimeInterval) throws -> (CKRecord, String) {
        let payload = AccountSnapshotSyncPayload(
            provider: .claude,
            deviceID: "synthetic-device",
            accountIdentity: "synthetic-account",
            displayLabel: "Synthetic",
            usage: UsageSnapshot(
                primary: RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(timeIntervalSince1970: capturedAt)))
        let record = CKRecord(
            recordType: SyncRecordType.accountSnapshot.rawValue,
            recordID: CKRecord.ID(recordName: payload.recordName, zoneID: Self.zoneID))
        record["schemaVersion"] = payload.schemaVersion as CKRecordValue
        record["provider"] = payload.provider.rawValue as CKRecordValue
        record["deviceID"] = payload.deviceID as CKRecordValue
        record["accountKey"] = payload.accountKey as CKRecordValue
        record["fetchedAt"] = payload.fetchedAt as CKRecordValue
        record.encryptedValues["displayLabel"] = payload.displayLabel as CKRecordValue
        record.encryptedValues["usagePayload"] = try CanonicalSyncJSON.string(payload.usage) as CKRecordValue
        return try (record, CanonicalSyncJSON.hash(payload))
    }
}
