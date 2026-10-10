import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import CodexBarCore

struct KimiDesktopDispatchTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Deliberately unsigned synthetic claims; never a real account credential.
    private static let token: String = {
        let header = #"{"alg":"HS256"}"#
        let claims = #"{"typ":"access","aud":"kimi.com","exp":1800003600}"#
        let segments = [header, claims].map {
            Data($0.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return segments.joined(separator: ".") + ".fixture-signature"
    }()

    @Test(arguments: ["deleted", "replaced", "unreadable"], [false, true])
    func `Code API and CLI keep quota when Desktop changes while Code response is paused`(
        change: String, cli: Bool) async throws
    {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let credentials = home.appendingPathComponent("credentials")
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        try Data(#"{"access_token":"synthetic-code","expires_at":4102444800}"#.utf8)
            .write(to: credentials.appendingPathComponent("kimi-code.json"))
        let state = DispatchSessionState(Self.token)
        let discovery = KimiDesktopSessionDiscovery { _, _ in state.rawValue() }
        let candidate = discovery.credential(
            settings: .init(cookieSource: .auto, manualCookieHeader: nil), homeDirectory: home, now: { Self.now })
        let credential = try #require(candidate)
        let transport = PausedCodeTransport()
        let context = Self.context(home: home, source: .auto)
        let strategy: any ProviderFetchStrategy = cli
            ? KimiCLICredentialFetchStrategy(transport: transport, resolveWebCredential: { _ in credential })
            : KimiAPIFetchStrategy(transport: transport, resolveWebCredential: { _ in credential })
        let task = Task { try await strategy.fetch(context) }
        await transport.waitForCodeRequest()
        state.replace(change == "replaced" ? Self.token + "-replacement" : nil)
        await transport.releaseCodeResponse()
        let result = try await task.value
        #expect(result.usage.primary?.usedPercent == 25)
        #expect(result.usage.extraRateWindows?.contains { $0.id == "kimi-monthly" } != true)
        #expect(await transport.membershipRequests == 0)
    }

    @Test(arguments: [ProviderCookieSource.manual, .off])
    func `disabled enrichment does not acquire a Desktop credential`(source: ProviderCookieSource) async throws {
        let transport = PausedCodeTransport(pause: false)
        let strategy = KimiAPIFetchStrategy(transport: transport, resolveWebCredential: { _ in
            Issue.record("Disabled discovery must not resolve Desktop")
            return nil
        })
        // Manual's explicit source is resolved by the resolver; an empty manual value never uses Desktop.
        let context = Self.context(home: FileManager.default.temporaryDirectory, source: source)
        if source == .manual {
            #expect(KimiWebEnrichmentTokenResolver.resolveCredential(context) == nil)
            _ = try await KimiAPIFetchStrategy(transport: transport).fetch(context)
        } else {
            _ = try await strategy.fetch(context)
        }
        #expect(await transport.membershipRequests == 0)
    }

    @Test(arguments: ["deleted", "replaced"], [KimiRegion.china, .international])
    func `invalidated Desktop web credential cannot dispatch or fall back`(
        change: String, region: KimiRegion) async throws
    {
        let state = DispatchSessionState(Self.token)
        let candidate = KimiDesktopSessionDiscovery { _, _ in state.rawValue() }.credential(
            settings: .init(cookieSource: .auto, manualCookieHeader: nil),
            homeDirectory: FileManager.default.temporaryDirectory,
            now: { Self.now })
        let credential = try #require(candidate)
        state.replace(change == "deleted" ? nil : Self.token + "-replacement")
        let transport = PausedCodeTransport(pause: false)
        let strategy = KimiWebFetchStrategy(
            transport: transport, desktopCredential: { _ in credential }, browserTokens: { _ in
                Issue.record("A changed Desktop session must not restart credential discovery")
                return [Self.token]
            })
        do {
            _ = try await strategy.fetch(Self.context(
                home: FileManager.default.temporaryDirectory, source: .auto, region: region))
            Issue.record("Expected changed Desktop session")
        } catch is KimiDesktopSessionChanged {} catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await transport.membershipRequests == 0)
        #expect(await transport.webRequests == 0)
    }

    @Test
    func `each concurrent web request revalidates rather than sharing an earlier success`() async throws {
        let checks = Mutex(0)
        let credential = KimiWebCredential(desktopToken: Self.token) {
            checks.withLock { count in count += 1; return count == 1 }
        }
        let transport = PausedCodeTransport(pause: false)
        do {
            _ = try await KimiUsageFetcher.fetchUsage(credential: credential, region: .china, transport: transport)
        } catch is KimiDesktopSessionChanged {}
        #expect(checks.withLock { $0 } >= 2)
        #expect(await transport.webRequests == 1)
    }

    @Test
    func `unchanged Desktop session still dispatches all three web requests`() async throws {
        let state = DispatchSessionState(Self.token)
        let candidate = KimiDesktopSessionDiscovery { _, _ in state.rawValue() }.credential(
            settings: .init(cookieSource: .auto, manualCookieHeader: nil),
            homeDirectory: FileManager.default.temporaryDirectory,
            now: { Self.now })
        let credential = try #require(candidate)
        let transport = PausedCodeTransport(pause: false)
        let strategy = KimiWebFetchStrategy(
            transport: transport, desktopCredential: { _ in credential }, browserTokens: { _ in [] })
        let result = try await strategy.fetch(Self.context(home: FileManager.default.temporaryDirectory, source: .auto))
        #expect(result.usage.primary?.usedPercent == 25)
        #expect(await transport.webRequests == 3)
        #expect(await transport.membershipRequests == 2)
    }

    @Test
    func `observed invalidation stays rejected if the old token reappears`() async throws {
        let state = DispatchSessionState(Self.token)
        let candidate = KimiDesktopSessionDiscovery { _, _ in state.rawValue() }.credential(
            settings: .init(cookieSource: .auto, manualCookieHeader: nil),
            homeDirectory: FileManager.default.temporaryDirectory,
            now: { Self.now })
        let credential = try #require(candidate)
        let transport = PausedCodeTransport(pause: false)
        state.replace(nil)
        for restore in [false, true] {
            if restore { state.replace(Self.token) }
            do {
                _ = try await KimiUsageFetcher.fetchUsage(credential: credential, region: .china, transport: transport)
                Issue.record("Invalidated credential must remain rejected")
            } catch is KimiDesktopSessionChanged {}
        }
        #expect(await transport.webRequests == 0)
    }

    @Test
    func `Desktop credential rejects another region even while the session is current`() async throws {
        let transport = PausedCodeTransport(pause: false)
        let credential = KimiWebCredential(desktopToken: Self.token, isCurrent: { true })
        do {
            _ = try await KimiUsageFetcher.fetchUsage(
                credential: credential, region: .international, transport: transport)
            Issue.record("Expected regional rejection")
        } catch is KimiDesktopSessionChanged {}
        #expect(await transport.webRequests == 0)
    }

    private static func context(
        home: URL, source: ProviderCookieSource, region: KimiRegion = .china) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: ["KIMI_CODE_API_KEY": "synthetic-code", "KIMI_CODE_HOME": home.path],
            settings: .make(kimi: .init(cookieSource: source, manualCookieHeader: "", region: region)),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: DispatchClaudeStub(),
            browserDetection: BrowserDetection(homeDirectory: home.path, cacheTTL: 0))
    }
}

