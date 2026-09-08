import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct KiroRegionalEnrichmentTests {
    @Test(arguments: ["us-east-1", "eu-central-1"])
    func `existing enrichment follows the CLI profile region`(region: String) async throws {
        let arn = "arn:aws:codewhisperer:\(region):123456789012:profile/test-profile"
        let database = try self.makeDatabase(profileARN: arn)
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        let original = try Data(contentsOf: database)
        let transport = ProviderHTTPTransportStub { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(KiroUsageLimitsAPITests.overageInUseResponse.utf8), response)
        }

        let usage = try await KiroUsageLimitsAPI.fetch(
            databaseURL: database, transport: transport)
        let requests = await transport.requests()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.url?.absoluteString == (region == "us-east-1"
                ? "https://codewhisperer.us-east-1.amazonaws.com/"
                : "https://q.eu-central-1.amazonaws.com/"))
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 10)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-kiro-token")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Target") == "AmazonCodeWhispererService.GetUsageLimits")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-amz-json-1.0")
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
        #expect(body == ["profileArn": arn])
        #expect(usage.planUsed == 10000)
        #expect(try Data(contentsOf: database) == original)
    }

    @Test(arguments: [
        "", "not-an-arn", "arn:aws:codewhisperer:eu-central-1:123456789012",
        "arn:aws-cn:codewhisperer:eu-central-1:123456789012:profile/test",
        "arn:aws:s3:eu-central-1:123456789012:profile/test",
        "arn:aws:codewhisperer::123456789012:profile/test",
        "arn:aws:codewhisperer:ap-southeast-1:123456789012:profile/test",
        "arn:aws:codewhisperer:EU-CENTRAL-1:123456789012:profile/test",
        "arn:aws:codewhisperer:eu-central-1.example:123456789012:profile/test",
        "arn:aws:codewhisperer:-eu-central-1:123456789012:profile/test",
        "arn:aws:codewhisperer:eu-central-1-:123456789012:profile/test",
        "arn:aws:codewhisperer:eu-central-1:123456789012:profile/",
        "arn:aws:codewhisperer:eu-central-1:123456789012:other/test",
        "arn:aws:codewhisperer:eu-central-1:123456789012:profile/test ",
    ])
    func `invalid profile state never sends credentials to a default endpoint`(arn: String) async throws {
        let database = try self.makeDatabase(profileARN: arn)
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        let transport = ProviderHTTPTransportStub { _ in throw CancellationError() }
        do {
            _ = try await KiroUsageLimitsAPI.fetch(databaseURL: database, transport: transport)
            Issue.record("Invalid profile unexpectedly fetched usage")
        } catch is KiroUsageLimitsError {}
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func `regional requests preserve cancellation and missing token behavior`() async throws {
        let arn = "arn:aws:codewhisperer:eu-central-1:123456789012:profile/test"
        let database = try self.makeDatabase(profileARN: arn)
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        let transport = ProviderHTTPTransportStub { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            _ = try await KiroUsageLimitsAPI.fetch(databaseURL: database, transport: transport)
        }
        #expect(await transport.requests().count == 1)
        let missing = try self.makeDatabase(profileARN: arn, token: nil)
        defer { try? FileManager.default.removeItem(at: missing.deletingLastPathComponent()) }
        await #expect(throws: KiroUsageLimitsError.self) {
            _ = try await KiroUsageLimitsAPI.fetch(databaseURL: missing, transport: transport)
        }
        #expect(await transport.requests().count == 1)
    }

    private func makeDatabase(profileARN: String, token: String? = "synthetic-kiro-token") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("data.sqlite3")
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        let opened = try #require(database)
        defer { sqlite3_close(opened) }
        let tokenJSON = try JSONSerialization.data(withJSONObject: token.map { ["access_token": $0] } ?? [:])
        let profileJSON = try JSONSerialization.data(withJSONObject: ["arn": profileARN])
        let tokenText = try #require(String(data: tokenJSON, encoding: .utf8)).replacingOccurrences(of: "'", with: "''")
        let profileText = try #require(String(data: profileJSON, encoding: .utf8))
            .replacingOccurrences(of: "'", with: "''")
        let sql = """
        CREATE TABLE auth_kv(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE state(key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO auth_kv VALUES ('kirocli:odic:token', '\(tokenText)');
        INSERT INTO state VALUES ('api.codewhisperer.profile', '\(profileText)');
        """
        #expect(sqlite3_exec(opened, sql, nil, nil, nil) == SQLITE_OK)
        return url
    }
}
