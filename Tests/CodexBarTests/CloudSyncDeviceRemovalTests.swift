import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CloudSyncDeviceRemovalTests {
    @Test
    func `removing a device targets its record and every snapshot it published`() {
        let stale = Self.snapshot(deviceID: "stale", accountKey: "a")
        let alsoStale = Self.snapshot(deviceID: "stale", accountKey: "b")
        let other = Self.snapshot(deviceID: "other", accountKey: "a")

        let names = CloudSyncDeviceRemoval.recordNames(
            forDeviceID: "stale",
            snapshots: Self.byRecordName([stale, alsoStale, other]))

        #expect(names == Set([
            DeviceSyncPayload.recordName(for: "stale"),
            stale.recordName,
            alsoStale.recordName,
        ]))
    }

    @Test
    func `removing a device spares snapshots published by other devices`() {
        let other = Self.snapshot(deviceID: "other", accountKey: "a")

        let names = CloudSyncDeviceRemoval.recordNames(
            forDeviceID: "stale",
            snapshots: Self.byRecordName([other]))

        #expect(names == Set([DeviceSyncPayload.recordName(for: "stale")]))
    }

    private static func byRecordName(
        _ snapshots: [AccountSnapshotSyncPayload]) -> [String: AccountSnapshotSyncPayload]
    {
        Dictionary(uniqueKeysWithValues: snapshots.map { ($0.recordName, $0) })
    }

    private static func snapshot(deviceID: String, accountKey: String) -> AccountSnapshotSyncPayload {
        let fetchedAt = Date(timeIntervalSince1970: 100)
        return AccountSnapshotSyncPayload(
            provider: .codex,
            deviceID: deviceID,
            accountKey: accountKey,
            fetchedAt: fetchedAt,
            displayLabel: "person@example.com",
            usage: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 25,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: fetchedAt))
    }
}
