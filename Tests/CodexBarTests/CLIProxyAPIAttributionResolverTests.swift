import Foundation
import Testing
@testable import CodexBarCore

struct CLIProxyAPIAttributionResolverTests {
    @Test
    func `request log confirms route without guessing upstream`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.5", timestamp: timestamp),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream == nil)
        #expect(attribution.evidence == [.cliProxyRequestLog, .modelProvider])
    }

    @Test
    func `request log does not confirm a distant request in the same session`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.5", timestamp: timestamp),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.addingTimeInterval(3 * 60 * 60).timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .unknown)
        #expect(attribution.upstream == nil)
        #expect(attribution.evidence == [.modelProvider])
    }

    @Test
    func `codex auth inventory identifies upstream after this session route is proven`() {
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "logged-session", model: "gpt-5.5", timestamp: nil),
            ],
            authProviders: [
                .init(provider: "codex", authType: .oauth),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "logged-session",
            timestampUnixMs: nil,
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream == .init(
            provider: "codex",
            authType: .oauth,
            model: "gpt-5.5"))
        #expect(attribution.evidence == [
            .cliProxyAuthInventory,
            .cliProxyRequestLog,
            .modelProvider,
        ])
    }

    @Test
    func `codex auth inventory does not transfer route proof between sessions`() {
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "logged-session", model: "gpt-5.5", timestamp: nil),
            ],
            authProviders: [
                .init(provider: "codex", authType: .oauth),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "unrelated-session",
            timestampUnixMs: nil,
            tokens: Self.tokens)

        #expect(attribution.route == .unknown)
        #expect(attribution.upstream == nil)
        #expect(attribution.evidence == [.modelProvider])
    }

    @Test
    func `codex auth inventory stays ambiguous with another active provider`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-auth-inventory-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        try Data(Self.requestLog(sessionID: "session-1", timestamp: timestamp).utf8)
            .write(to: logs.appendingPathComponent("request.log"))
        try Data(#"{"type":"codex"}"#.utf8)
            .write(to: home.appendingPathComponent("codex.json"))
        try Data(#"{"type":"openrouter"}"#.utf8)
            .write(to: home.appendingPathComponent("openrouter.json"))

        let resolver = try CLIProxyAPIAttributionResolver.load(home: home, fileManager: fileManager)
        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream == nil)
        #expect(attribution.evidence == [.cliProxyRequestLog, .modelProvider])
    }

    @Test
    func `request telemetry identifies exact codex oauth upstream`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.5", timestamp: timestamp),
            ],
            usageRecords: [
                Self.record(
                    timestamp: timestamp.addingTimeInterval(1),
                    provider: "codex",
                    authType: "oauth"),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream?.provider == "codex")
        #expect(attribution.upstream?.authType == .oauth)
        #expect(attribution.upstream?.model == "gpt-5.5")
        #expect(attribution.evidence == [
            .cliProxyRequestLog,
            .cliProxyUsageTelemetry,
            .modelProvider,
        ])
    }

    @Test
    func `dated request log outranks an undated log for telemetry correlation`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.5", timestamp: nil),
                .init(sessionID: "session-1", model: "gpt-5.5", timestamp: timestamp),
            ],
            usageRecords: [
                Self.record(timestamp: timestamp, provider: "openrouter", authType: "api_key"),
            ],
            authProviders: [
                .init(provider: "codex", authType: .oauth),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.upstream?.provider == "openrouter")
        #expect(attribution.upstream?.authType == .apiKey)
        #expect(attribution.evidence.contains(.cliProxyUsageTelemetry))
        #expect(!attribution.evidence.contains(.cliProxyAuthInventory))
    }

    @Test
    func `request telemetry preserves api key authentication type`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.5", timestamp: timestamp),
            ],
            usageRecords: [
                Self.record(timestamp: timestamp, provider: "openrouter", authType: "apikey"),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.upstream?.provider == "openrouter")
        #expect(attribution.upstream?.authType == .apiKey)
        #expect(attribution.upstream?.displayName == "OpenRouter API key")
    }

    @Test
    func `ambiguous telemetry does not claim an upstream`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.5", timestamp: timestamp),
            ],
            usageRecords: [
                Self.record(timestamp: timestamp, provider: "codex", authType: "oauth"),
                Self.record(timestamp: timestamp, provider: "openrouter", authType: "api_key"),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream == nil)
        #expect(!attribution.evidence.contains(.cliProxyUsageTelemetry))
    }

    @Test
    func `telemetry plausible for two requests does not claim either upstream`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.5", timestamp: timestamp),
                .init(
                    sessionID: "session-2",
                    model: "gpt-5.5",
                    timestamp: timestamp.addingTimeInterval(2)),
            ],
            usageRecords: [
                Self.record(
                    timestamp: timestamp.addingTimeInterval(1),
                    provider: "codex",
                    authType: "oauth"),
            ])

        let attributions = resolver.attributions(for: ["session-1", "session-2"].map { sessionID in
            CLIProxyAPIAttributionResolver.Request(
                model: "gpt-5.5",
                modelProvider: .openAI,
                sessionID: sessionID,
                timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
                tokens: Self.tokens)
        })

        for attribution in attributions {
            #expect(attribution.route == .cliProxyAPI)
            #expect(attribution.upstream == nil)
            #expect(!attribution.evidence.contains(.cliProxyUsageTelemetry))
        }
    }

    @Test
    func `failed and token mismatched telemetry are ignored`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.5", timestamp: timestamp),
            ],
            usageRecords: [
                Self.record(
                    timestamp: timestamp,
                    provider: "codex",
                    authType: "oauth",
                    failed: true),
                CLIProxyAPIUsageRecord(
                    timestamp: timestamp.addingTimeInterval(1),
                    provider: "codex",
                    model: "gpt-5.5",
                    alias: "gpt-5.5",
                    endpoint: "POST /v1/messages",
                    authType: "oauth",
                    requestID: "request-mismatch",
                    tokens: .init(input: 999, output: 999, total: 1998)),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream == nil)
    }

    @Test
    func `telemetry index isolates the matching model and time window`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let unrelated = (0..<10000).map { index in
            CLIProxyAPIUsageRecord(
                timestamp: timestamp.addingTimeInterval(TimeInterval(index - 5000)),
                provider: "openrouter",
                model: "unrelated-model",
                alias: "unrelated-model",
                endpoint: "POST /v1/messages",
                authType: "api_key",
                requestID: "unrelated-\(index)",
                tokens: .init(input: 10, output: 20, total: 30))
        }
        let matching = Self.record(
            timestamp: timestamp.addingTimeInterval(1),
            provider: "codex",
            authType: "oauth")
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.5", timestamp: timestamp),
            ],
            usageRecords: unrelated + [matching])

        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.upstream?.provider == "codex")
        #expect(attribution.upstream?.model == "gpt-5.5")
        #expect(attribution.evidence.contains(.cliProxyUsageTelemetry))
    }

    @Test
    func `model without correlated request does not claim cliproxyapi`() {
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "other-session", model: "gpt-5.5", timestamp: nil),
            ],
            usageRecords: [
                Self.record(timestamp: Date(), provider: "codex", authType: "oauth"),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: nil,
            tokens: Self.tokens)

        #expect(attribution.route == .unknown)
        #expect(attribution.upstream == nil)
        #expect(attribution.evidence == [.modelProvider])
    }

    @Test
    func `filesystem loader correlates sanitized cached telemetry`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-attribution-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let requestLog = """
        === REQUEST INFO ===
        URL: /v1/messages
        Method: POST
        Timestamp: 2026-07-16T12:00:00Z
        === HEADERS ===
        X-Claude-Code-Session-Id: session-1
        === REQUEST BODY ===
        {"model":"gpt-5.5"}
        === RESPONSE ===
        Status: 200
        """
        try Data(requestLog.utf8).write(to: logs.appendingPathComponent("v1-messages.log"))
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:01Z"))
        CLIProxyAPIUsageCacheIO.merge(
            [Self.record(timestamp: timestamp, provider: "codex", authType: "oauth")],
            cacheRoot: cacheRoot,
            now: timestamp)

        let resolver = try CLIProxyAPIAttributionResolver.load(
            home: home,
            cacheRoot: cacheRoot,
            fileManager: fileManager)
        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.upstream?.isCodex == true)
        #expect(attribution.evidence.contains(.cliProxyUsageTelemetry))
    }

    @Test
    func `filesystem loader preserves observations beyond five hundred newer logs`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-log-window-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let timestamp = try #require(CostUsageDateParser.parse("2026-01-01T12:00:00Z"))
        let targetURL = logs.appendingPathComponent("target.log")
        try Data(Self.requestLog(
            sessionID: "target-session",
            timestamp: timestamp).utf8).write(to: targetURL)
        try fileManager.setAttributes([.modificationDate: timestamp], ofItemAtPath: targetURL.path)
        for index in 0..<500 {
            let newerTimestamp = timestamp.addingTimeInterval(TimeInterval(index + 1))
            let url = logs.appendingPathComponent("newer-\(index).log")
            try Data(Self.requestLog(
                sessionID: "newer-session-\(index)",
                timestamp: newerTimestamp).utf8).write(to: url)
            try fileManager.setAttributes(
                [.modificationDate: newerTimestamp],
                ofItemAtPath: url.path)
        }

        let resolver = try CLIProxyAPIAttributionResolver.load(home: home, fileManager: fileManager)
        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "target-session",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: Self.tokens)

        #expect(attribution.route == .cliProxyAPI)
        #expect(attribution.evidence.contains(.cliProxyRequestLog))
    }

    @Test
    func `filesystem loader checks cancellation before reading request logs`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-log-cancellation-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try Data(Self.requestLog(
            sessionID: "cancelled-session",
            timestamp: Date()).utf8).write(to: logs.appendingPathComponent("request.log"))

        #expect(throws: CancellationError.self) {
            try CLIProxyAPIAttributionResolver.load(
                home: home,
                fileManager: fileManager,
                checkCancellation: { throw CancellationError() })
        }
    }

    @Test
    func `filesystem loader reuses unchanged logs and refreshes changed paths`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-log-cache-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        let logURL = logs.appendingPathComponent("request.log")
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let requestTimestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let pinnedModificationDate = Date(timeIntervalSince1970: 1_000_000)
        let firstLog = Self.requestLog(sessionID: "session-one", timestamp: requestTimestamp)
        let secondLog = Self.requestLog(sessionID: "session-two", timestamp: requestTimestamp)
        let thirdLog = Self.requestLog(sessionID: "session-new", timestamp: requestTimestamp)
        #expect(firstLog.utf8.count == secondLog.utf8.count)
        #expect(secondLog.utf8.count == thirdLog.utf8.count)

        try Data(firstLog.utf8).write(to: logURL)
        try fileManager.setAttributes(
            [.modificationDate: pinnedModificationDate],
            ofItemAtPath: logURL.path)
        let firstResolver = try CLIProxyAPIAttributionResolver.load(home: home, fileManager: fileManager)
        #expect(Self.route(for: "session-one", resolver: firstResolver) == .cliProxyAPI)

        try Data(secondLog.utf8).write(to: logURL)
        try fileManager.setAttributes(
            [.modificationDate: pinnedModificationDate],
            ofItemAtPath: logURL.path)
        let cachedResolver = try CLIProxyAPIAttributionResolver.load(home: home, fileManager: fileManager)
        #expect(Self.route(for: "session-one", resolver: cachedResolver) == .cliProxyAPI)
        #expect(Self.route(for: "session-two", resolver: cachedResolver) == .unknown)

        let forcedResolver = try CLIProxyAPIAttributionResolver.load(
            home: home,
            fileManager: fileManager,
            forceReload: true)
        #expect(Self.route(for: "session-one", resolver: forcedResolver) == .unknown)
        #expect(Self.route(for: "session-two", resolver: forcedResolver) == .cliProxyAPI)

        try Data(firstLog.utf8).write(to: logURL)
        try fileManager.setAttributes(
            [.modificationDate: pinnedModificationDate.addingTimeInterval(1)],
            ofItemAtPath: logURL.path)
        let refreshedResolver = try CLIProxyAPIAttributionResolver.load(home: home, fileManager: fileManager)
        #expect(Self.route(for: "session-one", resolver: refreshedResolver) == .cliProxyAPI)
        #expect(Self.route(for: "session-two", resolver: refreshedResolver) == .unknown)

        try fileManager.removeItem(at: logURL)
        _ = try CLIProxyAPIAttributionResolver.load(home: home, fileManager: fileManager)
        try Data(thirdLog.utf8).write(to: logURL)
        try fileManager.setAttributes(
            [.modificationDate: pinnedModificationDate.addingTimeInterval(1)],
            ofItemAtPath: logURL.path)
        let recreatedResolver = try CLIProxyAPIAttributionResolver.load(home: home, fileManager: fileManager)
        #expect(Self.route(for: "session-one", resolver: recreatedResolver) == .unknown)
        #expect(Self.route(for: "session-new", resolver: recreatedResolver) == .cliProxyAPI)
    }

    @Test
    func `usage cache never persists source or api key fields`() throws {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: cacheRoot) }
        let payload = """
        [{
          "timestamp":"2026-07-16T12:00:00Z",
          "source":"private@example.com",
          "api_key":"secret-client-key",
          "provider":"codex",
          "executor_type":"CodexExecutor",
          "model":"gpt-5.5",
          "alias":"gpt-5.5",
          "endpoint":"POST /v1/messages",
          "auth_type":"oauth",
          "request_id":"request-1",
          "failed":false,
          "generate":true,
          "tokens":{
            "input_tokens":10,
            "output_tokens":20,
            "cache_read_tokens":30,
            "cache_creation_tokens":40,
            "total_tokens":100
          }
        }]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([CLIProxyAPIUsageRecord].self, from: Data(payload.utf8))
        let now = try #require(CostUsageDateParser.parse("2026-07-16T12:00:01Z"))

        #expect(CLIProxyAPIUsageCacheIO.merge(records, cacheRoot: cacheRoot, now: now) == 1)
        let persisted = try String(
            contentsOf: CLIProxyAPIUsageCacheIO.cacheFileURL(cacheRoot: cacheRoot),
            encoding: .utf8)
        #expect(!persisted.contains("private@example.com"))
        #expect(!persisted.contains("secret-client-key"))
        #expect(persisted.contains("\"provider\":\"codex\""))
    }

    @Test
    func `usage queue client authenticates and decodes sanitized records`() async throws {
        let responseBody = """
        [{
          "timestamp":"2026-07-16T12:00:00.123456789Z",
          "source":"private@example.com",
          "api_key":"secret-client-key",
          "provider":"codex",
          "executor_type":"CodexExecutor",
          "model":"gpt-5.5",
          "alias":"gpt-5.5",
          "endpoint":"POST /v1/messages",
          "auth_type":"oauth",
          "request_id":"request-1",
          "failed":false,
          "generate":true,
          "tokens":{"input_tokens":10,"output_tokens":20,"total_tokens":30}
        }]
        """
        let client = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                #expect(request.url?.absoluteString ==
                    "http://127.0.0.1:8317/v0/management/usage-queue?count=100")
                #expect(request.value(forHTTPHeaderField: "Authorization") ==
                    "Bearer management-secret")
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (Data(responseBody.utf8), response)
            })

        let batch = try await client.pop(count: 100)
        let records = batch.records

        #expect(records.count == 1)
        #expect(batch.receivedCount == 1)
        #expect(records[0].provider == "codex")
        #expect(records[0].authType == "oauth")
        #expect(records[0].tokens.total == 30)
    }

    @Test
    func `usage collector serializes queue pops and cache merges`() async throws {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-collector-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: cacheRoot) }
        let probe = CLIProxyAPICollectionConcurrencyProbe()
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))

        func client(requestID: String, seconds: TimeInterval) throws -> CLIProxyAPIUsageQueueClient {
            let record = CLIProxyAPIUsageRecord(
                timestamp: timestamp.addingTimeInterval(seconds),
                provider: "codex",
                model: "gpt-5.5",
                alias: "gpt-5.5",
                endpoint: "POST /v1/messages",
                authType: "oauth",
                requestID: requestID,
                tokens: .init(input: 10, output: 20, total: 30))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode([record])
            return CLIProxyAPIUsageQueueClient(
                settings: .init(managementKey: "management-secret"),
                dataLoader: { request in
                    await probe.recordCall()
                    let url = try #require(request.url)
                    let response = try #require(HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil))
                    return (data, response)
                })
        }

        let firstClient = try client(requestID: "request-1", seconds: 0)
        let secondClient = try client(requestID: "request-2", seconds: 1)
        let results = await withTaskGroup(
            of: CLIProxyAPIUsageCollectionResult.self,
            returning: [CLIProxyAPIUsageCollectionResult].self)
        { group in
            group.addTask {
                await CLIProxyAPIUsageCollector.collect(cacheRoot: cacheRoot, client: firstClient)
            }
            group.addTask {
                await CLIProxyAPIUsageCollector.collect(cacheRoot: cacheRoot, client: secondClient)
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.allSatisfy { $0 == .collected(1) })
        #expect(await probe.maximumActiveCallCount() == 1)
        #expect(Set(CLIProxyAPIUsageCacheIO.load(cacheRoot: cacheRoot).map(\.requestID)) == [
            "request-1",
            "request-2",
        ])
    }

    @Test
    func `usage collector persists a full batch before a later pop fails`() async throws {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: cacheRoot) }
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let records = (0..<100).map { index in
            CLIProxyAPIUsageRecord(
                timestamp: timestamp.addingTimeInterval(TimeInterval(index)),
                provider: "codex",
                model: "gpt-5.5",
                alias: "gpt-5.5",
                endpoint: "POST /v1/messages",
                authType: "oauth",
                requestID: "request-\(index)",
                tokens: .init(input: 10, output: 20, total: 30))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sequence = try CLIProxyAPIBatchSequence(firstPayload: encoder.encode(records))
        let client = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                try await sequence.load(request)
            })

        let result = await CLIProxyAPIUsageCollector.collect(cacheRoot: cacheRoot, client: client)

        #expect(result == .failed("The second queue pop failed."))
        #expect(CLIProxyAPIUsageCacheIO.load(cacheRoot: cacheRoot).count == 100)
    }

    @Test
    func `usage collector prunes expired cache records when the queue is empty`() async {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: cacheRoot) }
        let now = Date()
        let expired = Self.record(
            timestamp: now.addingTimeInterval(-367 * 24 * 60 * 60),
            provider: "codex",
            authType: "oauth")
        let current = Self.record(
            timestamp: now.addingTimeInterval(-24 * 60 * 60),
            provider: "codex",
            authType: "oauth")
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [expired, current],
            cacheRoot: cacheRoot,
            now: current.timestamp) == 2)
        let client = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (Data("[]".utf8), response)
            })

        let result = await CLIProxyAPIUsageCollector.collect(cacheRoot: cacheRoot, client: client)

        #expect(result == .collected(0))
        #expect(CLIProxyAPIUsageCacheIO.load(cacheRoot: cacheRoot).map(\.requestID) == [current.requestID])
    }

    @Test
    func `usage cache prunes expired records from disk during load`() {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-load-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: cacheRoot) }
        let now = Date()
        let expired = Self.record(
            timestamp: now.addingTimeInterval(-367 * 24 * 60 * 60),
            provider: "codex",
            authType: "oauth")
        let current = Self.record(
            timestamp: now.addingTimeInterval(-24 * 60 * 60),
            provider: "codex",
            authType: "oauth")
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [expired, current],
            cacheRoot: cacheRoot,
            now: current.timestamp) == 2)

        #expect(CLIProxyAPIUsageCacheIO.load(
            cacheRoot: cacheRoot,
            now: now).map(\.requestID) == [current.requestID])
        #expect(CLIProxyAPIUsageCacheIO.load(
            cacheRoot: cacheRoot,
            now: now.addingTimeInterval(1)).map(\.requestID) == [current.requestID])
    }

    @Test
    func `empty usage poll does not rewrite an unchanged cache`() async throws {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-empty-poll-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: cacheRoot) }
        let current = Self.record(
            timestamp: Date(),
            provider: "codex",
            authType: "oauth")
        #expect(CLIProxyAPIUsageCacheIO.merge([current], cacheRoot: cacheRoot) == 1)
        let cacheURL = CLIProxyAPIUsageCacheIO.cacheFileURL(cacheRoot: cacheRoot)
        let marker = Date(timeIntervalSince1970: 1_700_000_000)
        try fileManager.setAttributes([.modificationDate: marker], ofItemAtPath: cacheURL.path)
        let before = try #require(
            fileManager.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date)
        let client = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (Data("[]".utf8), response)
            })

        let result = await CLIProxyAPIUsageCollector.collect(cacheRoot: cacheRoot, client: client)
        let after = try #require(
            fileManager.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date)

        #expect(result == .collected(0))
        #expect(after == before)
    }

    @Test
    func `plain http management url is limited to loopback`() {
        #expect(CLIProxyAPIConnectionSettings(
            baseURL: "http://127.0.0.1:8317",
            managementKey: "secret").isConfigured)
        #expect(CLIProxyAPIConnectionSettings(
            baseURL: "http://localhost:8317",
            managementKey: "secret").isConfigured)
        #expect(!CLIProxyAPIConnectionSettings(
            baseURL: "http://192.168.1.10:8317",
            managementKey: "secret").isConfigured)
        #expect(!CLIProxyAPIConnectionSettings(
            baseURL: "https://proxy.example.com",
            managementKey: "secret").isConfigured)
        #expect(CLIProxyAPIConnectionSettings(
            baseURL: "https://[::1]:8317",
            managementKey: "secret").isConfigured)
    }

    private static let tokens = CLIProxyAPIAttributionResolver.TokenSignature(
        input: 10,
        cacheRead: 30,
        cacheCreate: 40,
        output: 20)

    private static func route(
        for sessionID: String,
        resolver: CLIProxyAPIAttributionResolver) -> CostUsageAttribution.Route
    {
        resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: sessionID,
            timestampUnixMs: nil,
            tokens: self.tokens).route
    }

    private static func requestLog(sessionID: String, timestamp: Date) -> String {
        """
        === REQUEST INFO ===
        URL: /v1/messages
        Method: POST
        Timestamp: \(ISO8601DateFormatter().string(from: timestamp))
        === HEADERS ===
        X-Claude-Code-Session-Id: \(sessionID)
        === REQUEST BODY ===
        {"model":"gpt-5.5"}
        === RESPONSE ===
        Status: 200
        """
    }

    private static func record(
        timestamp: Date,
        provider: String,
        authType: String,
        failed: Bool = false) -> CLIProxyAPIUsageRecord
    {
        CLIProxyAPIUsageRecord(
            timestamp: timestamp,
            provider: provider,
            executorType: provider == "codex" ? "CodexExecutor" : "OpenAICompatExecutor",
            model: "gpt-5.5",
            alias: "gpt-5.5",
            endpoint: "POST /v1/messages",
            authType: authType,
            requestID: "request-\(provider)-\(authType)-\(timestamp.timeIntervalSince1970)",
            failed: failed,
            tokens: .init(
                input: 10,
                output: 20,
                cacheRead: 30,
                cacheCreation: 40,
                total: 100))
    }
}

struct CLIProxyAPIAttributionTimestampTests {
    @Test
    func `undated request log does not confirm a dated request`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.5", timestamp: nil),
            ])

        let attribution = resolver.attribution(
            model: "gpt-5.5",
            modelProvider: .openAI,
            sessionID: "session-1",
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            tokens: nil)

        #expect(attribution.route == .unknown)
        #expect(attribution.upstream == nil)
        #expect(attribution.evidence == [.modelProvider])
    }
}

struct CLIProxyAPIAttributionEqualTimestampTests {
    @Test
    func `equal timestamp logs retain distinct observations for token matched telemetry`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let firstTokens = CLIProxyAPIAttributionResolver.TokenSignature(
            input: 10,
            cacheRead: 0,
            cacheCreate: 0,
            output: 20)
        let secondTokens = CLIProxyAPIAttributionResolver.TokenSignature(
            input: 30,
            cacheRead: 0,
            cacheCreate: 0,
            output: 40)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sourceID: "first.log", sessionID: "session-1", model: "gpt-5.5", timestamp: timestamp),
                .init(sourceID: "second.log", sessionID: "session-1", model: "gpt-5.5", timestamp: timestamp),
            ],
            usageRecords: [
                CLIProxyAPIUsageRecord(
                    timestamp: timestamp,
                    provider: "codex",
                    model: "gpt-5.5",
                    alias: "gpt-5.5",
                    endpoint: "POST /v1/messages",
                    authType: "oauth",
                    requestID: "request-first",
                    tokens: .init(input: 10, output: 20, total: 30)),
                CLIProxyAPIUsageRecord(
                    timestamp: timestamp,
                    provider: "openrouter",
                    model: "gpt-5.5",
                    alias: "gpt-5.5",
                    endpoint: "POST /v1/messages",
                    authType: "api_key",
                    requestID: "request-second",
                    tokens: .init(input: 30, output: 40, total: 70)),
            ])
        let attributions = resolver.attributions(for: [firstTokens, secondTokens].map { tokens in
            CLIProxyAPIAttributionResolver.Request(
                model: "gpt-5.5",
                modelProvider: .openAI,
                sessionID: "session-1",
                timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
                tokens: tokens)
        })

        #expect(attributions.map(\.route) == [.cliProxyAPI, .cliProxyAPI])
        #expect(attributions.map(\.upstream?.provider) == ["codex", "openrouter"])
        #expect(attributions.allSatisfy { $0.evidence.contains(.cliProxyUsageTelemetry) })
    }
}

struct CLIProxyAPIAttributionEndpointTests {
    @Test(arguments: [
        "/v1/messages",
        "/v1/messages?beta=true",
        "POST /v1/messages",
        "https://localhost:8317/v1/messages?beta=true",
    ])
    func `accepts Claude generation endpoint URL variants`(_ endpoint: String) {
        #expect(CLIProxyAPIAttributionResolver.isClaudeMessagesGenerationEndpoint(endpoint))
    }

    @Test(arguments: [
        "/v1/messages/count_tokens",
        "/v1/messages/batches",
        "/v1/messageship",
        "POST /v1/messages/count_tokens",
    ])
    func `rejects non generation Claude endpoint variants`(_ endpoint: String) {
        #expect(!CLIProxyAPIAttributionResolver.isClaudeMessagesGenerationEndpoint(endpoint))
    }
}

private actor CLIProxyAPICollectionConcurrencyProbe {
    private var activeCallCount = 0
    private var maximumActiveCount = 0

    func recordCall() async {
        self.activeCallCount += 1
        self.maximumActiveCount = max(self.maximumActiveCount, self.activeCallCount)
        try? await Task.sleep(for: .milliseconds(100))
        self.activeCallCount -= 1
    }

    func maximumActiveCallCount() -> Int {
        self.maximumActiveCount
    }
}

private actor CLIProxyAPIBatchSequence {
    private enum SequenceError: LocalizedError {
        case secondPopFailed

        var errorDescription: String? {
            "The second queue pop failed."
        }
    }

    private let firstPayload: Data
    private var callCount = 0

    init(firstPayload: Data) {
        self.firstPayload = firstPayload
    }

    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        self.callCount += 1
        guard self.callCount == 1 else {
            throw SequenceError.secondPopFailed
        }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil))
        return (self.firstPayload, response)
    }
}
