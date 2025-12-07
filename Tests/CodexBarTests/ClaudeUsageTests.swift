import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct ClaudeUsageTests {
    @Test
    func parsesUsageJSONWithSonnetLimit() {
        let json = """
        {
          "ok": true,
          "session_5h": { "pct_used": 1, "resets": "11am (Europe/Vienna)" },
          "week_all_models": { "pct_used": 8, "resets": "Nov 21 at 5am (Europe/Vienna)" },
          "week_sonnet": { "pct_used": 0, "resets": "Nov 21 at 5am (Europe/Vienna)" }
        }
        """
        let data = Data(json.utf8)
        let snap = ClaudeUsageFetcher.parse(json: data)
        #expect(snap != nil)
        #expect(snap?.primary.usedPercent == 1)
        #expect(snap?.secondary.usedPercent == 8)
        #expect(snap?.primary.resetDescription == "11am (Europe/Vienna)")
    }

    @Test
    func parsesLegacyOpusAndAccount() {
        let json = """
        {
          "ok": true,
          "session_5h": { "pct_used": 2, "resets": "10:59pm (Europe/Vienna)" },
          "week_all_models": { "pct_used": 13, "resets": "Nov 21 at 4:59am (Europe/Vienna)" },
          "week_opus": { "pct_used": 0, "resets": "" },
          "account_email": " steipete@gmail.com ",
          "account_org": ""
        }
        """
        let data = Data(json.utf8)
        let snap = ClaudeUsageFetcher.parse(json: data)
        #expect(snap?.opus?.usedPercent == 0)
        #expect(snap?.opus?.resetDescription?.isEmpty == true)
        #expect(snap?.accountEmail == "steipete@gmail.com")
        #expect(snap?.accountOrganization == nil)
    }

    @Test
    func parsesUsageJSONWhenOnlySonnetLimitIsPresent() {
        let json = """
        {
          "ok": true,
          "session_5h": { "pct_used": 3, "resets": "11am (Europe/Vienna)" },
          "week_all_models": { "pct_used": 9, "resets": "Nov 21 at 5am (Europe/Vienna)" },
          "week_sonnet_only": { "pct_used": 12, "resets": "Nov 22 at 5am (Europe/Vienna)" }
        }
        """
        let data = Data(json.utf8)
        let snap = ClaudeUsageFetcher.parse(json: data)
        #expect(snap?.secondary.usedPercent == 9)
        #expect(snap?.opus?.usedPercent == 12)
        #expect(snap?.opus?.resetDescription == "Nov 22 at 5am (Europe/Vienna)")
    }

    @Test
    func trimsAccountFields() throws {
        let cases: [[String: String?]] = [
            ["email": " steipete@gmail.com ", "org": "  Org  "],
            ["email": "", "org": " Claude Max Account "],
            ["email": nil, "org": " "],
        ]

        for entry in cases {
            var payload = [
                "ok": true,
                "session_5h": ["pct_used": 0, "resets": ""],
                "week_all_models": ["pct_used": 0, "resets": ""],
            ] as [String: Any]
            if let email = entry["email"] { payload["account_email"] = email }
            if let org = entry["org"] { payload["account_org"] = org }
            let data = try JSONSerialization.data(withJSONObject: payload)
            let snap = ClaudeUsageFetcher.parse(json: data)
            let emailRaw: String? = entry["email"] ?? Optional<String>.none
            let expectedEmail = emailRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedEmail = (expectedEmail?.isEmpty ?? true) ? nil : expectedEmail
            #expect(snap?.accountEmail == normalizedEmail)
            let orgRaw: String? = entry["org"] ?? Optional<String>.none
            let expectedOrg = orgRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedOrg = (expectedOrg?.isEmpty ?? true) ? nil : expectedOrg
            #expect(snap?.accountOrganization == normalizedOrg)
        }
    }

    @Test
    func liveClaudeFetchPTY() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_CLAUDE_FETCH"] == "1" else {
            return
        }
        let fetcher = ClaudeUsageFetcher()
        do {
            let snap = try await fetcher.loadLatestUsage()
            let opusUsed = snap.opus?.usedPercent ?? -1
            let email = snap.accountEmail ?? "nil"
            let org = snap.accountOrganization ?? "nil"
            print(
                """
                Live Claude usage (PTY):
                session used \(snap.primary.usedPercent)% 
                week used \(snap.secondary.usedPercent)% 
                opus \(opusUsed)% 
                email \(email) org \(org)
                """)
            #expect(snap.primary.usedPercent >= 0)
        } catch {
            // Dump raw CLI text captured via `script` to help debug.
            let raw = try Self.captureClaudeUsageRaw(timeout: 15)
            print("RAW CLAUDE OUTPUT BEGIN\n\(raw)\nRAW CLAUDE OUTPUT END")
            throw error
        }
    }

    private static func captureClaudeUsageRaw(timeout: TimeInterval) throws -> String {
        let process = Process()
        process.launchPath = "/usr/bin/script"
        process.arguments = [
            "-q",
            "/dev/null",
            "claude",
            "/usage",
            "--allowed-tools",
            "",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = nil

        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
