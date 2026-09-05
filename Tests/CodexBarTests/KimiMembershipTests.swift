import Foundation
import Testing
@testable import CodexBarCore

struct KimiMembershipTests {
    @Test(arguments: [
        ("LEVEL_FREE", "Adagio"),
        ("LEVEL_TRIAL", "Andante"),
        ("LEVEL_BASIC", "Moderato"),
        ("LEVEL_INTERMEDIATE", "Allegretto"),
        ("LEVEL_ADVANCED", "Allegro"),
        ("LEVEL_FUTURE", "LEVEL_FUTURE"),
    ])
    func `API membership is available without cookies`(level: String, title: String) throws {
        let json = """
        {"user":{"membership":{"level":"\(level)"}},"version":"GOODS_VERSION_V1",
        "usage":{"limit":"100","used":"25","remaining":"75"}}
        """
        let snapshot = try KimiUsageFetcher._parseCodeAPIUsageForTesting(Data(json.utf8))
        #expect(snapshot.toUsageSnapshot().loginMethod(for: .kimi) == title)
    }

    @Test(arguments: [
        #"{}"#,
        #"{"user":{"membership":{"level":" "}}}"#,
        #"{"user":{"membership":{"level":"LEVEL_UNSPECIFIED"}}}"#,
        #"{"user":{"membership":{"level":42}}}"#,
        #"{"user":"unavailable"}"#,
    ])
    func `absent or malformed optional membership preserves valid usage`(_ fields: String) throws {
        var json = try #require(JSONSerialization.jsonObject(with: Data(fields.utf8)) as? [String: Any])
        json["usage"] = ["limit": "100", "used": "25", "remaining": "75"]
        let snapshot = try KimiUsageFetcher._parseCodeAPIUsageForTesting(JSONSerialization.data(withJSONObject: json))
        #expect(snapshot.weekly.used == "25")
        #expect(snapshot.planName == nil)
    }

    @Test(arguments: [#""GOODS_VERSION_FUTURE""#, "2", "{}", "[]"])
    func `unknown catalog version preserves the reported membership level`(_ version: String) throws {
        let json = """
        {"user":{"membership":{"level":"LEVEL_ADVANCED"}},
        "version":\(version),"usage":{"limit":"100","used":"25"}}
        """
        let snapshot = try KimiUsageFetcher._parseCodeAPIUsageForTesting(Data(json.utf8))
        #expect(snapshot.planName == "LEVEL_ADVANCED")
    }

    @Test
    func `API account membership takes precedence over web membership`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            let json: String
            if url.path.hasSuffix("/usages") {
                json = """
                {"user":{"membership":{"level":"LEVEL_ADVANCED"}},
                "version":"GOODS_VERSION_V1","usage":{"limit":"100","used":"25"}}
                """
            } else if url.path.hasSuffix("/GetSubscriptionStats") {
                json = #"{"subscriptionBalance":{"amountUsedRatio":0.42}}"#
            } else {
                Issue.record("An API membership should not request a web account's plan")
                json = """
                {"subscription":{"active":true,"status":"SUBSCRIPTION_STATUS_ACTIVE",
                "goods":{"title":"Moderato"}}}
                """
            }
            return (Data(json.utf8), response)
        }
        let snapshot = try await KimiUsageFetcher.fetchCodeAPIUsage(
            apiKey: "fixture-api-key", webAuthToken: "fixture-web-token", transport: transport)
        #expect(snapshot.planName == "Allegro")
        #expect(snapshot.subscriptionBalance?.amountUsedRatio == 0.42)
    }

    @Test
    func `active subscription title reaches existing plan presentation`() throws {
        let data = Data(
            #"{"subscription":{"active":true,"status":"SUBSCRIPTION_STATUS_ACTIVE","goods":{"title":"Allegro"}}}"#
                .utf8)
        let response = try JSONDecoder().decode(KimiSubscriptionResponse.self, from: data)
        let snapshot = KimiUsageSnapshot(
            weekly: .init(limit: "100", used: "25", remaining: "75", resetTime: nil),
            rateLimit: nil,
            subscriptionBalance: nil,
            planName: response.planName,
            updatedAt: Date())
        #expect(snapshot.toUsageSnapshot().loginMethod(for: .kimi) == "Allegro")
        #expect(snapshot.toUsageSnapshot().loginMethod(for: .claude) == nil)
    }

