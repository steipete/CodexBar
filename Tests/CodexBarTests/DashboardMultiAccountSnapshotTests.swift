import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct DashboardMultiAccountSnapshotTests {
    private let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let primaryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let secondaryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test
    func `projects generic multi account usage into one provider row`() throws {
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [
                self.payload(
                    label: "alice@corp.example",
                    id: self.primaryID,
                    active: false,
                    usedPercent: 20,
                    source: "api-primary"),
                self.payload(
                    label: "IBM Bob Team",
                    id: self.secondaryID,
                    active: true,
                    usedPercent: 65,
                    source: "api-secondary"),
            ],
            costPayloads: [],
            config: self.config(accountCount: 2, activeIndex: 1),
            identityMode: .redacted,
            generatedAt: self.generatedAt,
            refreshInterval: 60,
            codexBarVersion: nil)
        let provider = try self.provider(snapshot)
        let accounts = try #require(provider["accounts"] as? [[String: Any]])

        #expect(provider["id"] as? String == "ibmbob")
        #expect(provider["source"] as? String == "api-secondary")
        #expect((provider["windows"] as? [[String: Any]])?.first?["usedPercent"] as? Double == 65)
        #expect(accounts.count == 2)
        #expect(accounts.compactMap { $0["label"] as? String } == ["redacted@corp.example", "IBM Bob Team"])
        #expect(accounts.compactMap { $0["active"] as? Bool } == [false, true])
        #expect(Set(accounts.compactMap { $0["id"] as? String }).count == 2)
        #expect(accounts.allSatisfy { row in
            guard let id = row["id"] as? String else { return false }
            return id.hasPrefix("account:") && !id.contains("alice") && !id.contains("corp.example")
        })
        #expect(provider["accountsError"] == nil)
    }

    @Test
    func `keeps account fetch failure row local`() throws {
        let failed = ProviderPayload(
            provider: .ibmbob,
            account: "Secondary",
            cacheAccountKey: "token:\(self.secondaryID.uuidString.lowercased())",
            accountIsActive: true,
            version: nil,
            source: "api",
            status: nil,
            usage: nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: ProviderErrorPayload(code: 1, message: "account unavailable", kind: .provider))
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [
                self.payload(label: "Primary", id: self.primaryID, active: false, usedPercent: 20),
                failed,
            ],
            costPayloads: [],
            config: self.config(accountCount: 2, activeIndex: 1),
            identityMode: .full,
            generatedAt: self.generatedAt,
            refreshInterval: 60,
            codexBarVersion: nil)
        let provider = try self.provider(snapshot)
        let accounts = try #require(provider["accounts"] as? [[String: Any]])

        #expect(accounts.count == 2)
        #expect(accounts[1]["error"] as? String == "account unavailable")
        #expect((accounts[1]["windows"] as? [Any])?.isEmpty == true)
        #expect(provider["accountsError"] == nil)
    }

    @Test
    func `reports incomplete configured account collection`() throws {
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [self.payload(
                label: "Primary",
                id: self.primaryID,
                active: true,
                usedPercent: 20)],
            costPayloads: [],
            config: self.config(accountCount: 2, activeIndex: 0),
            identityMode: .full,
            generatedAt: self.generatedAt,
            refreshInterval: 60,
            codexBarVersion: nil)
        let provider = try self.provider(snapshot)

        #expect((provider["accounts"] as? [Any])?.count == 1)
        #expect(provider["accountsError"] as? String == "Failed to collect usage for every configured account.")
    }

    @Test
    func `reports reconciler account collection failure`() throws {
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [
                self.payload(
                    label: "Primary",
                    id: self.primaryID,
                    active: true,
                    usedPercent: 20,
                    accountCollectionError: "Managed account storage is unreadable."),
                self.payload(label: "Secondary", id: self.secondaryID, active: false, usedPercent: 40),
            ],
            costPayloads: [],
            config: self.config(accountCount: 2, activeIndex: 0),
            identityMode: .full,
            generatedAt: self.generatedAt,
            refreshInterval: 60,
            codexBarVersion: nil)
        let provider = try self.provider(snapshot)

        #expect((provider["accounts"] as? [Any])?.count == 2)
        #expect(provider["accountsError"] as? String == "Managed account storage is unreadable.")
    }

    @Test
    func `single account provider keeps additive account keys absent`() throws {
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [self.payload(
                label: "Only",
                id: self.primaryID,
                active: true,
                usedPercent: 20)],
            costPayloads: [],
            config: self.config(accountCount: 1, activeIndex: 0),
            identityMode: .full,
            generatedAt: self.generatedAt,
            refreshInterval: 60,
            codexBarVersion: nil)
        let provider = try self.provider(snapshot)

        #expect(provider["accounts"] == nil)
        #expect(provider["accountsError"] == nil)
    }

    @Test
    func `headless resolver can enumerate every configured generic account`() throws {
        let config = self.config(accountCount: 2, activeIndex: 1)
        let context = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:])

        #expect(try context.resolvedAccounts(for: .ibmbob).map(\.id) == [self.secondaryID])
        #expect(try context.resolvedAccounts(for: .ibmbob, includeAllAccounts: true).map(\.id) == [
            self.primaryID,
            self.secondaryID,
        ])
    }

    private func payload(
        label: String,
        id: UUID,
        active: Bool,
        usedPercent: Double,
        source: String = "api",
        accountCollectionError: String? = nil) -> ProviderPayload
    {
        ProviderPayload(
            provider: .ibmbob,
            account: label,
            cacheAccountKey: "token:\(id.uuidString.lowercased())",
            accountIsActive: active,
            accountCollectionError: accountCollectionError,
            version: nil,
            source: source,
            status: nil,
            usage: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: nil,
                    resetsAt: self.generatedAt.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: self.generatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .ibmbob,
                    accountEmail: label.contains("@") ? label : nil,
                    accountOrganization: nil,
                    loginMethod: nil)),
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
    }

    private func config(accountCount: Int, activeIndex: Int) -> CodexBarConfig {
        let ids = [self.primaryID, self.secondaryID]
        var provider = ProviderConfig(id: .ibmbob, enabled: true)
        provider.tokenAccounts = ProviderTokenAccountData(
            version: 1,
            accounts: (0..<accountCount).map { index in
                ProviderTokenAccount(
                    id: ids[index],
                    label: index == 0 ? "Primary" : "Secondary",
                    token: "test-token-\(index)",
                    addedAt: 0,
                    lastUsed: nil)
            },
            activeIndex: activeIndex)
        return CodexBarConfig(providers: [provider])
    }

    private func provider(_ payload: DashboardSnapshotPayload) throws -> [String: Any] {
        let json = try #require(CodexBarCLI.encodeJSON(payload, pretty: false))
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require((object["providers"] as? [[String: Any]])?.first)
    }
}
