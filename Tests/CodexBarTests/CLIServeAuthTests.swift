import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// Unit coverage for the dashboard snapshot auth surface: option decoding, token
/// resolution, startup validation, and the constant-time bearer-token gate.
struct CLIServeAuthTests {
    @Test
    func `serve help documents dashboard token transport honestly`() {
        let serve = CodexBarCLI.serveHelp(version: "0.0.0")
        let root = CodexBarCLI.rootHelp(version: "0.0.0")

        #expect(serve.contains("--host <host>"))
        #expect(serve.contains("--dashboard-token <token>"))
        #expect(serve.contains("--allow-plain-http"))
        #expect(serve.contains("GET /dashboard/v1/snapshot"))
        #expect(serve.contains("CODEXBAR_DASHBOARD_TOKEN"))
        #expect(serve.contains("cleartext"))
        #expect(!serve.contains("never traverses the network"))
        #expect(root.contains("--dashboard-token <token>"))
        #expect(root.contains("--allow-plain-http"))
    }

    @Test
    func `serve host option parses and normalizes`() {
        #expect(CodexBarCLI.decodeServeHost(from: ParsedValues(
            positional: [],
            options: [:],
            flags: [])) == "127.0.0.1")
        #expect(CodexBarCLI.decodeServeHost(from: ParsedValues(
            positional: [],
            options: ["host": ["0.0.0.0"]],
            flags: [])) == "0.0.0.0")
        #expect(CodexBarCLI.decodeServeHost(from: ParsedValues(
            positional: [],
            options: ["host": ["  "]],
            flags: [])) == nil)
        #expect(CodexBarCLI.decodeServeHost(from: ParsedValues(
            positional: [],
            options: ["host": ["::1"]],
            flags: [])) == nil)
        #expect(CodexBarCLI.decodeServeHost(from: ParsedValues(
            positional: [],
            options: ["host": ["dashboard.local"]],
            flags: [])) == nil)
        #expect(CodexBarCLI.decodeServeHost(from: ParsedValues(
            positional: [],
            options: ["host": ["256.1.1.1"]],
            flags: [])) == nil)

        #expect(CLIServeSecurity.bindHost("localhost") == "127.0.0.1")
        #expect(CLIServeSecurity.bindHost(" LOCALHOST ") == "127.0.0.1")
        #expect(CLIServeSecurity.bindHost("0.0.0.0") == "0.0.0.0")
        #expect(CLIServeSecurity.bindHost("192.168.1.10") == "192.168.1.10")
        #expect(CLIServeSecurity.isSupportedIPv4BindHost("127.0.0.1"))
        #expect(CLIServeSecurity.isSupportedIPv4BindHost("0.0.0.0"))
        #expect(!CLIServeSecurity.isSupportedIPv4BindHost("::1"))
        #expect(!CLIServeSecurity.isSupportedIPv4BindHost("01.2.3.4"))

        #expect(CLIServeSecurity.isLoopbackHost("127.0.0.1"))
        #expect(CLIServeSecurity.isLoopbackHost("127.1.2.3"))
        #expect(CLIServeSecurity.isLoopbackHost("localhost"))
        #expect(CLIServeSecurity.isLoopbackHost("::1"))
        #expect(!CLIServeSecurity.isLoopbackHost("0.0.0.0"))
        #expect(!CLIServeSecurity.isLoopbackHost("192.168.1.10"))

        #expect(CLIServeSecurity.allowedHosts(forBindHost: "127.0.0.1") == .loopbackOnly)
        #expect(CLIServeSecurity.allowedHosts(forBindHost: "127.0.0.2") == .loopbackAnd(["127.0.0.2"]))
        #expect(CLIServeSecurity.allowedHosts(forBindHost: "0.0.0.0") == .any)
        #expect(CLIServeSecurity.allowedHosts(forBindHost: "192.168.1.10")
            == .loopbackAnd(["192.168.1.10"]))
    }

    @Test
    func `serve flags parse through the real commander signature`() throws {
        // Guards the ParsedValues key contract: keys are property names, so a
        // mismatch between --allow-plain-http and its decode key would silently
        // drop the flag. Parse real argv instead of hand-building ParsedValues.
        let parser = CommandParser(signature: CommandSignature.describe(ServeOptions()))
        let values = try parser.parse(arguments: [
            "--host", "0.0.0.0",
            "--dashboard-token", "secret",
            "--allow-plain-http",
        ])
        let defaults = try parser.parse(arguments: [])

        #expect(CodexBarCLI.decodeServeHost(from: values) == "0.0.0.0")
        #expect(CodexBarCLI.decodeServeAllowPlainHTTP(from: values))
        #expect(CodexBarCLI.resolveDashboardToken(from: values, environment: [:]) == .token("secret"))
        #expect(CodexBarCLI.decodeServeHost(from: defaults) == "127.0.0.1")
        #expect(!CodexBarCLI.decodeServeAllowPlainHTTP(from: defaults))
        #expect(CodexBarCLI.resolveDashboardToken(from: defaults, environment: [:]) == .absent)
    }

    @Test
    func `dashboard token resolution prefers the environment and rejects blanks`() {
        let flagValues = ParsedValues(
            positional: [],
            options: ["dashboardBearer": [" flag-token "]],
            flags: [])
        let emptyValues = ParsedValues(positional: [], options: [:], flags: [])
        let envOverride = Dictionary(uniqueKeysWithValues: [
            (CodexBarCLI.dashboardTokenEnvironmentVariable, "ENV_VALUE"),
        ])

        #expect(CodexBarCLI.resolveDashboardToken(
            from: emptyValues,
            environment: [:]) == .absent)
        #expect(CodexBarCLI.resolveDashboardToken(
            from: flagValues,
            environment: [:]) == .token("flag-token"))
        #expect(CodexBarCLI.resolveDashboardToken(
            from: flagValues,
            environment: envOverride) == .token("ENV_VALUE"))
        #expect(CodexBarCLI.resolveDashboardToken(
            from: emptyValues,
            environment: ["CODEXBAR_DASHBOARD_TOKEN": "  "])
            == .empty(source: "CODEXBAR_DASHBOARD_TOKEN"))
        #expect(CodexBarCLI.resolveDashboardToken(
            from: ParsedValues(positional: [], options: ["dashboardBearer": [""]], flags: []),
            environment: [:]) == .empty(source: "--dashboard-token"))
    }

    @Test
    func `serve startup validation enforces the token and plain-http matrix`() {
        // Loopback binds serve regardless of token or acceptance flag.
        #expect(CodexBarCLI.validateServeStartup(
            host: "127.0.0.1",
            hasConfiguredBearer: false,
            allowPlainHTTP: false) == nil)
        #expect(CodexBarCLI.validateServeStartup(
            host: "127.0.0.1",
            hasConfiguredBearer: true,
            allowPlainHTTP: false) == nil)

        // Non-loopback without a token always errors.
        #expect(CodexBarCLI.validateServeStartup(
            host: "0.0.0.0",
            hasConfiguredBearer: false,
            allowPlainHTTP: false) == .missingDashboardToken(host: "0.0.0.0"))
        #expect(CodexBarCLI.validateServeStartup(
            host: "192.168.1.10",
            hasConfiguredBearer: false,
            allowPlainHTTP: true) == .missingDashboardToken(host: "192.168.1.10"))

        // Non-loopback with a token requires the explicit plain-HTTP acceptance.
        #expect(CodexBarCLI.validateServeStartup(
            host: "0.0.0.0",
            hasConfiguredBearer: true,
            allowPlainHTTP: false) == .plainHTTPNotAccepted(host: "0.0.0.0"))
        #expect(CodexBarCLI.validateServeStartup(
            host: "0.0.0.0",
            hasConfiguredBearer: true,
            allowPlainHTTP: true) == nil)
    }

    @Test
    func `dashboard auth compares constant-time digests and fails closed`() {
        let auth = CLIServeDashboardAuth(bearer: "secret")
        let unconfigured = CLIServeDashboardAuth(bearer: nil)

        #expect(auth.isConfigured)
        #expect(!unconfigured.isConfigured)
        #expect(auth.authorize(Self.snapshotRequest(authorization: "Bearer secret")))
        #expect(auth.authorize(Self.snapshotRequest(authorization: "  bearer secret ")))
        #expect(!auth.authorize(Self.snapshotRequest(authorization: "Bearer wrong")))
        #expect(!auth.authorize(Self.snapshotRequest(authorization: "Bearer secret-longer")))
        #expect(!auth.authorize(Self.snapshotRequest(authorization: "secret")))
        #expect(!auth.authorize(Self.snapshotRequest(authorization: nil)))
        // Query strings never carry credentials.
        #expect(!auth.authorize(CLILocalHTTPRequest(
            method: "GET",
            target: "/dashboard/v1/snapshot?token=secret",
            host: "localhost",
            path: "/dashboard/v1/snapshot",
            queryItems: ["token": "secret"],
            authorization: nil)))
        #expect(!unconfigured.authorize(Self.snapshotRequest(authorization: "Bearer secret")))

        #expect(CLIServeDashboardAuth.bearerToken(from: "Bearer abc") == "abc")
        #expect(CLIServeDashboardAuth.bearerToken(from: "Bearer   ") == nil)
        #expect(CLIServeDashboardAuth.bearerToken(from: "Basic abc") == nil)
        #expect(CLIServeDashboardAuth.bearerToken(from: nil) == nil)

        #expect(CLIServeDashboardAuth.constantTimeEquals([1, 2, 3], [1, 2, 3]))
        #expect(!CLIServeDashboardAuth.constantTimeEquals([1, 2, 3], [1, 2, 4]))
        #expect(!CLIServeDashboardAuth.constantTimeEquals([1, 2, 3], [1, 2]))
        #expect(CLIServeDashboardAuth.constantTimeEquals([], []))
    }

    @Test
    func `adding no-store preserves an existing cache-control header`() {
        let plain = CLILocalHTTPResponse(status: .ok, body: Data("[]".utf8))
        let declared = CLILocalHTTPResponse(
            status: .ok,
            body: Data("[]".utf8),
            extraHeaders: [("Cache-Control", "no-store")])

        let annotated = CodexBarCLI.addingNoStore(plain)
        let untouched = CodexBarCLI.addingNoStore(declared)

        #expect(annotated.extraHeaders.contains { $0 == ("Cache-Control", "no-store") })
        #expect(untouched.extraHeaders.count == 1)
        #expect(CodexBarCLI.addingNoStore(annotated).extraHeaders.count == 1)
    }

    @Test
    func `unauthorized response advertises bearer challenge and no-store`() {
        let response = CodexBarCLI.serveUnauthorizedResponse()

        #expect(response.status == .unauthorized)
        #expect(response.extraHeaders.contains { $0 == ("WWW-Authenticate", "Bearer") })
        #expect(response.extraHeaders.contains { $0 == ("Cache-Control", "no-store") })
        let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        #expect(object?["error"] as? String == "unauthorized")
    }

    private static func snapshotRequest(authorization: String?) -> CLILocalHTTPRequest {
        CLILocalHTTPRequest(
            method: "GET",
            target: "/dashboard/v1/snapshot",
            host: "localhost",
            path: "/dashboard/v1/snapshot",
            queryItems: [:],
            authorization: authorization)
    }
}
