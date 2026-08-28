import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct WindsurfWebFetcherTests {
    @Test
    func `missing session guidance names current and legacy origins`() {
        let message = WindsurfWebFetcherError.noSessionData.errorDescription

        #expect(message?.contains("app.devin.ai") == true)
        #expect(message?.contains("windsurf.com") == true)
    }

    private struct ResponseFixture {
        let planName: String
        let dailyRemaining: Int
        let weeklyRemaining: Int
        let planEndUnix: Int64
        let dailyResetUnix: Int64
        let weeklyResetUnix: Int64
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WindsurfWebFetcherStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func withWindsurfSessionOverrides<T>(
        importSessions: ((BrowserDetection, ((String) -> Void)?) -> [WindsurfDevinSessionImporter.SessionInfo])? = nil,
        preferredSessions: ((BrowserDetection, ((String) -> Void)?) -> [WindsurfDevinSessionImporter.SessionInfo])? =
            nil,
        fallbackSessions: ((BrowserDetection, ((String) -> Void)?) -> [WindsurfDevinSessionImporter.SessionInfo])? =
            nil,
        operation: () async throws -> T) async rethrows -> T
    {
        try await WindsurfDevinSessionImporter.withImportSessionsOverrideForTesting(importSessions) {
            try await WindsurfDevinSessionImporter.withImportPreferredSessionsOverrideForTesting(preferredSessions) {
                try await WindsurfDevinSessionImporter.withImportFallbackSessionsOverrideForTesting(fallbackSessions) {
                    try await operation()
                }
            }
        }
    }

    @Test
    func `manual devin session sends protobuf request and auth headers`() async throws {
        defer {
            WindsurfWebFetcherStubURLProtocol.requests = []
            WindsurfWebFetcherStubURLProtocol.handler = nil
        }

        WindsurfWebFetcherStubURLProtocol.requests = []
        WindsurfWebFetcherStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(url.host == "windsurf.com")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/proto")
            #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://windsurf.com")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://windsurf.com/profile")
            #expect(request.value(forHTTPHeaderField: "x-auth-token") == "devin-session-token$abc")
            #expect(request.value(forHTTPHeaderField: "x-devin-session-token") == "devin-session-token$abc")
            #expect(request.value(forHTTPHeaderField: "x-devin-auth1-token") == "auth1_xyz")
            #expect(request.value(forHTTPHeaderField: "x-devin-account-id") == "account-123")
            #expect(request.value(forHTTPHeaderField: "x-devin-primary-org-id") == "org-456")

            let body = try WindsurfPlanStatusProtoCodec.decodeRequest(Self.requestBodyData(from: request))
            #expect(body.authToken == "devin-session-token$abc")
            #expect(body.includeTopUpStatus == true)

            return Self.makeResponse(
                url: url,
                body: Self.makePlanStatusResponse(ResponseFixture(
                    planName: "Pro",
                    dailyRemaining: 68,
                    weeklyRemaining: 84,
                    planEndUnix: 1_777_888_000,
                    dailyResetUnix: 1_777_900_000,
                    weeklyResetUnix: 1_778_000_000)),
                contentType: "application/proto",
                statusCode: 200)
        }

        let manualSession = """
        {
          "devin_session_token": "devin-session-token$abc",
          "devin_auth1_token": "auth1_xyz",
          "devin_account_id": "account-123",
          "devin_primary_org_id": "org-456"
        }
        """

        let snapshot = try await WindsurfWebFetcher.fetchUsage(
            browserDetection: BrowserDetection(cacheTTL: 0),
            cookieSource: .manual,
            manualSessionInput: manualSession,
            timeout: 2,
            session: self.makeSession())

        #expect(WindsurfWebFetcherStubURLProtocol.requests.count == 1)
        #expect(snapshot.identity?.providerID == .windsurf)
        #expect(snapshot.identity?.loginMethod == "Pro")
        #expect(snapshot.primary?.usedPercent == 32)
        #expect(snapshot.secondary?.usedPercent == 16)
    }

    @Test
    func `auto session import retries next profile after auth failure`() async throws {
        defer {
            WindsurfWebFetcherStubURLProtocol.requests = []
            WindsurfWebFetcherStubURLProtocol.handler = nil
        }

        let preferredSessions: (BrowserDetection, ((String) -> Void)?)
            -> [WindsurfDevinSessionImporter.SessionInfo] = { _, _ in
                [
                    WindsurfDevinSessionImporter.SessionInfo(
                        session: WindsurfDevinSessionAuth(
                            sessionToken: "stale-token",
                            auth1Token: "stale-auth1",
                            accountID: "stale-account",
                            primaryOrgID: "stale-org"),
                        sourceLabel: "Chrome Default"),
                    WindsurfDevinSessionImporter.SessionInfo(
                        session: WindsurfDevinSessionAuth(
                            sessionToken: "fresh-token",
                            auth1Token: "fresh-auth1",
                            accountID: "fresh-account",
                            primaryOrgID: "fresh-org"),
                        sourceLabel: "Chrome Profile 1"),
                ]
            }

        WindsurfWebFetcherStubURLProtocol.requests = []
        WindsurfWebFetcherStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            let token = request.value(forHTTPHeaderField: "x-devin-session-token")

            if token == "stale-token" {
                return Self.makeResponse(
                    url: url,
                    body: Data("unauthorized".utf8),
                    contentType: "text/plain",
                    statusCode: 401)
            }

            #expect(token == "fresh-token")
            return Self.makeResponse(
                url: url,
                body: Self.makePlanStatusResponse(ResponseFixture(
                    planName: "Teams",
                    dailyRemaining: 75,
                    weeklyRemaining: 90,
                    planEndUnix: 1_777_888_000,
                    dailyResetUnix: 1_777_900_000,
                    weeklyResetUnix: 1_778_000_000)),
                contentType: "application/proto",
                statusCode: 200)
        }

        try await self.withWindsurfSessionOverrides(preferredSessions: preferredSessions) {
            let snapshot = try await WindsurfWebFetcher.fetchUsage(
                browserDetection: BrowserDetection(cacheTTL: 0),
                cookieSource: .auto,
                timeout: 2,
                session: self.makeSession())

            #expect(WindsurfWebFetcherStubURLProtocol.requests.count == 2)
            #expect(snapshot.identity?.loginMethod == "Teams")
            #expect(snapshot.primary?.usedPercent == 25)
            #expect(snapshot.secondary?.usedPercent == 10)
        }
    }

    @Test
    func `auto session import tries fallback browsers after preferred sessions fail`() async throws {
        defer {
            WindsurfWebFetcherStubURLProtocol.requests = []
            WindsurfWebFetcherStubURLProtocol.handler = nil
        }

        let preferredSessions: (BrowserDetection, ((String) -> Void)?)
            -> [WindsurfDevinSessionImporter.SessionInfo] = { _, _ in
                [
                    WindsurfDevinSessionImporter.SessionInfo(
                        session: WindsurfDevinSessionAuth(
                            sessionToken: "stale-chrome-token",
                            auth1Token: "stale-auth1",
                            accountID: "stale-account",
                            primaryOrgID: "stale-org"),
                        sourceLabel: "Chrome Default"),
                ]
            }
        let fallbackSessions: (BrowserDetection, ((String) -> Void)?)
            -> [WindsurfDevinSessionImporter.SessionInfo] = { _, _ in
                [
                    WindsurfDevinSessionImporter.SessionInfo(
                        session: WindsurfDevinSessionAuth(
                            sessionToken: "fresh-edge-token",
                            auth1Token: "fresh-auth1",
                            accountID: "fresh-account",
                            primaryOrgID: "fresh-org"),
                        sourceLabel: "Microsoft Edge Default"),
                ]
            }

        WindsurfWebFetcherStubURLProtocol.requests = []
        WindsurfWebFetcherStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            let token = request.value(forHTTPHeaderField: "x-devin-session-token")

            if token == "stale-chrome-token" {
                return Self.makeResponse(
                    url: url,
                    body: Data("unauthorized".utf8),
                    contentType: "text/plain",
                    statusCode: 401)
            }

            #expect(token == "fresh-edge-token")
            return Self.makeResponse(
                url: url,
                body: Self.makePlanStatusResponse(ResponseFixture(
                    planName: "Teams",
                    dailyRemaining: 64,
                    weeklyRemaining: 80,
                    planEndUnix: 1_777_888_000,
                    dailyResetUnix: 1_777_900_000,
                    weeklyResetUnix: 1_778_000_000)),
                contentType: "application/proto",
                statusCode: 200)
        }

        try await self.withWindsurfSessionOverrides(
            preferredSessions: preferredSessions,
            fallbackSessions: fallbackSessions)
        {
            let snapshot = try await WindsurfWebFetcher.fetchUsage(
                browserDetection: BrowserDetection(cacheTTL: 0),
                cookieSource: .auto,
                timeout: 2,
                session: self.makeSession())

            #expect(WindsurfWebFetcherStubURLProtocol.requests.count == 2)
            #expect(snapshot.identity?.loginMethod == "Teams")
            #expect(snapshot.primary?.usedPercent == 36)
            #expect(snapshot.secondary?.usedPercent == 20)
        }
    }

    @Test
    func `auto import uses complete legacy origin when app origin is partial`() async throws {
        defer {
            WindsurfWebFetcherStubURLProtocol.requests = []
            WindsurfWebFetcherStubURLProtocol.handler = nil
        }

        let appOrigin = try #require(URL(string: "https://app.devin.ai"))
        let legacyOrigin = try #require(URL(string: "https://windsurf.com"))
        let snapshots = WindsurfDevinSessionImporter.localStorageSnapshots(from: [
            (
                origin: appOrigin,
                entries: [
                    Self.localStorageEntry(origin: appOrigin, key: "devin_session_token", value: "app-session"),
                    Self.localStorageEntry(origin: appOrigin, key: "devin_auth1_token", value: "app-auth1"),
                ]),
            (
                origin: legacyOrigin,
                entries: [
                    Self.localStorageEntry(origin: legacyOrigin, key: "devin_session_token", value: "legacy-session"),
                    Self.localStorageEntry(origin: legacyOrigin, key: "devin_auth1_token", value: "legacy-auth1"),
                    Self.localStorageEntry(origin: legacyOrigin, key: "devin_account_id", value: "legacy-account"),
                    Self.localStorageEntry(origin: legacyOrigin, key: "devin_primary_org_id", value: "legacy-org"),
                ]),
        ])

        let sessionInfos = snapshots.compactMap { snapshot in
            WindsurfDevinSessionImporter.session(
                from: snapshot.storage,
                sourceLabel: "Chrome Default (\(snapshot.sourceSuffix ?? "unknown"))")
        }
        WindsurfWebFetcherStubURLProtocol.requests = []
        WindsurfWebFetcherStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "x-devin-session-token") == "legacy-session")
            #expect(request.value(forHTTPHeaderField: "x-devin-auth1-token") == "legacy-auth1")
            #expect(request.value(forHTTPHeaderField: "x-devin-account-id") == "legacy-account")
            #expect(request.value(forHTTPHeaderField: "x-devin-primary-org-id") == "legacy-org")

            let body = try WindsurfPlanStatusProtoCodec.decodeRequest(Self.requestBodyData(from: request))
            #expect(body.authToken == "legacy-session")

            return Self.makeResponse(
                url: url,
                body: Self.makePlanStatusResponse(ResponseFixture(
                    planName: "Pro",
                    dailyRemaining: 70,
                    weeklyRemaining: 85,
                    planEndUnix: 1_777_888_000,
                    dailyResetUnix: 1_777_900_000,
                    weeklyResetUnix: 1_778_000_000)),
                contentType: "application/proto",
                statusCode: 200)
        }

        try await self.withWindsurfSessionOverrides(
            preferredSessions: { _, _ in sessionInfos },
            operation: {
                let snapshot = try await WindsurfWebFetcher.fetchUsage(
                    browserDetection: BrowserDetection(cacheTTL: 0),
                    cookieSource: .auto,
                    timeout: 2,
                    session: self.makeSession())

                #expect(snapshots.count == 1)
                #expect(sessionInfos.map(\.sourceLabel) == ["Chrome Default (windsurf.com)"])
                #expect(WindsurfWebFetcherStubURLProtocol.requests.count == 1)
                #expect(snapshot.identity?.loginMethod == "Pro")
                #expect(snapshot.primary?.usedPercent == 30)
                #expect(snapshot.secondary?.usedPercent == 15)
            })
    }

    @Test
    func `manual mode with empty session does not fall back to imported session`() async {
        defer {
            WindsurfWebFetcherStubURLProtocol.requests = []
            WindsurfWebFetcherStubURLProtocol.handler = nil
        }

        let importedSessions: (BrowserDetection, ((String) -> Void)?)
            -> [WindsurfDevinSessionImporter.SessionInfo] = { _, _ in
                [
                    WindsurfDevinSessionImporter.SessionInfo(
                        session: WindsurfDevinSessionAuth(
                            sessionToken: "auto-token",
                            auth1Token: "auto-auth1",
                            accountID: "auto-account",
                            primaryOrgID: "auto-org"),
                        sourceLabel: "Chrome Default"),
                ]
            }
        WindsurfWebFetcherStubURLProtocol.requests = []

        _ = await self.withWindsurfSessionOverrides(importSessions: importedSessions) {
            await #expect {
                _ = try await WindsurfWebFetcher.fetchUsage(
                    browserDetection: BrowserDetection(cacheTTL: 0),
                    cookieSource: .manual,
                    manualSessionInput: "   \n",
                    timeout: 2,
                    session: self.makeSession())
            } throws: { error in
                guard case let WindsurfWebFetcherError.invalidManualSession(message) = error else { return false }
                return message == "empty input"
            }
        }
        #expect(WindsurfWebFetcherStubURLProtocol.requests.isEmpty)
    }

    @Test
    func `manual key value session input is accepted`() throws {
        let parsed = try WindsurfWebFetcher.parseManualSessionInput(
            """
            devin_session_token=devin-session-token$abc
            devin_auth1_token=auth1_xyz
            devin_account_id=account-123
            devin_primary_org_id=org-456
            """)

        #expect(parsed.sessionToken == "devin-session-token$abc")
        #expect(parsed.auth1Token == "auth1_xyz")
        #expect(parsed.accountID == "account-123")
        #expect(parsed.primaryOrgID == "org-456")
    }

    @Test
    func `manual JSON camelCase aliases are accepted`() throws {
        let parsed = try WindsurfWebFetcher.parseManualSessionInput(
            """
            {
              "devinSessionToken": "devin-session-token$abc",
              "devinAuth1Token": "auth1_xyz",
              "devinAccountId": "account-123",
              "devinPrimaryOrgId": "org-456"
            }
            """)

        #expect(parsed.sessionToken == "devin-session-token$abc")
        #expect(parsed.auth1Token == "auth1_xyz")
        #expect(parsed.accountID == "account-123")
        #expect(parsed.primaryOrgID == "org-456")
    }

    @Test
    func `manual session input rejects empty string`() {
        #expect {
            try WindsurfWebFetcher.parseManualSessionInput("   \n")
        } throws: { error in
            guard case let WindsurfWebFetcherError.invalidManualSession(message) = error else { return false }
            return message == "empty input"
        }
    }

    @Test
    func `manual session input rejects invalid text`() {
        #expect {
            try WindsurfWebFetcher.parseManualSessionInput("not a valid session bundle")
        } throws: { error in
            guard case let WindsurfWebFetcherError.invalidManualSession(message) = error else { return false }
            return message.contains("expected JSON")
        }
    }

    @Test
    func `manual session input rejects missing required fields`() {
        #expect {
            try WindsurfWebFetcher.parseManualSessionInput(
                """
                {
                  "devin_session_token": "devin-session-token$abc",
                  "devin_auth1_token": "auth1_xyz",
                  "devin_account_id": "account-123"
                }
                """)
        } throws: { error in
            guard case let WindsurfWebFetcherError.invalidManualSession(message) = error else { return false }
            return message.contains("expected JSON")
        }
    }

    private static func makeResponse(
        url: URL,
        body: Data,
        contentType: String,
        statusCode: Int) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        return (response, body)
    }

    private static func requestBodyData(from request: URLRequest) -> Data {
        if let data = request.httpBody {
            return data
        }

        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }

        return data
    }

    private static func makePlanStatusResponse(_ fixture: ResponseFixture) -> Data {
        let planInfo = self.message([
            self.stringField(2, fixture.planName),
        ])

        let planStatus = self.message([
            self.messageField(1, planInfo),
            self.messageField(3, self.timestamp(seconds: fixture.planEndUnix)),
            self.varintField(14, UInt64(fixture.dailyRemaining)),
            self.varintField(15, UInt64(fixture.weeklyRemaining)),
            self.varintField(17, UInt64(fixture.dailyResetUnix)),
            self.varintField(18, UInt64(fixture.weeklyResetUnix)),
        ])

        return self.message([
            self.messageField(1, planStatus),
        ])
    }

    private static func timestamp(seconds: Int64) -> Data {
        self.message([
            self.varintField(1, UInt64(seconds)),
        ])
    }

    private static func message(_ fields: [Data]) -> Data {
        fields.reduce(into: Data()) { partialResult, field in
            partialResult.append(field)
        }
    }

    private static func stringField(_ number: Int, _ value: String) -> Data {
        self.lengthDelimitedField(number, Data(value.utf8))
    }

    private static func messageField(_ number: Int, _ value: Data) -> Data {
        self.lengthDelimitedField(number, value)
    }

    private static func lengthDelimitedField(_ number: Int, _ value: Data) -> Data {
        var data = Data()
        data.append(self.fieldKey(number, wireType: 2))
        data.append(self.varint(UInt64(value.count)))
        data.append(value)
        return data
    }

    private static func varintField(_ number: Int, _ value: UInt64) -> Data {
        var data = Data()
        data.append(self.fieldKey(number, wireType: 0))
        data.append(self.varint(value))
        return data
    }

    private static func fieldKey(_ number: Int, wireType: UInt64) -> Data {
        self.varint(UInt64((number << 3) | Int(wireType)))
    }

    private static func varint(_ value: UInt64) -> Data {
        var remaining = value
        var data = Data()
        while remaining >= 0x80 {
            data.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        data.append(UInt8(remaining))
        return data
    }

    private static func localStorageEntry(origin: URL, key: String, value: String) -> ChromiumLocalStorageEntry {
        ChromiumLocalStorageEntry(
            origin: origin.absoluteString,
            key: key,
            value: value,
            rawValueLength: value.utf8.count)
    }
}

final class WindsurfWebFetcherStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let _handlerBox = LockIsolated<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self._handlerBox.value }
        set { Self._handlerBox.setValue(newValue) }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(self.request)
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
