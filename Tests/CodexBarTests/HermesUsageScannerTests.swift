import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Testing
@testable import CodexBarCore

#if canImport(SQLite3) || canImport(CSQLite3)
struct HermesUsageScannerTests {
    @Test
    func `provider mapping covers the shared Hermes and CodexBar routes`() {
        let expected: [String: UsageProvider] = [
            "alibaba": .qwencloud,
            "alibaba-coding-plan": .alibaba,
            "anthropic": .claude,
            "bedrock": .bedrock,
            "copilot": .copilot,
            "copilot-acp": .copilot,
            "deepinfra": .deepinfra,
            "deepseek": .deepseek,
            "fireworks": .fireworks,
            "gemini": .gemini,
            "kilocode": .kilo,
            "kimi-coding": .kimi,
            "kimi-coding-cn": .moonshot,
            "minimax": .minimax,
            "minimax-cn": .minimax,
            "minimax-oauth": .minimax,
            "ollama-cloud": .ollama,
            "openai-api": .openai,
            "openai-codex": .codex,
            "opencode-go": .opencodego,
            "opencode-zen": .opencode,
            "openrouter": .openrouter,
            "qwen-oauth": .qwencloud,
            "stepfun": .stepfun,
            "vertex": .vertexai,
            "xai": .xai,
            "xai-oauth": .grok,
            "xiaomi": .mimo,
            "zai": .zai,
        ]

        #expect(HermesUsageProviderMapping.supportedBillingProviders == expected.keys.sorted())
        for (billingProvider, provider) in expected {
            #expect(HermesUsageProviderMapping.route(for: billingProvider)?.provider == provider)
        }
        #expect(HermesUsageProviderMapping.route(for: "  OPENAI-CODEX  ")?.provider == .codex)

        for ambiguous in ["", "auto", "custom", "moa", "azure-foundry", "unknown-provider"] {
            #expect(HermesUsageProviderMapping.route(for: ambiguous) == nil)
        }

        #expect(HermesUsageProviderMapping.route(for: "alibaba-coding-plan")?.modelsDevProviderID == "alibaba")
        #expect(HermesUsageProviderMapping.route(for: "alibaba")?.provider == .qwencloud)
        #expect(HermesUsageProviderMapping.route(for: "alibaba-coding-plan")?.provider == .alibaba)
        #expect(HermesUsageProviderMapping.route(for: "kimi-coding")?.modelsDevProviderID == "moonshotai")
        #expect(HermesUsageProviderMapping.route(for: "kimi-coding-cn")?.modelsDevProviderID == "moonshotai-cn")
        #expect(HermesUsageProviderMapping.route(for: "minimax-oauth")?.modelsDevProviderID == "minimax")
    }

