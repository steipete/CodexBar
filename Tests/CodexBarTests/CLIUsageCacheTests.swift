import Commander
import Foundation
#if os(macOS)
import Security
#endif
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLIUsageCacheTests {
    private static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private static let now = fetchedAt.addingTimeInterval(90)
    private static let enabledConfig = CodexBarConfig(providers: [], shareUsageWithCLI: true)

    @Test
    func `round trip is private and carries windows only`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        let usage = UsageSnapshot(
            primary: Self.window(42),
            secondary: Self.window(7),
            extraRateWindows: [NamedRateWindow(id: "opus", title: "Opus", window: Self.window(63))],
            providerCost: ProviderCostSnapshot(
                used: 1,
                limit: 10,
                currencyCode: "USD",
                balance: 5,
                updatedAt: Self.fetchedAt),
            openAIAPIUsage: OpenAIAPIUsageSnapshot(daily: [], updatedAt: Self.fetchedAt, projectID: "proj-secret"),
            updatedAt: Self.fetchedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "person@example.com",
                accountOrganization: "Example Org",
                loginMethod: "Max"))

        try CLIUsageCache.write(Self.cache(.claude, usage), to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        for forbidden in [
            "person@example.com",
            "Example Org",
            "proj-secret",
            "accountEmail",
            "providerCost",
            "balance",
        ] {
            #expect(!raw.contains(forbidden))
        }
        #expect(try Self.mode(of: url) == 0o600)
        #expect(try Self.mode(of: url.deletingLastPathComponent()) == 0o700)
        let hit = try #require(CLIUsageCache.load(from: url)?.hit(for: .claude, now: Self.now))
        #expect(hit.ageSeconds == 90)
        #expect(hit.entry.usage.primary?.usedPercent == 42)
        #expect(hit.entry.usage.extraRateWindows?.map(\.id) == ["opus"])
        #expect(hit.entry.usage.identity == nil)
    }

    @Test
    func `future dated entries are rejected`() {
        let cache = Self.cache()
        #expect(cache.hit(for: .claude, now: Self.fetchedAt.addingTimeInterval(-61)) == nil)
        #expect(cache.hit(for: .claude, now: Self.fetchedAt.addingTimeInterval(-1)) == nil)
    }

    @Test
    func `decoded entries without rate windows are ignored`() throws {
        let stamp = ISO8601DateFormatter().string(from: Self.fetchedAt)
        let data = Data("{\"entries\":[{\"provider\":\"claude\",\"usage\":{\"updatedAt\":\"\(stamp)\"}}]}".utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(CLIUsageCache.self, from: data).hit(for: .claude, now: Self.now) == nil)
    }

    @Test
    func `decoded entries cannot carry identity or costs`() throws {
        let usage = UsageSnapshot(
            primary: Self.window(42),
            secondary: nil,
            providerCost: ProviderCostSnapshot(used: 1, limit: 10, currencyCode: "USD", updatedAt: Self.fetchedAt),
            updatedAt: Self.fetchedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "person@example.com",
                accountOrganization: nil,
                loginMethod: nil))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedUsage = try #require(String(data: encoder.encode(usage), encoding: .utf8))
        let data = Data("{\"entries\":[{\"provider\":\"claude\",\"usage\":\(encodedUsage)}]}".utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cache = try decoder.decode(CLIUsageCache.self, from: data)
        let hit = try #require(cache.hit(for: .claude, now: Self.now))
        #expect(hit.entry.usage.identity == nil)
        #expect(hit.entry.usage.providerCost == nil)
    }

    @Test
    func `stale corrupt and foreign files are ignored`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        try CLIUsageCache.write(Self.cache(), to: url)
        let cache = try #require(CLIUsageCache.load(from: url))

        #expect(cache.hit(for: .claude, now: Self.fetchedAt.addingTimeInterval(CLIUsageCache.maximumAge + 1)) == nil)
        #expect(CLIUsageCache.load(from: url, ownerUID: geteuid() &+ 1) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        #expect(CLIUsageCache.load(from: url) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(CLIUsageCache.load(from: url) == nil)
        try FileManager.default.removeItem(at: url)
        let target = root.appendingPathComponent("target/usage.json")
        try CLIUsageCache.write(Self.cache(), to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(CLIUsageCache.load(from: url) == nil)
        try FileManager.default.removeItem(at: url)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url.deletingLastPathComponent())
        #expect(throws: (any Error).self) {
            try CLIUsageCache.write(Self.cache(), to: link.appendingPathComponent("usage.json"))
        }
        try Data("{not json".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(CLIUsageCache.load(from: url) == nil)
    }

    @Test
    func `reader needs a non GUI session an observed locked keychain and a credential failure`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        try CLIUsageCache.write(Self.cache(), to: url)
        let credential = ClaudeWebAPIFetcher.FetchError.noSessionKeyFound

        #expect(CLIUsageCache.fallbackReader(config: Self.enabledConfig, url: url, hasGraphicSession: { true }) == nil)
        let now = Self.now
        let optionalReader = CLIUsageCache.fallbackReader(
            config: Self.enabledConfig, url: url, hasGraphicSession: { false }, now: { now })
        let reader = try #require(optionalReader)
        #expect(reader(.claude, true, credential)?.ageSeconds == 90)
        #expect(reader(.claude, false, credential) == nil)
        #expect(reader(.claude, true, URLError(.timedOut)) == nil)
        #expect(reader(.zai, true, credential) == nil)
    }

    @Test
    func `reader excludes managed and profile Codex accounts`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        try CLIUsageCache.write(Self.cache(.codex), to: url)
        let sources: [CodexActiveSource] = [.liveSystem, .managedAccount(id: UUID()), .profileHome(path: "/synthetic")]
        for source in sources {
            var provider = ProviderConfig(id: .codex)
            provider.codexActiveSource = source
            let config = CodexBarConfig(providers: [provider], shareUsageWithCLI: true)
            let optionalReader = CLIUsageCache.fallbackReader(
                config: config, url: url, hasGraphicSession: { false }, now: { Self.now })
            let reader = try #require(optionalReader)
            let hit = reader(.codex, true, ProviderFetchClassifiedError(kind: .missingCredential, message: "Synthetic"))
            #expect((hit != nil) == (source == .liveSystem))
        }
    }

    @Test
    func `only credential access failures justify the cache`() {
        let credentialFailures: [Error] = [
            ClaudeWebAPIFetcher.FetchError.noSessionKeyFound,
            ProviderFetchClassifiedError(
                kind: .permissionDenied,
                message: "Chrome cookie access needs Keychain permission"),
            ProviderFetchClassifiedError(kind: .missingCredential, message: "No session"),
            ClaudeOAuthCredentialsError.keychainError(-25308),
            ClaudeOAuthCredentialsError.notFound,
            ProviderBrowserSessionFailure(owner: nil, underlyingError: ProviderFetchClassifiedError(
                kind: .permissionDenied, message: "Synthetic cookie permission failure")),
        ]
        let unrelatedFailures: [Error] = [
            URLError(.timedOut),
            ClaudeWebAPIFetcher.FetchError.unauthorized,
            ClaudeWebAPIFetcher.FetchError.serverError(statusCode: 403),
            ClaudeWebAPIFetcher.FetchError.networkError(URLError(.notConnectedToInternet)),
            ClaudeWebAPIFetcher.FetchError.invalidResponse,
            ClaudeOAuthCredentialsError.decodeFailed,
            ClaudeUsageError.parseFailed("garbage"),
            ProviderFetchClassifiedError(kind: .authenticationExpired, message: "HTTP 401"),
            ProviderFetchClassifiedError(kind: .parseFailure, message: "bad json"),
            ProviderFetchClassifiedError(kind: .networkFailure, message: "timed out"),
            ProviderFetchClassifiedError(kind: .apiFailure, message: "HTTP 500"),
            ProviderFetchError.noAvailableStrategy(.claude),
            ProviderBrowserSessionFailure(owner: nil, underlyingError: URLError(.timedOut)),
        ]

        #expect(credentialFailures.allSatisfy(CLIUsageCache.isCredentialAccessFailure))
        #expect(unrelatedFailures.allSatisfy { !CLIUsageCache.isCredentialAccessFailure($0) })
    }

    #if os(macOS)
    @Test
    func `witness records only locked statuses inside its own fetch`() async {
        KeychainLockWitness.note(errSecInteractionNotAllowed)
        let (_, other) = await CLIUsageCache.observingLockedKeychain { KeychainLockWitness.note(errSecItemNotFound) }
        let (_, locked) = await CLIUsageCache.observingLockedKeychain { KeychainLockWitness.note(errSecAuthFailed) }
        let (_, interaction) = await CLIUsageCache.observingLockedKeychain {
            KeychainLockWitness.note(errSecInteractionNotAllowed)
        }

        #expect(!other)
        #expect(locked)
        #expect(interaction)
    }

    @Test
    func `witness survives a detached hop only through a preserved access context`() async {
        let (_, plain) = await CLIUsageCache.observingLockedKeychain {
            await Task.detached { KeychainLockWitness.note(errSecInteractionNotAllowed) }.value
        }
        let (_, preserved) = await CLIUsageCache.observingLockedKeychain {
            let note = BrowserCookieAccessGate.operationPreservingAccessContext {
                KeychainLockWitness.note(errSecInteractionNotAllowed)
            }
            await Task.detached { try? note() }.value
        }
        #expect(!plain)
        #expect(preserved)
    }
    #endif

    @Test
    func `cli fallback is off without the config flag`() {
        #expect(CLIUsageCache
            .fallbackReader(config: CodexBarConfig(providers: []), hasGraphicSession: { false }) == nil)
    }

    #if os(macOS)
    /// Claude's web strategy fails with `failure` after reading the keychain with `lockStatus`; the CLI then decides
    /// whether the app cache may stand in for that failure.
    private static func fetchClaudeWeb(
        lockStatus: OSStatus?,
        failure: Error,
        sourceOverride: ProviderSourceMode? = nil) async throws -> UsageCommandOutput
    {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache/usage.json")
        try CLIUsageCache.write(
            Self.cache(.claude, UsageSnapshot(primary: Self.window(42), secondary: nil, updatedAt: Date())),
            to: url)
        let reader = try #require(CLIUsageCache.fallbackReader(
            config: Self.enabledConfig, url: url, hasGraphicSession: { false }))
        var command = try Self.command(provider: .claude)
        command.sourceModeOverride = sourceOverride
        command.usageCacheFallback = reader
        let context = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: CodexBarConfig(providers: [ProviderConfig(id: .claude, enabled: true, source: .web)]),
            verbose: false,
            baseEnvironment: [:])
        let loader: ClaudeWebFetchStrategy.UsageLoader = { _ in
            if let lockStatus { KeychainLockWitness.note(lockStatus) }
            throw failure
        }
        return await ClaudeWebFetchStrategy.$usageLoaderOverrideForTesting.withValue(loader) {
            await CodexBarCLI.fetchUsageOutputs(provider: .claude, status: nil, tokenContext: context, command: command)
        }
    }

    @Test
    func `cli serves the cache when a locked cookie import ends with no session key`() async throws {
        let output = try await Self.fetchClaudeWeb(
            lockStatus: errSecInteractionNotAllowed,
            failure: ClaudeWebAPIFetcher.FetchError.noSessionKeyFound)

        #expect(output.exitCode == .success)
        #expect(output.payload.first?.source == "codexbar-app")
        #expect((output.payload.first?.ageSeconds ?? -1) >= 0)
        #expect(output.payload.first?.usage?.identity == nil)
        #expect(output.payload.first?.credits == nil)
        #expect(output.payload.first?.openaiDashboard == nil)
    }

    @Test
    func `cli keeps its own error when no keychain read was locked`() async throws {
        let output = try await Self.fetchClaudeWeb(
            lockStatus: nil,
            failure: ClaudeWebAPIFetcher.FetchError.noSessionKeyFound)

        #expect(output.exitCode != .success)
        #expect(output.payload.first?.source != "codexbar-app")
        #expect(output.payload.first?.error != nil)
    }

    @Test
    func `cli keeps an unrelated failure after a locked optional lookup`() async throws {
        let output = try await Self.fetchClaudeWeb(
            lockStatus: errSecInteractionNotAllowed, failure: URLError(.timedOut))

        #expect(output.exitCode != .success)
        #expect(output.payload.first?.source != "codexbar-app")
        #expect(output.payload.first?.error != nil)
    }

    @Test
    func `explicit source selection keeps its own credential failure`() async throws {
        let output = try await Self.fetchClaudeWeb(
            lockStatus: errSecInteractionNotAllowed,
            failure: ClaudeWebAPIFetcher.FetchError.noSessionKeyFound,
            sourceOverride: .web)
        #expect(output.exitCode != .success)
        #expect(output.payload.first?.source != "codexbar-app")
    }
    #endif

    private static func command(provider: UsageProvider = .zai) throws -> UsageCommandContext {
        let values = try Program(descriptors: CodexBarCLI.commandDescriptors())
            .resolve(argv: ["usage", "--no-color", "--json"]).parsedValues
        return try CLIUsageFetchSetup(
            values: values,
            providers: [provider],
            output: CLIOutputPreferences.from(values: values, allowsToon: true)).command
    }

    private static func cache(_ provider: UsageProvider = .claude, _ usage: UsageSnapshot? = nil) -> CLIUsageCache {
        let usage = usage ?? UsageSnapshot(primary: Self.window(42), secondary: nil, updatedAt: Self.fetchedAt)
        return CLIUsageCache(entries: [CLIUsageCache.Entry(provider: provider, usage: usage)].compactMap(\.self))
    }

    private static func window(_ used: Double) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
    }

    private static func mode(of url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIUsageCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
