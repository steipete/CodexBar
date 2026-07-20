import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct GrokWebBillingFetcherTests {
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.value += 1
            return self.value
        }

        func current() -> Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }
    }

    @Test
    func `provider exposes cli and web source modes`() {
        #expect(GrokProviderDescriptor.descriptor.fetchPlan.sourceModes == [.auto, .cli, .web])
    }

    @Test
    func `descriptor uses Credits label for primary usage window`() {
        let metadata = GrokProviderDescriptor.descriptor.metadata
        #expect(metadata.sessionLabel == "Credits")
        #expect(metadata.weeklyLabel == "On-demand")
        #expect(!metadata.supportsOpus)
    }

    @Test
    func `primaryLabel derives Weekly or Monthly from resetsAt`() {
        let now = Date()
        let in6Days = now.addingTimeInterval(6 * 86400)
        let in30Days = now.addingTimeInterval(30 * 86400)
        let in90Days = now.addingTimeInterval(90 * 86400)
        let lateWeeklyWindow = RateWindow(
            usedPercent: 25,
            windowMinutes: 7 * 24 * 60,
            resetsAt: now.addingTimeInterval(86400),
            resetDescription: nil)

        #expect(GrokProviderDescriptor.primaryLabel(resetsAt: in6Days, now: now) == "Weekly")
        #expect(GrokProviderDescriptor.primaryLabel(resetsAt: in30Days, now: now) == "Monthly")
        #expect(GrokProviderDescriptor.primaryLabel(resetsAt: in90Days, now: now) == nil)
        #expect(GrokProviderDescriptor.primaryLabel(window: lateWeeklyWindow, now: now) == "Weekly")
        #expect(GrokProviderDescriptor.primaryLabel(resetsAt: nil) == nil)
    }

    @Test
    func `cli runtime does not import browser cookies unless explicitly enabled`() {
        #expect(GrokWebFetchStrategy.canImportBrowserCookies(runtime: .app, env: [:]))
        #expect(!GrokWebFetchStrategy.canImportBrowserCookies(runtime: .cli, env: [:]))
        #expect(GrokWebFetchStrategy.canImportBrowserCookies(
            runtime: .cli,
            env: ["CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT": "1"]))
    }

    @Test
    func `web strategy tries later browser session when first cookie is stale`() async throws {
        let stale = try #require(Self.cookie(name: "sso", value: "stale"))
        let valid = try #require(Self.cookie(name: "sso", value: "valid"))
        let sessions = [
            GrokCookieImporter.SessionInfo(cookies: [stale], sourceLabel: "Chrome Profile 1"),
            GrokCookieImporter.SessionInfo(cookies: [valid], sourceLabel: "Chrome Profile 2"),
        ]
        var attemptedHeaders: [String] = []

        let result = try await GrokWebFetchStrategy.fetchFirstValidCookieSession(sessions) { cookieHeader, _ in
            attemptedHeaders.append(cookieHeader)
            guard cookieHeader.contains("valid") else {
                throw GrokWebBillingError.requestFailed(401, "stale")
            }
            return GrokWebBillingSnapshot(
                usedPercent: 12,
                resetsAt: Date(timeIntervalSince1970: 1_800_000_000))
        }

        #expect(attemptedHeaders == ["sso=stale", "sso=valid"])
        #expect(result.0.usedPercent == 12)
        #expect(result.1 == "Chrome Profile 2")
    }

    @Test
    func `cookie authenticated web billing does not reuse auth file identity`() {
        #expect(GrokWebFetchStrategy.credentialsForWebBillingSnapshot(
            credentials: Self.credentials,
            authenticatedByAuthFile: false) == nil)
        #expect(GrokWebFetchStrategy.credentialsForWebBillingSnapshot(
            credentials: Self.credentials,
            authenticatedByAuthFile: true)?
            .email == "grok@example.com")
    }

    @Test
    func `parses grok grpc web billing frame`() throws {
        let reset = UInt64(1_800_000_000)
        let payload = Self.protobufPayload(usedPercent: 42.5, resetEpoch: reset)
        let data = Self.grpcFrame(payload)

        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(
            data,
            now: Date(timeIntervalSince1970: 1_799_000_000))

        #expect(snapshot.usedPercent == 42.5)
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: TimeInterval(reset)))
    }

    @Test
    func `parses unframed grok billing protobuf payload`() throws {
        let hex =
            "0a3f0d7f6a9c3f12001a002206088097f3d0062a060880b191d2063a07080215a9389b3f3a07080115d6ea183c" +
            "421208011206088097f3d0061a060880b191d206"
        let data = try #require(Self.data(hexString: hex))

        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(
            data,
            now: Date(timeIntervalSince1970: 1_780_000_000))

        #expect(snapshot.usedPercent == 1.222000002861023)
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: 1_782_864_000))
    }

    @Test
    func `parses unframed zero percent payload that resembles an empty grpc frame`() throws {
        let reset = UInt64(1_800_000_000)
        let payload = Self.protobufPayload(usedPercent: 0, resetEpoch: reset)

        #expect(GrokWebBillingFetcher.grpcWebDataFrames(from: payload).isEmpty)

        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(
            payload,
            now: Date(timeIntervalSince1970: 1_799_000_000))

        #expect(snapshot.usedPercent == 0)
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: TimeInterval(reset)))
    }

    @Test
    func `does not treat grpc frame prefix as raw protobuf`() {
        #expect(!GrokWebBillingFetcher.looksLikeProtobufPayload(Data([0, 0, 0, 0, 10])))
    }

    @Test
    func `web strategy tries cookie plus bearer before cookie only`() async throws {
        let cookie = try #require(Self.cookie(name: "sso", value: "session"))
        let sessions = [GrokCookieImporter.SessionInfo(cookies: [cookie], sourceLabel: "Chrome")]
        var attempts: [String] = []

        let result = try await GrokWebFetchStrategy.fetchFirstValidCookieSession(
            sessions,
            credentials: Self.credentials)
        { _, authCredentials in
            let mode = authCredentials == nil ? "cookie-only" : "cookie+bearer"
            attempts.append(mode)
            guard mode == "cookie+bearer" else {
                throw GrokWebBillingError.requestFailed(401, "needs bearer")
            }
            return GrokWebBillingSnapshot(usedPercent: 9, resetsAt: nil)
        }

        #expect(attempts == ["cookie+bearer"])
        #expect(result.0.usedPercent == 9)
    }

    @Test
    func `cookie session loop preserves team unsupported billing`() async throws {
        let cookie = try #require(Self.cookie(name: "sso", value: "team-session"))
        let sessions = [GrokCookieImporter.SessionInfo(cookies: [cookie], sourceLabel: "Chrome")]

        await #expect {
            _ = try await GrokWebFetchStrategy.fetchFirstValidCookieSession(
                sessions,
                credentials: Self.credentials)
            { _, authCredentials in
                if authCredentials != nil {
                    throw GrokWebBillingError.teamUsageUnsupported
                }
                throw GrokWebBillingError.rpcFailed(9, "No personal team")
            }
        } throws: { error in
            guard case GrokWebBillingError.teamUsageUnsupported = error else { return false }
            return true
        }
    }

    @Test
    func `web strategy skips expired bearer for browser cookies`() async throws {
        let cookie = try #require(Self.cookie(name: "sso", value: "session"))
        let sessions = [GrokCookieImporter.SessionInfo(cookies: [cookie], sourceLabel: "Chrome")]
        let expired = GrokCredentials(
            accessToken: "expired-token",
            refreshToken: nil,
            scope: "https://auth.x.ai::client",
            authMode: "oidc",
            userId: nil,
            email: nil,
            firstName: nil,
            lastName: nil,
            teamId: nil,
            oidcIssuer: nil,
            oidcClientId: nil,
            expiresAt: .distantPast,
            createTime: nil)
        var attempts: [String] = []

        _ = try await GrokWebFetchStrategy.fetchFirstValidCookieSession(
            sessions,
            credentials: expired)
        { _, authCredentials in
            attempts.append(authCredentials == nil ? "cookie-only" : "cookie+bearer")
            return GrokWebBillingSnapshot(usedPercent: 9, resetsAt: nil)
        }

        #expect(attempts == ["cookie-only"])
    }

    @Test
    func `web strategy preserves malformed auth file error`() async throws {
        let grokHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-GrokWebBilling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: grokHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: grokHome) }
        try Data("not-json".utf8).write(to: grokHome.appendingPathComponent("auth.json"))

        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: true,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: ["GROK_HOME": grokHome.path],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)

        await #expect {
            _ = try await GrokWebFetchStrategy().fetch(context)
        } throws: { error in
            guard case GrokCredentialsError.decodeFailed = error else { return false }
            return true
        }
    }

    @Test
    func `status seven scope failure is not classified as bad credentials`() {
        #expect(!GrokWebBillingError.isAuthenticationFailure(
            status: 7,
            message: "OAuth2 access token lacks the required billing scope"))
    }

    @Test
    func `only a team principal with no personal team gets unsupported billing guidance`() {
        #expect(GrokWebBillingFetcher.isTeamBillingUnavailable(
            status: 9,
            message: "No personal team"))
        #expect(GrokWebBillingFetcher.isTeamBillingUnavailable(
            status: 9,
            message: " no PERSONAL team "))
        #expect(GrokWebBillingFetcher.isTeamBillingUnavailable(
            status: 9,
            message: "No personal team."))
        #expect(!GrokWebBillingFetcher.isTeamBillingUnavailable(
            status: 9,
            message: "Permission denied"))
        #expect(!GrokWebBillingFetcher.isTeamBillingUnavailable(
            status: 7,
            message: "No personal team"))
        #expect(GrokWebBillingError.teamUsageUnsupported.errorDescription?.contains("identity") == false)
    }

    @Test
    func `team principal status nine response is classified as unsupported billing`() async throws {
        defer {
            GrokWebBillingStubURLProtocol.requests = []
            GrokWebBillingStubURLProtocol.requestBodies = []
            GrokWebBillingStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokWebBillingStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = try #require(URL(string: "https://grok.test/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"))
        let message = "No personal team.".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? "No personal team."
        let body = Self.grpcFrame(
            Data("grpc-status: 9\r\ngrpc-message: \(message)\r\n".utf8),
            flags: 0x80)

        GrokWebBillingStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/grpc-web+proto"])!
            return (response, body)
        }

        await #expect {
            _ = try await GrokWebBillingFetcher.fetch(
                credentials: Self.credentials,
                session: session,
                endpoint: endpoint)
        } throws: { error in
            guard case GrokWebBillingError.teamUsageUnsupported = error else { return false }
            return true
        }

        let expiredCredentials = GrokCredentials(
            accessToken: "expired-token",
            refreshToken: nil,
            scope: Self.credentials.scope,
            authMode: Self.credentials.authMode,
            userId: Self.credentials.userId,
            email: Self.credentials.email,
            firstName: Self.credentials.firstName,
            lastName: Self.credentials.lastName,
            teamId: Self.credentials.teamId,
            principalType: Self.credentials.principalType,
            oidcIssuer: Self.credentials.oidcIssuer,
            oidcClientId: Self.credentials.oidcClientId,
            expiresAt: .distantPast,
            createTime: Self.credentials.createTime)

        await #expect {
            _ = try await GrokWebBillingFetcher.fetch(
                cookieHeader: "sso=team-session",
                credentials: expiredCredentials,
                session: session,
                endpoint: endpoint)
        } throws: { error in
            guard case let GrokWebBillingError.rpcFailed(status, message) = error else { return false }
            return status == 9 && message == "No personal team."
        }

        await #expect {
            _ = try await GrokWebBillingFetcher.fetch(
                credentials: expiredCredentials,
                session: session,
                endpoint: endpoint)
        } throws: { error in
            guard case let GrokWebBillingError.rpcFailed(status, message) = error else { return false }
            return status == 9 && message == "No personal team."
        }
    }

    @Test
    func `web strategy publishes identity-only result for team billing`() async throws {
        let grokHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-GrokTeamFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: grokHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: grokHome) }
        let auth = #"""
        {
          "https://auth.x.ai::client": {
            "key": "team-token",
            "email": "team@example.com",
            "team_id": "team-123",
            "principal_type": "Team"
          }
        }
        """#
        try Data(auth.utf8).write(to: grokHome.appendingPathComponent("auth.json"))

        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: true,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [
                "GROK_HOME": grokHome.path,
                "GROK_CLI_PATH": grokHome.appendingPathComponent("missing-grok").path,
                "PATH": grokHome.path,
            ],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)

        let result = try await GrokWebFetchStrategy().fetch(context) {
            throw GrokWebBillingError.teamUsageUnsupported
        }

        #expect(result.sourceLabel == "grok-web")
        #expect(result.diagnostic == GrokStatusProbe.teamUsageUnavailableMessage)
        #expect(result.usage.primary == nil)
        #expect(result.usage.accountEmail(for: .grok) == "team@example.com")
        #expect(result.usage.accountOrganization(for: .grok) == "team-123")
    }

    @Test
    func `ignores grpc web trailer frames`() {
        let payload = Self.protobufPayload(usedPercent: 12.25, resetEpoch: 1_800_000_001)
        let trailer = Data("grpc-status: 0\r\n".utf8)
        let data = Self.grpcFrame(payload) + Self.grpcFrame(trailer, flags: 0x80)

        let frames = GrokWebBillingFetcher.grpcWebDataFrames(from: data)

        #expect(frames == [payload])
    }

    @Test
    func `web fetch turns grpc unauthenticated trailer into reauth guidance`() async throws {
        defer {
            GrokWebBillingStubURLProtocol.requests = []
            GrokWebBillingStubURLProtocol.requestBodies = []
            GrokWebBillingStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokWebBillingStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = try #require(URL(string: "https://grok.test/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"))
        let body = Self.grpcFrame(Data("grpc-status: 16\r\ngrpc-message: token%20expired\r\n".utf8), flags: 0x80)

        #expect(GrokWebBillingFetcher.grpcWebTrailerFields(from: body)["grpc-status"] == "16")

        GrokWebBillingStubURLProtocol.requests = []
        GrokWebBillingStubURLProtocol.requestBodies = []
        GrokWebBillingStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/grpc-web+proto"])!
            return (response, body)
        }

        await #expect {
            _ = try await GrokWebBillingFetcher.fetch(
                credentials: Self.credentials,
                session: session,
                endpoint: endpoint)
        } throws: { error in
            error.localizedDescription.contains("grok login")
        }
    }

    @Test
    func `web fetch turns grpc unauthenticated headers into reauth guidance`() async throws {
        defer {
            GrokWebBillingStubURLProtocol.requests = []
            GrokWebBillingStubURLProtocol.requestBodies = []
            GrokWebBillingStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokWebBillingStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = try #require(URL(string: "https://grok.test/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"))

        GrokWebBillingStubURLProtocol.requests = []
        GrokWebBillingStubURLProtocol.requestBodies = []
        GrokWebBillingStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/grpc-web+proto",
                    "grpc-status": "16",
                    "grpc-message": "Invalid%20bearer%20token.",
                ])!
            return (response, Data())
        }

        await #expect {
            _ = try await GrokWebBillingFetcher.fetch(
                credentials: Self.credentials,
                session: session,
                endpoint: endpoint)
        } throws: { error in
            error.localizedDescription.contains("grok login")
        }
    }

    @Test
    func `web fetch turns grpc permission denied bad credentials into reauth guidance`() async throws {
        defer {
            GrokWebBillingStubURLProtocol.requests = []
            GrokWebBillingStubURLProtocol.requestBodies = []
            GrokWebBillingStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokWebBillingStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = try #require(URL(string: "https://grok.test/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"))
        let message = "The OAuth2 access token could not be validated. [WKE=unauthenticated:bad-credentials]"
        let encodedMessage = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? message
        let body = Self.grpcFrame(
            Data("grpc-status: 7\r\ngrpc-message: \(encodedMessage)\r\n".utf8),
            flags: 0x80)

        GrokWebBillingStubURLProtocol.requests = []
        GrokWebBillingStubURLProtocol.requestBodies = []
        GrokWebBillingStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/grpc-web+proto"])!
            return (response, body)
        }

        await #expect {
            _ = try await GrokWebBillingFetcher.fetch(
                credentials: Self.credentials,
                session: session,
                endpoint: endpoint)
        } throws: { error in
            error.localizedDescription.contains("grok.com") &&
                error.localizedDescription.contains("grok login") &&
                !error.localizedDescription.contains("status 7")
        }
    }

    @Test
    func `rejects reset only billing because it cannot render usage`() {
        var payload = Data()
        payload.append(0x10) // field 2, varint reset timestamp
        payload.append(contentsOf: Self.varint(1_800_000_001))

        #expect {
            _ = try GrokWebBillingFetcher.parseGRPCWebResponse(Self.grpcFrame(payload))
        } throws: { error in
            guard case GrokWebBillingError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `parses grok no usage yet billing response as zero percent`() throws {
        let data = Data([
            0x00, 0x00, 0x00, 0x00, 0x37, 0x0A, 0x35, 0x12,
            0x00, 0x1A, 0x00, 0x22, 0x06, 0x08, 0x80, 0xDA,
            0xCF, 0xCF, 0x06, 0x2A, 0x06, 0x08, 0x80, 0x97,
            0xF3, 0xD0, 0x06, 0x32, 0x09, 0x0A, 0x05, 0x08,
            0xEA, 0x0F, 0x10, 0x04, 0x12, 0x00, 0x32, 0x09,
            0x0A, 0x05, 0x08, 0xEA, 0x0F, 0x10, 0x03, 0x12,
            0x00, 0x32, 0x09, 0x0A, 0x05, 0x08, 0xEA, 0x0F,
            0x10, 0x02, 0x12, 0x00, 0x80, 0x00, 0x00, 0x00,
            0x0F, 0x67, 0x72, 0x70, 0x63, 0x2D, 0x73, 0x74,
            0x61, 0x74, 0x75, 0x73, 0x3A, 0x30, 0x0D, 0x0A,
        ])

        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(
            data,
            now: Date(timeIntervalSince1970: 1_768_000_000))

        #expect(snapshot.usedPercent == 0)
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: 1_780_272_000))
    }

    @Test
    func `parses omitted zero percent with current billing period`() throws {
        let data = Data([
            0x00, 0x00, 0x00, 0x00, 0x2A, 0x0A, 0x28, 0x12,
            0x00, 0x1A, 0x00, 0x22, 0x06, 0x08, 0x80, 0x97,
            0xF3, 0xD0, 0x06, 0x2A, 0x06, 0x08, 0x80, 0xB1,
            0x91, 0xD2, 0x06, 0x42, 0x12, 0x08, 0x01, 0x12,
            0x06, 0x08, 0x80, 0x97, 0xF3, 0xD0, 0x06, 0x1A,
            0x06, 0x08, 0x80, 0xB1, 0x91, 0xD2, 0x06, 0x80,
            0x00, 0x00, 0x00, 0x0F, 0x67, 0x72, 0x70, 0x63,
            0x2D, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x3A,
            0x30, 0x0D, 0x0A,
        ])

        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(
            data,
            now: Date(timeIntervalSince1970: 1_781_000_000))

        #expect(snapshot.usedPercent == 0)
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: 1_782_864_000))
    }

    @Test
    func `uses billing field one instead of earlier unrelated float`() throws {
        var payload = Data()
        payload.append(0x4D) // field 9, fixed32 unrelated in-range float
        var unrelatedBits = Float(7).bitPattern.littleEndian
        withUnsafeBytes(of: &unrelatedBits) { payload.append(contentsOf: $0) }
        payload.append(0x0D) // field 1, fixed32 billing usage percent
        var usageBits = Float(42).bitPattern.littleEndian
        withUnsafeBytes(of: &usageBits) { payload.append(contentsOf: $0) }
        payload.append(0x10) // field 2, varint reset timestamp
        payload.append(contentsOf: Self.varint(1_800_000_001))

        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(Self.grpcFrame(payload))

        #expect(snapshot.usedPercent == 42)
    }

    @Test
    func `chooses future billing end instead of recent billing start`() throws {
        let recentStart = UInt64(1_800_000_000)
        let billingEnd = UInt64(1_802_592_000)
        var payload = Data()
        payload.append(0x0D) // field 1, fixed32 usage percent
        var percentBits = Float(33).bitPattern.littleEndian
        withUnsafeBytes(of: &percentBits) { payload.append(contentsOf: $0) }
        payload.append(0x10) // field 2, varint billing start
        payload.append(contentsOf: Self.varint(recentStart))
        payload.append(0x18) // field 3, varint billing end
        payload.append(contentsOf: Self.varint(billingEnd))

        let snapshot = try GrokWebBillingFetcher.parseGRPCWebResponse(
            Self.grpcFrame(payload),
            now: Date(timeIntervalSince1970: TimeInterval(recentStart + 1800)))

        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: TimeInterval(billingEnd)))
    }

    @Test
    func `web fetch posts grpc web request with bearer token`() async throws {
        defer {
            GrokWebBillingStubURLProtocol.requests = []
            GrokWebBillingStubURLProtocol.requestBodies = []
            GrokWebBillingStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokWebBillingStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = try #require(URL(string: "https://grok.test/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"))
        let reset = UInt64(1_800_000_002)

        GrokWebBillingStubURLProtocol.requests = []
        GrokWebBillingStubURLProtocol.requestBodies = []
        GrokWebBillingStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(url == endpoint)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://grok.com")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://grok.com/?_s=usage")
            #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/grpc-web+proto")
            #expect(request.value(forHTTPHeaderField: "x-grpc-web") == "1")
            #expect(request.timeoutInterval == 15)

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/grpc-web+proto"])!
            let body = Self.grpcFrame(Self.protobufPayload(usedPercent: 55.5, resetEpoch: reset))
            return (response, body)
        }

        let snapshot = try await GrokWebBillingFetcher.fetch(
            credentials: Self.credentials,
            session: session,
            endpoint: endpoint)

        #expect(GrokWebBillingStubURLProtocol.requests.count == 1)
        #expect(GrokWebBillingStubURLProtocol.requestBodies == [Data([0x00, 0x00, 0x00, 0x00, 0x00])])
        #expect(snapshot.usedPercent == 55.5)
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: TimeInterval(reset)))
    }

    @Test
    func `web fetch retries transient grpc timeout once`() async throws {
        defer {
            GrokWebBillingStubURLProtocol.requests = []
            GrokWebBillingStubURLProtocol.requestBodies = []
            GrokWebBillingStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokWebBillingStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = try #require(URL(string: "https://grok.test/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"))
        let reset = UInt64(1_800_000_005)
        let attempts = AttemptCounter()

        GrokWebBillingStubURLProtocol.requests = []
        GrokWebBillingStubURLProtocol.requestBodies = []
        GrokWebBillingStubURLProtocol.handler = { request in
            let attempt = attempts.increment()
            let url = try #require(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/grpc-web+proto"])!
            if attempt == 1 {
                let body = Self.grpcFrame(
                    Data("grpc-status: 1\r\ngrpc-message: Timeout%20expired\r\n".utf8),
                    flags: 0x80)
                return (response, body)
            }
            return (response, Self.grpcFrame(Self.protobufPayload(usedPercent: 25, resetEpoch: reset)))
        }

        let snapshot = try await GrokWebBillingFetcher.fetch(
            credentials: Self.credentials,
            session: session,
            endpoint: endpoint)

        #expect(attempts.current() == 2)
        #expect(GrokWebBillingStubURLProtocol.requests.count == 2)
        #expect(snapshot.usedPercent == 25)
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: TimeInterval(reset)))
    }

    @Test
    func `web fetch retries grpc deadline exceeded without message`() async throws {
        defer {
            GrokWebBillingStubURLProtocol.requests = []
            GrokWebBillingStubURLProtocol.requestBodies = []
            GrokWebBillingStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokWebBillingStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = try #require(URL(string: "https://grok.test/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"))
        let attempts = AttemptCounter()

        GrokWebBillingStubURLProtocol.requests = []
        GrokWebBillingStubURLProtocol.requestBodies = []
        GrokWebBillingStubURLProtocol.handler = { request in
            let attempt = attempts.increment()
            let url = try #require(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/grpc-web+proto"])!
            if attempt == 1 {
                return (response, Self.grpcFrame(Data("grpc-status: 4\r\n".utf8), flags: 0x80))
            }
            return (response, Self.grpcFrame(Self.protobufPayload(usedPercent: 25, resetEpoch: 1_800_000_005)))
        }

        let snapshot = try await GrokWebBillingFetcher.fetch(
            credentials: Self.credentials,
            session: session,
            endpoint: endpoint)

        #expect(attempts.current() == 2)
        #expect(snapshot.usedPercent == 25)
    }

    @Test
    func `web fetch retries HTTP gateway timeout once`() async throws {
        defer {
            GrokWebBillingStubURLProtocol.requests = []
            GrokWebBillingStubURLProtocol.requestBodies = []
            GrokWebBillingStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokWebBillingStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = try #require(URL(string: "https://grok.test/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"))
        let attempts = AttemptCounter()

        GrokWebBillingStubURLProtocol.requests = []
        GrokWebBillingStubURLProtocol.requestBodies = []
        GrokWebBillingStubURLProtocol.handler = { request in
            let attempt = attempts.increment()
            let url = try #require(request.url)
            let statusCode = attempt == 1 ? 504 : 200
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/grpc-web+proto"])!
            if attempt == 1 {
                return (response, Data("gateway timeout".utf8))
            }
            return (response, Self.grpcFrame(Self.protobufPayload(usedPercent: 25, resetEpoch: 1_800_000_005)))
        }

        let snapshot = try await GrokWebBillingFetcher.fetch(
            credentials: Self.credentials,
            session: session,
            endpoint: endpoint)

        #expect(attempts.current() == 2)
        #expect(snapshot.usedPercent == 25)
    }
}

extension GrokWebBillingFetcherTests {
    @Test
    func `web fetch can authenticate with browser cookies`() async throws {
        defer {
            GrokWebBillingStubURLProtocol.requests = []
            GrokWebBillingStubURLProtocol.requestBodies = []
            GrokWebBillingStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokWebBillingStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = try #require(URL(string: "https://grok.test/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"))

        GrokWebBillingStubURLProtocol.requests = []
        GrokWebBillingStubURLProtocol.requestBodies = []
        GrokWebBillingStubURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "sso=session; sso-rw=session")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "x-user-agent") == "connect-es/2.1.1")
            let response = HTTPURLResponse(
                url: endpoint,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/grpc-web+proto"])!
            let body = Self.grpcFrame(Self.protobufPayload(usedPercent: 9, resetEpoch: 1_800_000_004))
            return (response, body)
        }

        let snapshot = try await GrokWebBillingFetcher.fetch(
            cookieHeader: "sso=session; sso-rw=session",
            session: session,
            endpoint: endpoint)

        #expect(snapshot.usedPercent == 9)
    }

    @Test
    func `web fetch sends browser cookies with bearer credentials`() async throws {
        defer {
            GrokWebBillingStubURLProtocol.requests = []
            GrokWebBillingStubURLProtocol.requestBodies = []
            GrokWebBillingStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokWebBillingStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = try #require(URL(string: "https://grok.test/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"))

        GrokWebBillingStubURLProtocol.requests = []
        GrokWebBillingStubURLProtocol.requestBodies = []
        GrokWebBillingStubURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "sso=session")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")
            let response = HTTPURLResponse(
                url: endpoint,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/grpc-web+proto"])!
            return (response, Self.protobufPayload(usedPercent: 9, resetEpoch: 1_800_000_004))
        }

        let snapshot = try await GrokWebBillingFetcher.fetch(
            cookieHeader: "sso=session",
            credentials: Self.credentials,
            session: session,
            endpoint: endpoint)

        #expect(snapshot.usedPercent == 9)
    }

    @Test
    func `web fetch turns unauthorized response into reauth guidance`() async throws {
        defer {
            GrokWebBillingStubURLProtocol.requests = []
            GrokWebBillingStubURLProtocol.requestBodies = []
            GrokWebBillingStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokWebBillingStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = try #require(URL(string: "https://grok.test/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"))

        GrokWebBillingStubURLProtocol.requests = []
        GrokWebBillingStubURLProtocol.requestBodies = []
        GrokWebBillingStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"])!
            return (response, Data("unauthorized".utf8))
        }

        await #expect {
            _ = try await GrokWebBillingFetcher.fetch(
                credentials: Self.credentials,
                session: session,
                endpoint: endpoint)
        } throws: { error in
            error.localizedDescription.contains("grok login")
        }
    }

    @Test
    func `usage snapshot maps web billing when cli billing is absent`() {
        let snapshot = GrokUsageSnapshot(
            billing: nil,
            webBilling: GrokWebBillingSnapshot(
                usedPercent: 67.25,
                resetsAt: Date(timeIntervalSince1970: 1_800_000_003)),
            credentials: Self.credentials,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: Date(timeIntervalSince1970: 1_799_000_000))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 67.25)
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_800_000_003))
        #expect(usage.accountEmail(for: .grok) == "grok@example.com")
        #expect(usage.loginMethod(for: .grok) == "SuperGrok")
    }

    private static let credentials = GrokCredentials(
        accessToken: "token-123",
        refreshToken: "refresh-123",
        scope: "https://auth.x.ai::client",
        authMode: "oidc",
        userId: "user-123",
        email: "grok@example.com",
        firstName: "G",
        lastName: "Rok",
        teamId: "team-123",
        principalType: "Team",
        oidcIssuer: "https://auth.x.ai",
        oidcClientId: "client",
        expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
        createTime: Date(timeIntervalSince1970: 1_799_000_000))

    private static func protobufPayload(usedPercent: Float, resetEpoch: UInt64) -> Data {
        var data = Data()
        data.append(0x0D) // field 1, fixed32
        var percentBits = usedPercent.bitPattern.littleEndian
        withUnsafeBytes(of: &percentBits) { data.append(contentsOf: $0) }
        data.append(0x10) // field 2, varint
        data.append(contentsOf: Self.varint(resetEpoch))
        return data
    }

    private static func grpcFrame(_ payload: Data, flags: UInt8 = 0x00) -> Data {
        var data = Data([flags])
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    private static func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }

    private static func cookie(name: String, value: String) -> HTTPCookie? {
        HTTPCookie(properties: [
            .domain: "grok.com",
            .path: "/",
            .name: name,
            .value: value,
        ])
    }

    private static func data(hexString: String) -> Data? {
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

final class GrokWebBillingStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var requestBodies: [Data?] = []
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
        Self.requestBodies.append(Self.readBody(from: self.request))
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

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}
