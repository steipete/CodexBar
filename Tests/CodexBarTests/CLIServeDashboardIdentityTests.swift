import Commander
import Foundation
import Testing
@testable import CodexBarCLI

/// `codexbar serve` resolves dashboard identity per request: an explicit `--identity` pins the
/// mode, and an absent flag follows the app's "Hide personal information" setting. The resolved
/// mode also joins the cache key so a body cached before a toggle cannot be replayed after it.
struct CLIServeDashboardIdentityTests {
    @Test
    func `dashboard identity follows the app privacy setting without a flag`() {
        #expect(CodexBarCLI.resolveDashboardIdentityMode(
            configured: nil,
            hidesPersonalInfo: true) == .redacted)
        #expect(CodexBarCLI.resolveDashboardIdentityMode(
            configured: nil,
            hidesPersonalInfo: false) == .full)
    }

    @Test
    func `dashboard identity flag overrides the app privacy setting`() {
        #expect(CodexBarCLI.resolveDashboardIdentityMode(
            configured: .full,
            hidesPersonalInfo: true) == .full)
        #expect(CodexBarCLI.resolveDashboardIdentityMode(
            configured: .redacted,
            hidesPersonalInfo: false) == .redacted)
    }

    @Test
    func `dashboard identity flag presence separates an explicit full from an absent flag`() {
        #expect(CodexBarCLI.dashboardIdentityFlagPresent(in: ParsedValues(
            positional: [],
            options: ["identity": ["full"]],
            flags: [])))
        #expect(!CodexBarCLI.dashboardIdentityFlagPresent(in: ParsedValues(
            positional: [],
            options: [:],
            flags: [])))
    }

    @Test
    func `an absent identity flag still decodes to the full default`() {
        #expect(CodexBarCLI.decodeDashboardIdentityMode(from: ParsedValues(
            positional: [],
            options: [:],
            flags: [])) == .full)
    }

    @Test
    func `dashboard operation key separates identity modes`() throws {
        let redacted = try CodexBarCLI.serveDashboardOperationKey(
            identityMode: .redacted,
            usageBarsShowUsed: false,
            provider: nil)
        let full = try CodexBarCLI.serveDashboardOperationKey(
            identityMode: .full,
            usageBarsShowUsed: false,
            provider: nil)

        #expect(redacted != full)
    }

    @Test
    func `dashboard operation key separates usage bars fill preferences`() throws {
        let used = try CodexBarCLI.serveDashboardOperationKey(
            identityMode: .full,
            usageBarsShowUsed: true,
            provider: nil)
        let remaining = try CodexBarCLI.serveDashboardOperationKey(
            identityMode: .full,
            usageBarsShowUsed: false,
            provider: nil)

        #expect(used != remaining)
    }

    @Test
    func `warm dashboard responses retain the requested fill mode through toggles`() async throws {
        let (_, cache) = makeServeTestCache()
        let counter = DashboardFillBuildCounter()
        for showUsed in [false, true, false, true] {
            let key = try CodexBarCLI.serveDashboardOperationKey(
                identityMode: .redacted,
                usageBarsShowUsed: showUsed,
                provider: "codex")
            let response = await CodexBarCLI.cachedServeResponse(
                key: key, cache: cache, refreshInterval: 60, configFingerprint: "synthetic-config")
            {
                let build = await counter.increment()
                return CLILocalHTTPResponse(
                    status: .ok,
                    body: Data("{\"usageBarsShowUsed\":\(showUsed),\"build\":\(build)}".utf8))
            }
            let payload = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            #expect(payload["usageBarsShowUsed"] as? Bool == showUsed)
        }
        #expect(await counter.count == 2)
    }
}

private actor DashboardFillBuildCounter {
    private(set) var count = 0

    func increment() -> Int {
        self.count += 1
        return self.count
    }
}
