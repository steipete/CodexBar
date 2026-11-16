import Testing
@testable import CodexBarCLI

struct CLIServeUsageAllAccountsTests {
    @Test
    func `routes usage allAccounts query parameter`() throws {
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/usage",
                queryItems: ["provider": "clinepass", "allAccounts": "true"]) ==
                .usage(provider: "clinepass", allAccounts: true))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/usage",
                queryItems: ["provider": "clinepass", "allAccounts": "1"]) ==
                .usage(provider: "clinepass", allAccounts: true))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/usage",
                queryItems: ["provider": "clinepass", "allAccounts": "false"]) ==
                .usage(provider: "clinepass", allAccounts: false))
    }
}
