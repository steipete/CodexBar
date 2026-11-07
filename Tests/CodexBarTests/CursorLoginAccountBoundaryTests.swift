import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CursorLoginAccountBoundaryTests {
    @Test
    func `interactive login uses the current Cursor owned login entry point`() async throws {
        let expected = try #require(URL(string: "https://cursor.com/login"))
        let browser = URL(fileURLWithPath: "/Applications/Fixture Cursor Browser.app")
        var routedURLs: [URL] = []
        var launches: [CursorLoginBrowserRouter.Route] = []
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.01,
            launchRoute: { route in
                launches.append(route)
                return true
            },
            loadSnapshot: {
                CursorStatusSnapshot(
                    planPercentUsed: 20,
                    planUsedUSD: 4,
                    planLimitUSD: 20,
                    onDemandUsedUSD: 0,
                    onDemandLimitUSD: nil,
                    teamOnDemandUsedUSD: nil,
                    teamOnDemandLimitUSD: nil,
                    billingCycleEnd: nil,
                    membershipType: "pro",
                    accountEmail: "cursor-login@example.test",
                    accountID: "cursor-login-fixture",
                    accountName: nil,
                    rawJSON: nil)
            },
            sleeper: { _ in },
            browserApplicationResolver: { _ in browser },
            routeResolver: { loginURL, selectedBrowser in
                routedURLs.append(loginURL)
                return .route(.init(launchURL: loginURL, browserApplicationURL: selectedBrowser ?? browser))
            },
            conditionalMutationCoordinator: .init(),
            replaceSessionCache: { _ in true })

        let result = await runner.run { _ in }

        #expect(CursorLoginRunner.authURL == expected)
        #expect(routedURLs == [expected])
        #expect(launches.map(\.launchURL) == [expected])
        #expect(launches.map(\.browserApplicationURL) == [browser])
        #expect(result.email == "cursor-login@example.test")
        guard case .success = result.outcome else {
            Issue.record("Expected synthetic Cursor login to complete")
            return
        }
    }
}
