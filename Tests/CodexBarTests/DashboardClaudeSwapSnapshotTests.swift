import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct DashboardClaudeSwapSnapshotTests {
    private let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `projects ordered claude swap accounts with windows pace and redacted identity`() throws {
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.threeAccountList(),
            now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])

        #expect(rows.compactMap { $0["id"] as? String } == [
            "claude-swap:2", "claude-swap:1", "claude-swap:3",
        ])
        #expect(rows.compactMap { $0["label"] as? String } == [
            "redacted@personal.example", "redacted@example.com", "redacted@example.net",
        ])
        #expect(rows.compactMap { $0["active"] as? Bool } == [true, false, false])

        let active = try #require(rows.first)
        let identity = try #require(active["identity"] as? [String: Any])
        let windows = try #require(active["windows"] as? [[String: Any]])
        let pace = try #require(active["pace"] as? [String: Any])
        #expect(identity["accountEmail"] as? String == "redacted@personal.example")
        #expect(identity["plan"] is NSNull)
        #expect(windows.compactMap { $0["kind"] as? String } == [
            "session", "weekly", "claude-weekly-scoped-fable",
        ])
        #expect(windows.compactMap { $0["label"] as? String } == ["Session", "Weekly", "Fable only"])
        #expect(pace["primary"] is [String: Any])
        #expect(pace["secondary"] is [String: Any])
        #expect(active["updatedAt"] as? String == "2027-01-15T08:00:00Z")
    }

    @Test
    func `full identity mode keeps real account emails`() throws {
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(
            from: self.threeAccountList(),
            now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .full,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        let emails = rows.compactMap { ($0["identity"] as? [String: Any])?["accountEmail"] as? String }
        #expect(emails == ["personal@personal.example", "work@example.com", "third@example.net"])
    }

    @Test
    func `shared emails stay distinct and alias replaces the email label`() throws {
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    self.accountRow(
                        number: 1,
                        email: "shared@example.com",
                        organizationName: "Sendbird",
                        alias: "Work",
                        active: true),
                    self.accountRow(
                        number: 2,
                        email: "shared@example.com",
                        organizationName: "Acme",
                        active: false),
                ]),
            now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .full,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        #expect(rows.compactMap { $0["label"] as? String } == ["Work", "shared@example.com · Acme"])
        #expect(rows.compactMap { $0["id"] as? String } == ["claude-swap:1", "claude-swap:2"])

        let redactedProviders = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let redactedClaude = try #require(redactedProviders.first { $0["id"] as? String == "claude" })
        let redactedRows = try #require(redactedClaude["accounts"] as? [[String: Any]])
        #expect(redactedRows.compactMap { $0["label"] as? String } == [
            "Work",
            "redacted@example.com · Acme",
        ])
    }

    @Test
    func `redacted dashboard mode rewrites email shaped aliases`() throws {
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    self.accountRow(
                        number: 1,
                        email: "shared@example.com",
                        organizationName: "Sendbird",
                        alias: "other@example.com",
                        active: true),
                    self.accountRow(
                        number: 2,
                        email: "shared@example.com",
                        organizationName: "Acme",
                        active: false),
                ]),
            now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        #expect(rows.compactMap { $0["label"] as? String } == [
            "redacted@example.com",
            "redacted@example.com · Acme",
        ])
        #expect(rows.compactMap { ($0["identity"] as? [String: Any])?["accountEmail"] as? String } == [
            "redacted@example.com",
            "redacted@example.com",
        ])
    }

    @Test
    func `redacted dashboard mode keeps non email alias text around an address`() throws {
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    self.accountRow(
                        number: 1,
                        email: "shared@example.com",
                        organizationName: "Sendbird",
                        alias: "Work (owner@example.com)",
                        active: true),
                    self.accountRow(
                        number: 2,
                        email: "shared@example.com",
                        organizationName: "Acme",
                        active: false),
                ]),
            now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        #expect(rows.compactMap { $0["label"] as? String } == [
            "Work (redacted@example.com)",
            "redacted@example.com · Acme",
        ])
        #expect(rows.compactMap { ($0["identity"] as? [String: Any])?["accountEmail"] as? String } == [
            "redacted@example.com",
            "redacted@example.com",
        ])
    }

    @Test
    func `redacted dashboard mode keeps alias text around colon prefixed emails`() throws {
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    self.accountRow(
                        number: 1,
                        email: "shared@example.com",
                        organizationName: "Sendbird",
                        alias: "Work:owner@example.com",
                        active: true),
                    self.accountRow(
                        number: 2,
                        email: "shared@example.com",
                        organizationName: "Acme",
                        active: false),
                ]),
            now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        #expect(rows.compactMap { $0["label"] as? String } == [
            "Work:redacted@example.com",
            "redacted@example.com · Acme",
        ])
        #expect(rows.compactMap { ($0["identity"] as? [String: Any])?["accountEmail"] as? String } == [
            "redacted@example.com",
            "redacted@example.com",
        ])
    }

    @Test
    func `redacted dashboard mode rewrites emails inside organization suffixes`() throws {
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    self.accountRow(
                        number: 1,
                        email: "shared@example.com",
                        organizationName: "admin@company.com",
                        active: true),
                    self.accountRow(
                        number: 2,
                        email: "shared@example.com",
                        organizationName: "Acme",
                        active: false),
                ]),
            now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        #expect(rows.compactMap { $0["label"] as? String } == [
            "redacted@example.com · redacted@company.com",
            "redacted@example.com · Acme",
        ])
    }

    @Test
    func `redacted dashboard mode rewrites internal and domain literal addresses`() throws {
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    self.accountRow(
                        number: 1,
                        email: "shared@example.com",
                        organizationName: "Sendbird",
                        alias: "Work (owner@corp)",
                        active: true),
                    self.accountRow(
                        number: 2,
                        email: "shared@example.com",
                        organizationName: "ops@[192.0.2.1]",
                        active: false),
                ]),
            now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        #expect(rows.compactMap { $0["label"] as? String } == [
            "Work (redacted@corp)",
            "redacted@example.com · redacted@[192.0.2.1]",
        ])
    }

    @Test
    func `redacted dashboard mode rewrites apostrophe local parts`() throws {
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    self.accountRow(
                        number: 1,
                        email: "shared@example.com",
                        organizationName: "Sendbird",
                        alias: "Work (o'connor@example.com)",
                        active: true),
                    self.accountRow(
                        number: 2,
                        email: "shared@example.com",
                        organizationName: "Acme",
                        active: false),
                ]),
            now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        #expect(rows.compactMap { $0["label"] as? String } == [
            "Work (redacted@example.com)",
            "redacted@example.com · Acme",
        ])
    }

    @Test
    func `redacted dashboard mode rewrites unicode local parts`() throws {
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    self.accountRow(
                        number: 1,
                        email: "用户@例子.公司",
                        organizationName: "Sendbird",
                        active: true),
                ]),
            now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        #expect(rows.compactMap { $0["label"] as? String } == ["redacted@例子.公司"])
    }

    @Test
    func `redacted dashboard mode rewrites quoted local parts`() throws {
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    self.accountRow(
                        number: 1,
                        email: "shared@example.com",
                        organizationName: "Sendbird",
                        alias: "Contact \"owner\"@example.com",
                        active: true),
                    self.accountRow(
                        number: 2,
                        email: "shared@example.com",
                        organizationName: "Acme",
                        active: false),
                ]),
            now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        #expect(rows.compactMap { $0["label"] as? String } == [
            "Contact redacted@example.com",
            "redacted@example.com · Acme",
        ])
    }

    @Test
    func `redacted dashboard mode rewrites quoted local parts that contain spaces`() throws {
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    self.accountRow(
                        number: 1,
                        email: "shared@example.com",
                        organizationName: "Sendbird",
                        alias: "Contact \"owner smith\"@example.com",
                        active: true),
                    self.accountRow(
                        number: 2,
                        email: "shared@example.com",
                        organizationName: "Acme",
                        active: false),
                ]),
            now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        #expect(rows.compactMap { $0["label"] as? String } == [
            "Contact redacted@example.com",
            "redacted@example.com · Acme",
        ])
    }

    @Test
    func `redacted dashboard mode rewrites slash separated addresses independently`() throws {
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [
                    self.accountRow(
                        number: 1,
                        email: "shared@example.com",
                        organizationName: "Sendbird",
                        alias: "owner@example.com/backup@example.net",
                        active: true),
                    self.accountRow(
                        number: 2,
                        email: "shared@example.com",
                        organizationName: "Acme",
                        active: false),
                ]),
            now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        #expect(rows.compactMap { $0["label"] as? String } == [
            "redacted@example.com/redacted@example.net",
            "redacted@example.com · Acme",
        ])
    }

    @Test
    func `dashboard identity flag decodes redacted full and rejects others`() {
        #expect(CodexBarCLI.decodeDashboardIdentityMode(from: self.parsedValues(identity: nil)) == .full)
        #expect(CodexBarCLI.decodeDashboardIdentityMode(from: self.parsedValues(identity: "redacted")) == .redacted)
        #expect(CodexBarCLI.decodeDashboardIdentityMode(from: self.parsedValues(identity: "full")) == .full)
        #expect(CodexBarCLI.decodeDashboardIdentityMode(from: self.parsedValues(identity: "FULL")) == .full)
        #expect(CodexBarCLI.decodeDashboardIdentityMode(from: self.parsedValues(identity: "none")) == nil)
        #expect(CodexBarCLI.decodeDashboardIdentityMode(from: self.parsedValues(identity: "bogus")) == nil)
    }

    private func parsedValues(identity: String?) -> ParsedValues {
        ParsedValues(
            positional: [],
            options: identity.map { ["identity": [$0]] } ?? [:],
            flags: [])
    }

    @Test
    func `dashboard output flag decodes stdout default file paths and rejects empty`() {
        #expect(CodexBarCLI.decodeDashboardOutputDestination(from: self.parsedValues(output: nil)) == .stdout)
        #expect(CodexBarCLI.decodeDashboardOutputDestination(from: self.parsedValues(output: "/tmp/snapshot.json"))
            == .file("/tmp/snapshot.json"))
        #expect(CodexBarCLI.decodeDashboardOutputDestination(from: self.parsedValues(output: "relative.json"))
            == .file("relative.json"))
        #expect(CodexBarCLI.decodeDashboardOutputDestination(from: self.parsedValues(output: "")) == nil)
    }

    private func parsedValues(output: String?) -> ParsedValues {
        ParsedValues(
            positional: [],
            options: output.map { ["output": [$0]] } ?? [:],
            flags: [])
    }

    @Test
    func `per account failure keeps healthy siblings and ambient row intact`() throws {
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                self.accountRow(number: 1, email: "healthy@example.com", active: true),
                ClaudeSwapAccountRow(
                    number: 2,
                    email: "expired@example.com",
                    isActive: false,
                    usageStatus: .tokenExpired,
                    fiveHour: nil,
                    sevenDay: nil),
            ])
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        let healthy = try #require(rows.first)
        let failed = try #require(rows.last)

        #expect((healthy["windows"] as? [[String: Any]])?.count == 2)
        #expect(healthy["error"] is NSNull)
        #expect(failed["error"] as? String ==
            "Token expired. Switch to this account in claude-swap to refresh it.")
        #expect((failed["windows"] as? [Any])?.isEmpty == true)
        #expect(failed["label"] as? String == "redacted@example.com")
        #expect((failed["identity"] as? [String: Any])?["accountEmail"] as? String == "redacted@example.com")
        #expect(failed["pace"] is NSNull)
        #expect(failed["updatedAt"] is NSNull)
        #expect(claude["error"] is NSNull)
    }

    @Test
    func `failed disambiguated accounts keep the raw email identity`() throws {
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                ClaudeSwapAccountRow(
                    number: 1,
                    email: "shared@example.com",
                    organizationName: "Sendbird",
                    alias: "Work",
                    isActive: true,
                    usageStatus: .tokenExpired,
                    fiveHour: nil,
                    sevenDay: nil),
                ClaudeSwapAccountRow(
                    number: 2,
                    email: "shared@example.com",
                    organizationName: "Acme",
                    isActive: false,
                    usageStatus: .noCredentials,
                    fiveHour: nil,
                    sevenDay: nil),
            ])
        let accounts = ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.generatedAt)
        let providers = try self.providers(
            identityMode: .full,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        let rows = try #require(claude["accounts"] as? [[String: Any]])
        #expect(rows.compactMap { $0["label"] as? String } == ["Work", "shared@example.com · Acme"])
        #expect(rows.compactMap { ($0["identity"] as? [String: Any])?["accountEmail"] as? String } == [
            "shared@example.com",
            "shared@example.com",
        ])
        #expect((rows.last?["windows"] as? [Any])?.isEmpty == true)
        #expect(rows.last?["updatedAt"] is NSNull)
    }

    @Test
    func `adapter failure adds only accounts error and preserves ambient fields`() throws {
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(
                accounts: nil,
                adapterError: "claude-swap timed out.",
                weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })

        #expect(claude["accounts"] == nil)
        #expect(claude["accountsError"] as? String == "claude-swap timed out.")
        #expect((claude["windows"] as? [[String: Any]])?.count == 1)
        #expect((claude["identity"] as? [String: Any])?["accountEmail"] as? String ==
            "redacted@ambient.example")
    }

    @Test
    func `absent swap omits additive keys from every provider row`() throws {
        let providers = try self.providers(identityMode: .redacted, claudeSwap: nil)

        #expect(providers.count == 2)
        for provider in providers {
            #expect(provider["accounts"] == nil)
            #expect(provider["accountsError"] == nil)
        }
    }

    @Test
    func `account identity honors redaction modes and rejects placeholder labels`() throws {
        let realAccount = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [self.accountRow(number: 1, email: "person@example.com", active: true)]),
            now: self.generatedAt)
        let placeholderAccount = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 2,
                accounts: [self.accountRow(number: 2, email: "", active: true)]),
            now: self.generatedAt)

        let none = try self.firstAccount(mode: .none, accounts: realAccount)
        let full = try self.firstAccount(mode: .full, accounts: realAccount)
        let placeholder = try self.firstAccount(mode: .full, accounts: placeholderAccount)

        #expect(none["identity"] is NSNull)
        #expect((full["identity"] as? [String: Any])?["accountEmail"] as? String == "person@example.com")
        #expect(placeholder["identity"] is NSNull)
    }

    @Test
    func `enabled swap with no accounts emits an empty array`() throws {
        let providers = try self.providers(
            identityMode: .redacted,
            claudeSwap: DashboardClaudeSwapInput(accounts: [], adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })

        #expect((claude["accounts"] as? [Any])?.isEmpty == true)
        #expect(claude["accountsError"] == nil)
    }

    @Test
    func `producer collects swap accounts with config while its default omits them`() async throws {
        let recorder = DashboardClaudeSwapConfigRecorder()
        let account = ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: [self.accountRow(number: 1, email: "person@example.com", active: true)]),
            now: self.generatedAt)
        let config = self.enabledSwapConfig()
        let ambient = self.ambientPayload()
        var producer = DashboardSnapshotProducer(
            collectUsage: { _ in
                var output = UsageCommandOutput()
                output.payload = [ambient]
                return output
            },
            collectCost: { _, _ in [] },
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
        producer.collectClaudeSwapAccounts = { config in
            await recorder.record(config)
            return DashboardClaudeSwapCollection(accounts: account, adapterError: nil)
        }

        let result = try await producer.collect(config: config, refreshInterval: 0, codexBarVersion: nil)
        let rows = try self.providerRows(result.payload)
        let claude = try #require(rows.first)
        #expect((claude["accounts"] as? [Any])?.count == 1)
        #expect(await recorder.receivedEnabledSwapConfig())

        let defaultProducer = DashboardSnapshotProducer(
            collectUsage: { _ in
                var output = UsageCommandOutput()
                output.payload = [ambient]
                return output
            },
            collectCost: { _, _ in [] },
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let defaultResult = try await defaultProducer.collect(
            config: config,
            refreshInterval: 0,
            codexBarVersion: nil)
        #expect(try #require(self.providerRows(defaultResult.payload).first)["accounts"] == nil)
    }

    @Test
    func `dashboard swap eligibility requires enabled Claude and integration opt in`() {
        var disabled = ProviderConfig(id: .claude, enabled: false)
        disabled.claudeSwapEnabled = true
        let unset = ProviderConfig(id: .claude, enabled: true)
        var explicitFalse = ProviderConfig(id: .claude, enabled: true)
        explicitFalse.claudeSwapEnabled = false
        var enabled = ProviderConfig(id: .claude, enabled: true)
        enabled.claudeSwapEnabled = true

        #expect(!CodexBarCLI.dashboardClaudeSwapIsEligible(config: CodexBarConfig(providers: [disabled])))
        #expect(!CodexBarCLI.dashboardClaudeSwapIsEligible(config: CodexBarConfig(providers: [unset])))
        #expect(!CodexBarCLI.dashboardClaudeSwapIsEligible(config: CodexBarConfig(providers: [explicitFalse])))
        #expect(CodexBarCLI.dashboardClaudeSwapIsEligible(config: CodexBarConfig(providers: [enabled])))
    }

    private func providers(
        identityMode: DashboardIdentityMode,
        claudeSwap: DashboardClaudeSwapInput?) throws -> [[String: Any]]
    {
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [self.ambientPayload(), self.codexPayload()],
            costPayloads: [],
            config: CodexBarConfig(providers: [
                ProviderConfig(id: .claude, enabled: true),
                ProviderConfig(id: .codex, enabled: true),
            ]),
            identityMode: identityMode,
            generatedAt: self.generatedAt,
            refreshInterval: 60,
            codexBarVersion: nil,
            claudeSwap: claudeSwap)
        return try self.providerRows(snapshot)
    }

    private func firstAccount(
        mode: DashboardIdentityMode,
        accounts: [ProviderAccountUsageSnapshot]) throws -> [String: Any]
    {
        let providers = try self.providers(
            identityMode: mode,
            claudeSwap: DashboardClaudeSwapInput(accounts: accounts, adapterError: nil, weeklyWorkDays: nil))
        let claude = try #require(providers.first { $0["id"] as? String == "claude" })
        return try #require((claude["accounts"] as? [[String: Any]])?.first)
    }

    private func threeAccountList() -> ClaudeSwapAccountList {
        ClaudeSwapAccountList(
            activeAccountNumber: 2,
            accounts: [
                self.accountRow(number: 1, email: "work@example.com", active: false),
                self.accountRow(number: 3, email: "third@example.net", active: false),
                self.accountRow(
                    number: 2,
                    email: "personal@personal.example",
                    active: true,
                    scoped: [ClaudeSwapScopedUsageWindow(
                        name: "Fable",
                        usedPercent: 33,
                        resetsAt: self.generatedAt.addingTimeInterval(2 * 24 * 60 * 60))]),
            ])
    }

    private func accountRow(
        number: Int,
        email: String,
        organizationName: String = "",
        alias: String? = nil,
        active: Bool,
        scoped: [ClaudeSwapScopedUsageWindow] = []) -> ClaudeSwapAccountRow
    {
        ClaudeSwapAccountRow(
            number: number,
            email: email,
            organizationName: organizationName,
            alias: alias,
            isActive: active,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(
                usedPercent: 40,
                resetsAt: self.generatedAt.addingTimeInterval(60 * 60)),
            sevenDay: ClaudeSwapUsageWindow(
                usedPercent: 60,
                resetsAt: self.generatedAt.addingTimeInterval(2 * 24 * 60 * 60)),
            scoped: scoped)
    }

    private func ambientPayload() -> ProviderPayload {
        ProviderPayload(
            provider: .claude,
            account: nil,
            version: nil,
            source: "web",
            status: nil,
            usage: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 300,
                    resetsAt: self.generatedAt.addingTimeInterval(60 * 60),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: self.generatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: "ambient@ambient.example",
                    accountOrganization: nil,
                    loginMethod: "pro")),
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
    }

    private func codexPayload() -> ProviderPayload {
        ProviderPayload(
            provider: .codex,
            account: nil,
            version: nil,
            source: "oauth",
            status: nil,
            usage: nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
    }

    private func enabledSwapConfig() -> CodexBarConfig {
        var claude = ProviderConfig(id: .claude, enabled: true)
        claude.claudeSwapEnabled = true
        return CodexBarConfig(providers: [claude])
    }

    private func providerRows(_ payload: DashboardSnapshotPayload) throws -> [[String: Any]] {
        let json = try #require(CodexBarCLI.encodeJSON(payload, pretty: false))
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["providers"] as? [[String: Any]])
    }
}

private actor DashboardClaudeSwapConfigRecorder {
    private var received = false

    func record(_ config: CodexBarConfig) {
        self.received = config.enabledProviders().compactMap(\.firstPartyProvider).contains(.claude)
            && config.providerConfig(for: .claude)?.claudeSwapEnabled == true
    }

    func receivedEnabledSwapConfig() -> Bool {
        self.received
    }
}
