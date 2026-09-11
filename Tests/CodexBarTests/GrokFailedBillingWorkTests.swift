import Foundation
import Testing
@testable import CodexBarCore

struct GrokFailedBillingWorkTests {
    enum Scenario: String, CaseIterable, Sendable {
        case personalUnavailable, teamUnauthorized, initializationFailure, expiredTeam, teamFallback, billingSuccess
        case expiresDuringScan, expiresDuringVersion, acceptedIdentity

        var acceptsSnapshot: Bool {
            self == .teamFallback || self == .billingSuccess || self == .acceptedIdentity
        }

        var scansBeforeResult: Bool {
            self.acceptsSnapshot || self == .expiresDuringScan || self == .expiresDuringVersion
        }

        var errorMessage: String {
            switch self {
            case .teamUnauthorized: "Unauthorized"
            case .initializationFailure: "Initialize failed"
            default: "Method not found"
            }
        }
    }

    @Test(arguments: Scenario.allCases)
    func `terminal billing failures skip local history and settings work`(_ scenario: Scenario) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if scenario != .personalUnavailable, scenario != .billingSuccess {
            let auth = try JSONSerialization.data(withJSONObject: [
                "https://auth.x.ai::fake-client": [
                    "key": "synthetic-token", "refresh_token": "synthetic-refresh",
                    "email": "team@example.com", "team_id": "example-team", "user_id": "example-user",
                    "auth_mode": "oidc", "principal_type": "Team",
                    "expires_at": [.expiredTeam, .acceptedIdentity].contains(scenario)
                        ? "2000-01-01T00:00:00Z" : "2099-01-01T00:00:00Z",
                ],
            ])
            try auth.write(to: root.appendingPathComponent("auth.json"))
        }
        let binary = root.appendingPathComponent("grok-fixture")
        func reply(id: Int, result: [String: Any], error: String?) throws -> String {
            var value: [String: Any] = ["jsonrpc": "2.0", "id": id]
            if let error {
                value["error"] = ["code": -32601, "message": error]
            } else {
                value["result"] = result
            }
            let data = try JSONSerialization.data(withJSONObject: value)
            return try #require(String(bytes: data, encoding: .utf8))
        }
        let initialize = try reply(
            id: 1, result: [:], error: scenario == .initializationFailure ? scenario.errorMessage : nil)
        let billing = try reply(
            id: 2,
            result: ["monthlyLimit": ["val": 100], "usage": ["totalUsed": ["val": 25]]],
            error: scenario == .billingSuccess ? nil : scenario.errorMessage)
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            if [ "$GROK_TEST_MARK_EXPIRY" = "1" ]; then : > "$GROK_HOME/expiry-marker"; fi
            printf '%s\\n' 'grok synthetic-version'
            exit 0
        fi
        IFS= read -r initialize_request
        printf '%s\\n' '\(initialize)'
        IFS= read -r billing_request || exit 0
        printf '%s\\n' '\(billing)'
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let environment = [
            "HOME": root.path,
            "GROK_HOME": root.path,
            "GROK_CLI_PATH": binary.path,
            "PATH": "/usr/bin:/bin",
            "GROK_TEST_MARK_EXPIRY": scenario == .expiresDuringVersion ? "1" : "0",
        ]
        let calls = GrokFetchWorkRecorder()
        let summary = GrokLocalSessionSummary(
            sessionCount: 2,
            totalTokens: 42,
            lastSessionAt: nil,
            primaryModel: "example-model",
            models: ["example-model"],
            daily: [.init(date: "2026-09-11", totalTokens: 42, sessionCount: 2, models: [])])
        let expiryMarker = root.appendingPathComponent("expiry-marker")
        var probe = GrokStatusProbe()
        if scenario == .expiresDuringScan || scenario == .expiresDuringVersion {
            probe.identityOnlyFallback = { credentials, attempted, error in
                GrokStatusProbe.shouldUseIdentityOnlyFallback(
                    credentials: credentials, billingAttempted: attempted, error: error)
                    && !FileManager.default.fileExists(atPath: expiryMarker.path)
            }
        } else if scenario == .acceptedIdentity {
            // Model a prior accepted decision without racing a wall clock; the default expired case stays rejected.
            probe.identityOnlyFallback = { _, _, _ in true }
        }
        probe.localSummary = { receivedEnvironment in
            #expect(receivedEnvironment == environment)
            await calls.scanned()
            if scenario == .expiresDuringScan { try Data().write(to: expiryMarker) }
            return summary
        }
        probe.settingsTransport = ProviderHTTPTransportHandler { request in
            #expect(request.url == GrokCLISettingsFetcher.defaultEndpoint)
            await calls.loadedSettings()
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data("{\"subscription_tier_display\":\"Grok Team\"}".utf8), response)
        }

        do {
            let snapshot = try await probe.fetch(env: environment)
            #expect(scenario.acceptsSnapshot)
            #expect(snapshot.localSummary?.totalTokens == 42)
            #expect(snapshot.localSummary?.daily == summary.daily)
            #expect(snapshot.cliVersion == "synthetic-version")
            if scenario != .billingSuccess {
                #expect(snapshot.billing == nil)
                #expect(snapshot.credentials?.email == "team@example.com")
                #expect(snapshot.diagnostic == GrokStatusProbe.teamUsageUnavailableMessage)
            } else {
                #expect(snapshot.billing?.monthlyUsedPercent == 25)
                #expect(snapshot.diagnostic == nil)
            }
        } catch let error as GrokRPCError {
            #expect(!scenario.acceptsSnapshot)
            guard case let .requestFailed(message) = error else {
                Issue.record("Unexpected RPC error: \(error)")
                return
            }
            #expect(message == scenario.errorMessage)
        }
        #expect(await calls.scans == (scenario.scansBeforeResult ? 1 : 0))
        #expect(await calls.settings == (scenario == .teamFallback ? 1 : 0))
    }
}

private actor GrokFetchWorkRecorder {
    private(set) var scans = 0
    private(set) var settings = 0
    func scanned() {
        self.scans += 1
    }

    func loadedSettings() {
        self.settings += 1
    }
}
