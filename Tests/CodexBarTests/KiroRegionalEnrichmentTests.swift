import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct KiroRegionalEnrichmentTests {
    @Test(arguments: ["us-east-1", "eu-central-1"])
    func `background reachability uses the profile region without sending credentials`(region: String) async throws {
        let database = try self.makeDatabase(
            profileARN: "arn:aws:codewhisperer:\(region):123456789012:profile/test-profile")
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        let original = try Data(contentsOf: database)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 403, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }
        try await KiroUsageLimitsAPI.ensureReachable(databaseURL: database, transport: transport)
        let request = try #require(await transport.requests().first)
        #expect(request.url?.absoluteString == (region == "us-east-1"
                ? "https://codewhisperer.us-east-1.amazonaws.com/"
                : "https://q.eu-central-1.amazonaws.com/"))
        #expect(request.httpMethod == "HEAD")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == nil)
        #expect(try Data(contentsOf: database) == original)
    }

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

    @Test
    func `missing profile sends an empty usage request without changing CLI state`() async throws {
        let database = try self.makeDatabase(profileARN: nil)
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        let original = try Data(contentsOf: database)
        let transport = ProviderHTTPTransportStub { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(KiroUsageLimitsAPITests.overageInUseResponse.utf8), response)
        }

        let usage = try await KiroUsageLimitsAPI.fetch(databaseURL: database, transport: transport)
        let requests = await transport.requests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://codewhisperer.us-east-1.amazonaws.com/")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-kiro-token")
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
        #expect(body == [:])
        #expect(usage.planUsed == 10000)
        #expect(try Data(contentsOf: database) == original)
    }

    @Test(arguments: ["{", "null", "[]", "{}", "{\"arn\":null}", "{\"arn\":7}"])
    func `present malformed profile does not use the missing profile fallback`(profileJSON: String) async throws {
        let database = try self.makeDatabase(profileARN: nil, profileJSON: profileJSON)
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        let transport = ProviderHTTPTransportStub { _ in throw CancellationError() }
        await #expect(throws: KiroUsageLimitsError.self) {
            _ = try await KiroUsageLimitsAPI.fetch(databaseURL: database, transport: transport)
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func `missing profile does not bypass missing token rejection`() async throws {
        let database = try self.makeDatabase(profileARN: nil, token: nil)
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        let transport = ProviderHTTPTransportStub { _ in throw CancellationError() }
        await #expect(throws: KiroUsageLimitsError.self) {
            _ = try await KiroUsageLimitsAPI.fetch(databaseURL: database, transport: transport)
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func `missing profile keeps API cancellation fatal`() async throws {
        let database = try self.makeDatabase(profileARN: nil)
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        let transport = ProviderHTTPTransportStub { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            _ = try await KiroUsageLimitsAPI.fetch(databaseURL: database, transport: transport)
        }
        #expect(await transport.requests().count == 1)
    }

    @Test(arguments: ["DROP TABLE state", "INSERT INTO state VALUES ('api.codewhisperer.profile', NULL)"])
    func `unreadable profile storage never becomes an absent profile`(mutation: String) async throws {
        let database = try self.makeDatabase(profileARN: nil)
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        var connection: OpaquePointer?
        #expect(sqlite3_open(database.path, &connection) == SQLITE_OK)
        let opened = try #require(connection)
        defer { sqlite3_close(opened) }
        #expect(sqlite3_exec(opened, mutation, nil, nil, nil) == SQLITE_OK)
        let transport = ProviderHTTPTransportStub { _ in throw CancellationError() }
        await #expect(throws: KiroUsageLimitsError.self) {
            _ = try await KiroUsageLimitsAPI.fetch(databaseURL: database, transport: transport)
        }
        #expect(await transport.requests().isEmpty)
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

    func makeDatabase(
        profileARN: String?,
        token: String? = "synthetic-kiro-token",
        profileJSON: String? = nil) throws -> URL
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("data.sqlite3")
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        let opened = try #require(database)
        defer { sqlite3_close(opened) }
        let tokenJSON = try JSONSerialization.data(withJSONObject: token.map { ["access_token": $0] } ?? [:])
        let profileData = try profileARN.map { try JSONSerialization.data(withJSONObject: ["arn": $0]) }
        let tokenText = try #require(String(data: tokenJSON, encoding: .utf8)).replacingOccurrences(of: "'", with: "''")
        let profileText = (profileJSON ?? profileData.flatMap { String(data: $0, encoding: .utf8) })?
            .replacingOccurrences(of: "'", with: "''")
        let profileInsert = profileText.map {
            "INSERT INTO state VALUES ('api.codewhisperer.profile', '\($0)');"
        } ?? ""
        let sql = """
        CREATE TABLE auth_kv(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE state(key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO auth_kv VALUES ('kirocli:odic:token', '\(tokenText)');
        \(profileInsert)
        """
        #expect(sqlite3_exec(opened, sql, nil, nil, nil) == SQLITE_OK)
        return url
    }
}
