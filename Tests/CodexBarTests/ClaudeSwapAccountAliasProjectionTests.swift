import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSwapAccountAliasProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_782_000_000)

    @Test
    func `keeps unique emails as email only even when organization names are present`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "work@example.com", organizationName: "Sendbird"),
                self.row(number: 2, email: "personal@example.com", organizationName: "Acme", active: true)),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == ["personal@example.com", "work@example.com"])
        #expect(snapshots.map { $0.snapshot?.identity?.accountOrganization } == [nil, nil])
        #expect(snapshots.map { $0.snapshot?.identity?.accountEmail } == [
            "personal@example.com",
            "work@example.com",
        ])
        #expect(snapshots.map(\.id.opaqueID) == ["2", "1"])
    }

    @Test
    func `disambiguates shared emails with organization name or slot ordinal`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "shared@example.com", organizationName: "Sendbird"),
                self.row(number: 4, email: "shared@example.com", organizationName: "", active: true)),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == [
            "shared@example.com · Account 4",
            "shared@example.com · Sendbird",
        ])
        #expect(snapshots.first?.id == ProviderAccountIdentity(source: "claude-swap", opaqueID: "4"))
        #expect(snapshots.last?.id == ProviderAccountIdentity(source: "claude-swap", opaqueID: "1"))
        #expect(snapshots.first?.snapshot?.identity?.accountOrganization == nil)
        #expect(snapshots.last?.snapshot?.identity?.accountOrganization == nil)
        #expect(snapshots.first?.snapshot?.identity?.accountEmail == "shared@example.com")
    }

    @Test
    func `disambiguates shared emails that differ only by case`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "Shared@example.com", organizationName: "Sendbird"),
                self.row(number: 2, email: "shared@example.com", organizationName: "Acme", active: true)),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == [
            "shared@example.com · Acme",
            "Shared@example.com · Sendbird",
        ])
        #expect(snapshots.map { $0.snapshot?.identity?.accountEmail } == [
            "shared@example.com",
            "Shared@example.com",
        ])
    }

    @Test
    func `appends account ordinal when shared emails also share an organization name`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "shared@example.com", organizationName: "Sendbird"),
                self.row(number: 4, email: "shared@example.com", organizationName: "Sendbird", active: true)),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == [
            "shared@example.com · Sendbird · Account 4",
            "shared@example.com · Sendbird · Account 1",
        ])
        #expect(snapshots.map(\.id.opaqueID) == ["4", "1"])
        #expect(snapshots.map { $0.snapshot?.identity?.accountEmail } == [
            "shared@example.com",
            "shared@example.com",
        ])
        #expect(snapshots.map { $0.snapshot?.identity?.accountOrganization } == [nil, nil])
    }

    @Test
    func `appends account ordinal when same-mailbox emails differ only by case`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "Shared@example.com", organizationName: "Sendbird"),
                self.row(number: 4, email: "shared@example.com", organizationName: "Sendbird", active: true)),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == [
            "shared@example.com · Sendbird · Account 4",
            "Shared@example.com · Sendbird · Account 1",
        ])
    }

    @Test
    func `prefers user alias over email and empty email ordinal`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "shared@example.com", organizationName: "Sendbird", alias: "Work"),
                self.row(number: 2, email: "shared@example.com", organizationName: "Acme"),
                self.row(number: 3, email: "", alias: "Empty slot")),
            now: self.now)

        #expect(snapshots.map(\.displayLabel) == ["Work", "shared@example.com · Acme", "Empty slot"])
        #expect(snapshots.map(\.id.opaqueID) == ["1", "2", "3"])
        #expect(snapshots.map { $0.snapshot?.identity?.accountOrganization } == [nil, nil, nil])
        #expect(snapshots.map { $0.snapshot?.identity?.accountEmail } == [
            "shared@example.com",
            "shared@example.com",
            nil,
        ])
    }

    @Test
    func `cloud sync payload omits display only organization names`() throws {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "shared@example.com", organizationName: "Sendbird"),
                self.row(
                    number: 2,
                    email: "shared@example.com",
                    organizationName: "Acme",
                    alias: "Work",
                    active: true)),
            now: self.now)
        let account = try #require(snapshots.first)
        let usage = try #require(account.snapshot)
        let payload = AccountSnapshotSyncPayload(
            provider: account.provider.instanceID,
            deviceID: "test-device",
            accountIdentity: account.accountEmail,
            displayLabel: account.accountEmail ?? "Account \(account.id.opaqueID)",
            usage: usage)
        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedUsage = try #require(json["usage"] as? [String: Any])

        #expect(account.displayLabel == "Work")
        #expect(payload.displayLabel == "shared@example.com")
        #expect(payload.usage.identity?.accountOrganization == nil)
        #expect(encodedUsage["accountOrganization"] == nil || encodedUsage["accountOrganization"] is NSNull)
        #expect(encodedUsage["accountEmail"] as? String == "shared@example.com")
        #expect(usage.identity?.accountID == "claude-swap:2")
    }

    @Test
    func `retained fingerprints skip email shaped aliases when the mailbox is empty`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "", alias: "owner@example.com", active: true)),
            now: self.now)
        let account = snapshots[0]
        #expect(account.displayLabel == "owner@example.com")
        #expect(account.accountEmail == nil)
        #expect(ClaudeSwapRetainedUsageStore.fingerprint(from: account) == nil)
        #expect(ClaudeSwapRetainedUsageStore.snapshotsForRetention(snapshots).isEmpty)
    }

    @Test
    func `cloud sync keys duplicate swap slots by source identity`() {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(
                self.row(number: 1, email: "shared@example.com", organizationName: "Sendbird"),
                self.row(
                    number: 2,
                    email: "shared@example.com",
                    organizationName: "Acme",
                    active: true)),
            now: self.now)
        let names = snapshots.compactMap { account -> String? in
            guard let usage = account.snapshot else { return nil }
            let identity = usage.identity?.accountID
                ?? usage.identity?.accountEmail
                ?? "\(account.id.source):\(account.id.opaqueID)"
            return AccountSnapshotSyncPayload(
                provider: account.provider.instanceID,
                deviceID: "test-device",
                accountIdentity: identity,
                displayLabel: account.accountEmail ?? "Account \(account.id.opaqueID)",
                usage: usage).recordName
        }

        #expect(snapshots.map { $0.snapshot?.identity?.accountID } == [
            "claude-swap:2",
            "claude-swap:1",
        ])
        #expect(Set(names).count == 2)
    }

    @Test
    func `cloud sync payload omits aliases when swap email is missing`() throws {
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.list(self.row(number: 3, email: "", alias: "Empty slot")),
            now: self.now)
        let account = try #require(snapshots.first)
        let usage = try #require(account.snapshot)
        let payload = AccountSnapshotSyncPayload(
            provider: account.provider.instanceID,
            deviceID: "test-device",
            accountIdentity: "\(account.id.source):\(account.id.opaqueID)",
            displayLabel: account.accountEmail ?? "Account \(account.id.opaqueID)",
            usage: usage)
        #expect(account.displayLabel == "Empty slot")
        #expect(account.accountEmail == nil)
        #expect(payload.displayLabel == "Account 3")
    }

    private func list(_ rows: ClaudeSwapAccountRow...) -> ClaudeSwapAccountList {
        ClaudeSwapAccountList(
            activeAccountNumber: rows.first { $0.isActive }?.number,
            accounts: rows)
    }

    private func row(
        number: Int,
        email: String,
        organizationName: String = "",
        alias: String? = nil,
        active: Bool = false) -> ClaudeSwapAccountRow
    {
        ClaudeSwapAccountRow(
            number: number,
            email: email,
            organizationName: organizationName,
            alias: alias,
            isActive: active,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: 10, resetsAt: nil),
            sevenDay: nil)
    }
}
