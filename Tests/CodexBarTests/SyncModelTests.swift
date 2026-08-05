import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SyncModelTests {
    @Test
    func `provider intent round trip strips machine local fields and separates secrets`() throws {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Work",
            token: "account-secret",
            addedAt: 1,
            lastUsed: nil)
        var local = ProviderConfig(
            id: .codex,
            enabled: true,
            source: .cli,
            extrasEnabled: true,
            apiKey: "api-secret",
            secretKey: "secondary-secret",
            cookieHeader: "session=secret",
            cookieSource: .manual,
            region: "us",
            workspaceID: "workspace",
            tokenAccounts: .init(version: 1, accounts: [account], activeIndex: 0))
        local.claudeSwapExecutablePath = "/machine/bin/cswap"
        local.codexActiveSource = .managedAccount(id: UUID())
        local.codexProfileHomePaths = ["/machine/codex"]
        local.awsProfile = "machine-profile"
        local.awsAuthMode = "machine-auth"

        let payload = ProviderIntentPayload(config: local)
        let encoded = try CanonicalSyncJSON.string(payload)
        let decoded = try CanonicalSyncJSON.decode(ProviderIntentPayload.self, from: encoded)
        let secrets = try ProviderIntentPayload.secretFields(for: local, includeSecrets: true)

        #expect(!encoded.contains("api-secret"))
        #expect(!encoded.contains("machine/bin"))
        #expect(!encoded.contains("machine-profile"))
        #expect(!encoded.contains("source"))
        #expect(secrets["apiKey"] == "api-secret")
        #expect(secrets["cookieHeader"] == "session=secret")
        #expect(secrets["tokenAccounts"]?.contains("account-secret") == true)

        var baseline = ProviderConfig(
            id: .codex,
            enabled: false,
            source: .web,
            apiKey: "local-api",
            cookieSource: .off)
        baseline.claudeSwapExecutablePath = "/local/cswap"
        baseline.codexActiveSource = .liveSystem
        baseline.codexProfileHomePaths = ["/local/home"]
        baseline.awsProfile = "local-profile"
        baseline.awsAuthMode = "local-auth"
        let applied = try decoded.applying(to: baseline, secretFields: secrets) { _, _ in true }

        #expect(applied.enabled == true)
        #expect(applied.extrasEnabled == true)
        #expect(applied.region == "us")
        #expect(applied.source == .web)
        #expect(applied.cookieSource == .off)
        #expect(applied.claudeSwapExecutablePath == "/local/cswap")
        #expect(applied.codexActiveSource == .liveSystem)
        #expect(applied.codexProfileHomePaths == ["/local/home"])
        #expect(applied.awsProfile == "local-profile")
        #expect(applied.awsAuthMode == "local-auth")
        #expect(applied.apiKey == "api-secret")
        #expect(applied.tokenAccounts?.accounts.first?.token == "account-secret")
    }

    @Test
    func `malicious intent hooks never alter local hooks`() throws {
        let malicious = """
        {
          "schemaVersion": 1,
          "provider": "codex",
          "enabled": false,
          "hooks": {"enabled": true, "events": [{"executable": "/tmp/evil"}]}
        }
        """
        let payload = try CanonicalSyncJSON.decode(ProviderIntentPayload.self, from: malicious)
        let hooks = HooksConfig(enabled: true, events: [HookRule(
            id: "safe",
            event: .quotaLow,
            executable: "/usr/bin/true")])
        var config = CodexBarConfig(providers: [ProviderConfig(id: .codex, enabled: true)], hooks: hooks)
        let local = try #require(config.providerConfig(for: .codex))
        try config.setProviderConfig(payload.applying(to: local, secretFields: [:]) { _, _ in true })

        #expect(config.hooks == hooks)
        #expect(config.providerConfig(for: .codex)?.enabled == false)
    }

    @Test
    func `enabled intent is gated but disabling always applies`() throws {
        let local = ProviderConfig(id: .claude, enabled: false, source: .cli)
        let enable = ProviderIntentPayload(config: ProviderConfig(id: .claude, enabled: true))
        let blocked = try enable.applying(to: local, secretFields: [:]) { _, _ in false }
        #expect(blocked.enabled == false)

        let disable = ProviderIntentPayload(config: ProviderConfig(id: .claude, enabled: false))
        let disabled = try disable.applying(
            to: ProviderConfig(id: .claude, enabled: true, source: .cli),
            secretFields: [:]) { _, _ in false }
        #expect(disabled.enabled == false)
    }

    @Test
    func `gated remote enable intent survives the next upload`() throws {
        let local = ProviderConfig(id: .claude, enabled: false, source: .cli)
        let remote = ProviderIntentPayload(config: ProviderConfig(id: .claude, enabled: true))
        let gated = try remote.applying(to: local, secretFields: [:]) { _, _ in false }
        let nextUpload = CloudSyncEngine.providerIntentPayload(
            config: gated,
            suppressedEnableIntents: [UsageProvider.claude.rawValue])

        #expect(gated.enabled == false)
        #expect(nextUpload.enabled == true)
    }

    @Test
    func `absent secrets preserve local values and empty markers delete them`() throws {
        let payload = ProviderIntentPayload(config: ProviderConfig(id: .openai))
        let local = ProviderConfig(id: .openai, apiKey: "keep", secretKey: "remove")
        let preserved = try payload.applying(to: local, secretFields: [:]) { _, _ in true }
        #expect(preserved.apiKey == "keep")
        #expect(preserved.secretKey == "remove")

        let deleted = try payload.applying(to: local, secretFields: ["secretKey": ""]) { _, _ in true }
        #expect(deleted.apiKey == "keep")
        #expect(deleted.secretKey == nil)
    }

    @Test
    func `conflict resolver picks higher edit count then later modified date`() {
        let older = SyncConflictValue(value: "older", editCount: 3, modifiedAt: Date(timeIntervalSince1970: 20))
        let higher = SyncConflictValue(value: "higher", editCount: 4, modifiedAt: Date(timeIntervalSince1970: 10))
        #expect(SyncConflictResolver.winner(local: older, server: higher).value == "higher")

        let later = SyncConflictValue(value: "later", editCount: 3, modifiedAt: Date(timeIntervalSince1970: 30))
        #expect(SyncConflictResolver.winner(local: older, server: later).value == "later")
    }

    @Test
    func `newer schema version requires an app update`() {
        #expect(CodexBarSyncSchema.canApply(1))
        #expect(!CodexBarSyncSchema.canApply(2))
    }

    @Test
    func `account snapshot canonical round trip keeps stable identity`() throws {
        let usage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 42,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 200),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 100))
        let payload = AccountSnapshotSyncPayload(
            provider: .claude,
            deviceID: "device-id",
            accountIdentity: "Person@Example.COM",
            displayLabel: "Person",
            usage: usage)
        let decoded = try CanonicalSyncJSON.decode(
            AccountSnapshotSyncPayload.self,
            from: CanonicalSyncJSON.encode(payload))

        #expect(decoded.accountKey == AccountSnapshotSyncPayload.accountKey(for: "person@example.com"))
        #expect(decoded.recordName == payload.recordName)
        #expect(decoded.recordName.hasSuffix("-device-id"))
        #expect(decoded.usage.primary?.usedPercent == 42)
        #expect(decoded.fetchedAt == usage.updatedAt)
    }

    @Test
    func `account snapshot ignores retired provider payload keys`() throws {
        let legacy = #"""
        {
          "schemaVersion": 1,
          "provider": "openrouter",
          "deviceID": "device-id",
          "accountKey": "default",
          "fetchedAt": "2026-08-04T12:00:00Z",
          "displayLabel": "OpenRouter",
          "usage": {
            "primary": null,
            "secondary": null,
            "tertiary": null,
            "mimoUsage": {"legacy": true},
            "openRouterUsage": {"balance": 42},
            "sakanaPayAsYouGo": {"creditBalance": 12},
            "clawRouterUsage": {"requestCount": 3},
            "sub2APIUsage": {"kind": "wallet"},
            "wayfinderUsage": {"gatewayStatus": "ok"},
            "cursorRequests": {"used": 3, "limit": 10},
            "zaiUsage": {"legacy": true},
            "zoommateCreditsHistory": {"records": []},
            "minimaxUsage": {"planName": "legacy"},
            "groqConsoleUsage": {"daily": []},
            "deepgramUsage": {"requests": 3},
            "poeUsage": {"daily": []},
            "xaiUsage": {"balanceUSD": 4},
            "kiroUsage": {"creditsRemaining": 4},
            "ampUsage": {"individualCredits": 4},
            "deepseekUsage": {"todayTokens": 4},
            "claudeAdminAPIUsage": {"daily": []},
            "updatedAt": "2026-08-04T12:00:00Z"
          }
        }
        """#

        let decoded = try CanonicalSyncJSON.decode(AccountSnapshotSyncPayload.self, from: legacy)

        #expect(decoded.provider == .openrouter)
        #expect(decoded.usage.details.isEmpty)
        #expect(decoded.usage.updatedAt == decoded.fetchedAt)
    }
}

import CloudKit

struct CloudSyncRecordRebaseTests {
    @Test
    func `copying user fields keeps encrypted fields on the encrypted API surface`() {
        // Regression: allKeys() includes encrypted field names; assigning them through the
        // plain subscript makes CloudKit throw NSInvalidArgumentException and crashed the
        // app while applying fetched records (receiver crash-loop, 2026-08-03).
        let source = CKRecord(recordType: "ProviderIntent", recordID: .init(recordName: "intent-test"))
        source["payload"] = "{}" as CKRecordValue
        source["editCount"] = 3 as CKRecordValue
        source.encryptedValues["apiKey"] = "sk-secret" as CKRecordValue
        source.encryptedValues["cookieHeader"] = "cookie=1" as CKRecordValue

        let server = CKRecord(recordType: "ProviderIntent", recordID: .init(recordName: "intent-test"))
        server["payload"] = "{\"old\":true}" as CKRecordValue
        server["schemaVersion"] = 1 as CKRecordValue
        server.encryptedValues["apiKey"] = "sk-older" as CKRecordValue

        let rebased = CloudSyncEngine.copyUserFields(from: source, onto: server)

        #expect(rebased["payload"] as? String == "{}")
        #expect((rebased["editCount"] as? NSNumber)?.intValue == 3)
        #expect(rebased["schemaVersion"] == nil)
        #expect(rebased.encryptedValues["apiKey"] as? String == "sk-secret")
        #expect(rebased.encryptedValues["cookieHeader"] as? String == "cookie=1")
    }
}
