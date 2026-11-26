import Foundation
import Testing
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

// MARK: - AntigravityParityURLProtocol

private final class AntigravityParityURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    private static let allowedHosts: Set<String> = [
        "cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com", "oauth2.googleapis.com",
    ]
    private static let handlerLock = NSLock()
    private nonisolated(unsafe) static var activeHandler: Handler?

    @MainActor
    static func withRegisteredHandler<T>(
        handler: @escaping Handler,
        operation: () async throws -> T) async rethrows -> T
    {
        self.handlerLock.withLock { self.activeHandler = handler }
        URLProtocol.registerClass(Self.self)
        defer {
            URLProtocol.unregisterClass(Self.self)
            self.handlerLock.withLock { self.activeHandler = nil }
        }
        return try await operation()
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased(), self.allowedHosts.contains(host) else { return false }
        return self.handlerLock.withLock { self.activeHandler != nil }
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handlerLock.withLock({ Self.activeHandler }) else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        do {
            let (data, response) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - AntigravityParityHarness

private enum AntigravityParityHarness {
    struct StoreContext {
        let root: URL
        let settings: SettingsStore
        let store: UsageStore
        let historyStore: PlanUtilizationHistoryStore
        let environment: [String: String]

        func cleanup() { try? FileManager.default.removeItem(at: self.root) }
    }

    @MainActor
    static func withStore(
        email: String = "parity-user@example.com",
        showOptional: Bool = true,
        _ body: (StoreContext) async throws -> Void) async throws
    {
        let suite = "ag-e2e-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let token = try AntigravityOAuthCredentialsStore.tokenAccountValue(for: AntigravityOAuthCredentials(
            accessToken: "parity-access-token",
            refreshToken: "parity-refresh-token",
            expiryDate: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: email),
            email: email,
            projectID: "proj-parity",
            clientID: "parity-client-id",
            clientSecret: "parity-client-secret"))
        let env: [String: String] = [
            "HOME": root.path, "CFFIXED_USER_HOME": root.path,
            AntigravityOAuthCredentialsStore.environmentCredentialsKey: token,
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1", "CODEXBAR_DISABLE_KEYCHAIN_ACCESS": "1",
        ]
        let historyStore = testPlanUtilizationHistoryStore(suiteName: suite)
        let managedURL = root.appendingPathComponent("managed-codex-accounts.json")
        let emptyAccounts = ManagedCodexAccountSet(version: FileManagedCodexAccountStore.currentVersion, accounts: [])
        try FileManagedCodexAccountStore(fileURL: managedURL).storeAccounts(emptyAccounts)
        let settings = testSettingsStore(
            suiteName: suite,
            userDefaults: InMemoryUserDefaults(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings._test_managedCodexAccountStoreURL = managedURL
        settings.statusChecksEnabled = false
        enableTestProviders([.antigravity], settings: settings)
        settings.antigravityUsageDataSource = .oauth
        settings.antigravityShowCredits = true
        settings.showOptionalCreditsAndExtraUsage = showOptional
        settings.historicalTrackingEnabled = true
        let histURL = root.appendingPathComponent("hist.json")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: env),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(fileURL: histURL),
            planUtilizationHistoryStore: historyStore,
            startupBehavior: .testing,
            environmentBase: env)
        store._cancelPlanUtilizationHistoryLoadForTesting()
        store.planUtilizationHistory = [:]
        let ctx = StoreContext(
            root: root, settings: settings, store: store, historyStore: historyStore, environment: env)
        defer { ctx.cleanup() }
        try await body(ctx)
    }

    @MainActor
    static func runRefresh(
        email: String = "parity-user@example.com",
        showOptional: Bool = true,
        load: String = #"{"paidTier":{"id":"g1-pro-tier"}}"#,
        summaryStatus: Int = 200,
        summary: String? = nil,
        summaryDict: [String: Any]? = nil,
        modelsStatus: Int = 200,
        models: String = #"{"models":{}}"#,
        quota: String = #"{"buckets":[]}"#,
        _ body: (StoreContext, UsageSnapshot) async throws -> Void) async throws
    {
        try await self.withStore(email: email, showOptional: showOptional) { ctx in
            try await self.refresh(
                ctx,
                load: load,
                summaryStatus: summaryStatus,
                summary: summary,
                summaryDict: summaryDict,
                modelsStatus: modelsStatus,
                models: models,
                quota: quota)
            try await body(ctx, self.snap(ctx))
        }
    }

    @MainActor
    static func refresh(
        _ ctx: StoreContext,
        load: String = #"{"paidTier":{"id":"g1-pro-tier"}}"#,
        summaryStatus: Int = 200,
        summary: String? = nil,
        summaryDict: [String: Any]? = nil,
        modelsStatus: Int = 200,
        models: String = #"{"models":{}}"#,
        quota: String = #"{"buckets":[]}"#) async throws
    {
        let summaryData = summary.map { Data($0.utf8) }
            ?? GeminiAPITestHelpers.jsonData(summaryDict ?? self.fourBucketSummary())
        try await AntigravityParityURLProtocol.withRegisteredHandler(
            handler: { request in
                let url = try #require(request.url)
                switch url.path {
                case "/v1internal:loadCodeAssist": return self.rawHTTP(url, data: Data(load.utf8))
                case "/v1internal:retrieveUserQuotaSummary":
                    return self.rawHTTP(url, status: summaryStatus, data: summaryData)
                case "/v1internal:fetchAvailableModels":
                    return self.rawHTTP(url, status: modelsStatus, data: Data(models.utf8))
                case "/v1internal:retrieveUserQuota": return self.rawHTTP(url, data: Data(quota.utf8))
                default: throw URLError(.unsupportedURL)
                }
            },
            operation: { await ctx.store.refreshProvider(.antigravity) })
    }

    static func fourBucketSummary(
        g5h: Double = 0.75,
        gw: Double = 0.60,
        c5h: Double? = 0.80,
        cw: Double? = 0.50,
        g5hAmt: Any? = nil,
        c5hAmt: Any? = nil,
        avail: [String: Any]? = nil,
        now: Date = Date()) -> [String: Any]
    {
        let iso = ISO8601DateFormatter()
        func b(_ id: String, _ name: String, _ win: String, _ f: Double, _ dt: TimeInterval, _ a: Any? = nil)
            -> [String: Any]
        {
            var d: [String: Any] = [
                "bucketId": id, "displayName": name, "window": win,
                "remainingFraction": f, "resetTime": iso.string(from: now.addingTimeInterval(dt)),
            ]
            if let a { d["remainingAmount"] = a }
            return d
        }
        let tp: [[String: Any]] = [
            c5h.map { b("3p-5h", "5-hour", "5h", $0, 7200, c5hAmt) },
            cw.map { b("3p-weekly", "Weekly", "weekly", $0, 432_000) },
        ].compactMap(\.self)
        var groups: [[String: Any]] = [[
            "displayName": "Gemini Models",
            "description": "Models within this group: Gemini 3.1 Pro, Gemini 3 Flash. Resets regularly.",
            "buckets": [
                b("gemini-5h", "5-hour", "5h", g5h, 10800, g5hAmt),
                b("gemini-weekly", "Weekly", "weekly", gw, 345_600),
            ],
        ]]
        if !tp.isEmpty {
            groups.append([
                "displayName": "Claude and GPT models",
                "description": "Models within this group: Claude Sonnet 4.6, GPT-OSS 120B. Shared pool.",
                "buckets": tp,
            ])
        }
        var body: [String: Any] = ["groups": groups]
        if let avail { body["modelAvailabilities"] = avail }
        return body
    }

    static func singleSummary(cadence: String, frac: Double = 0.65, resetOffset: TimeInterval? = 3600) -> String {
        let is5h = cadence == "5h"
        let id = is5h ? "gemini-5h" : "gemini-weekly"
        let reset = resetOffset
            .map { #","resetTime":"\#(ISO8601DateFormatter().string(from: Date().addingTimeInterval($0)))""# } ?? ""
        return #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"\#(id)","#
            + #""displayName":"\#(is5h ? "5-hour" : "Weekly")","window":"\#(cadence)","#
            + #""remainingFraction":\#(frac)\#(reset)}]}]}"#
    }

    static func agyUsage(_ groups: [(String, String, String)], avail: String? = nil) -> String {
        let joined = groups.map { #"{"name":"\#($0.0)","description":"\#($0.1)","buckets":[\#($0.2)]}"# }
            .joined(separator: ",")
        let av = avail.map { #","model_availabilities":\#($0)"# } ?? ""
        return #"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[\#(joined)]\#(av)}}}"#
    }

    static func mod(_ entries: String) -> String { #"{"models":{\#(entries)}}"# }

    @MainActor
    static func snap(_ ctx: StoreContext) throws -> UsageSnapshot {
        try #require(ctx.store.snapshot(for: .antigravity))
    }

    @MainActor
    static func dashURL(_ ctx: StoreContext) throws -> String? {
        try AntigravityProviderDescriptor.subscriptionDashboardURL(from: self.snap(ctx))?.absoluteString
    }

    static func rawHTTP(_ url: URL, status: Int = 200, data: Data) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    static func makeAgyStub(
        reportBody: String,
        version: String = "1.2.2",
        exitCode: Int32 = 0,
        stderr: String = "") throws -> (directory: URL, binary: URL, environment: [String: String])
    {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ag-e2e-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("agy")
        try version.write(to: dir.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        let script = """
        #!/bin/sh
        [ "${1:-}" = --version ] && exec /bin/cat "$HOME/version"
        printf '%s\\n' "$*" > "$HOME/invoked-args"
        [ -n "\(stderr)" ] && printf '%s\\n' "\(stderr)" >&2
        [ "\(exitCode)" -ne 0 ] && exit \(exitCode)
        /bin/cat <<'REPORT'
        \(reportBody)
        REPORT
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let env = [
            "HOME": dir.path, "PATH": "/usr/bin:/bin",
            "ANTIGRAVITY_CLI_PATH": binary.path, "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        ]
        return (dir, binary, env)
    }

    static func fetchAgyJSON(_ reportBody: String, version: String = "1.2.2") async throws -> (
        result: ProviderFetchResult, args: String)
    {
        let stub = try self.makeAgyStub(reportBody: reportBody, version: version)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        let warm = makeAntigravityWarmDependencies(
            processInfos: { _ in [] },
            listeningPorts: { _, _ in [] },
            fetchSnapshot: { _, _ in throw AntigravityStatusProbeError.notRunning })
        let noCache = BrowserDetection(cacheTTL: 0)
        let ctx = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .cli,
            includeCredits: true,
            webTimeout: 5,
            webDebugDumpHTML: false,
            verbose: false,
            env: stub.environment,
            settings: nil,
            fetcher: UsageFetcher(environment: stub.environment),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: noCache),
            browserDetection: noCache)
        let res = try await AntigravityCLIHTTPSFetchStrategy().fetch(
            ctx,
            warmDependencies: warm,
            spawnFetch: { _, _, _, _ in throw AntigravityStatusProbeError.timedOut })
        let argsURL = stub.directory.appendingPathComponent("invoked-args")
        let args = (try? String(contentsOf: argsURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (res, args ?? "")
    }

    static func seedPricing(in homeRoot: URL) throws {
        let json = #"{"google":{"id":"google","models":{"gemini-2.5-pro":{"id":"gemini-2.5-pro","#
            + #""cost":{"input":1.25,"output":10.0,"cache_read":0.31}}}},"anthropic":{"id":"anthropic","#
            + #""models":{"claude-sonnet-4-6":{"id":"claude-sonnet-4-6","cost":{"input":3.0,"output":15.0,"#
            + #""cache_read":0.3}}}},"google-vertex":{"id":"google-vertex","models":{"openai/gpt-oss-120b-maas":"#
            + #"{"id":"openai/gpt-oss-120b-maas","cost":{"input":0.09,"output":0.36}}}}}"#
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
        let cacheRoot = homeRoot.appendingPathComponent("Library/Caches/CodexBar", isDirectory: true)
        ModelsDevCache.save(catalog: catalog, fetchedAt: Date(), cacheRoot: cacheRoot)
    }

    static func runCostCLI(
        _ args: [String], homeRoot: URL, extraEnv: [String: String] = [:]) throws -> (exitCode: Int32, stdout: Data)
    {
        let cfgURL = homeRoot.appendingPathComponent("codexbar-config.json")
        if !FileManager.default.fileExists(atPath: cfgURL.path) {
            try JSONSerialization.data(withJSONObject: [
                "version": 1, "providers": [["id": "antigravity", "enabled": true]],
            ]).write(to: cfgURL)
        }
        let process = Process()
        process.executableURL = TestBuildProducts.executableURL(named: "CodexBarCLI")
        process.arguments = ["cost", "--provider", "antigravity"] + args
        var env: [String: String] = [
            "HOME": homeRoot.path, "CFFIXED_USER_HOME": homeRoot.path, "CODEXBAR_CONFIG": cfgURL.path,
            "TOKSCALE_CONFIG_DIR": homeRoot.appendingPathComponent(".config/tokscale").path,
            "CODEX_HOME": homeRoot.appendingPathComponent(".codex").path,
            "CODEXBAR_DISABLE_KEYCHAIN_ACCESS": "1", "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
            "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1", "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1",
            "PATH": "/usr/bin:/bin", "TZ": "UTC",
        ]
        extraEnv.forEach { env[$0.key] = $0.value }
        process.environment = env
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    static func costJSON(
        _ args: [String] = [],
        in homeRoot: URL,
        extraEnv: [String: String] = [:]) throws -> [String: Any]
    {
        let res = try self.runCostCLI(args + ["--format", "json"], homeRoot: homeRoot, extraEnv: extraEnv)
        #expect(res.exitCode == 0)
        let payloads = try #require(JSONSerialization.jsonObject(with: res.stdout) as? [[String: Any]])
        return try #require(payloads.first)
    }

    static func costText(_ args: [String] = [], in homeRoot: URL) throws -> String {
        let res = try self.runCostCLI(args + ["--no-color"], homeRoot: homeRoot)
        #expect(res.exitCode == 0)
        return String(data: res.stdout, encoding: .utf8) ?? ""
    }

    @discardableResult
    static func db(
        _ fixture: AntigravityLocalFixture,
        _ session: String,
        model: String = "gemini-2.5-pro",
        input: UInt64 = 100,
        seconds: UInt64 = 1_787_832_000,
        root: Int = 0,
        ws: String? = nil,
        mtime: Date? = nil) throws -> URL
    {
        let meta = ws.map { AntigravityLocalFixture.trajectoryMetadataBlob(workspaces: [.init(workspaceURI: $0)]) }
        let blob = AntigravityLocalFixture.blob(model: model, input: input, output: 30, seconds: seconds)
        let url = try fixture.database(session, rootIndex: root, blobs: [blob], trajectoryMetadataBlob: meta)
        if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
        return url
    }

    static func writeWAL(
        at url: URL,
        blobs: [[UInt8]],
        createTable: Bool = false,
        dbDate: Date? = nil,
        walDate: Date? = nil) throws
    {
        let db = try AntigravityLocalFixture.open(url)
        defer { sqlite3_close(db) }
        let prefix = createTable ? "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB); " : ""
        let mode = walDate != nil ? "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0" : ""
        if !prefix.isEmpty || !mode.isEmpty { try AntigravityLocalFixture.execute(db, prefix + mode) }
        for (idx, blob) in blobs.enumerated() {
            try AntigravityLocalFixture.insert(db, row: Int64(idx), blob: blob)
        }
        if let dbDate { try FileManager.default.setAttributes([.modificationDate: dbDate], ofItemAtPath: url.path) }
        if let walDate {
            try FileManager.default.setAttributes([.modificationDate: walDate], ofItemAtPath: url.path + "-wal")
        }
    }

    typealias Fix = AntigravityLocalFixture

    static func walDB(_ f: Fix, _ s: String, blobs: [[UInt8]], ws: String? = nil, db: Date, wal: Date) throws -> URL {
        let m = ws.map { Fix.trajectoryMetadataBlob(workspaces: [.init(workspaceURI: $0)]) }
        let url = try f.database(s, blobs: [], trajectoryMetadataBlob: m)
        try self.writeWAL(at: url, blobs: blobs, dbDate: db, walDate: wal)
        return url
    }

    static func payload(_ usage: UsageSnapshot, source: String = "oauth", email: String? = nil) -> ProviderPayload {
        ProviderPayload(
            provider: .antigravity,
            account: email,
            version: nil,
            source: source,
            status: nil,
            usage: usage,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
    }

    static func payloadJSON(_ usage: UsageSnapshot, source: String = "oauth") throws -> [String: Any] {
        let p = self.payload(usage, source: source, email: usage.identity?.accountEmail)
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
    }

    static func cliText(_ usage: UsageSnapshot, now: Date = Date()) -> String {
        let ctx = RenderContext(header: "AG", status: nil, useColor: false, resetStyle: .countdown)
        return CLIRenderer.renderText(provider: .antigravity, snapshot: usage, credits: nil, context: ctx, now: now)
    }

    static func cardModel(
        _ usage: UsageSnapshot,
        showOptional: Bool = true,
        now: Date = Date()) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.antigravity])
        let input = UsageMenuCardView.Model.Input(
            provider: .antigravity,
            metadata: metadata,
            snapshot: usage,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: showOptional,
            hidePersonalInfo: false,
            now: now)
        return UsageMenuCardView.Model.make(input)
    }

    @MainActor
    static func menuDesc(_ ctx: StoreContext, actions: Bool = false) -> MenuDescriptor {
        MenuDescriptor.build(
            provider: .antigravity,
            store: ctx.store,
            settings: ctx.settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: actions)
    }

    @MainActor
    static func menuLines(_ ctx: StoreContext) -> [String] {
        self.menuDesc(ctx).sections.flatMap(\.entries).compactMap {
            if case let .text(t, _) = $0 {
                t
            } else { nil }
        }
    }

    @MainActor
    static func hasDashboard(_ ctx: StoreContext) -> Bool {
        self.menuDesc(ctx, actions: true).sections.flatMap(\.entries).contains {
            if case .action(_, .dashboard) = $0 { return true }
            return false
        }
    }

    @MainActor
    static func visibleSeries(
        _ ctx: StoreContext,
        now: Date = Date(),
        extra: [PlanUtilizationSeriesHistory] = []) -> [String]
    {
        let hists = ctx.store.planUtilizationHistory(for: .antigravity) + extra
        let snap = ctx.store.snapshot(for: .antigravity)
        return PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: hists,
            provider: .antigravity,
            snapshot: snap,
            referenceDate: now).visibleSeries
    }

    @MainActor
    static func burndown(
        _ ctx: StoreContext,
        histories: [PlanUtilizationSeriesHistory]? = nil,
        now: Date = Date()) -> QuotaBurndownChartMenuView
    {
        QuotaBurndownChartMenuView(
            provider: .antigravity,
            histories: histories ?? ctx.store.planUtilizationHistory(for: .antigravity),
            snapshot: ctx.store.snapshot(for: .antigravity),
            width: 400,
            referenceDate: now)
    }

    static func dashboardWindowLabels(_ snap: UsageSnapshot, now: Date = Date()) throws -> [String] {
        let cfg = CodexBarConfig(providers: [ProviderConfig(id: .antigravity, enabled: true)])
        let dash = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [self.payload(snap)],
            costPayloads: [],
            config: cfg,
            identityMode: .redacted,
            generatedAt: now,
            refreshInterval: 60,
            codexBarVersion: nil)
        let dashData = try #require(CodexBarCLI.encodeJSON(dash, pretty: false)?.data(using: .utf8))
        let dashObj = try #require(JSONSerialization.jsonObject(with: dashData) as? [String: Any])
        let wins = try #require((dashObj["providers"] as? [[String: Any]])?.first?["windows"] as? [[String: Any]])
        return wins.compactMap { $0["label"] as? String }
    }

    static func tokenSnapshot(
        from rep: AntigravityLocalReader.DailyReportResult,
        provenance: CostProvenance = .unknown) -> CostUsageTokenSnapshot
    {
        CostUsageFetcher.tokenSnapshot(
            from: rep.report,
            now: AntigravityLocalFixture.now,
            historyDays: 30,
            useCurrentLocalDayForSession: true,
            calendar: AntigravityLocalFixture.calendar,
            historyCoverageIsEstablished: rep.isComplete,
            historyScanIsPartial: !rep.isComplete,
            costProvenance: provenance,
            projects: rep.projects,
            sessions: rep.sessions,
            detailsAreComplete: rep.isComplete)
    }

    @MainActor
    static func card(_ ctx: StoreContext, now: Date = Date()) -> UsageMenuCardView.Model {
        ctx.store.menuCardModel(for: .antigravity, context: .menu, now: now)
    }

    static func discover(
        _ fixture: AntigravityLocalFixture,
        limits: AntigravityLocalReader.Limits = .init()) throws -> AntigravityLocalReader.Discovery
    {
        try AntigravityLocalReader.discover(
            roots: fixture.context.databaseRoots,
            extension: "db",
            budget: AntigravityLocalReader.Budget(limits: limits, cancellation: {}),
            dayRange: ("2026-07-29", "2026-08-27"),
            calendar: AntigravityLocalFixture.calendar)
    }

    static func calDate(_ key: String) throws -> Date {
        try #require(CostUsageLocalDay.date(fromKey: key, calendar: AntigravityLocalFixture.calendar))
    }

    static func limits(_ apply: (inout AntigravityLocalReader.Limits) -> Void) -> AntigravityLocalReader.Limits {
        var l = AntigravityLocalReader.Limits()
        apply(&l)
        return l
    }

    @MainActor static func flushHistory(_ ctx: StoreContext, minSeries: Int = 4) async {
        for _ in 0..<40 {
            let b = ctx.historyStore.load()[UsageProvider.antigravity.instanceID]
            if let b, let k = b.preferredAccountKey, b.histories(for: k).count >= minSeries { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @MainActor static func seedPreFeatureWeekly(_ ctx: StoreContext, now: Date, used: Double = 90) throws {
        let id = ProviderIdentitySnapshot(
            providerID: .antigravity,
            accountEmail: "parity-user@example.com",
            accountOrganization: nil,
            loginMethod: nil)
        let snap = UsageSnapshot(primary: nil, secondary: nil, updatedAt: now, identity: id)
        let key = try #require(UsageStore._planUtilizationAccountKeyForTesting(provider: .antigravity, snapshot: snap))
        var seeded = PlanUtilizationHistoryBuckets()
        let e = PlanUtilizationHistoryEntry(capturedAt: now.addingTimeInterval(-7200), usedPercent: used, resetsAt: nil)
        let h = [PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [e])]
        seeded.setHistories(h, for: key)
        ctx.store.planUtilizationHistory[.antigravity] = seeded
    }
}

// MARK: - AntigravityParityE2ETests

@Suite(.serialized)
struct AntigravityParityE2ETests {
    private typealias Harness = AntigravityParityHarness

    // MARK: Tier 1: F1, F2, & F3

    @Test @MainActor func `OAuth returns four quota windows and reset times`() async throws {
        let summary = Harness.fourBucketSummary(g5h: 0.72, gw: 0.61, c5h: 0.85, cw: 0.40)
        try await Harness.runRefresh(summaryDict: summary) { _, snap in
            let wins = try #require(snap.extraRateWindows)
            #expect(wins.map(\.id) == [
                "antigravity-quota-summary-gemini-5h", "antigravity-quota-summary-gemini-weekly",
                "antigravity-quota-summary-3p-5h", "antigravity-quota-summary-3p-weekly",
            ])
            #expect(wins.map { Int($0.window.usedPercent.rounded()) } == [28, 39, 15, 60]
                && wins.map(\.window.windowMinutes) == [300, 10080, 300, 10080]
                && wins.allSatisfy { $0.window.resetsAt != nil })
        }
    }

    @Test @MainActor func `menu card CLI text and dashboard render four quota lanes`() async throws {
        let now = Date()
        try await Harness.runRefresh(summaryDict: Harness.fourBucketSummary(now: now)) { ctx, snap in
            let card = Harness.card(ctx, now: now)
            #expect(card.metrics.map(\.percentLabel) == ["75% left", "60% left", "80% left", "50% left"]
                && card.metrics.allSatisfy { $0.resetText != nil })
            let text = Harness.cliText(snap, now: now)
            #expect(text.contains("Gemini 5-hour: 75% left") && text.contains("Claude/GPT weekly: 50% left"))
            let labels = try Harness.dashboardWindowLabels(snap, now: now)
            #expect(labels == ["Gemini 5-hour", "Gemini weekly", "Claude/GPT 5-hour", "Claude/GPT weekly"])
        }
    }

    @Test(arguments: ["session", "5h", "5-hour", "five-hour"])
    @MainActor
    func `cadence aliases normalize to five hour window`(alias: String) async throws {
        let sum = Harness.singleSummary(cadence: alias, frac: 0.65, resetOffset: nil)
        try await Harness.runRefresh(summary: sum) { _, s in
            let window = try #require(s.extraRateWindows?.first)
            #expect(window.window.windowMinutes == 300 && window.title == "Gemini 5-hour")
        }
    }

    @Test @MainActor func `primary pool preference reorders menu card lead metric`() async throws {
        try await Harness.withStore { ctx in
            ctx.settings.antigravityPrimaryPoolPreference = .claudeGPTWeekly
            try await Harness.refresh(ctx)
            #expect(Harness.card(ctx).metrics.first?.id == "antigravity-quota-summary-3p-weekly")
        }
    }

    @Test @MainActor func `multi refresh persists four series and renders utilization charts`() async throws {
        try await Harness.withStore { ctx in
            let now = Date()
            let priorData = GeminiAPITestHelpers.jsonData(
                Harness.fourBucketSummary(g5h: 0.90, gw: 0.85, c5h: 0.95, cw: 0.80, now: now))
            let prior = try AntigravityStatusProbe.parseQuotaSummaryResponse(priorData).toUsageSnapshot()
            await ctx.store.recordPlanUtilizationHistorySample(
                provider: .antigravity, snapshot: prior, now: now.addingTimeInterval(-3600))
            try await Harness.refresh(ctx, summaryDict: Harness.fourBucketSummary(now: now))
            await Harness.flushHistory(ctx)
            let histories = ctx.store.planUtilizationHistory(for: .antigravity)
            #expect(Set(histories.map(\.name))
                == [.session, .weekly, .antigravityClaudeGPTSession, .antigravityClaudeGPTWeekly])
            #expect(Set(Harness.visibleSeries(ctx, now: now)) == [
                "session:300", "weekly:10080", "antigravityClaudeGPTSession:300", "antigravityClaudeGPTWeekly:10080",
            ])
            let bd = Harness.burndown(ctx, histories: histories, now: Date())
            #expect(bd.hasSeries && bd._seriesRemainingForTesting["antigravityClaudeGPTWeekly:10080"] == 50)
            #expect(ctx.historyStore.load()[UsageProvider.antigravity.instanceID]?.accounts.isEmpty == false)
        }
    }

    @Test(arguments: ["5h", "weekly"])
    @MainActor
    func `single cadence Gemini snapshots record independently`(cadence: String) async throws {
        try await Harness.withStore { ctx in
            let isSession = cadence == "5h"
            try await Harness.refresh(ctx, summary: Harness.singleSummary(cadence: cadence))
            let histories = ctx.store.planUtilizationHistory(for: .antigravity)
            #expect(histories.map(\.name) == [isSession ? .session : .weekly])
            #expect(Harness.visibleSeries(ctx) == [isSession ? "session:300" : "weekly:10080"])
            #expect(Harness.burndown(ctx, histories: histories).hasSeries)
        }
    }

    @Test(arguments: ["transition", "reload"])
    @MainActor
    func `Claude GPT transitions and disk reloads drive utilization charts`(mode: String) async throws {
        try await Harness.withStore { ctx in
            try await Harness.refresh(ctx, summaryDict: Harness.fourBucketSummary(c5h: 1.0, cw: 1.0))
            #expect(Harness.visibleSeries(ctx) == ["session:300", "weekly:10080"])
            let now = Date()
            try await Harness.refresh(ctx, summaryDict: Harness.fourBucketSummary(c5h: 0.6, cw: 0.5, now: now))
            await Harness.flushHistory(ctx)
            if mode == "transition" {
                #expect(Harness.visibleSeries(ctx, now: now).count == 4)
            } else {
                let snap = try Harness.snap(ctx)
                let key = try #require(UsageStore._planUtilizationAccountKeyForTesting(
                    provider: .antigravity, snapshot: snap))
                let reloaded = ctx.historyStore.load()[UsageProvider.antigravity.instanceID]?.histories(for: key) ?? []
                #expect(Harness.burndown(ctx, histories: reloaded, now: now)._seriesTitlesForTesting.count == 4)
            }
        }
    }

    @Test(arguments: [
        ("g1-ultra-tier", "Google AI Ultra"), ("g1-ultra-lite-tier", "Google AI Ultra Lite"),
        ("g1-pro-tier", "Google AI Pro"), ("g1-plus-tier", "Google AI Plus"),
        ("GOOGLE_ONE_HELIUM", "Google AI Ultra"),
    ])
    @MainActor
    func `subscription tier mapping flows to store card and JSON`(tierID: String, expected: String) async throws {
        let load = tierID == "GOOGLE_ONE_HELIUM"
            ? #"{"g1Tier":"GOOGLE_ONE_HELIUM","currentTier":{"id":"standard-tier"}}"#
            : #"{"paidTier":{"id":"\#(tierID)"}}"#
        try await Harness.runRefresh(load: load) { ctx, snap in
            #expect(snap.identity?.loginMethod == expected && Harness.card(ctx).planText == expected)
            let u = try Harness.payloadJSON(snap)["usage"] as? [String: Any]
            #expect((u?["identity"] as? [String: Any])?["loginMethod"] as? String == expected)
        }
    }

    @Test @MainActor func `manage and upgrade URIs surface dashboard email and credits`() async throws {
        try await Harness.withStore(email: "ultra-e2e@example.com") { ctx in
            let load = #"{"paidTier":{"id":"g1-ultra-tier","#
                + #""manageSubscriptionUri":"https://one.google.com/subscriptions","#
                + #""availableCredits":[{"creditType":"GOOGLE_ONE_AI","creditAmount":"250"}]}}"#
            try await Harness.refresh(ctx, load: load)
            #expect(try Harness.dashURL(ctx) == "https://one.google.com/subscriptions"
                && Harness.card(ctx).email == "ultra-e2e@example.com" && Harness.hasDashboard(ctx)
                && Harness.cliText(Harness.snap(ctx)).contains("Google One credits: 250 remaining"))
            let upg = #"{"paidTier":{"id":"g1-pro-tier","upgradeSubscriptionUri":"https://one.google.com/upgrade"}}"#
            try await Harness.refresh(ctx, load: upg)
            #expect(try Harness.dashURL(ctx) == "https://one.google.com/upgrade")
        }
    }

    // MARK: Tier 1: F4, F5, F6, F7, & F8

    @Test @MainActor func `remaining amount and model availabilities flow to card CLI and JSON`() async throws {
        let avail: [String: Any] = [
            "gemini-3-flash": ["state": "MODEL_AVAILABILITY_STATE_OPERATIONAL"],
            "gemini-3.1-pro": ["state": "MODEL_AVAILABILITY_STATE_CONGESTED", "explanation": "Regional load"],
        ]
        try await Harness.runRefresh(
            summaryDict: Harness.fourBucketSummary(g5hAmt: "170", c5hAmt: 42, avail: avail))
        { ctx, snap in
            #expect(snap.antigravityCatalog?.bucketAmounts?.map(\.remainingAmount) == [170, 42]
                && snap.antigravityCatalog?.modelAvailabilities?["gemini-3-flash"]?.state
                == "MODEL_AVAILABILITY_STATE_OPERATIONAL")
            let details = Harness.card(ctx).providerDetails
            #expect(details.first { $0.title == "Bucket amounts" }?.rows.map(\.value) == [
                "170 remaining",
                "42 remaining",
            ])
            #expect(details.first { $0.title == "Model availability" }?.rows.first?.secondaryValue == "Regional load"
                && Harness.cliText(snap).contains("170 remaining"))
            let u = try Harness.payloadJSON(snap)["usage"] as? [String: Any]
            #expect(((u?["antigravityCatalog"] as? [String: Any])?["bucketAmounts"] as? [[String: Any]])?.count == 2)
        }
    }

    @Test(arguments: ["oneof", "cli-snake-case", "403-fallback", "verified-merge"])
    @MainActor
    func `remaining amount decodes across summary and fallback modes`(mode: String) async throws {
        switch mode {
        case "oneof":
            let sum = #"{"buckets":[{"bucketId":"g5h","displayName":"5h","refreshWindowLabel":"5h","#
                + #""remaining":{"case":"remainingFraction","value":0.6},"remainingAmount":"300"},"#
                + #"{"bucketId":"c5h","displayName":"5h","refreshWindowLabel":"5h","#
                + #""remainingFraction":0.8,"remaining":{"case":"remainingAmount","value":40}}]}"#
            try await Harness.runRefresh(summary: sum) { _, snap in
                #expect(snap.antigravityCatalog?.bucketAmounts?.map(\.remainingAmount) == [300, 40])
            }
        case "cli-snake-case":
            let b = #"{"id":"g5h","name":"5h","window":"5h","remaining_fraction":0.6,"remaining_amount":"300"},"#
                + #"{"id":"c5h","name":"5h","window":"5h","remaining_fraction":0.8,"#
                + #""remaining":{"case":"remaining_amount","value":"40"}}"#
            let fetched = try await Harness.fetchAgyJSON(Harness.agyUsage([("Gemini Models", "M", b)]))
            #expect(fetched.result.usage.antigravityCatalog?.bucketAmounts?.map(\.remainingAmount) == [300, 40])
        case "403-fallback":
            let q = #"{"buckets":[{"modelId":"g3p","remainingFraction":0.4,"remainingAmount":"120"}]}"#
            try await Harness.runRefresh(summaryStatus: 403, summary: "{}", modelsStatus: 403, models: "{}", quota: q) {
                #expect($1.antigravityCatalog?.bucketAmounts?.first?.remainingAmount == 120)
            }
        default:
            let m = Harness.mod(#""gemini-3-pro":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":1.0}}"#)
            let q = #"{"buckets":[{"modelId":"gemini-3-pro","remainingFraction":0.55,"remainingAmount":"88"}]}"#
            try await Harness.runRefresh(summaryStatus: 404, summary: "{}", models: m, quota: q) { _, merged in
                #expect(Int((merged.primary?.usedPercent ?? -1).rounded()) == 45
                    && merged.antigravityCatalog?.bucketAmounts?.first?.remainingAmount == 88)
            }
        }
    }

    @Test(arguments: [
        ("1", "MODEL_PRICING_TYPE_STATIC_CREDIT", "Static credit"),
        ("2", "MODEL_PRICING_TYPE_API", "API"), ("3", "MODEL_PRICING_TYPE_BYOK", "BYOK"),
    ])
    @MainActor
    func `pricing codes and catalog attributes flow to menu card`(
        raw: String, canonical: String, humanized: String) async throws
    {
        let m = Harness.mod(#""g3p":{"displayName":"Gemini 3 Pro","creditMultiplier":1.5,"#
            + #""pricingType":"\#(raw)","isPremium":true,"tagTitle":"New"}"#)
        try await Harness.runRefresh(models: m) { ctx, snap in
            let entry = try #require(snap.antigravityCatalog?.modelCatalog?.first)
            #expect(entry.pricingType == canonical && entry.creditMultiplier == 1.5)
            let row = try #require(Harness.card(ctx).providerDetails.first { $0.title == "Model catalog" }?.rows.first)
            #expect(row.value == "1.5× · \(humanized)" && row.secondaryValue == "Premium · New")
            let u = try Harness.payloadJSON(snap)["usage"] as? [String: Any]
            #expect((u?["antigravityCatalog"] as? [String: Any])?["modelCatalog"] != nil)
        }
    }

    @Test(arguments: ["local-configs", "with-identity", "oauth-snake-case"])
    @MainActor
    func `catalog attributes decode and merge across sources`(mode: String) async throws {
        switch mode {
        case "local-configs":
            let json = #"{"clientModelConfigs":[{"label":"Claude Opus 4.6","#
                + #""model_or_alias":{"model":"claude-opus-4-6"},"quota_info":{"remaining_fraction":0.7},"#
                + #""credit_multiplier":"2.0","pricing_type":2,"premium":true,"tag_title":"Thinking"}]}"#
            let entry = try #require(try AntigravityStatusProbe.parseCommandModelResponse(
                Data(json.utf8)).toUsageSnapshot().antigravityCatalog?.modelCatalog?.first)
            #expect(entry.creditMultiplier == 2.0 && entry.pricingType == "MODEL_PRICING_TYPE_API")
        case "with-identity":
            let base = try AntigravityStatusProbe.parseQuotaSummaryResponse(
                GeminiAPITestHelpers.jsonData(Harness.fourBucketSummary()))
            let item = AntigravityModelCatalogEntry(
                modelId: "gemini-3.1-pro",
                label: "Gemini 3.1 Pro",
                creditMultiplier: 1.25,
                pricingType: "MODEL_PRICING_TYPE_STATIC_CREDIT",
                isPremium: true,
                tagTitle: "New")
            let extra = AntigravityStatusSnapshot(
                modelQuotas: [],
                accountEmail: "a@example.com",
                accountPlan: "Google AI Ultra",
                modelCatalog: [item])
            let cat = try base.withIdentity(from: extra).toUsageSnapshot().antigravityCatalog
            #expect(cat?.modelCatalog?.first?.modelId == "gemini-3.1-pro")
        default:
            try await Harness.withStore { ctx in
                let m = Harness.mod(#""claude-opus-4-6":{"label":"Claude Opus 4.6","credit_multiplier":"2.0","#
                    + #""pricing_type":2,"premium":true,"tag_title":"Thinking"}"#)
                try await Harness.refresh(ctx, models: m)
                let entry = try #require(Harness.snap(ctx).antigravityCatalog?.modelCatalog?.first)
                #expect(entry.isPremium == true && entry.tagTitle == "Thinking")
            }
        }
    }

    @Test(arguments: ["sorted-rosters", "models-vs-prose", "cli-flags"])
    func `agy subprocess parses group rosters across formats`(mode: String) async throws {
        func b(_ id: String, _ frac: Double) -> String {
            #"{"id":"\#(id)","window":"5h","remaining_fraction":\#(frac)}"#
        }
        let g = [
            ("Gemini 4 Argon", "For paid Pro plans, Argon quota is separate.", b("a", 0.9)),
            ("Claude and GPT models", "Models within this group: Claude Sonnet 4.6, GPT-OSS 120B", b("c", 0.7)),
            ("Gemini Models", "Models within this group: Gemini 3.1 Pro, Gemini 3 Flash", b("g", 0.8)),
        ]
        let fetched = try await Harness.fetchAgyJSON(Harness.agyUsage(g))
        let parsed = try #require(fetched.result.usage.antigravityCatalog?.quotaGroups)
        switch mode {
        case "sorted-rosters":
            #expect(parsed.map(\.displayName) == ["Gemini Models", "Claude and GPT models", "Gemini 4 Argon"])
            let u = try Harness.payloadJSON(fetched.result.usage, source: "cli")["usage"] as? [String: Any]
            #expect((u?["antigravityCatalog"] as? [String: Any])?["quotaGroups"] != nil)
        case "models-vs-prose":
            #expect(parsed[0].models == ["Gemini 3.1 Pro", "Gemini 3 Flash"] && parsed[2].models.isEmpty)
            let rows = try #require(fetched.result.usage.details.first { $0.title == "Quota groups" }?.rows)
            #expect(rows.map(\.value) == [
                "Gemini 3.1 Pro, Gemini 3 Flash", "Claude Sonnet 4.6, GPT-OSS 120B",
                "For paid Pro plans, Argon quota is separate.",
            ])
        default:
            let cli = Harness.cliText(fetched.result.usage)
            #expect(fetched.args == "-p /usage --output-format json --print-timeout 90s"
                && cli.contains("Gemini 3.1 Pro, Gemini 3 Flash"))
        }
    }

    @Test(arguments: [false, true])
    @MainActor
    func `optional details toggle gates menu card while CLI remains full`(showOptional: Bool) async throws {
        let load = #"{"paidTier":{"id":"g1-ultra-tier","availableCredits":"#
            + #"[{"creditType":"GOOGLE_ONE_AI","creditAmount":"250"}]}}"#
        let av: [String: Any] = ["gemini-3.1-pro": ["state": "MODEL_AVAILABILITY_STATE_CONGESTED"]]
        let models = Harness
            .mod(#""gemini-3.1-pro":{"displayName":"Gemini 3.1 Pro","creditMultiplier":1.5,"isPremium":true}"#)
        try await Harness.runRefresh(
            showOptional: showOptional,
            load: load,
            summaryDict: Harness.fourBucketSummary(g5hAmt: "100", avail: av),
            models: models)
        { ctx, snap in
            let expected = showOptional
                ? ["Credits", "Model availability", "Bucket amounts", "Quota groups", "Model catalog"]
                : ["Model availability", "Bucket amounts"]
            #expect(Harness.card(ctx).providerDetails.map(\.title) == expected)
            let cli = Harness.cliText(snap)
            #expect(cli.contains("Gemini 3.1 Pro, Gemini 3 Flash") && cli.contains("1.5×"))
        }
    }

    @Test(arguments: ["limits", "day-range", "wal-rescue", "multi-root"])
    func `local scan honors limits day range WAL rescue and multi root`(mode: String) throws {
        let limits = AntigravityLocalReader.Limits()
        if mode == "limits" {
            #expect(limits.databases == 2000 && limits.directoryEntries == 20000)
            #expect(limits.rows == 500_000 && limits.bytes == 2 * 1024 * 1024 * 1024 && limits.duration == 120)
            return
        }
        let fixture = try AntigravityLocalFixture()
        let sinceDate = try Harness.calDate("2026-07-29")
        let old = sinceDate.addingTimeInterval(-86400), fresh = sinceDate.addingTimeInterval(3600)
        try Harness.db(fixture, "stale", mtime: sinceDate.addingTimeInterval(-3600))
        if mode == "day-range" {
            try Harness.db(fixture, "plain-fresh", input: 120, mtime: fresh)
        } else {
            let blob = AntigravityLocalFixture.blob(input: 120, seconds: 1_787_832_000)
            _ = try Harness.walDB(fixture, "wal-rescued", blobs: [blob], db: old, wal: fresh)
            if mode == "multi-root" { try Harness.db(fixture, "desktop-conv", root: 2) }
        }
        let discovery = try Harness.discover(fixture, limits: limits)
        let report = try fixture.report(includeBreakdowns: true, dayRange: ("2026-07-29", "2026-08-27"))
        #expect(discovery.skippedOldDatabases == 1 && report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == (mode == "multi-root" ? 207 + 187 : 207))
    }

    @Test func `CLI cost subprocess scans synthetic home with pricing cache`() throws {
        let fixture = try AntigravityLocalFixture()
        let nowSec = UInt64(Date().timeIntervalSince1970)
        try Harness.db(fixture, "priced-cli", seconds: nowSec, ws: "file:///tmp/parity-proj")
        try Harness.db(fixture, "priced-desktop", model: "claude-sonnet-4-6", seconds: nowSec, root: 2)
        try Harness.seedPricing(in: fixture.root)
        let first = try Harness.costJSON(in: fixture.root)
        #expect(first["source"] as? String == "local" && first["historyCoverageIsEstablished"] as? Bool == true)
        #expect(first["last30DaysTokens"] as? Int == 374 && (first["last30DaysCostUSD"] as? Double ?? 0) > 0)
    }

    @Test(arguments: ["databases", "rows", "bytes"])
    func `graceful capping modes preserve newest local breakdowns`(mode: String) throws {
        let fixture = try AntigravityLocalFixture()
        let base = AntigravityLocalFixture.now.addingTimeInterval(-300)
        let blobSize = AntigravityLocalFixture.blob(input: 100).count
        for (idx, name) in ["oldest", "middle", "newest"].enumerated() {
            let ws = "file:///tmp/\(name)-repo"
            let mt = base.addingTimeInterval(Double(idx) * 60)
            try Harness.db(fixture, name, input: UInt64(100 + idx * 10), ws: ws, mtime: mt)
        }
        let limits = switch mode {
        case "databases": Harness.limits { $0.databases = 2 }
        case "rows": Harness.limits { $0.rows = 2 }
        default: Harness.limits { $0.bytes = blobSize * 2 }
        }
        let rep = try fixture.report(limits: limits, includeBreakdowns: true)
        let snap = Harness.tokenSnapshot(from: rep)
        #expect(rep.coverage == .partial && !snap.historyCoverageIsEstablished && snap.historyScanIsPartial)
        #expect(Set(snap.projects.map(\.name)) == ["middle-repo", "newest-repo"])
        #expect(Set(snap.sessions.map(\.sessionID)) == ["middle", "newest"])
    }

    @Test(arguments: ["project", "session"])
    func `CLI cost outputs project and session groupings`(groupBy: String) throws {
        let fixture = try AntigravityLocalFixture()
        let sec = UInt64(Date().timeIntervalSince1970)
        try Harness.db(fixture, "cascade-session-abcdef", seconds: sec, ws: "file:///tmp/e2e-project")
        try Harness.seedPricing(in: fixture.root)
        if groupBy == "project" {
            let first = try Harness.costJSON(["--group-by", "project"], in: fixture.root)
            #expect((first["projects"] as? [[String: Any]])?.first?["name"] as? String == "e2e-project")
        }
        let text = try Harness.costText(["--group-by", groupBy], in: fixture.root)
        #expect(groupBy == "project"
            ? (text.contains("Projects (Last 30 days):") && text.contains("e2e-project:"))
            : (text.contains("Conversations (Last 30 days):") && text.contains("187 tokens")))
    }
}

// MARK: - AntigravityParityE2ETests + Tier2

extension AntigravityParityE2ETests {
    // MARK: Tier 2: F1 & F2 Boundaries

    @Test(arguments: ["5h", "weekly"])
    @MainActor
    func `single cadence Gemini shapes primary window and pace visibility`(cadence: String) async throws {
        let isSession = cadence == "5h"
        try await Harness.runRefresh(summary: Harness.singleSummary(cadence: cadence, frac: 0.6, resetOffset: nil)) {
            #expect($1.extraRateWindows?.count == 1 && $1.secondary == nil)
            #expect($1.primary?.windowMinutes == (isSession ? 300 : 10080))
            if !isSession { #expect(!Harness.menuLines($0).contains { $0.hasPrefix("Pace:") }) }
        }
    }

    @Test(arguments: ["disabled", "unknown-cadence", "all-idle"])
    func `disabled buckets unknown cadence and all idle snapshots hold boundaries`(mode: String) throws {
        switch mode {
        case "disabled":
            let d = #"{"groups":[{"displayName":"Gemini Models","buckets":"#
                + #"[{"bucketId":"g-5h","displayName":"5-hour","disabled":true,"remainingFraction":0.3}]}]}"#
            let usage = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(d.utf8)).toUsageSnapshot()
            #expect(usage.extraRateWindows?.first?.usageKnown == false)
            let text = Harness.cliText(usage)
            #expect(text.contains("Gemini 5-hour: Unavailable") && !text.contains("30% left"))
        case "unknown-cadence":
            let d = #"{"groups":[{"displayName":"Gemini Models","buckets":"#
                + #"[{"bucketId":"g-custom","displayName":"Custom allowance","remainingFraction":0.5}]}]}"#
            let usage = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(d.utf8)).toUsageSnapshot()
            #expect(usage.extraRateWindows?.first?.window.windowMinutes == nil)
        default:
            let data = GeminiAPITestHelpers.jsonData(Harness.fourBucketSummary(g5h: 1.0, gw: 1.0, c5h: 1.0, cw: 1.0))
            let text = try Harness.cliText(AntigravityStatusProbe.parseQuotaSummaryResponse(data).toUsageSnapshot())
            #expect(text.contains("Gemini 5-hour: 100% left") && text.contains("Claude/GPT weekly: 100% left"))
        }
    }

    @Test @MainActor func `pre feature weekly history drops when structured session arrives`() async throws {
        try await Harness.withStore { ctx in
            try Harness.seedPreFeatureWeekly(ctx, now: Date(), used: 90)
            try await Harness.refresh(ctx, summaryDict: Harness.fourBucketSummary(g5h: 0.75, gw: 0.80))
            let weekly = ctx.store.planUtilizationHistory(for: .antigravity).first { $0.name == .weekly }?.entries ?? []
            #expect(weekly.count == 1 && Int(weekly[0].usedPercent.rounded()) == 20)
        }
    }

    @Test(arguments: ["5h", "weekly"])
    @MainActor
    func `structured single cadence suppresses observations and disables forecast`(cadence: String) async throws {
        try await Harness.withStore { ctx in
            let now = Date()
            try await Harness.refresh(
                ctx,
                summary: Harness.singleSummary(cadence: cadence, frac: 0.6, resetOffset: nil))
            let snap = try Harness.snap(ctx)
            #expect(UsageStore.antigravityQuotaObservationSamples(snapshot: snap, capturedAt: now).isEmpty)
            #expect(Harness.card(ctx, now: now).metrics.allSatisfy { $0.sessionEquivalentDetail == nil })
            let staleEntry = PlanUtilizationHistoryEntry(
                capturedAt: now.addingTimeInterval(3600), usedPercent: 90, resetsAt: nil)
            let staleObs = PlanUtilizationSeriesHistory(
                name: .antigravityGemini,
                windowMinutes: 0,
                entries: [staleEntry])
            #expect(!Harness.visibleSeries(ctx, now: now, extra: [staleObs]).contains("antigravityGemini:0"))
        }
    }

    @Test(arguments: ["idle-persisted", "expired-reset"])
    @MainActor
    func `idle Claude GPT persists and expired resets exclude from burndown`(mode: String) async throws {
        try await Harness.withStore { ctx in
            let now = Date()
            try await Harness.refresh(ctx, summaryDict: Harness.fourBucketSummary(c5h: 1.0, cw: 1.0, now: now))
            if mode == "idle-persisted" {
                #expect(ctx.store.planUtilizationHistory(for: .antigravity)
                    .contains { $0.name == .antigravityClaudeGPTSession })
            } else {
                let sE = PlanUtilizationHistoryEntry(
                    capturedAt: now,
                    usedPercent: 30,
                    resetsAt: now.addingTimeInterval(-60))
                let wE = PlanUtilizationHistoryEntry(
                    capturedAt: now, usedPercent: 40, resetsAt: now.addingTimeInterval(86400))
                let expired = [
                    PlanUtilizationSeriesHistory(name: .session, windowMinutes: 300, entries: [sE]),
                    PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [wE]),
                ]
                #expect(Harness.burndown(ctx, histories: expired, now: now)._seriesTitlesForTesting
                    == ["weekly:10080": "Weekly"])
            }
        }
    }

    @Test(arguments: ["Pro", "Google AI Pro", "Paid"])
    @MainActor
    func `Ultra tier overrides generic paid tier display names`(rawName: String) async throws {
        let load = #"{"g1Tier":"G1_ULTRA_TIER","paidTier":{"id":"g1-ultra-tier","name":"\#(rawName)"}}"#
        try await Harness.runRefresh(load: load) { ctx, snap in
            #expect(snap.identity?.loginMethod == "Google AI Ultra" && Harness.card(ctx).planText == "Google AI Ultra")
            #expect(Harness.cliText(snap).lowercased().contains("google ai ultra"))
        }
    }

    @Test @MainActor
    func `free tier with five hour window strips free plan and applies G1 tier fallback`() async throws {
        try await Harness.withStore { ctx in
            let sum = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"g-5h","window":"5h","#
                + #""remainingFraction":0.5},{"bucketId":"g-w","window":"weekly","remainingFraction":0.75}]}]}"#
            try await Harness.refresh(ctx, load: #"{"currentTier":{"id":"free-tier","name":"Free"}}"#, summary: sum)
            let freeSnap = try Harness.snap(ctx)
            #expect(freeSnap.identity?.loginMethod == nil)
            #expect(freeSnap.extraRateWindows?.first { $0.window.windowMinutes == 10080 }?.window.usedPercent == 25)
            try await Harness.refresh(ctx, load: #"{"g1Tier":"GOOGLE_ONE_HELIUM","paidTier":{"name":"Google AI Pro"}}"#)
            #expect(try Harness.snap(ctx).identity?.loginMethod == "Google AI Ultra")
        }
    }

    @Test(arguments: [
        "http://one.google.com/insecure", "javascript:alert(1)", "https://:443/path", "https://user@/path",
    ])
    @MainActor
    func `invalid manage URI falls back to HTTPS upgrade or hides dashboard`(invalidURI: String) async throws {
        try await Harness.withStore { ctx in
            try await Harness.refresh(
                ctx, load: #"{"paidTier":{"id":"g1-pro-tier","manageSubscriptionUri":"\#(invalidURI)"}}"#)
            #expect(!Harness.hasDashboard(ctx))
            let load = #"{"paidTier":{"id":"g1-pro-tier","manageSubscriptionUri":"\#(invalidURI)","#
                + #""upgradeSubscriptionUri":"https://one.google.com/upgrade"}}"#
            try await Harness.refresh(ctx, load: load)
            #expect(try Harness.dashURL(ctx) == "https://one.google.com/upgrade")
        }
    }

    @Test(arguments: [
        "overflow-amount", "all-operational", "unspecified-numeric", "non-numeric-fallback", "empty-groups-fallback",
    ])
    @MainActor
    func `quota summary and fallback handle overflow and edge boundaries`(mode: String) async throws {
        switch mode {
        case "overflow-amount":
            let s = Harness.fourBucketSummary(g5hAmt: "99999999999999999999999", c5hAmt: "50")
            try await Harness.runRefresh(summaryDict: s) {
                #expect($1.antigravityCatalog?.bucketAmounts?.map(\.remainingAmount) == [50])
            }
        case "all-operational":
            let av: [String: Any] = [
                "gemini-3-flash": ["state": "MODEL_AVAILABILITY_STATE_OPERATIONAL"],
                "gemini-3.1-pro": ["state": "OPERATIONAL"],
            ]
            try await Harness.runRefresh(summaryDict: Harness.fourBucketSummary(avail: av)) { ctx, snap in
                #expect(snap.antigravityCatalog?.modelAvailabilities?.count == 2)
                #expect(!Harness.card(ctx).providerDetails.contains { $0.title == "Model availability" })
            }
        case "unspecified-numeric":
            let av: [String: Any] = [
                "m0": ["state": ""], "m1": ["state": "MODEL_AVAILABILITY_STATE_UNSPECIFIED"],
                "m2": ["state": 0], "m3": ["state": 1], "m4": ["state": "MODEL_AVAILABILITY_STATE_UNAVAILABLE"],
            ]
            try await Harness.runRefresh(summaryDict: Harness.fourBucketSummary(avail: av)) { _, snap in
                let avail = try #require(snap.details.first { $0.title == "Model availability" })
                #expect(avail.rows.count == 1 && avail.rows[0].value == "Unavailable")
            }
        case "non-numeric-fallback":
            let q = #"{"buckets":[{"modelId":"gemini-3-pro","remainingFraction":0.5,"remainingAmount":"abc"}]}"#
            try await Harness.runRefresh(summaryStatus: 403, summary: "{}", modelsStatus: 403, models: "{}", quota: q) {
                #expect(Int(($1.primary?.usedPercent ?? -1).rounded()) == 50)
                #expect($1.antigravityCatalog?.bucketAmounts == nil)
            }
        default:
            let m = Harness.mod(#""gemini-3-pro":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.3}}"#)
            try await Harness.runRefresh(summary: #"{"groups":[]}"#, models: m) { _, snap in
                #expect(Int((snap.primary?.usedPercent ?? -1).rounded()) == 70)
            }
        }
    }

    @Test(arguments: ["nan-inf-bad", "extreme-1e30", "quotaless", "http-500", "unspecified-omitted"])
    @MainActor
    func `catalog parsing handles non finite multipliers and error boundaries`(mode: String) async throws {
        switch mode {
        case "nan-inf-bad":
            let m = Harness.mod(#""m-ok":{"displayName":"OK","creditMultiplier":"1.5"},"#
                + #""m-nan":{"displayName":"NaN","creditMultiplier":"NaN","pricingType":"MODEL_PRICING_TYPE_API"},"#
                + #""m-inf":{"displayName":"Inf","creditMultiplier":"Infinity"},"#
                + #""m-bad":{"displayName":"Bad","creditMultiplier":"not-a-number"}"#)
            try await Harness.runRefresh(models: m) { _, snap in
                let cat = try #require(snap.antigravityCatalog?.modelCatalog)
                #expect(cat.count == 2 && cat.first { $0.modelId == "m-nan" }?.creditMultiplier == nil)
            }
        case "extreme-1e30":
            try await Harness
                .runRefresh(models: Harness.mod(#""m-huge":{"displayName":"Huge","creditMultiplier":1e30}"#)) {
                    #expect($1.details.first { $0.title == "Model catalog" }?.rows.first?.value.contains("×") == true)
                }
        case "quotaless":
            let m = Harness.mod(#""quotaless":{"displayName":"Quotaless","creditMultiplier":2.5,"isPremium":true}"#)
            try await Harness.runRefresh(summaryStatus: 404, summary: "{}", models: m) {
                #expect($1.antigravityCatalog?.modelCatalog?.map(\.modelId) == ["quotaless"]
                    && $1.extraRateWindows == nil)
            }
        case "http-500":
            try await Harness.runRefresh(modelsStatus: 500, models: "{}") {
                #expect($1.antigravityCatalog?.modelCatalog == nil && $0.store.error(for: .antigravity) == nil)
            }
        default:
            let m = Harness.mod(#""plain":{"displayName":"Plain","pricingType":"MODEL_PRICING_TYPE_UNSPECIFIED"}"#)
            try await Harness.runRefresh(models: m) { #expect($1.antigravityCatalog?.modelCatalog == nil) }
        }
    }

    @Test(arguments: ["section-caps", "decimals-sentence", "empty-desc", "no-marker-desc", "agy-unsupported-stderr"])
    func `roster caps decimal versions and agy CLI errors hold boundaries`(mode: String) async throws {
        typealias Avail = AntigravityModelAvailability
        typealias Amt = AntigravityQuotaBucketAmount
        typealias Roster = AntigravityQuotaGroupRoster
        typealias Entry = AntigravityModelCatalogEntry
        switch mode {
        case "section-caps":
            let aVal = Avail(state: "CONGESTED", explanation: nil)
            let av = Dictionary(uniqueKeysWithValues: (0..<30).map { ("m-\($0)", aVal) })
            let amts = (0..<30).map { Amt(bucketId: "b-\($0)", displayName: "B", groupName: nil, remainingAmount: $0) }
            let grps = (0..<30).map { Roster(displayName: "G\($0)", description: "M", models: ["M"], bucketIds: []) }
            let cats = (0..<30).map { Entry(modelId: "c-\($0)", label: "C", creditMultiplier: 1.5, isPremium: true) }
            let sum = AntigravityQuotaSummary(description: nil, groups: [], modelAvailabilities: av)
            let cat = AntigravityCatalogSnapshot(
                bucketAmounts: amts, modelAvailabilities: av, quotaGroups: grps, modelCatalog: cats)
            let cr = AntigravityCreditsSnapshot(prompt: .init(available: 100, used: 10, monthly: 110))
            let secs = AntigravityStatusSnapshot.detailSections(
                quotaSummary: sum, catalog: cat, credits: cr, showCredits: true)
            #expect(secs.count <= ProviderDetailSection.maximumSectionsPerSnapshot
                && secs.allSatisfy { $0.rows.count <= ProviderDetailSection.maximumRowsPerSection })
        case "decimals-sentence":
            let b = #"{"id":"g5h","name":"5h","window":"5h","remaining_fraction":0.8}"#
            let desc = "Models within this group: Gemini 3.1 Pro, Sonnet 3.5. Resets 5h."
            let body = Harness.agyUsage([("Gemini", desc, b)])
            #expect(try await Harness.fetchAgyJSON(body).result.usage.antigravityCatalog?.quotaGroups?.first?.models
                == ["Gemini 3.1 Pro", "Sonnet 3.5"])
        case "empty-desc":
            let b = #"{"id":"g5h","name":"5h","window":"5h","remaining_fraction":0.8}"#
            #expect(try await Harness.fetchAgyJSON(Harness.agyUsage([("Gemini", "   ", b)]))
                .result.usage.antigravityCatalog?.quotaGroups == nil)
        case "no-marker-desc":
            let b = #"{"id":"a5h","name":"5h","window":"5h","remaining_fraction":0.9}"#
            let res = try await Harness.fetchAgyJSON(Harness.agyUsage([("Argon", "Argon uses a dedicated pool.", b)]))
            #expect(res.result.usage.antigravityCatalog?.quotaGroups?.first?.models.isEmpty == true
                && res.result.usage.details.first { $0.title == "Quota groups" }?.rows.first?.value
                == "Argon uses a dedicated pool.")
        default:
            let oldStub = try Harness.makeAgyStub(reportBody: "{}", version: "1.1.10")
            let errStub = try Harness.makeAgyStub(reportBody: "", exitCode: 7, stderr: "secret-diagnostic-token")
            defer { [oldStub.directory, errStub.directory].forEach { try? FileManager.default.removeItem(at: $0) } }
            let strat = AntigravityCLIHTTPSFetchStrategy()
            await #expect(throws: AntigravityStatusProbeError
                .parseFailed("CLI usage reports require agy 1.1.11 or later"))
            { try await strat.fetchPrintUsage(binary: oldStub.binary.path, environment: oldStub.environment) }
            do {
                _ = try await strat.fetchPrintUsage(binary: errStub.binary.path, environment: errStub.environment)
                Issue.record("Expected exit 7 failure")
            } catch let error as AntigravityStatusProbeError {
                #expect(!error.localizedDescription.contains("secret-diagnostic-token"))
            }
        }
    }

    @Test(arguments: ["symlink-wal", "after-until", "invalid-since", "all-old-confirmed-empty", "summary-db-excluded"])
    func `local scan day range handles symlinks future files and empty summaries`(mode: String) async throws {
        let fixture = try AntigravityLocalFixture()
        let sinceDate = try Harness.calDate("2026-07-29")
        switch mode {
        case "symlink-wal":
            let fm = FileManager.default, dir = fixture.root.appendingPathComponent("wal-targets", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let targetDB = dir.appendingPathComponent("target.db")
            let old = sinceDate.addingTimeInterval(-86400), fresh = sinceDate.addingTimeInterval(3600)
            let b = AntigravityLocalFixture.blob(seconds: 1_787_832_000)
            try Harness.writeWAL(at: targetDB, blobs: [b], createTable: true, dbDate: old, walDate: fresh)
            let r0 = fixture.context.databaseRoots[0]
            try fm.createDirectory(at: r0, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: r0.appendingPathComponent("symlinked.db"), withDestinationURL: targetDB)
            #expect(try fixture.report(dayRange: ("2026-07-29", "2026-08-27")).report.summary?.totalTokens == 187)
        case "after-until":
            try Harness.db(fixture, "future", mtime: Harness.calDate("2026-09-15"))
            #expect(try fixture.report(dayRange: ("2026-07-29", "2026-08-27")).statistics.files == 1)
        case "invalid-since":
            try Harness.db(fixture, "old", mtime: Date(timeIntervalSince1970: 1_700_000_000))
            #expect(try fixture.report(dayRange: ("not-a-date", "2026-08-27")).statistics.files == 1)
        case "all-old-confirmed-empty":
            try Harness.db(fixture, "old", seconds: 1_700_000_000, mtime: sinceDate.addingTimeInterval(-86400))
            try fixture.jsonl([AntigravityLocalFixture.cacheUsage])
            let snap = try await fixture.snapshot(historyDays: 30)
            #expect(snap.historyCoverageIsEstablished && snap.last30DaysTokens == 0 && snap.daily.isEmpty)
        default:
            let sumDB = try fixture.conversationSummariesDatabase(
                relativePath: "antigravity/conversations/conversation_summaries.db", rows: [])
            try FileManager.default.setAttributes(
                [.modificationDate: sinceDate.addingTimeInterval(-86400)],
                ofItemAtPath: sumDB.path)
            #expect(try Harness.discover(fixture).skippedOldDatabases == 0)
        }
    }

    @Test(arguments: ["schema-exhausted", "duration-exhausted", "jsonl-exhausted", "cli-empty", "cli-unpriced"])
    func `resource exhaustion and CLI cost handle empty and unpriced boundaries`(mode: String) throws {
        let fixture = try AntigravityLocalFixture()
        switch mode {
        case "schema-exhausted":
            try Harness.db(fixture, "valid-1")
            let base = try fixture.report(clock: { 0 })
            let db = try AntigravityLocalFixture.open(fixture.database("oversized"))
            defer { sqlite3_close(db) }
            try AntigravityLocalFixture.execute(
                db,
                "DROP TABLE gen_metadata; CREATE TABLE long_unused (a, b); "
                    + "CREATE TABLE gen_metadata (idx INT, data BLOB)")
            try AntigravityLocalFixture.insert(db, row: 0, blob: AntigravityLocalFixture.blob())
            let lim = Harness.limits { $0.schemaBytes = base.statistics.schemaBytes }
            let rep = try fixture.report(limits: lim, includeBreakdowns: true, clock: { 0 })
            #expect(rep.coverage == .partial && rep.sessions.map(\.sessionID) == ["valid-1"])
        case "duration-exhausted":
            let base = AntigravityLocalFixture.now.addingTimeInterval(-120)
            try Harness.db(fixture, "newer", input: 150, mtime: base.addingTimeInterval(60))
            var warm = 0
            _ = try fixture.report(clock: { warm += 1; return 0 })
            try Harness.db(fixture, "older", input: 100, mtime: base)
            var tick = 0
            let lim = Harness.limits { $0.duration = 5 }
            let rep = try fixture.report(limits: lim, clock: { tick += 1; return tick > warm + 2 ? 10.0 : 0.0 })
            #expect(rep.coverage == .partial && !rep.report.data.isEmpty)
        case "jsonl-exhausted":
            try fixture.jsonl([AntigravityLocalFixture.cacheUsage], session: "j1")
            try fixture.jsonl([AntigravityLocalFixture.cacheUsage], session: "j2")
            let rep = try fixture.report(limits: Harness.limits { $0.rows = 1 })
            #expect(rep.coverage == .partial && !rep.report.data.isEmpty)
        case "cli-empty":
            #expect(try (Harness.costJSON(in: fixture.root)["daily"] as? [[String: Any]])?.isEmpty == true)
        default:
            try Harness.db(fixture, "unpriced", model: "unknown-model", seconds: UInt64(Date().timeIntervalSince1970))
            #expect(try Harness.costText(["--group-by", "session"], in: fixture.root)
                .contains("dollar costs unavailable"))
        }
    }
}

// MARK: - AntigravityParityE2ETests + Tier3

extension AntigravityParityE2ETests {
    // MARK: Tier 3: Cross-Feature Pairwise Combinations (R1 to R5)

    @Test @MainActor func `Ultra tier dashboard links pair with four utilization charts`() async throws {
        let load = #"{"paidTier":{"id":"g1-ultra-tier","manageSubscriptionUri":"https://one.google.com/subscriptions"}}"#
        try await Harness.runRefresh(load: load) { ctx, _ in
            #expect(Harness.card(ctx).planText == "Google AI Ultra")
            #expect(Harness.visibleSeries(ctx).count == 4 && Harness.hasDashboard(ctx))
        }
    }

    @Test @MainActor func `four quota windows pair with remaining amounts and model availability`() async throws {
        let av: [String: Any] = ["claude-sonnet-4-6": ["state": "MODEL_AVAILABILITY_STATE_DEGRADED"]]
        try await Harness.runRefresh(summaryDict: Harness.fourBucketSummary(g5hAmt: "200", avail: av)) {
            #expect($0.store.planUtilizationHistory(for: .antigravity).count == 4)
            #expect($1.antigravityCatalog?.bucketAmounts?.first?.remainingAmount == 200)
            #expect($1.details.first { $0.title == "Model availability" }?.rows.first?.value == "Degraded")
        }
    }

    @Test @MainActor func `four quota windows remain preserved when optional details toggle`() async throws {
        let m = Harness.mod(#""gemini-3.1-pro":{"displayName":"Gemini 3.1 Pro","isPremium":true}"#)
        try await Harness.runRefresh(showOptional: false, models: m) { ctx, _ in
            #expect(Harness.card(ctx).metrics.count == 4 && Harness.card(ctx).providerDetails.isEmpty)
            ctx.settings.showOptionalCreditsAndExtraUsage = true
            let shown = Harness.card(ctx)
            #expect(shown.metrics.count == 4 && shown.providerDetails.map(\.title) == ["Quota groups", "Model catalog"])
        }
    }

    @Test @MainActor func `usage store pairs remote quotas with local cost snapshot`() async throws {
        let fixture = try AntigravityLocalFixture()
        let ref = AntigravityLocalFixture.now
        let blob = AntigravityLocalFixture.blob(model: "gemini-2.5-pro", seconds: 1_787_832_000)
        _ = try Harness.walDB(fixture, "pair-r1-r5", blobs: [blob], db: ref.addingTimeInterval(-3600), wal: ref)
        try Harness.seedPricing(in: fixture.root)
        let localCost = try await fixture.snapshot()
        try await Harness.runRefresh { ctx, _ in
            ctx.settings.costUsageEnabled = true
            ctx.store._setTokenSnapshotForTesting(localCost, provider: .antigravity)
            let card = Harness.card(ctx)
            #expect(card.metrics.count == 4 && card.tokenUsage?.monthLine.contains("187") == true)
        }
    }

    @Test @MainActor func `Ultra Lite fallback preserves remaining amount and dashboard link`() async throws {
        let load = #"{"paidTier":{"id":"g1-ultra-lite-tier","#
            + #""manageSubscriptionUri":"https://one.google.com/subscriptions"}}"#
        let quota = #"{"buckets":[{"modelId":"g3p","remainingFraction":0.5,"remainingAmount":"60"}]}"#
        try await Harness.runRefresh(
            load: load, summaryStatus: 403, summary: "{}", modelsStatus: 403, models: "{}", quota: quota)
        { ctx, snap in
            let url = try Harness.dashURL(ctx)
            #expect(
                snap.identity?.loginMethod == "Google AI Ultra Lite" && url == "https://one.google.com/subscriptions"
                    && snap.antigravityCatalog?.bucketAmounts?.first?.remainingAmount == 60)
        }
    }

    @Test @MainActor func `Pro tier upgrade link and catalog attributes flow to JSON`() async throws {
        let load = #"{"paidTier":{"id":"g1-pro-tier","upgradeSubscriptionUri":"https://one.google.com/upgrade"}}"#
        let models = Harness.mod(#""gemini-3.1-pro":{"displayName":"Gemini 3.1 Pro","creditMultiplier":1.5,"#
            + #""pricingType":"1","isPremium":true,"tagTitle":"Flagship"}"#)
        try await Harness.runRefresh(load: load, models: models) { ctx, snap in
            let usageObj = try #require(try Harness.payloadJSON(snap)["usage"] as? [String: Any])
            #expect((usageObj["identity"] as? [String: Any])?["loginMethod"] as? String == "Google AI Pro")
            #expect((usageObj["antigravityCatalog"] as? [String: Any])?["modelCatalog"] != nil)
            #expect(try Harness.dashURL(ctx) == "https://one.google.com/upgrade")
        }
    }

    @Test @MainActor func `CLI cost subprocess ignores OAuth while store resolves Ultra tier`() async throws {
        try await Harness.withStore { ctx in
            let dbDir = ctx.root.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            let blob = AntigravityLocalFixture.blob(
                model: "gemini-2.5-pro", seconds: UInt64(Date().timeIntervalSince1970))
            try Harness.writeWAL(at: dbDir.appendingPathComponent("pair-r2-r5.db"), blobs: [blob], createTable: true)
            try Harness.seedPricing(in: ctx.root)
            let envKey = AntigravityOAuthCredentialsStore.environmentCredentialsKey
            let first = try Harness.costJSON(in: ctx.root, extraEnv: [envKey: #require(ctx.environment[envKey])])
            #expect(first["last30DaysTokens"] as? Int == 187)
            try await Harness.refresh(ctx, load: #"{"paidTier":{"id":"g1-ultra-tier"}}"#)
            #expect(try Harness.snap(ctx).identity?.loginMethod == "Google AI Ultra")
        }
    }

    @Test func `agy report merges bucket amounts availabilities and group rosters`() async throws {
        let b = #"{"id":"g5h","name":"5h","window":"5h","remaining_fraction":0.75,"remaining_amount":"150"}"#
        let av = #"{"gemini-3-flash":{"state":"MODEL_AVAILABILITY_STATE_OPERATIONAL"},"#
            + #""gemini-3.1-pro":{"state":"MODEL_AVAILABILITY_STATE_CONGESTED","explanation":"Busy"}}"#
        let gDesc = "Models within this group: Gemini 3.1 Pro, Gemini 3 Flash. Refreshes every 5h."
        let fetched = try await Harness.fetchAgyJSON(Harness.agyUsage(
            [("Gemini Models", gDesc, b)],
            avail: av))
        #expect(fetched.result.usage.antigravityCatalog?.bucketAmounts?.first?.remainingAmount == 150)
        #expect(fetched.result.usage.antigravityCatalog?.quotaGroups?.first?.models
            == ["Gemini 3.1 Pro", "Gemini 3 Flash"])
        #expect(fetched.result.usage.antigravityCatalog?.modelAvailabilities?["gemini-3-flash"]?.state
            == "MODEL_AVAILABILITY_STATE_OPERATIONAL")
        #expect(fetched.result.usage.details.map(\.title) == ["Model availability", "Bucket amounts", "Quota groups"])
    }

    @Test @MainActor func `remote quota amounts coexist with capped local scan`() async throws {
        try await Harness.runRefresh(summaryDict: Harness.fourBucketSummary(g5hAmt: "99")) { _, snap in
            let fixture = try AntigravityLocalFixture()
            let base = AntigravityLocalFixture.now.addingTimeInterval(-120)
            for idx in 0..<2 {
                try Harness.db(fixture, "cap-\(idx)", mtime: base.addingTimeInterval(Double(idx) * 60))
            }
            #expect(try fixture.report(limits: Harness.limits { $0.databases = 1 }).coverage == .partial)
            #expect(snap.antigravityCatalog?.bucketAmounts?.first?.remainingAmount == 99)
        }
    }

    @Test func `group roster models pair with local Vertex pricing in CLI cost`() async throws {
        let desc = "Models within this group: Claude Sonnet 4.6, gpt-oss-120b-medium"
        let b = #"{"id":"3p-5h","name":"5h","window":"5h","remaining_fraction":0.9}"#
        let usageRes = try await Harness.fetchAgyJSON(Harness.agyUsage([("Claude and GPT models", desc, b)]))
        #expect(usageRes.result.usage.antigravityCatalog?.quotaGroups?.first?.models
            == ["Claude Sonnet 4.6", "gpt-oss-120b-medium"])
        let fixture = try AntigravityLocalFixture()
        let sec = UInt64(Date().timeIntervalSince1970)
        try Harness.db(fixture, "vertex", model: "gpt-oss-120b-medium", seconds: sec)
        try Harness.seedPricing(in: fixture.root)
        #expect(try (Harness.costJSON(in: fixture.root)["last30DaysCostUSD"] as? Double ?? 0) > 0)
    }

    @Test @MainActor func `Google AI Ultra multi refresh populates burndown card dashboard and JSON`() async throws {
        try await Harness.withStore(email: "ultra-workload@example.com") { ctx in
            let t0 = Date()
            let priorRaw = Harness.fourBucketSummary(g5h: 0.92, gw: 0.88, c5h: 0.90, cw: 0.82, now: t0)
            let prior = try AntigravityStatusProbe
                .parseQuotaSummaryResponse(GeminiAPITestHelpers.jsonData(priorRaw)).toUsageSnapshot()
            await ctx.store.recordPlanUtilizationHistorySample(
                provider: .antigravity, snapshot: prior, now: t0.addingTimeInterval(-3600))
            let av: [String: Any] = ["gemini-3.1-pro": ["state": "MODEL_AVAILABILITY_STATE_OPERATIONAL"]]
            let summary = Harness.fourBucketSummary(
                g5h: 0.68, gw: 0.72, c5h: 0.76, cw: 0.55, g5hAmt: "340", c5hAmt: "190", avail: av, now: t0)
            let load = #"{"g1Tier":"G1_ULTRA_TIER","paidTier":{"id":"g1-ultra-tier","name":"Google AI Pro","#
                + #""manageSubscriptionUri":"https://one.google.com/subscriptions","#
                + #""availableCredits":[{"creditType":"GOOGLE_ONE_AI","creditAmount":"500"}]}}"#
            let models = Harness.mod(#""gemini-3.1-pro":{"displayName":"Gemini 3.1 Pro","creditMultiplier":1.5,"#
                + #""pricingType":"MODEL_PRICING_TYPE_STATIC_CREDIT","isPremium":true,"tagTitle":"New"}"#)
            try await Harness.refresh(ctx, load: load, summaryDict: summary, models: models)
            await Harness.flushHistory(ctx)
            let card = Harness.card(ctx, now: t0)
            #expect(card.planText == "Google AI Ultra" && card.metrics.count == 4)
            #expect(card.providerDetails.map(\.title) == ["Credits", "Bucket amounts", "Quota groups", "Model catalog"])
            #expect(Harness.hasDashboard(ctx) && Harness.visibleSeries(ctx, now: t0).count == 4
                && Harness.burndown(ctx, now: Date())._seriesTitlesForTesting.count == 4)
            let u = try Harness.payloadJSON(Harness.snap(ctx))["usage"] as? [String: Any]
            #expect(u?["antigravityCatalog"] != nil)
        }
    }

    @Test @MainActor func `single cadence Gemini transitions smoothly when Claude GPT becomes active`() async throws {
        try await Harness.withStore { ctx in
            let t0 = Date()
            try Harness.seedPreFeatureWeekly(ctx, now: t0, used: 95)
            let s1 = Harness.fourBucketSummary(g5h: 0.85, gw: 0.90, c5h: 1.0, cw: 1.0, now: t0)
            try await Harness.refresh(ctx, summaryDict: s1)
            #expect(Harness.card(ctx, now: t0).metrics.count == 2
                && Harness.visibleSeries(ctx, now: t0) == ["session:300", "weekly:10080"])
            let s2 = Harness.fourBucketSummary(g5h: 0.65, gw: 0.70, c5h: 0.75, cw: 0.55, now: t0)
            try await Harness.refresh(ctx, summaryDict: s2)
            #expect(Harness.card(ctx, now: t0).metrics.count == 4 && Harness.visibleSeries(ctx, now: t0).count == 4)
        }
    }

    @Test @MainActor
    func `OAuth summary 403 falls back to retrieveUserQuota with partial catalog`() async throws {
        let load = #"{"paidTier":{"id":"g1-pro-tier","upgradeSubscriptionUri":"https://one.google.com/upgrade"}}"#
        let models = Harness.mod(#""gemini-3-pro":{"displayName":"Gemini 3 Pro","creditMultiplier":"1.5","#
            + #""quotaInfo":{"remainingFraction":1.0}},"gemini-nan":{"displayName":"Gemini NaN","#
            + #""creditMultiplier":"NaN","pricingType":"MODEL_PRICING_TYPE_API","quotaInfo":"#
            + #"{"remainingFraction":1.0}},"quotaless-pro":{"displayName":"Quotaless Pro","#
            + #""creditMultiplier":1e30,"isPremium":true}"#)
        let quota = #"{"buckets":[{"modelId":"gemini-3-pro","remainingFraction":0.65,"remainingAmount":"130"},"#
            + #"{"modelId":"gemini-nan","remainingFraction":0.50,"#
            + #""remainingAmount":"99999999999999999999999"}]}"#
        try await Harness.runRefresh(
            load: load, summaryStatus: 403, summary: #"{"error":"forbidden"}"#, models: models, quota: quota)
        { ctx, snap in
            let url = try Harness.dashURL(ctx)
            #expect(snap.identity?.loginMethod == "Google AI Pro" && url == "https://one.google.com/upgrade")
            #expect(snap.antigravityCatalog?.bucketAmounts?.map(\.remainingAmount) == [130])
            #expect(snap.antigravityCatalog?.modelCatalog?.count == 3)
            #expect(Harness.card(ctx).providerDetails.map(\.title) == ["Bucket amounts", "Model catalog"])
        }
    }

    @Test func `agy CLI subprocess renders multi group rosters with optional toggle`() async throws {
        let gB = #"{"id":"g5h","name":"5h","window":"5h","remaining_fraction":0.85,"remaining_amount":"170"},"#
            + #"{"id":"gw","name":"Weekly","window":"weekly","remaining_fraction":0.70}"#
        let cB = #"{"id":"c5h","name":"5h","window":"5h","remaining_fraction":0.60,"remaining_amount":"60"},"#
            + #"{"id":"cw","name":"Weekly","window":"weekly","remaining_fraction":0.50}"#
        let aB = #"{"id":"a5h","name":"5h","window":"5h","remaining_fraction":0.95}"#
        let groups = [
            ("Gemini Models", "Models within this group: Gemini 3.1 Pro, Gemini 3 Flash. Resets every 5h.", gB),
            ("Claude and GPT models", "Models within this group: Claude Sonnet 4.6, GPT-OSS 120B", cB),
            ("Gemini 4 Argon", "Argon uses a separate quota pool.", aB),
        ]
        let av = #"{"gemini-3-flash":{"state":"MODEL_AVAILABILITY_STATE_OPERATIONAL"},"#
            + #""claude-sonnet-4-6":{"state":"MODEL_AVAILABILITY_STATE_CONGESTED","explanation":"Regional spike"}}"#
        let fetched = try await Harness.fetchAgyJSON(Harness.agyUsage(groups, avail: av))
        #expect(try Harness.cardModel(fetched.result.usage, showOptional: false).providerDetails.map(\.title)
            == ["Model availability", "Bucket amounts"])
        #expect(try Harness.cardModel(fetched.result.usage, showOptional: true).providerDetails.map(\.title)
            == ["Model availability", "Bucket amounts", "Quota groups"])
        let text = Harness.cliText(fetched.result.usage)
        #expect(text.contains("170 remaining") && text.contains("Gemini 3.1 Pro, Gemini 3 Flash"))
    }

    @Test func `multi root local scan CLI cost subprocess rescues WAL databases`() throws {
        let fixture = try AntigravityLocalFixture()
        let now = Date()
        let nowSec = UInt64(now.timeIntervalSince1970)
        let stale = now.addingTimeInterval(-10 * 86400)
        try Harness.db(fixture, "excluded-old", seconds: nowSec - 10 * 86400, mtime: stale)
        let walBlob = AntigravityLocalFixture.blob(model: "gemini-2.5-pro", seconds: nowSec)
        let w1 = "file:///tmp/wal-project", m2 = "claude-sonnet-4-6", w2 = "file:///tmp/desktop-project"
        _ = try Harness.walDB(fixture, "wal-rescued-cli", blobs: [walBlob], ws: w1, db: stale, wal: now)
        try Harness.db(fixture, "desktop-active", model: m2, input: 200, seconds: nowSec, root: 2, ws: w2)
        try Harness.seedPricing(in: fixture.root)
        let first = try Harness.costJSON(["--days", "7"], in: fixture.root)
        #expect(first["source"] as? String == "local" && first["historyCoverageIsEstablished"] as? Bool == true)
        #expect(first["last30DaysTokens"] as? Int == 187 + 287)
        let proj = try Harness.costJSON(["--days", "7", "--group-by", "project"], in: fixture.root)
        let projNames = (proj["projects"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        #expect(Set(projNames) == ["wal-project", "desktop-project"])
    }

    @Test func `ceiling exceeded local scan caps newest first while preserving breakdowns`() throws {
        let fixture = try AntigravityLocalFixture()
        let base = AntigravityLocalFixture.now.addingTimeInterval(-600)
        for idx in 0..<6 {
            let mtime = base.addingTimeInterval(Double(idx) * 60)
            let ws = "file:///tmp/cap-proj-\(idx)"
            try Harness.db(fixture, "cap-session-\(idx)", input: UInt64(100 + idx * 10), ws: ws, mtime: mtime)
        }
        let rep = try fixture.report(limits: Harness.limits { $0.databases = 3 }, includeBreakdowns: true)
        let snap = Harness.tokenSnapshot(from: rep, provenance: .listPriceEstimate)
        #expect(rep.coverage == .partial && !snap.historyCoverageIsEstablished && snap.historyScanIsPartial)
        #expect(!snap.daily.isEmpty)
        #expect(Set(snap.projects.map(\.name)) == ["cap-proj-3", "cap-proj-4", "cap-proj-5"])
        #expect(Set(snap.sessions.map(\.sessionID)) == ["cap-session-3", "cap-session-4", "cap-session-5"])
        #expect(CodexBarCLI.renderCostText(provider: .antigravity, snapshot: snap, useColor: false)
            .contains("Partial local history · recorded token subtotal"))
    }
}