private final class DispatchSessionState: Sendable {
    private let token: Mutex<String?>
    init(_ token: String?) { self.token = Mutex(token) }
    func replace(_ value: String?) { self.token.withLock { $0 = value } }
    func rawValue() -> Data? { self.token.withLock { $0.map { Data([1]) + Data($0.utf8) } } }
}

private actor PausedCodeTransport: ProviderHTTPTransport {
    private let pause: Bool
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private(set) var membershipRequests = 0
    private(set) var webRequests = 0
    init(pause: Bool = true) { self.pause = pause }

    func waitForCodeRequest() async {
        if self.entered { return }
        await withCheckedContinuation { self.waiter = $0 }
    }

    func releaseCodeResponse() { self.release?.resume(); self.release = nil }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let body: String
        if request.httpMethod == "GET" {
            self.entered = true
            if self.pause {
                await withCheckedContinuation { continuation in
                    self.release = continuation
                    self.waiter?.resume()
                    self.waiter = nil
                }
            }
            body = #"{"usage":{"limit":"100","used":"25","remaining":"75"}}"#
        } else {
            self.webRequests += 1
            if url.path.contains("membership") { self.membershipRequests += 1 }
            body = url.lastPathComponent == "GetUsages"
                ? #"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"25","remaining":"75"}}]}"#
                : #"{}"#
        }
        return try (Data(body.utf8), #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

private struct DispatchClaudeStub: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ClaudeUsageError.parseFailed("fixture")
    }

    func debugRawProbe(model _: String) async -> String { "fixture" }
    func detectVersion() -> String? { nil }
}
