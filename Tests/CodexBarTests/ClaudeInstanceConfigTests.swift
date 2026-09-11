import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeInstanceConfigTests {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    @Test
    func `environment points Claude at the instance config directory and binary`() throws {
        let instance = ClaudeInstanceConfig(
            name: "Work",
            binaryPath: "/opt/claude/bin/claude",
            configDirectory: "~/.claude-work")

        let environment = try #require(ClaudeInstanceEnvironment.environment(
            for: instance,
            base: ["HOME": Self.home, "PATH": "/usr/bin"]))

        #expect(environment["CLAUDE_CONFIG_DIR"] == "\(Self.home)/.claude-work")
        #expect(environment["CLAUDE_CLI_PATH"] == "/opt/claude/bin/claude")
        #expect(environment["HOME"] == Self.home)
        #expect(environment["PATH"] == "/usr/bin")
    }

    @Test
    func `environment drops inherited credential routing and ignores reserved instance keys`() throws {
        let instance = ClaudeInstanceConfig(
            name: "Work",
            configDirectory: "/tmp/claude-work",
            environment: [
                "HTTPS_PROXY": "http://proxy.local:8080",
                "ANTHROPIC_API_KEY": "sk-ant-instance",
                "CLAUDE_CODE_OAUTH_TOKEN": "instance-token",
                "CLAUDE_CONFIG_DIR": "/tmp/elsewhere",
                "HOME": "/tmp/fake-home",
                "not a key": "ignored",
            ])
        let base = [
            "HOME": Self.home,
            "ANTHROPIC_AUTH_TOKEN": "inherited",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/other-profile",
            "CLAUDE_CLI_PATH": "/tmp/other-claude",
            "CLAUDE_CONFIG_DIR": "/tmp/inherited-profile",
        ]

        let environment = try #require(ClaudeInstanceEnvironment.environment(for: instance, base: base))

        #expect(environment["HTTPS_PROXY"] == "http://proxy.local:8080")
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/tmp/claude-work")
        #expect(environment["HOME"] == Self.home)
        for key in [
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR",
            "CLAUDE_CLI_PATH",
            "not a key",
        ] {
            #expect(environment[key] == nil, "\(key) should not reach the instance CLI")
        }
    }

    @Test
    func `instances without an absolute config directory have no environment`() {
        for directory in ["", "   ", "relative/profile"] {
            let instance = ClaudeInstanceConfig(name: "Broken", configDirectory: directory)
            #expect(ClaudeInstanceEnvironment.environment(for: instance, base: [:]) == nil)
        }
    }

    @Test
    func `environment text parses key value lines and formats them sorted`() {
        let parsed = ClaudeInstanceEnvironment.parseVariables("""
        # proxy for the work account
        HTTPS_PROXY=http://proxy.local:8080

        EXTRA=a=b
        =missing-key
        1BAD=value
        """)

        #expect(parsed == ["HTTPS_PROXY": "http://proxy.local:8080", "EXTRA": "a=b"])
        #expect(ClaudeInstanceEnvironment.formatVariables(parsed) == "EXTRA=a=b\nHTTPS_PROXY=http://proxy.local:8080")
    }

    @Test
    func `provider config round trips instances and only exposes cost directories while enabled`() throws {
        var config = ProviderConfig(id: .claude)
        config.claudeInstances = [
            ClaudeInstanceConfig(id: "a", name: "Work", configDirectory: "/tmp/claude-work"),
            ClaudeInstanceConfig(id: "b", name: "Broken", configDirectory: "relative"),
        ]
        #expect(config.enabledClaudeInstanceConfigDirectories.isEmpty)

        config.claudeInstancesEnabled = true
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))

        #expect(decoded.claudeInstances == config.claudeInstances)
        #expect(decoded.claudeInstancesEnabled == true)
        #expect(decoded.enabledClaudeInstanceConfigDirectories == ["/tmp/claude-work"])
    }

    @Test
    func `failed refresh keeps the previous instance usage and labels unnamed instances`() {
        let instance = ClaudeInstanceConfig(id: "a", name: "  ", configDirectory: "/tmp/claude-work")
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))
        let first = ClaudeInstanceAccountProjection.accountSnapshot(
            for: instance,
            index: 1,
            result: .success(usage),
            previous: nil)

        let failed = ClaudeInstanceAccountProjection.accountSnapshot(
            for: instance,
            index: 1,
            result: .failure(ClaudeInstanceUsageFetcher.FetchError.invalidConfigDirectory),
            previous: first)

        #expect(first.id == ProviderAccountIdentity(source: "claude-instance", opaqueID: "a"))
        #expect(first.displayLabel == "Instance 2")
        #expect(first.error == nil)
        #expect(failed.snapshot?.primary?.usedPercent == 40)
        #expect(failed.error?.hasPrefix("Showing the last successful update:") == true)
        #expect(failed.canActivate == false)
    }

    @Test
    func `rate limit cooldown is scoped to each explicit config directory`() {
        let work = ["CLAUDE_CONFIG_DIR": "/tmp/claude-rate-limit-work"]
        let personal = ["CLAUDE_CONFIG_DIR": "/tmp/claude-rate-limit-personal"]
        defer {
            ClaudeCLIRateLimitGate.resetForTesting(environment: work)
            ClaudeCLIRateLimitGate.resetForTesting(environment: personal)
        }

        #expect(ClaudeCLIRateLimitGate.storageKey(environment: [:]) == "claudeCLIUsageRateLimitBlockedUntilV1")
        #expect(ClaudeCLIRateLimitGate.storageKey(environment: ["CLAUDE_CONFIG_DIR": ""]) ==
            ClaudeCLIRateLimitGate.storageKey(environment: [:]))

        ClaudeCLIRateLimitGate.recordRateLimit(environment: work)

        #expect(ClaudeCLIRateLimitGate.currentBlockedUntil(environment: work) != nil)
        #expect(ClaudeCLIRateLimitGate.currentBlockedUntil(environment: personal) == nil)
    }

    @Test
    func `cost scanning appends instance projects roots to the default roots`() {
        let instanceRoots = CostUsageFetcher.claudeProjectsRoots(
            forConfigDirectories: ["/tmp/claude-work", "/tmp/claude-work/", "relative"])
        #expect(instanceRoots.map(\.path) == ["/tmp/claude-work/projects", "/tmp/claude-work/projects"])

        let options = CostUsageScanner.Options()
        let defaults = CostUsageScanner.defaultClaudeProjectsRoots(options: options).map(\.path)
        let roots = CostUsageScanner.claudeProjectsRoots(
            appendingInstanceRoots: instanceRoots,
            options: options).map(\.path)

        #expect(Array(roots.prefix(defaults.count)) == defaults)
        #expect(roots.count(where: { $0 == "/tmp/claude-work/projects" }) == 1)
    }
}
