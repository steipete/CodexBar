import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized)
struct DevinOrganizationGuidanceTests {
    @Test(arguments: [DevinUsageError.noSession, .browserStorageUnreadable, .invalidCredentials])
    func `session errors explain manual setup in CLI output`(_ error: DevinUsageError) {
        let output = CLICardsRenderer.render(
            cards: [],
            failures: [.init(provider: .devin, accountLabel: nil, message: error.localizedDescription)],
            terminalWidth: 100,
            useColor: false)

        #expect(output.contains("~/.config/codexbar/config.json"))
        #expect(output.contains("cookieSource=manual"))
        #expect(output.contains("docs/devin.md#manual-auth"))
    }

    private static let guidance =
        "No Devin organization was found. For automatic auth, open the organization's Usage page in Chrome. " +
        "For manual auth, set Organization to the internal org-... or org_... ID from a successful quota " +
        "request's x-cog-org-id header."

    @Test(arguments: [401, 403], ["example-org", "org_fixture"])
    func `manual organization failures preserve actionable guidance and never import browsers`(
        _ code: Int,
        _ organization: String) async throws
    {
        try await DevinSessionImporter.withImportSessionOverrideForTesting { _, _, _ in
            Issue.record("Manual auth must not import a browser session")
            return nil
        } operation: {
            let transport = ProviderHTTPTransportStub { request in
                #expect(request.url?.host == "app.devin.ai")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer auth1_synthetic-fixture")
                let internalID: String? = organization == "org_fixture" ? "org_fixture" : nil
                #expect(request.value(forHTTPHeaderField: "x-cog-org-id") == internalID)
                let firstPath = request.url?.path == "/api/\(internalID ?? "org/example-org")/billing/quota/usage"
                let body = #"{"detail":"No organizations found for auth1 user","trace":"synthetic-private-trace"}"#
                return (Data(body.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: firstPath ? code : 404, httpVersion: nil, headerFields: nil)!)
            }
            do {
                _ = try await DevinUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0)).fetch(
                    bearerTokenOverride: "auth1_synthetic-fixture",
                    organizationOverride: organization,
                    transport: transport)
                Issue.record("Expected organization guidance")
            } catch let error as DevinUsageError {
                if case .missingOrganization = error {} else {
                    Issue.record("Expected missingOrganization, got \(error)")
                }
                #expect(error.localizedDescription == Self.guidance)
                let output = CLICardsRenderer.render(
                    cards: [],
                    failures: [.init(provider: .devin, accountLabel: nil, message: error.localizedDescription)],
                    terminalWidth: 100,
                    useColor: false)
                #expect(!output.contains("synthetic-private-trace"))
                #expect(!output.contains("auth1_synthetic-fixture"))
                if organization == "example-org",
                   let path = ProcessInfo.processInfo.environment["CODEXBAR_DEVIN_PROOF_DIR"]
                {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try output.write(
                        to: directory.appendingPathComponent("organization-\(code).txt"),
                        atomically: true,
                        encoding: .utf8)
                }
            }
            #expect(await transport.requests().count == 1)
        }
    }

    @Test(arguments: [401, 403], ["Unauthorized", "Token expired", "No organizations found for another user"])
    func `unrelated authorization failures keep credential guidance`(_ code: Int, _ detail: String) async throws {
        let auth = try #require(DevinUsageFetcher.manualAuth(
            from: "auth1_synthetic-fixture",
            organization: "example-org"))
        let body = try JSONSerialization.data(withJSONObject: ["detail": detail])
        let transport = ProviderHTTPTransportStub { request in
            (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await DevinUsageFetcher.fetchQuotaUsage(auth: auth, transport: transport)
            Issue.record("Expected credential rejection")
        } catch let error as DevinUsageError {
            if case .invalidCredentials = error {} else {
                Issue.record("Expected invalidCredentials, got \(error)")
            }
        }
        #expect(await transport.requests().count == 1)
    }

    @Test(arguments: ["org_fixture", "org-fixture"])
    func `manual internal IDs preserve the first endpoint and organization header`(
        _ organization: String) async throws
    {
        let auth = try #require(DevinUsageFetcher.manualAuth(
            from: "Authorization: Bearer auth1_synthetic-fixture", organization: organization))
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.path == "/api/\(organization)/billing/quota/usage")
            #expect(request.value(forHTTPHeaderField: "x-cog-org-id") == organization)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer auth1_synthetic-fixture")
            return (Data(#"{"daily_percentage":25,"weekly_percentage":40}"#.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let usage = try await DevinUsageFetcher.fetchQuotaUsage(auth: auth, transport: transport)
        #expect(usage.daily?.usedPercent == 25)
        #expect(usage.weekly?.usedPercent == 40)
        #expect(await transport.requests().count == 1)
    }
}
