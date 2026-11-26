import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized)
struct AntigravityParityTier5Tests {
    private static func makeTempRoot(_ prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func runCodexBarCLI(
        _ args: [String],
        homeRoot: URL,
        extraEnv: [String: String] = [:]) throws -> (exitCode: Int32, stdout: Data, stderr: Data)
    {
        let cfgURL = homeRoot.appendingPathComponent("codexbar-config.json")
        if !FileManager.default.fileExists(atPath: cfgURL.path) {
            try JSONSerialization.data(withJSONObject: [
                "version": 1,
                "providers": [["id": "antigravity", "enabled": true]],
            ]).write(to: cfgURL)
        }
        let process = Process()
        process.executableURL = TestBuildProducts.executableURL(named: "CodexBarCLI")
        process.arguments = args
        var env: [String: String] = [
            "HOME": homeRoot.path,
            "CFFIXED_USER_HOME": homeRoot.path,
            "CODEXBAR_CONFIG": cfgURL.path,
            "TOKSCALE_CONFIG_DIR": homeRoot.appendingPathComponent(".config/tokscale").path,
            "CODEX_HOME": homeRoot.appendingPathComponent(".codex").path,
            "CODEXBAR_DISABLE_KEYCHAIN_ACCESS": "1",
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
            "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1",
            "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1",
            "PATH": "/usr/bin:/bin",
            "TZ": "UTC",
        ]
        extraEnv.forEach { env[$0.key] = $0.value }
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, outData, errData)
    }

    @Test
    func `CLI usage source produces catalog details and operational availability`() throws {
        let root = try Self.makeTempRoot("ag-t5-cli-usage")
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = root.appendingPathComponent("agy")
        try "1.2.2".write(to: root.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        let reportJSON = #"""
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "description": "Models within this group: Gemini 3.1 Pro, Gemini 3 Flash\r\nResets every 5h.",
                  "buckets": [
                    {
                      "id": "gemini-5h",
                      "name": "5-hour",
                      "window": "5h",
                      "remaining_fraction": 0.85,
                      "remaining_amount": "170"
                    },
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly",
                      "window": "weekly",
                      "remaining_fraction": 0.70
                    }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "description": "Models within this group:\nClaude Sonnet 4.6, GPT-OSS 120B\nResets weekly.",
                  "buckets": [
                    {
                      "id": "3p-5h",
                      "name": "5-hour",
                      "window": "5h",
                      "remaining_fraction": 0.60,
                      "remaining_amount": "42"
                    }
                  ]
                }
              ],
              "model_availabilities": {
                "gemini-3-flash": { "state": "MODEL_AVAILABILITY_STATE_OPERATIONAL" },
                "gemini-3.1-pro": {
                  "state": "MODEL_AVAILABILITY_STATE_CONGESTED",
                  "explanation": "Regional spike"
                }
              }
            }
          }
        }
        """#
        let script = """
        #!/bin/sh
        [ "${1:-}" = --version ] && exec /bin/cat "$HOME/version"
        /bin/cat <<'REPORT'
        \(reportJSON)
        REPORT
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)

        let res = try Self.runCodexBarCLI(
            ["usage", "--provider", "antigravity", "--source", "cli", "--format", "json"],
            homeRoot: root,
            extraEnv: ["ANTIGRAVITY_CLI_PATH": binary.path])
        #expect(res.exitCode == 0)

        let payloads = try #require(JSONSerialization.jsonObject(with: res.stdout) as? [[String: Any]])
        let first = try #require(payloads.first)
        #expect(first["source"] as? String == "cli")
        let usage = try #require(first["usage"] as? [String: Any])
        let catalog = try #require(usage["antigravityCatalog"] as? [String: Any])

        let groups = try #require(catalog["quotaGroups"] as? [[String: Any]])
        #expect(groups.count == 2)
        #expect(groups[0]["models"] as? [String] == ["Gemini 3.1 Pro", "Gemini 3 Flash"])
        #expect(groups[1]["models"] as? [String] == ["Claude Sonnet 4.6", "GPT-OSS 120B"])

        let bucketAmounts = try #require(catalog["bucketAmounts"] as? [[String: Any]])
        #expect(bucketAmounts.compactMap { $0["remainingAmount"] as? Int } == [170, 42])

        let availabilities = try #require(catalog["modelAvailabilities"] as? [String: [String: Any]])
        #expect(availabilities["gemini-3-flash"]?["state"] as? String == "MODEL_AVAILABILITY_STATE_OPERATIONAL")

        let details = try #require(usage["details"] as? [[String: Any]])
        let detailTitles = details.compactMap { $0["title"] as? String }
        #expect(detailTitles == ["Model availability", "Bucket amounts", "Quota groups"])
    }

    @Test(arguments: ["missing-credentials", "invalid-credentials-json"])
    func `CLI usage OAuth source fails closed without Keychain prompt`(mode: String) throws {
        let root = try Self.makeTempRoot("ag-t5-oauth-fail")
        defer { try? FileManager.default.removeItem(at: root) }

        let extraEnv: [String: String] = mode == "invalid-credentials-json"
            ? [AntigravityOAuthCredentialsStore.environmentCredentialsKey: "not-json"]
            : [:]

        let res = try Self.runCodexBarCLI(
            ["usage", "--provider", "antigravity", "--source", "oauth", "--format", "json"],
            homeRoot: root,
            extraEnv: extraEnv)
        #expect(res.exitCode == 1)

        let payloads = try #require(JSONSerialization.jsonObject(with: res.stdout) as? [[String: Any]])
        let errorObj = try #require(payloads.first?["error"] as? [String: Any])
        let message = try #require(errorObj["message"] as? String)
        if mode == "missing-credentials" {
            #expect(message.contains("Antigravity Google auth not found"))
        } else {
            #expect(message.contains("Could not decode selected account credentials"))
        }
    }

    @Test
    func `OAuth empty quota snapshot preserves catalog credits and metadata`() throws {
        let credits = AntigravityCreditsSnapshot(
            prompt: nil,
            flow: nil,
            availableCredits: [AntigravityTierCredit(creditType: "GOOGLE_ONE_AI", creditAmount: 450)])
        let metadata = AntigravityAccountMetadata(
            manageSubscriptionURI: "https://one.google.com/subscriptions")
        let entry = AntigravityModelCatalogEntry(
            modelId: "gemini-3.1-pro",
            label: "Gemini 3.1 Pro",
            creditMultiplier: 1.5,
            pricingType: "MODEL_PRICING_TYPE_STATIC_CREDIT",
            isPremium: true,
            tagTitle: "Flagship")
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [],
            accountEmail: "empty-quota@example.com",
            accountPlan: "Google AI Ultra",
            source: .remote,
            credits: credits,
            accountMetadata: metadata,
            modelCatalog: [entry])

        let usage = try AntigravityOAuthFetchStrategy.usageSnapshot(from: snapshot)
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.identity?.loginMethod == "Google AI Ultra")
        #expect(usage.antigravityCatalog?.modelCatalog == [entry])
        #expect(usage.details.map(\.title) == ["Credits", "Model catalog"])
        #expect(AntigravityProviderDescriptor.subscriptionDashboardURL(from: usage)?.absoluteString
            == "https://one.google.com/subscriptions")
    }
}
