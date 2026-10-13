import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ProviderConfigModelRateLimitsTests {
    @Test
    func `legacy provider-level limits decode as the provider key's limits`() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let config = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"""
        {"id":"openai","modelRateLimits":[{"model":"gpt-5","tokensPerMinute":100}],
         "tokenAccounts":{"version":1,"activeIndex":0,"accounts":[{
           "id":"00000000-0000-0000-0000-000000000001","label":"Legacy","token":"synthetic","addedAt":0
         }]}}
        """#.utf8))
        #expect(config.modelRateLimits(for: .provider) == [.init(model: "gpt-5", tokensPerMinute: 100)])
        #expect(config.modelRateLimits(for: .tokenAccount(id)).isEmpty)
        #expect(config.tokenAccounts?.accounts.first?.modelRateLimits == nil)
        #expect(config.modelRateLimits(for: .tokenAccount(UUID())).isEmpty)
    }

    @Test
    func `account limits validate at construction and decoding and encode inside the account`() throws {
        let rows: [ProviderModelRateLimit] = [
            .init(model: " ", tokensPerMinute: 1),
            .init(model: "zero", tokensPerMinute: 0),
            .init(model: "negative", tokensPerMinute: -1),
            .init(model: " gpt-5 ", tokensPerMinute: 100, requestsPerMinute: 10),
            .init(model: "gpt-5", tokensPerMinute: 200, requestsPerMinute: 0),
            .init(model: "gpt-4o", tokensPerMinute: 300, requestsPerMinute: -1),
        ]
        let expected: [ProviderModelRateLimit] = [
            .init(model: "gpt-5", tokensPerMinute: 200), .init(model: "gpt-4o", tokensPerMinute: 300),
        ]
        let account = self.account(limits: rows)
        #expect(account.modelRateLimits == expected)
        let config = ProviderConfig(
            id: .openai, tokenAccounts: .init(version: 1, accounts: [account], activeIndex: 0))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)
        #expect(decoded.modelRateLimits(for: .tokenAccount(account.id)) == expected)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["modelRateLimits"] == nil)
        let accounts = try #require(json["tokenAccounts"] as? [String: Any])
        let encoded = try #require((accounts["accounts"] as? [[String: Any]])?.first)
        #expect((encoded["modelRateLimits"] as? [[String: Any]])?.count == 2)
        // Feed unvalidated rows directly to the decoder, bypassing the validating initializer.
        var raw = encoded
        raw["modelRateLimits"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows))
        let fromRaw = try JSONDecoder().decode(
            ProviderTokenAccount.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(fromRaw.modelRateLimits == expected)
        let normalized = CodexBarConfig(providers: [decoded]).normalized()
        #expect(normalized.providerConfig(for: .openai)?.modelRateLimits(for: .tokenAccount(account.id)) == expected)
        #expect(CodexBarConfigValidator.validate(normalized).isEmpty)
        #expect(account.sanitizedForDump().modelRateLimits == expected)
        #expect(account.sanitizedForDump().token == "[REDACTED]")
        let copyJSON = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(account.withModelRateLimits(nil))) as? [String: Any])
        var identityJSON = encoded
        identityJSON.removeValue(forKey: "modelRateLimits")
        #expect(NSDictionary(dictionary: copyJSON) == NSDictionary(dictionary: identityJSON))
        for rows: [ProviderModelRateLimit]? in [nil, [], [.init(model: "bad", tokensPerMinute: 0)]] {
            let empty = account.withModelRateLimits(rows)
            #expect(empty.modelRateLimits == rows.map(ProviderModelRateLimit.validated))
            let encoded = try JSONEncoder().encode(empty)
            let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            if rows == nil {
                #expect(json["modelRateLimits"] == nil)
            } else {
                #expect((json["modelRateLimits"] as? [Any])?.isEmpty == true)
            }
            raw["modelRateLimits"] = try rows.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
            let decoded = try JSONDecoder().decode(
                ProviderTokenAccount.self, from: JSONSerialization.data(withJSONObject: raw))
            #expect(decoded.modelRateLimits == empty.modelRateLimits)
        }
    }

    @Test
    func `setting scoped limits preserves other credentials and fetch identity`() throws {
        let a = self.account(limits: [.init(model: "gpt-5", tokensPerMinute: 200)])
        let b = self.account(limits: [.init(model: "gpt-5", tokensPerMinute: 300)])
        var config = ProviderConfig(
            id: .openai,
            tokenAccounts: .init(version: 7, accounts: [a, b], activeIndex: 1),
            modelRateLimits: [.init(model: "gpt-5", tokensPerMinute: 100)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let identity = try encoder.encode(config.fetchIdentityConfig)
        let updated: [ProviderModelRateLimit] = [.init(model: " gpt-5 ", tokensPerMinute: 400)]
        let expected = ProviderModelRateLimit.validated(updated)
        config.setModelRateLimits(updated, for: .tokenAccount(a.id))
        #expect(config.modelRateLimits(for: .tokenAccount(a.id)) == expected)
        #expect(config.modelRateLimits(for: .tokenAccount(b.id)) == b.modelRateLimits)
        #expect(config.modelRateLimits(for: .provider) == [.init(model: "gpt-5", tokensPerMinute: 100)])
        #expect(config.tokenAccounts?.version == 7)
        #expect(config.tokenAccounts?.activeIndex == 1)
        #expect(try encoder.encode(config.fetchIdentityConfig) == identity)
        config.setModelRateLimits(updated, for: .provider)
        #expect(config.modelRateLimits(for: .provider) == expected)
        #expect(config.modelRateLimits(for: .tokenAccount(a.id)) == expected)
        #expect(config.modelRateLimits(for: .tokenAccount(b.id)) == b.modelRateLimits)
        let beforeMissing = try encoder.encode(config)
        config.setModelRateLimits([], for: .tokenAccount(UUID()))
        #expect(try encoder.encode(config) == beforeMissing)
        config.setModelRateLimits([], for: .tokenAccount(a.id))
        #expect(config.tokenAccounts?.accounts.first?.modelRateLimits == [])
        #expect(config.modelRateLimits(for: .provider) == expected)
        #expect(config.modelRateLimits(for: .tokenAccount(b.id)) == b.modelRateLimits)
        #expect(try encoder.encode(config.fetchIdentityConfig) == identity)
    }

    @Test
    func `sync preserves provider and account limits and older intent keeps local provider limits`() throws {
        let account = self.account(limits: [.init(model: "gpt-5", tokensPerMinute: 200)])
        let config = ProviderConfig(
            id: .openai,
            tokenAccounts: .init(version: 1, accounts: [account], activeIndex: 0),
            modelRateLimits: [.init(model: "gpt-5", tokensPerMinute: 100)])
        let payload = try CanonicalSyncJSON.decode(
            ProviderIntentPayload.self, from: CanonicalSyncJSON.string(ProviderIntentPayload(config: config)))
        let secrets = try ProviderIntentPayload.secretFields(for: config, includeSecrets: true)
        #expect(secrets["tokenAccounts"]?.contains("modelRateLimits") == true)
        #expect(try ProviderIntentPayload.secretFields(for: config, includeSecrets: false).isEmpty)
        let applied = try payload.applying(
            to: ProviderConfig(id: .openai), secretFields: secrets, canEnable: { _, _ in false })
        #expect(applied.modelRateLimits(for: .provider) == config.modelRateLimits)
        #expect(applied.modelRateLimits(for: .tokenAccount(account.id)) == account.modelRateLimits)
        #expect(try CanonicalSyncJSON.string(applied.tokenAccounts) == CanonicalSyncJSON.string(config.tokenAccounts))
        let older = try CanonicalSyncJSON.decode(
            ProviderIntentPayload.self, from: #"{"schemaVersion":1,"provider":"openai"}"#)
        #expect(older.modelRateLimits == nil)
        let retained = try older.applying(to: config, secretFields: [:], canEnable: { _, _ in false })
        #expect(retained.modelRateLimits(for: .provider) == config.modelRateLimits)
        #expect(retained.modelRateLimits(for: .tokenAccount(account.id)) == account.modelRateLimits)
    }

    @Test
    func `older sync peers cannot erase per-account limits`() throws {
        let x = self.account(limits: [.init(model: "gpt-5", tokensPerMinute: 200)])
        let y = self.account(limits: [.init(model: "gpt-4o", tokensPerMinute: 300)])
        let local = ProviderConfig(
            id: .openai, tokenAccounts: .init(version: 7, accounts: [x, y], activeIndex: 0))
        let older = try CanonicalSyncJSON.decode(
            ProviderIntentPayload.self, from: #"{"schemaVersion":1,"provider":"openai"}"#)
        let secrets = ["tokenAccounts": """
        {"version":1,"activeIndex":1,"accounts":[
          {"id":"\(x.id)","label":"Renamed X","token":"synthetic-x","addedAt":0},
          {"id":"\(y.id)","label":"Y","token":"synthetic-y","addedAt":0}
        ]}
        """]
        let applied = try older.applying(to: local, secretFields: secrets, canEnable: { _, _ in false })
        let accounts = try #require(applied.tokenAccounts)
        #expect(accounts.version == 1)
        #expect(accounts.activeIndex == 1)
        #expect(accounts.accounts.map(\.id) == [x.id, y.id])
        #expect(accounts.accounts[0].label == "Renamed X")
        #expect(accounts.accounts[0].token == "synthetic-x")
        #expect(accounts.accounts[0].modelRateLimits == x.modelRateLimits)
        #expect(accounts.accounts[1].modelRateLimits == y.modelRateLimits)

        var clearedLocal = local
        clearedLocal.setModelRateLimits([], for: .tokenAccount(y.id))
        let retainedClear = try older.applying(
            to: clearedLocal, secretFields: secrets, canEnable: { _, _ in false })
        #expect(retainedClear.tokenAccounts?.accounts[1].modelRateLimits == [])
    }

    @Test
    func `explicitly cleared account limits sync as an empty list`() throws {
        let x = self.account(limits: [.init(model: "gpt-5", tokensPerMinute: 200)])
        let y = self.account(limits: [.init(model: "gpt-4o", tokensPerMinute: 300)])
        let local = ProviderConfig(
            id: .openai, tokenAccounts: .init(version: 1, accounts: [x, y], activeIndex: 1))
        let intent = ProviderIntentPayload(config: local)
        let secrets = ["tokenAccounts": """
        {"version":1,"activeIndex":0,"accounts":[
          {"id":"\(x.id)","label":"X","token":"synthetic-x","addedAt":0,"modelRateLimits":[]}
        ]}
        """]
        let cleared = try intent.applying(to: local, secretFields: secrets, canEnable: { _, _ in false })
        let accounts = try #require(cleared.tokenAccounts)
        #expect(accounts.accounts.map(\.id) == [x.id])
        #expect(accounts.activeIndex == 0)
        #expect(accounts.accounts[0].modelRateLimits == [])
        #expect(cleared.modelRateLimits(for: .tokenAccount(y.id)).isEmpty)
        let uploaded = try ProviderIntentPayload.secretFields(for: cleared, includeSecrets: true)
        let uploadedAccounts = try CanonicalSyncJSON.decode(
            ProviderTokenAccountData.self, from: #require(uploaded["tokenAccounts"]))
        #expect(uploadedAccounts.accounts[0].modelRateLimits == [])

        let replacement = ["tokenAccounts": """
        {"version":1,"activeIndex":0,"accounts":[
          {"id":"\(x.id)","label":"X","token":"synthetic-x","addedAt":0,
           "modelRateLimits":[{"model":"gpt-5","tokensPerMinute":400}]}
        ]}
        """]
        let replaced = try intent.applying(to: local, secretFields: replacement, canEnable: { _, _ in false })
        #expect(replaced.tokenAccounts?.accounts.map(\.id) == [x.id])
        #expect(replaced.tokenAccounts?.accounts[0].modelRateLimits == [.init(model: "gpt-5", tokensPerMinute: 400)])
    }

    private func account(limits: [ProviderModelRateLimit]) -> ProviderTokenAccount {
        ProviderTokenAccount(
            id: UUID(),
            label: "Synthetic",
            token: "synthetic",
            addedAt: 1,
            lastUsed: 2,
            externalIdentifier: "synthetic-id",
            usageScope: "synthetic-scope",
            organizationID: "synthetic-org",
            workspaceID: "synthetic-workspace",
            seatCreditEntitlement: "100",
            modelRateLimits: limits)
    }

    @Test
    func `model rate limits round trip and empty values are omitted`() throws {
        let config = ProviderConfig(id: .openai, modelRateLimits: [
            .init(model: "gpt-5", tokensPerMinute: 40_000_000, requestsPerMinute: 15000),
            .init(model: "gpt-4o", tokensPerMinute: 100),
        ])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)
        #expect(decoded.modelRateLimits == config.modelRateLimits)
        #expect(decoded.id == config.id)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(json["modelRateLimits"] as? [[String: Any]])
        #expect(rows.first?["model"] as? String == "gpt-5")
        #expect(rows.first?["tokensPerMinute"] as? Int == 40_000_000)
        for value: [ProviderModelRateLimit]? in [nil, []] {
            let empty = try JSONEncoder().encode(ProviderConfig(id: .openai, modelRateLimits: value))
            #expect(try #require(String(data: empty, encoding: .utf8)).contains("modelRateLimits") == false)
        }
        let old = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"{"id":"openai"}"#.utf8))
        #expect(old.modelRateLimits == nil)
        #expect(try JSONEncoder().encode(old) == JSONEncoder().encode(ProviderConfig(id: .openai)))
    }

    @Test
    func `loading trims drops invalid counts and uses the last duplicate`() throws {
        let config = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"""
        {"id":"openai","modelRateLimits":[
          {"model":" ","tokensPerMinute":10},
          {"model":"zero","tokensPerMinute":0},
          {"model":"negative","tokensPerMinute":-1},
          {"model":" gpt-5 ","tokensPerMinute":100,"requestsPerMinute":5},
          {"model":"gpt-5","tokensPerMinute":200,"requestsPerMinute":0},
          {"model":"gpt-4o","tokensPerMinute":100,"requestsPerMinute":-1}
        ]}
        """#.utf8))
        #expect(config.modelRateLimits == [
            .init(model: "gpt-5", tokensPerMinute: 200), .init(model: "gpt-4o", tokensPerMinute: 100),
        ])
    }

    @Test
    func `limits sync as nonsecret intent and do not change fetch identity`() throws {
        let initial = ProviderConfig(id: .openai)
        var edited = initial
        edited.modelRateLimits = [.init(model: "gpt-5", tokensPerMinute: 100)]
        #expect(try JSONEncoder().encode(edited.fetchIdentityConfig) ==
            JSONEncoder().encode(initial.fetchIdentityConfig))
        let payload = ProviderIntentPayload(config: edited)
        let decoded = try JSONDecoder().decode(ProviderIntentPayload.self, from: JSONEncoder().encode(payload))
        let applied = try decoded.applying(to: initial, secretFields: [:], canEnable: { _, _ in false })
        #expect(applied.modelRateLimits == edited.modelRateLimits)
        let cleared = try ProviderIntentPayload(config: initial).applying(
            to: edited, secretFields: [:], canEnable: { _, _ in false })
        #expect(cleared.modelRateLimits == [])
    }

    @Test(arguments: ["40000000", "40,000,000", "40M", "40m", " 40M "])
    func `plain grouped and suffix counts parse`(text: String) {
        #expect(ProviderRateLimitNumber.parse(text) == 40_000_000)
    }

    @Test
    func `decimal suffixes round trip exactly without floating point loss`() {
        #expect(ProviderRateLimitNumber.parse("150k") == 150_000)
        #expect(ProviderRateLimitNumber.parse("1.5M") == 1_500_000)
        #expect(ProviderRateLimitNumber.parse("1.001k") == 1001)
        #expect(ProviderRateLimitNumber.parse(String(Int.max)) == Int.max)
        for value in [1, 1001, 150_000, 1_500_000, 40_000_000, Int.max] {
            #expect(ProviderRateLimitNumber.parse(ProviderRateLimitNumber.format(value)) == value)
        }
        #expect(ProviderRateLimitNumber.format(40_000_000) == "40M")
        #expect(ProviderRateLimitNumber.format(150_000) == "150K")
    }

    @Test(arguments: [
        "",
        "0",
        "-1",
        "+1",
        "1.5",
        "1,50",
        "1,,000",
        "1e3",
        "1.0001k",
        "NaN",
        "∞",
        "4B",
        "9223372036854775808",
        "9999999999999999999999999999999999999999999999999M"
    ])
    func `invalid and overflowing counts are rejected`(text: String) {
        #expect(ProviderRateLimitNumber.parse(text) == nil)
    }
}