    @Test(arguments: [
        #"{}"#,
        #"{"subscription":{"active":false,"status":"SUBSCRIPTION_STATUS_ACTIVE","goods":{"title":"Allegro"}}}"#,
        #"{"subscription":{"active":true,"status":"SUBSCRIPTION_STATUS_EXPIRED","goods":{"title":"Allegro"}}}"#,
        #"{"subscription":{"active":true,"status":"SUBSCRIPTION_STATUS_ACTIVE","goods":{"title":" "}}}"#,
    ])
    func `missing or inactive membership never invents a tier`(_ json: String) throws {
        #expect(try JSONDecoder().decode(KimiSubscriptionResponse.self, from: Data(json.utf8)).planName == nil)
    }

    @Test
    func `rejected desktop session falls through stale browser profiles`() async throws {
        var attempted: [String] = []
        let snapshot = try await KimiWebFetchStrategy.fetchWithFallback(
            desktopToken: "desktop",
            browserTokens: { ["desktop", "old-browser", "current-browser"] },
            environmentToken: nil,
            fetchUsage: { token in
                attempted.append(token)
                guard token == "current-browser" else { throw KimiAPIError.invalidToken }
                return KimiUsageSnapshot(
                    weekly: .init(limit: "100", used: "25", remaining: "75", resetTime: nil),
                    rateLimit: nil,
                    updatedAt: Date())
            })
        #expect(attempted == ["desktop", "old-browser", "current-browser"])
        #expect(snapshot.weekly.used == "25")
    }

    @Test
    func `working desktop session does not import browser cookies`() async throws {
        var imported = false
        _ = try await KimiWebFetchStrategy.fetchWithFallback(
            desktopToken: "desktop",
            browserTokens: { imported = true; return [] },
            environmentToken: nil,
            fetchUsage: { _ in
                KimiUsageSnapshot(
                    weekly: .init(limit: "100", used: "0", remaining: "100", resetTime: nil),
                    rateLimit: nil,
                    updatedAt: Date())
            })
        #expect(!imported)
    }

    @Test
    func `network errors do not trigger account fallback`() async {
        var imported = false
        do {
            _ = try await KimiWebFetchStrategy.fetchWithFallback(
                desktopToken: "desktop",
                browserTokens: { imported = true; return [] },
                environmentToken: nil,
                fetchUsage: { _ in throw URLError(.notConnectedToInternet) })
            Issue.record("Expected network failure")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
        }
        #expect(!imported)
    }

    @Test
    func `standalone CLI is detected when absent from GUI PATH`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".kimi-code/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("kimi")
        try "#!/bin/sh\n[ \"$1\" = --version ] && printf '0.38.0\\n'\n".write(
            to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        #expect(ProviderVersionDetector.kimiVersion(environment: [:], home: home, pathLookup: { nil }) == "0.38.0")
        #expect(ProviderVersionDetector.kimiVersion(
            environment: ["KIMI_CODE_HOME": home.appendingPathComponent("missing").path],
            home: home,
            pathLookup: { nil }) == nil)
    }

    @Test
    func `membership failure preserves API usage and monthly balance`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let isPlan = url.path.hasSuffix("/GetSubscription")
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: isPlan ? 500 : 200, httpVersion: nil, headerFields: nil))
            let json = url.path.hasSuffix("/usages")
                ? #"{"usage":{"limit":"100","used":"25","remaining":"75"}}"#
                : #"{"subscriptionBalance":{"amountUsedRatio":0.42}}"#
            return (Data(json.utf8), response)
        }
        let snapshot = try await KimiUsageFetcher.fetchCodeAPIUsage(
            apiKey: "test-api-key", webAuthToken: "test-web-token", transport: transport)
        #expect(snapshot.weekly.used == "25")
        #expect(snapshot.planName == nil)
        #expect(snapshot.subscriptionBalance?.amountUsedRatio == 0.42)
    }

    #if os(macOS)
    @Test
    func `desktop JWT expiry is checked independently of cookie expiry`() {
        let payload = Data(#"{"exp":100}"#.utf8).base64EncodedString()
        let token = "header.\(payload).signature"
        #expect(KimiDesktopAuthToken.isExpired(token, now: Date(timeIntervalSince1970: 101)))
        #expect(!KimiDesktopAuthToken.isExpired(token, now: Date(timeIntervalSince1970: 99)))
        #expect(!KimiDesktopAuthToken.isExpired("opaque-token"))
    }
    #endif
}
