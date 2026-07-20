import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct ClinePassProviderLinuxTests {
    @Test
    func `parses all rate windows`() throws {
        let body = #"""
        {
          "data": {
            "limits": [
              {
                "type": "five_hour",
                "percentUsed": 12.5,
                "resetsAt": "2026-07-16T10:20:30Z"
              },
              {
                "type": "weekly",
                "percentUsed": 34,
                "resetsAt": "2026-07-20T00:00:00Z"
              },
              {
                "type": "monthly",
                "percentUsed": 56.75,
                "resetsAt": "2026-08-01T00:00:00Z"
              }
            ]
          },
          "success": true
        }
        """#
        let updatedAt = Date(timeIntervalSince1970: 123)

        let snapshot = try ClinePassUsageFetcher._parseSnapshotForTesting(
            Data(body.utf8),
            updatedAt: updatedAt)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.primary?.windowMinutes == 5 * 60)
        #expect(usage.primary?.resetsAt == Self.date("2026-07-16T10:20:30Z"))
        #expect(usage.secondary?.usedPercent == 34)
        #expect(usage.secondary?.windowMinutes == 7 * 24 * 60)
        #expect(usage.secondary?.resetsAt == Self.date("2026-07-20T00:00:00Z"))
        #expect(usage.tertiary?.usedPercent == 56.75)
        #expect(usage.tertiary?.windowMinutes == 30 * 24 * 60)
        #expect(usage.tertiary?.resetsAt == Self.date("2026-08-01T00:00:00Z"))
        #expect(usage.updatedAt == updatedAt)
        #expect(usage.identity?.providerID == .clinepass)
        #expect(usage.identity?.loginMethod == "API key")
    }

    @Test
    func `leaves missing rate windows nil`() throws {
        let body = #"""
        {
          "data": {
            "limits": [
              {
                "type": "weekly",
                "percentUsed": 40
              }
            ]
          },
          "success": true
        }
        """#

        let snapshot = try ClinePassUsageFetcher._parseSnapshotForTesting(Data(body.utf8))

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 40)
        #expect(snapshot.secondary?.resetsAt == nil)
        #expect(snapshot.tertiary == nil)
    }

    @Test
    func `rejects malformed payload`() {
        let body = #"""
        {
          "data": {
            "limits": [
              {
                "type": "weekly",
                "percentUsed": "forty"
              }
            ]
          },
          "success": true
        }
        """#

        #expect {
            _ = try ClinePassUsageFetcher._parseSnapshotForTesting(Data(body.utf8))
        } throws: { error in
            guard case ClinePassUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `reads both environment keys and config override`() {
        #expect(ClinePassSettingsReader.apiKey(environment: [
            ClinePassSettingsReader.apiKeyEnvironmentKey: " primary ",
            ClinePassSettingsReader.alternateAPIKeyEnvironmentKey: "alternate",
        ]) == "primary")
        #expect(ClinePassSettingsReader.apiKey(environment: [
            ClinePassSettingsReader.alternateAPIKeyEnvironmentKey: " alternate ",
        ]) == "alternate")

        let config = ProviderConfig(id: .clinepass, apiKey: "config-key")
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .clinepass,
            config: config)

        #expect(environment[ClinePassSettingsReader.apiKeyEnvironmentKey] == "config-key")
        #expect(ClinePassSettingsReader.apiKey(environment: environment) == "config-key")
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .clinepass))
    }

    @Test
    func `registers descriptor and CLI selection`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .clinepass)
        let selection = try #require(ProviderSelection(argument: "clinepass"))

        #expect(descriptor.metadata.displayName == "ClinePass")
        #expect(descriptor.cli.name == "clinepass")
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(ProviderDescriptorRegistry.cliNameMap["clinepass"] == .clinepass)
        #expect(selection.asList == [.clinepass])
        #expect(ProviderHelp.list.split(separator: "|").contains("clinepass"))
    }

    @Test
    func `fetches usage with bearer authentication`() async throws {
        let body = #"""
        {
          "data": {
            "limits": [
              {
                "type": "five_hour",
                "percentUsed": 25
              }
            ]
          },
          "success": true
        }
        """#
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://api.cline.bot/api/v1/users/me/plan/usage-limits")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 15)
            return try Self.response(for: request, body: body, statusCode: 200)
        }

        let snapshot = try await ClinePassUsageFetcher._fetchUsage(
            apiKey: " test-key ",
            transport: transport,
            now: Date(timeIntervalSince1970: 456))

        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 456))
    }

    @Test
    func `requires authentication and rejects unauthorized response`() async {
        let unusedTransport = ProviderHTTPTransportHandler { _ in
            Issue.record("Transport should not be called without an API key")
            throw URLError(.userAuthenticationRequired)
        }

        do {
            _ = try await ClinePassUsageFetcher._fetchUsage(apiKey: "   ", transport: unusedTransport)
            Issue.record("Expected missing credentials")
        } catch let error as ClinePassUsageError {
            #expect(error == .missingCredentials)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let unauthorizedTransport = ProviderHTTPTransportHandler { request in
            try Self.response(for: request, body: "{}", statusCode: 401)
        }
        do {
            _ = try await ClinePassUsageFetcher._fetchUsage(
                apiKey: "test-key",
                transport: unauthorizedTransport)
            Issue.record("Expected unauthorized error")
        } catch let error as ClinePassUsageError {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func date(_ raw: String) -> Date? {
        ISO8601DateFormatter().date(from: raw)
    }

    private static func response(
        for request: URLRequest,
        body: String,
        statusCode: Int) throws -> (Data, URLResponse)
    {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"])
        else {
            throw URLError(.badServerResponse)
        }
        return (Data(body.utf8), response)
    }
}