    @Test
    func `resolved base URL distinguishes Kimi Moonshot MiniMax and StepFun regions`() {
        #expect(HermesUsageProviderMapping.route(
            for: "kimi-coding",
            billingBaseURL: "https://api.kimi.com/coding")?.provider == .kimi)
        #expect(HermesUsageProviderMapping.route(
            for: "kimi-coding",
            billingBaseURL: "https://api.moonshot.ai/v1") == .init(
            provider: .moonshot,
            modelsDevProviderID: "moonshotai"))
        #expect(HermesUsageProviderMapping.route(
            for: "kimi-coding-cn",
            billingBaseURL: "https://api.moonshot.cn/v1") == .init(
            provider: .moonshot,
            modelsDevProviderID: "moonshotai-cn"))
        #expect(HermesUsageProviderMapping.route(
            for: "minimax-oauth",
            billingBaseURL: "https://api.minimax.io/anthropic")?.modelsDevProviderID == "minimax")
        #expect(HermesUsageProviderMapping.route(
            for: "minimax-oauth",
            billingBaseURL: "https://api.minimaxi.com/anthropic")?.modelsDevProviderID == "minimax-cn")
        #expect(HermesUsageProviderMapping.route(
            for: "stepfun",
            billingBaseURL: "https://api.stepfun.ai/step_plan/v1")?.modelsDevProviderID == "stepfun-ai")
        #expect(HermesUsageProviderMapping.route(
            for: "stepfun",
            billingBaseURL: "https://api.stepfun.com/step_plan/v1")?.modelsDevProviderID == "stepfun")
    }

    @Test
    func `mapping audit classifies every canonical Hermes provider`() {
        // hermes_cli.models.CANONICAL_PROVIDERS, audited 2026-08-12. Virtual routers,
        // custom endpoints, and providers without a first-party CodexBar equivalent stay unmapped.
        let auditedCanonicalProviders: Set = [
            "actual", "ai-gateway", "alibaba", "alibaba-coding-plan", "anthropic", "arcee",
            "azure-foundry", "bedrock", "copilot", "copilot-acp", "custom", "deepinfra", "deepseek",
            "fireworks", "gemini", "gmi", "huggingface", "kilocode", "kimi-coding", "kimi-coding-cn",
            "lmstudio", "minimax", "minimax-cn", "minimax-oauth", "moa", "nous", "novita", "nvidia",
            "ollama-cloud", "openai-api", "openai-codex", "opencode-go", "opencode-zen", "openrouter",
            "qwen-oauth", "stepfun", "tencent-tokenhub", "upstage", "vertex", "xai", "xai-oauth",
            "xiaomi", "zai",
        ]
        let intentionallyUnmapped: Set = [
            "actual", "ai-gateway", "arcee", "azure-foundry", "custom", "gmi", "huggingface", "lmstudio",
            "moa", "nous", "novita", "nvidia", "tencent-tokenhub", "upstage",
        ]
        let mapped = Set(HermesUsageProviderMapping.supportedBillingProviders)

        #expect(mapped.isDisjoint(with: intentionallyUnmapped))
        #expect(mapped.union(intentionallyUnmapped) == auditedCanonicalProviders)
    }

    @Test
    func `scanner reads active WAL and keeps token and cost semantics separate`() throws {
        let fixture = try HermesUsageFixture()
        defer { fixture.remove() }
        try fixture.seedCurrentSchema()
        try Self.seedPricing(cacheRoot: fixture.cacheRoot)

        #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-wal"))
        let before = try fixture.databaseShape()
        let report = try HermesUsageScanner(modelsDevCacheRoot: fixture.cacheRoot).scan(
            databaseURLs: [fixture.databaseURL],
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let after = try fixture.databaseShape()

        #expect(before == after)
        #expect(report.sources.count == 1)
        #expect(report.sources[0].status == .read)
        #expect(report.summary.tokens.total == 265)
        #expect(report.summary.requests == 8)
        #expect(report.summary.tokens.reasoning == 16)
        #expect(report.summary.hermesEstimatedCostUSD == 1.5)
        #expect(report.summary.actualCostUSD == 1.2)
        #expect(report.summary.subscriptionIncludedTokens == 160)
        #expect(report.summary.subscriptionIncludedRequests == 3)
        #expect(report.summary.apiEquivalentPricedTokens == 222)
        #expect(report.summary.apiEquivalentUnpricedTokens == 43)
        #expect(report.summary.apiEquivalentCostUSD != nil)

        let codex = try #require(report.providers.first { $0.provider == .codex })
        #expect(codex.summary.tokens == HermesUsageTokenCounts(
            input: 103,
            output: 22,
            cacheRead: 30,
            cacheWrite: 5,
            reasoning: 10))
        #expect(codex.summary.subscriptionIncludedTokens == 160)
        #expect(codex.summary.actualCostUSD == nil)
        #expect(codex.summary.hermesEstimatedCostUSD == nil)
        #expect(abs((codex.summary.apiEquivalentCostUSD ?? 0) - 0.00016075) < 0.000000001)
        #expect(codex.models.map(\.name) == ["gpt-5.4"])
        #expect(codex.models[0].summary.tokens.total == 160)
        #expect(codex.tasks.map(\.name) == ["agent", "title_generation"])
        #expect(codex.tasks.map(\.summary.tokens.total) == [155, 5])

        let claude = try #require(report.providers.first { $0.provider == .claude })
        #expect(claude.summary.tokens.total == 62)
        #expect(claude.summary.hermesEstimatedCostUSD == 1.25)
        #expect(claude.summary.actualCostUSD == 1.0)
        #expect(abs((claude.summary.apiEquivalentCostUSD ?? 0) - 0.0002874) < 0.000000001)

        let deepSeek = try #require(report.providers.first { $0.provider == .deepseek })
        #expect(deepSeek.summary.tokens.total == 10)
        #expect(deepSeek.summary.hermesEstimatedCostUSD == 0.25)
        #expect(deepSeek.summary.actualCostUSD == 0.2)
        #expect(deepSeek.summary.apiEquivalentCostUSD == nil)
        #expect(deepSeek.summary.apiEquivalentUnpricedTokens == 10)

        #expect(report.unmapped.map(\.billingProvider) == ["auto", "custom"])
        #expect(report.unmapped.map(\.summary.tokens.total) == [24, 9])
        let automatic = try #require(report.unmapped.first { $0.billingProvider == "auto" })
        #expect(automatic.tasks.map(\.name) == ["agent", "compression"])
        #expect(automatic.tasks.map(\.summary.tokens.total) == [12, 12])
        #expect(report.unmapped.first { $0.billingProvider == "custom" }?.summary.hermesEstimatedCostUSD == nil)
        #expect(report.warnings.contains { $0.contains("not exact daily history") })
    }

    @Test
    func `legacy session aggregate is used only as a positive residual`() throws {
        let fixture = try HermesUsageFixture()
        defer { fixture.remove() }
        try fixture.seedLegacySchemaWithoutTask()

        let report = try HermesUsageScanner().scan(databaseURLs: [fixture.databaseURL])
        let codex = try #require(report.providers.first { $0.provider == .codex })

        #expect(codex.summary.tokens.total == 20)
        #expect(codex.summary.requests == 2)
        #expect(codex.tasks.map(\.name) == ["agent"])
        #expect(report.summary.tokens.total == 20)
    }

    @Test
    func `idle WAL database is read without recreating sidecars`() throws {
        let fixture = try HermesUsageFixture()
        try fixture.seedLegacySchemaWithoutTask()
        fixture.closeAndRemoveSidecars()
        defer { fixture.remove() }

        #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-shm"))

        let report = try HermesUsageScanner().scan(databaseURLs: [fixture.databaseURL])

        #expect(report.sources.first?.status == .read)
        #expect(report.summary.tokens.total == 20)
        #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-shm"))
    }

    @Test
    func `all zero plan pricing stays unpriced instead of becoming zero API equivalent`() throws {
        let fixture = try HermesUsageFixture()
        defer { fixture.remove() }
        try fixture.seedCurrentSchema()
        try Self.seedZeroPricing(cacheRoot: fixture.cacheRoot)

        let report = try HermesUsageScanner(modelsDevCacheRoot: fixture.cacheRoot).scan(
            databaseURLs: [fixture.databaseURL],
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let codex = try #require(report.providers.first { $0.provider == .codex })

        #expect(codex.summary.apiEquivalentCostUSD == nil)
        #expect(codex.summary.apiEquivalentPricedTokens == 0)
        #expect(codex.summary.apiEquivalentUnpricedTokens == 160)
    }

    @Test
    func `missing database is reported without being created`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesUsageScannerMissing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("state.db")

        let report = try HermesUsageScanner().scan(databaseURLs: [missing])

        #expect(report.sources.count == 1)
        #expect(report.sources[0].status == .missing)
        #expect(report.providers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test
    func `discovery finds default and named profiles but ignores snapshots`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesUsageDiscovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".hermes", isDirectory: true)
        let work = root.appendingPathComponent("profiles/work", isDirectory: true)
        let sport = root.appendingPathComponent("profiles/sport", isDirectory: true)
        let snapshot = work.appendingPathComponent("state-snapshots/old", isDirectory: true)
        for directory in [root, work, sport, snapshot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: directory.appendingPathComponent("state.db").path, contents: Data())
        }

        let discovered = HermesUsageDatabaseDiscovery.discover(
            environment: ["HERMES_HOME": work.path],
            homeDirectory: home)

        #expect(discovered.map(\.label) == ["default", "sport", "work"])
        #expect(!discovered.contains { $0.databaseURL.path.contains("state-snapshots") })
    }

    private static func seedPricing(cacheRoot: URL) throws {
        let catalog = ModelsDevCatalog(providers: [
            "openai": ModelsDevProvider(
                id: "openai",
                name: "OpenAI",
                models: [
                    "gpt-5.4": ModelsDevModel(
                        id: "gpt-5.4",
                        name: "GPT-5.4",
                        cost: ModelsDevCost(
                            input: 1,
                            output: 2,
                            cacheRead: 0.25,
                            cacheWrite: 1.25,
                            contextOver200K: nil),
                        limit: ModelsDevLimit(context: nil)),
                ]),
            "anthropic": ModelsDevProvider(
                id: "anthropic",
                name: "Anthropic",
                models: [
                    "claude-sonnet-4-6": ModelsDevModel(
                        id: "claude-sonnet-4-6",
                        name: "Claude Sonnet 4.6",
                        cost: ModelsDevCost(
                            input: 3,
                            output: 15,
                            cacheRead: 0.3,
                            cacheWrite: 3.75,
                            contextOver200K: nil),
                        limit: ModelsDevLimit(context: nil)),
                ]),
        ])
        #expect(ModelsDevCache.save(
            catalog: catalog,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            cacheRoot: cacheRoot))
    }

    private static func seedZeroPricing(cacheRoot: URL) throws {
        let catalog = ModelsDevCatalog(providers: [
            "openai": ModelsDevProvider(
                id: "openai",
                name: "OpenAI plan",
                models: [
                    "gpt-5.4": ModelsDevModel(
                        id: "gpt-5.4",
                        name: "GPT-5.4",
                        cost: ModelsDevCost(
                            input: 0,
                            output: 0,
                            cacheRead: 0,
                            cacheWrite: 0,
                            contextOver200K: nil),
                        limit: ModelsDevLimit(context: nil)),
                ]),
        ])
        #expect(ModelsDevCache.save(
            catalog: catalog,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            cacheRoot: cacheRoot))
    }
}

