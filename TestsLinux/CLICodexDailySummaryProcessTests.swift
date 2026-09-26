import Foundation
import Testing
@testable import CodexBarCore

struct CLICodexDailySummaryProcessTests {
    @Test(arguments: ["valid", "invalidZone", "zoneOnly", "conflictingMode", "periodAll", "periodMonth", "legacySummary"])
    func `daily CLI validates and scans independently of unrelated unreadable config`(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex")
        let sessions = codex.appendingPathComponent("sessions")
        let config = root.appendingPathComponent("unreadable-config")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        // A directory cannot be decoded as a configuration file, even when tests run as root.
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let now = Date()
        let timestamp = now.ISO8601Format()
        let lines = """
        {"type":"session_meta","timestamp":"\(timestamp)","payload":{"id":"synthetic-session"}}
        {"type":"turn_context","timestamp":"\(timestamp)","payload":{"model":"gpt-5.4"}}
        {"type":"event_msg","timestamp":"\(timestamp)",\
        "payload":{"type":"token_count","info":{"model":"gpt-5.4",\
        "total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}
        """
        try Data((lines + "\n").utf8).write(to: sessions.appendingPathComponent("fixture.jsonl"))
        let prices = #"{"openai":{"id":"openai","models":{"gpt-5.4":{"id":"gpt-5.4","cost":{"#
            + #""input":2,"output":8,"cache_read":0.5}}}}}"#
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(prices.utf8))
        // Foundation uses the fixed home on Darwin and XDG cache location on Linux.
        for path in ["Library/Caches/CodexBar", "cache/CodexBar"] {
            try #require(ModelsDevCache.save(
                catalog: catalog, fetchedAt: now, cacheRoot: root.appendingPathComponent(path)))
        }
        let environment = [
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "CODEX_HOME": codex.path,
            "CODEXBAR_CONFIG": config.path,
            "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1",
            "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1",
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        ]
        var arguments = [
            "cost", "--provider", "codex", "--format", "json", "--provider-native-only",
            "--daily-summary", "--days", "30", "--bucket-time-zone", mode == "invalidZone" ? "invalid/fixture" : "GMT",
        ]
        if mode == "zoneOnly" { arguments.removeAll { $0 == "--daily-summary" } }
        if mode == "conflictingMode" { arguments.append("--summary-only") }
        if mode == "periodAll" { arguments += ["--period", "all"] }
        if mode == "periodMonth" { arguments += ["--period", "month-to-date"] }
        if mode == "legacySummary" {
            arguments.removeLast(2)
            arguments.removeAll { $0 == "--daily-summary" }
            arguments.append("--summary-only")
        }
        let bundleURL = Bundle(for: DailySummaryProcessBundle.self).bundleURL
        #if os(Linux)
        let binary = bundleURL.appendingPathComponent("CodexBarCLI")
        #else
        let binary = bundleURL.deletingLastPathComponent().appendingPathComponent("CodexBarCLI")
        #endif
        let result = try await SubprocessRunner.run(
            binary: binary.path,
            arguments: arguments,
            environment: environment,
            timeout: 15,
            maxOutputBytes: 16 * 1024,
            standardInput: FileHandle.nullDevice,
            currentDirectoryURL: root,
            acceptsNonZeroExit: true,
            label: "isolated daily CLI")
        let response = try #require(
            (JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])?.first)
        if mode != "legacySummary" {
            #expect(!result.stdout.contains(config.lastPathComponent))
            #expect(!result.stderr.contains(config.lastPathComponent))
        }
        if mode == "valid" {
            #expect(response["error"] == nil)
            #expect(response["kind"] as? String == "daily")
            let row = try #require((response["daily"] as? [[String: Any]])?.first)
            #expect(row["totalTokens"] as? Int == 110)
            #expect(try abs(#require(row["costUSD"] as? Double) - 0.00025) < 1e-12)
        } else {
            let error = try #require(response["error"] as? [String: Any])
            #expect(error["kind"] as? String == (mode == "legacySummary" ? "config" : "args"))
            #expect(error["code"] as? Int == 1)
            if mode != "legacySummary" {
                #expect((error["message"] as? String)?.hasPrefix("Use --daily-summary") == true)
            }
        }
    }
}

private final class DailySummaryProcessBundle: NSObject {}
