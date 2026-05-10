import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct GeminiStatusProbeAPITests {
    @Test
    func `missing credentials throws not logged in`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.notLoggedIn) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `rejects api key auth type`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeSettings(authType: "api-key")

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.unsupportedAuthType("API key")) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `rejects vertex auth type`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeSettings(authType: "vertex-ai")

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.unsupportedAuthType("Vertex AI")) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `refreshes expired token and updates stored credentials`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"))

        let binURL = try env.writeFakeGeminiCLI()
        let previousValue = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        defer {
            if let previousValue {
                setenv("GEMINI_CLI_PATH", previousValue, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
        }

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                // Fail the refresh if the client_id did not come from the test stub.
                // This guards against the probe accidentally extracting OAuth creds
                // from an unrelated Gemini install on the developer's machine.
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard body.contains("client_id=test-client-id") else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 400, body: Data())
                }
                let json = GeminiAPITestHelpers.jsonData([
                    "access_token": "new-token",
                    "expires_in": 3600,
                    "id_token": GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
                ])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudresourcemanager.googleapis.com":
                let json = GeminiAPITestHelpers.jsonData(["projects": []])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    let auth = request.value(forHTTPHeaderField: "Authorization")
                    if auth != "Bearer new-token" {
                        return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                    }
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistStandardTierResponse())
                }
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                let auth = request.value(forHTTPHeaderField: "Authorization")
                if auth != "Bearer new-token" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                }
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.sampleQuotaResponse())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 2, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        let snapshot = try await probe.fetch()
        #expect(snapshot.accountPlan == "Paid")

        let updated = try env.readCredentials()
        #expect(updated["access_token"] as? String == "new-token")
    }

    @Test
    func `refreshes expired token with nix share layout`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"))

        let binURL = try env.writeFakeGeminiCLI(layout: .nixShare)
        let previousValue = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        defer {
            if let previousValue {
                setenv("GEMINI_CLI_PATH", previousValue, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
        }

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                // Fail the refresh if the client_id did not come from the test stub.
                // This guards against the probe accidentally extracting OAuth creds
                // from an unrelated Gemini install on the developer's machine.
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard body.contains("client_id=test-client-id") else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 400, body: Data())
                }
                let json = GeminiAPITestHelpers.jsonData([
                    "access_token": "new-token",
                    "expires_in": 3600,
                    "id_token": GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
                ])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudresourcemanager.googleapis.com":
                let json = GeminiAPITestHelpers.jsonData(["projects": []])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    let auth = request.value(forHTTPHeaderField: "Authorization")
                    if auth != "Bearer new-token" {
                        return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                    }
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistStandardTierResponse())
                }
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                let auth = request.value(forHTTPHeaderField: "Authorization")
                if auth != "Bearer new-token" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                }
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.sampleQuotaResponse())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 2, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        let snapshot = try await probe.fetch()
        #expect(snapshot.accountPlan == "Paid")
    }

    @Test
    func `refreshes expired token with fnm bundle layout`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"))

        let binURL = try env.writeFakeGeminiCLI(layout: .fnmBundle)
        // Match the real fnm layout: package root is inside the same multishell
        // dir as the bin symlink target, under lib/node_modules/@google/gemini-cli.
        let multishellRoot = binURL.deletingLastPathComponent().deletingLastPathComponent()
        let packageJSONPath = multishellRoot
            .appendingPathComponent("lib")
            .appendingPathComponent("node_modules")
            .appendingPathComponent("@google")
            .appendingPathComponent("gemini-cli")
            .appendingPathComponent("package.json")
        let npmRoot = packageJSONPath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        _ = try env.writeFakeFnm(npmRoot: npmRoot, geminiPackageJSONPath: packageJSONPath.path)

        let previousPath = ProcessInfo.processInfo.environment["PATH"]
        let fakeBinDir = env.homeURL.appendingPathComponent("bin").path
        let pathValue = if let previousPath, !previousPath.isEmpty {
            "\(fakeBinDir):\(binURL.deletingLastPathComponent().path):\(previousPath)"
        } else {
            "\(fakeBinDir):\(binURL.deletingLastPathComponent().path)"
        }
        setenv("PATH", pathValue, 1)

        let previousGeminiPath = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        defer {
            if let previousPath {
                setenv("PATH", previousPath, 1)
            } else {
                unsetenv("PATH")
            }

            if let previousGeminiPath {
                setenv("GEMINI_CLI_PATH", previousGeminiPath, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
        }

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                // Fail the refresh if the client_id did not come from the test stub.
                // This guards against the probe accidentally extracting OAuth creds
                // from an unrelated Gemini install on the developer's machine.
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard body.contains("client_id=test-client-id") else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 400, body: Data())
                }
                let json = GeminiAPITestHelpers.jsonData([
                    "access_token": "new-token",
                    "expires_in": 3600,
                    "id_token": GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
                ])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudresourcemanager.googleapis.com":
                let json = GeminiAPITestHelpers.jsonData(["projects": []])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    let auth = request.value(forHTTPHeaderField: "Authorization")
                    if auth != "Bearer new-token" {
                        return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                    }
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistStandardTierResponse())
                }
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                let auth = request.value(forHTTPHeaderField: "Authorization")
                if auth != "Bearer new-token" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                }
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.sampleQuotaResponse())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 2, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        let snapshot = try await probe.fetch()
        #expect(snapshot.accountPlan == "Paid")

        let updated = try env.readCredentials()
        #expect(updated["access_token"] as? String == "new-token")
    }

    @Test
    func `refreshes expired token with homebrew bundle layout`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"))

        let binURL = try env.writeFakeGeminiCLI(layout: .homebrewBundle)
        let previousGeminiPath = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        defer {
            if let previousGeminiPath {
                setenv("GEMINI_CLI_PATH", previousGeminiPath, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
        }

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard body.contains("client_id=test-client-id") else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 400, body: Data())
                }
                let json = GeminiAPITestHelpers.jsonData([
                    "access_token": "new-token",
                    "expires_in": 3600,
                    "id_token": GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
                ])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token" else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                }
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistStandardTierResponse())
                }
                if url.path == "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.sampleQuotaResponse())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 2, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        let snapshot = try await probe.fetch()
        #expect(snapshot.accountPlan == "Paid")

        let updated = try env.readCredentials()
        #expect(updated["access_token"] as? String == "new-token")
    }

    @Test
    func `uses code assist project for quota`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        final class ProjectCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var value: String?

            func set(_ newValue: String?) {
                self.lock.lock()
                self.value = newValue
                self.lock.unlock()
            }

            func get() -> String? {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.value
            }
        }

        let projectId = "managed-project-123"
        let seenProject = ProjectCapture()

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistResponse(
                            tierId: "free-tier",
                            projectId: projectId))
                }
                if url.path == "/v1internal:retrieveUserQuota" {
                    if let body = request.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                    {
                        seenProject.set(json["project"] as? String)
                    }
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.sampleQuotaResponse())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 500, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        _ = try await probe.fetch()
        #expect(seenProject.get() == projectId)
    }

    @Test
    func `falls back to curl loader when URL session times out`() async throws {
        let calls = LoaderCalls()
        let url = try #require(URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"))
        let request = URLRequest(url: url)
        let body = Data("{\"ok\":true}".utf8)
        let loader = GeminiStatusProbe.dataLoaderWithCurlFallback(
            primary: { _ in
                calls.incrementPrimary()
                throw URLError(.timedOut)
            },
            fallback: { request in
                calls.incrementFallback()
                let (response, data) = GeminiAPITestHelpers.response(
                    url: request.url!.absoluteString,
                    status: 200,
                    body: body)
                return (data, response)
            })

        let (loadedBody, loadedResponse) = try await loader(request)
        let counts = calls.counts()
        #expect(loadedBody == body)
        #expect((loadedResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(counts.primary == 1)
        #expect(counts.fallback == 1)
    }

    @Test
    func `does not fall back to curl loader for non-timeout errors`() async throws {
        let calls = LoaderCalls()
        let url = try #require(URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"))
        let request = URLRequest(url: url)
        let loader = GeminiStatusProbe.dataLoaderWithCurlFallback(
            primary: { _ in
                calls.incrementPrimary()
                throw URLError(.cannotFindHost)
            },
            fallback: { request in
                calls.incrementFallback()
                let (response, data) = GeminiAPITestHelpers.response(
                    url: request.url!.absoluteString,
                    status: 200,
                    body: Data())
                return (data, response)
            })

        do {
            _ = try await loader(request)
            Issue.record("Expected non-timeout URLSession error")
        } catch let error as URLError {
            #expect(error.code == .cannotFindHost)
        }

        let counts = calls.counts()
        #expect(counts.primary == 1)
        #expect(counts.fallback == 0)
    }

    @Test
    func `fails refresh when O auth config missing`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: nil)

        let binURL = try env.writeFakeGeminiCLI(includeOAuth: false)
        let previousValue = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        defer {
            if let previousValue {
                setenv("GEMINI_CLI_PATH", previousValue, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.apiError("Could not find Gemini CLI OAuth configuration")) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `reports api errors`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }
            switch host {
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 500, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.apiError("HTTP 500")) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `reports not logged in when access token missing`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.notLoggedIn) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `reports not logged in on401`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }
            switch host {
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.notLoggedIn) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `reports parse errors for invalid payload`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }
            switch host {
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["buckets": []]))
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        do {
            _ = try await probe.fetch()
            #expect(Bool(false))
        } catch {
            let cast = error as? GeminiStatusProbeError
            #expect(cast?.errorDescription?.contains("Could not parse Gemini usage") == true)
        }
    }

    private static func expectError(
        _ expected: GeminiStatusProbeError,
        operation: () async throws -> Void) async
    {
        do {
            try await operation()
            #expect(Bool(false))
        } catch {
            #expect(error as? GeminiStatusProbeError == expected)
        }
    }

    private final class LoaderCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var primaryCount = 0
        private var fallbackCount = 0

        func incrementPrimary() {
            self.lock.lock()
            self.primaryCount += 1
            self.lock.unlock()
        }

        func incrementFallback() {
            self.lock.lock()
            self.fallbackCount += 1
            self.lock.unlock()
        }

        func counts() -> (primary: Int, fallback: Int) {
            self.lock.lock()
            defer { self.lock.unlock() }
            return (self.primaryCount, self.fallbackCount)
        }
    }
}