private final class HermesUsageFixture {
    enum FixtureError: Error {
        case open(Int32)
        case exec(Int32, String)
    }

    let root: URL
    let databaseURL: URL
    let cacheRoot: URL
    private var database: OpaquePointer?

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesUsageScannerTests-\(UUID().uuidString)", isDirectory: true)
        self.databaseURL = self.root.appendingPathComponent("state.db")
        self.cacheRoot = self.root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        let result = sqlite3_open_v2(
            self.databaseURL.path,
            &self.database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil)
        guard result == SQLITE_OK else { throw FixtureError.open(result) }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    func remove() {
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
        try? FileManager.default.removeItem(at: self.root)
    }

    func closeAndRemoveSidecars() {
        if let database {
            sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            sqlite3_close_v2(database)
            self.database = nil
        }
        try? FileManager.default.removeItem(atPath: self.databaseURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: self.databaseURL.path + "-shm")
    }

    func seedCurrentSchema() throws {
        try self.exec("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;")
        try self.exec(Self.sessionsSchema)
        try self.exec(Self.modelUsageSchemaWithTask)
        try self.exec("""
        INSERT INTO sessions VALUES
          ('s1','gpt-5.4','openai-codex','https://api.openai.com','subscription_included',2,100,20,30,5,10,0,0,'included','none'),
          ('s2','claude-sonnet-4-6','anthropic','https://api.anthropic.com','official_docs_snapshot',1,40,10,8,4,6,1.25,1.0,'estimated','provider'),
          ('s3','deepseek-v4-pro','deepseek','https://api.deepseek.com','official_models_api',1,7,3,0,0,0,0.25,0.2,'estimated','provider'),
          ('s4','gpt-5.4','auto','', '',1,9,3,0,0,0,0,0,NULL,NULL),
          ('s5','gemma4:12b-mlx','custom','http://localhost:1234','',1,8,1,0,0,0,9.5,0,'unknown','none');
        """)
        try self.exec("""
        INSERT INTO session_model_usage VALUES
          ('s1','gpt-5.4','openai-codex','https://api.openai.com','subscription_included','',2,100,20,30,5,10,0,0,'included','none',1,2),
          ('s1','gpt-5.4','openai-codex','https://api.openai.com','subscription_included','title_generation',1,3,2,0,0,0,0,0,'included','none',1,2),
          ('s2','claude-sonnet-4-6','anthropic','https://api.anthropic.com','official_docs_snapshot','',1,40,10,8,4,6,1.25,1.0,'estimated','provider',1,2),
          ('s4','gpt-5.4','auto','','','compression',1,9,3,0,0,0,0,0,NULL,NULL,1,2),
          ('s5','gemma4:12b-mlx','custom','http://localhost:1234','','',1,8,1,0,0,0,9.5,0,'unknown','none',1,2);
        """)
    }

