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
        let redacted = try CodexBarCLI.serveOperationKey(
            kind: "dashboard-\(DashboardIdentityMode.redacted.rawValue)",
            provider: nil)
        let full = try CodexBarCLI.serveOperationKey(
            kind: "dashboard-\(DashboardIdentityMode.full.rawValue)",
            provider: nil)

        #expect(redacted != full)
    }
}
