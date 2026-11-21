import Testing
@testable import CodexBarCLI

struct CLIServeUsageAllAccountsTests {
    @Test
    func `routes usage allAccounts query parameter`() throws {
        for value in ["true", "1", "yes", " YES "] {
            #expect(
                try CLIServeRouter.route(
                    method: "GET",
                    path: "/usage",
                    queryItems: ["provider": "clinepass", "allAccounts": value]) ==
                    .usage(provider: "clinepass", allAccounts: true))
        }
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/usage",
                queryItems: ["provider": "clinepass", "allAccounts": "false"]) ==
                .usage(provider: "clinepass", allAccounts: false))
    }
}