    func seedLegacySchemaWithoutTask() throws {
        try self.exec("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;")
        try self.exec(Self.sessionsSchema)
        try self.exec(Self.modelUsageSchemaWithoutTask)
        try self.exec("""
        INSERT INTO sessions VALUES
          ('legacy','gpt-5.4','openai-codex','https://api.openai.com','subscription_included',2,10,5,4,1,3,0,0,'included','none');
        INSERT INTO session_model_usage VALUES
          ('legacy','gpt-5.4','openai-codex','https://api.openai.com','subscription_included',1,6,3,2,0,2,0,0,'included','none',1,2);
        """)
    }

    func databaseShape() throws -> String {
        var statement: OpaquePointer?
        let sql = """
        SELECT (SELECT COUNT(*) FROM sessions),
               (SELECT COUNT(*) FROM session_model_usage),
               (SELECT COUNT(*) FROM sqlite_master)
        """
        let prepare = sqlite3_prepare_v2(self.database, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK else { throw FixtureError.exec(prepare, sql) }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { throw FixtureError.exec(step, sql) }
        return [0, 1, 2]
            .map { String(sqlite3_column_int64(statement, Int32($0))) }
            .joined(separator: ":")
    }

    private func exec(_ sql: String) throws {
        let result = sqlite3_exec(self.database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            let message = self.database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw FixtureError.exec(result, message)
        }
    }

    private static let sessionsSchema = """
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      model TEXT,
      billing_provider TEXT,
      billing_base_url TEXT,
      billing_mode TEXT,
      api_call_count INTEGER NOT NULL DEFAULT 0,
      input_tokens INTEGER NOT NULL DEFAULT 0,
      output_tokens INTEGER NOT NULL DEFAULT 0,
      cache_read_tokens INTEGER NOT NULL DEFAULT 0,
      cache_write_tokens INTEGER NOT NULL DEFAULT 0,
      reasoning_tokens INTEGER NOT NULL DEFAULT 0,
      estimated_cost_usd REAL NOT NULL DEFAULT 0,
      actual_cost_usd REAL NOT NULL DEFAULT 0,
      cost_status TEXT,
      cost_source TEXT
    );
    """

    private static let modelUsageSchemaWithTask = """
    CREATE TABLE session_model_usage (
      session_id TEXT NOT NULL,
      model TEXT NOT NULL,
      billing_provider TEXT NOT NULL DEFAULT '',
      billing_base_url TEXT NOT NULL DEFAULT '',
      billing_mode TEXT NOT NULL DEFAULT '',
      task TEXT NOT NULL DEFAULT '',
      api_call_count INTEGER NOT NULL DEFAULT 0,
      input_tokens INTEGER NOT NULL DEFAULT 0,
      output_tokens INTEGER NOT NULL DEFAULT 0,
      cache_read_tokens INTEGER NOT NULL DEFAULT 0,
      cache_write_tokens INTEGER NOT NULL DEFAULT 0,
      reasoning_tokens INTEGER NOT NULL DEFAULT 0,
      estimated_cost_usd REAL NOT NULL DEFAULT 0,
      actual_cost_usd REAL NOT NULL DEFAULT 0,
      cost_status TEXT,
      cost_source TEXT,
      first_seen REAL,
      last_seen REAL,
      PRIMARY KEY (session_id, model, billing_provider, billing_base_url, billing_mode, task)
    );
    """

    private static let modelUsageSchemaWithoutTask = """
    CREATE TABLE session_model_usage (
      session_id TEXT NOT NULL,
      model TEXT NOT NULL,
      billing_provider TEXT NOT NULL DEFAULT '',
      billing_base_url TEXT NOT NULL DEFAULT '',
      billing_mode TEXT NOT NULL DEFAULT '',
      api_call_count INTEGER NOT NULL DEFAULT 0,
      input_tokens INTEGER NOT NULL DEFAULT 0,
      output_tokens INTEGER NOT NULL DEFAULT 0,
      cache_read_tokens INTEGER NOT NULL DEFAULT 0,
      cache_write_tokens INTEGER NOT NULL DEFAULT 0,
      reasoning_tokens INTEGER NOT NULL DEFAULT 0,
      estimated_cost_usd REAL NOT NULL DEFAULT 0,
      actual_cost_usd REAL NOT NULL DEFAULT 0,
      cost_status TEXT,
      cost_source TEXT,
      first_seen REAL,
      last_seen REAL,
      PRIMARY KEY (session_id, model, billing_provider, billing_base_url, billing_mode)
    );
    """
}
#endif
