import Commander
import Testing
@testable import CodexBarCLI

struct CLIDocumentedInvocationTests {
    /// Complete invocations in docs/cli.md and README.md. Shell pipes/environment assignments
    /// are outside argv; placeholders use synthetic values and no command is executed.
    private static let examples: [Example] = [
        .init("", path: "usage"),
        .init("usage --format toon", path: "usage", options: ["format": ["toon"]]),
        .init("cost --provider both", path: "cost", options: ["provider": ["both"]]),
        .init("cost --provider claude", path: "cost", options: ["provider": ["claude"]]),
        .init("--format json --pretty", path: "usage", options: ["format": ["json"]], flags: ["pretty"]),
        .init("--format json --provider both", path: "usage", options: ["format": ["json"], "provider": ["both"]]),
        .init(
            "--json-only --format json --pretty",
            path: "usage",
            options: ["format": ["json"]],
            flags: ["jsonOnly", "pretty"]),
        .init("--provider all", path: "usage", options: ["provider": ["all"]]),
        .init("--provider claude", path: "usage", options: ["provider": ["claude"]]),
        .init(
            "--provider claude --account user@example.com",
            path: "usage",
            options: ["provider": ["claude"], "account": ["user@example.com"]]),
        .init(
            "--provider claude --all-accounts --format json --pretty",
            path: "usage",
            options: ["provider": ["claude"], "format": ["json"]],
            flags: ["allAccounts", "pretty"]),
        .init(
            "--provider codex --all-accounts --format json --pretty",
            path: "usage",
            options: ["provider": ["codex"], "format": ["json"]],
            flags: ["allAccounts", "pretty"]),
        .init(
            "--provider codex --source oauth --format json --pretty",
            path: "usage",
            options: ["provider": ["codex"], "source": ["oauth"], "format": ["json"]],
            flags: ["pretty"]),
        .init(
            "--provider codex --source web --format json --pretty",
            path: "usage",
            options: ["provider": ["codex"], "source": ["web"], "format": ["json"]],
            flags: ["pretty"]),
        .init(
            "--provider copilot --format json --pretty",
            path: "usage",
            options: ["provider": ["copilot"], "format": ["json"]],
            flags: ["pretty"]),
        .init(
            "--provider gemini --source api --format json --pretty",
            path: "usage",
            options: ["provider": ["gemini"], "source": ["api"], "format": ["json"]],
            flags: ["pretty"]),
        .init(
            "--provider kilo --source api --format json --pretty",
            path: "usage",
            options: ["provider": ["kilo"], "source": ["api"], "format": ["json"]],
            flags: ["pretty"]),
        .init(
            "--provider moonshot --source api --format json --pretty",
            path: "usage",
            options: ["provider": ["moonshot"], "source": ["api"], "format": ["json"]],
            flags: ["pretty"]),
        .init("--status", path: "usage", flags: ["status"]),
        .init("cache clear", path: "cache clear"),
        .init(
            "cache clear --all --format json --pretty",
            path: "cache clear",
            options: ["format": ["json"]],
            flags: ["all", "pretty"]),
        .init("cache clear --cookies", path: "cache clear", flags: ["cookies"]),
        .init(
            "cache clear --cookies --provider claude",
            path: "cache clear",
            options: ["provider": ["claude"]],
            flags: ["cookies"]),
        .init("cards", path: "cards"),
        .init("codex-accounts list --json", path: "codex-accounts list", flags: ["jsonShortcut"]),
        .init(
            "codex-accounts promote 00000000-0000-0000-0000-000000000001",
            path: "codex-accounts promote",
            positional: ["00000000-0000-0000-0000-000000000001"]),
        .init(
            "config clear-credential --provider claude --cookie",
            path: "config clear-credential",
            options: ["provider": ["claude"]],
            flags: ["cookie"]),
        .init("config disable --provider cursor", path: "config disable", options: ["provider": ["cursor"]]),
        .init("config dump", path: "config dump"),
        .init("config dump --pretty", path: "config dump", flags: ["pretty"]),
        .init("config enable --provider grok", path: "config enable", options: ["provider": ["grok"]]),
        .init("config providers", path: "config providers"),
        .init("config providers --format json", path: "config providers", options: ["format": ["json"]]),
        .init(
            "config set-api-key --provider elevenlabs --stdin",
            path: "config set-api-key",
            options: ["provider": ["elevenlabs"]],
            flags: ["stdin"]),
        .init(
            "config set-api-key --provider openai --stdin",
            path: "config set-api-key",
            options: ["provider": ["openai"]],
            flags: ["stdin"]),
        .init(
            "config set-cookie --provider claude --stdin",
            path: "config set-cookie",
            options: ["provider": ["claude"]],
            flags: ["stdin"]),
        .init(
            "config set-source --provider claude --source auto",
            path: "config set-source",
            options: ["provider": ["claude"], "source": ["auto"]]),
        .init(
            "config set-source --provider claude --source cli",
            path: "config set-source",
            options: ["provider": ["claude"], "source": ["cli"]]),
        .init("config validate", path: "config validate"),
        .init(
            "config validate --format json --pretty",
            path: "config validate",
            options: ["format": ["json"]],
            flags: ["pretty"]),
        .init("cookie refresh", path: "cookie refresh"),
        .init(
            "cookie refresh --provider opencodego --allow-keychain-prompt",
            path: "cookie refresh",
            options: ["provider": ["opencodego"]],
            flags: ["allowKeychainPrompt"]),
        .init("cost", path: "cost"),
        .init("cost --days 90", path: "cost", options: ["days": ["90"]]),
        .init("cost --format json", path: "cost", options: ["format": ["json"]]),
        .init("cost --period all --json", path: "cost", options: ["period": ["all"]], flags: ["jsonShortcut"]),
        .init(
            "cost --period month-to-date --json",
            path: "cost",
            options: ["period": ["month-to-date"]],
            flags: ["jsonShortcut"]),
        .init(
            "cost --provider claude --format json --pretty",
            path: "cost",
            options: ["provider": ["claude"], "format": ["json"]],
            flags: ["pretty"]),
        .init("cost --provider codex", path: "cost", options: ["provider": ["codex"]]),
        .init(
            "cost --provider codex --group-by project",
            path: "cost",
            options: ["provider": ["codex"], "groupBy": ["project"]]),
        .init(
            "cost --provider codex --group-by session",
            path: "cost",
            options: ["provider": ["codex"], "groupBy": ["session"]]),
        .init(
            "cost --provider codex --identified-only --format json --days 30",
            path: "cost",
            options: ["provider": ["codex"], "format": ["json"], "days": ["30"]],
            flags: ["identifiedOnly"]),
        .init("cost --provider cursor", path: "cost", options: ["provider": ["cursor"]]),
        .init("dashboard", path: "dashboard"),
        .init("guard", path: "guard"),
        .init("guard --provider codex", path: "guard", options: ["provider": ["codex"]]),
        .init(
            "guard --provider codex --min-remaining 20 --window weekly --json",
            path: "guard",
            options: ["provider": ["codex"], "minRemaining": ["20"], "window": ["weekly"]],
            flags: ["json"]),
        .init("hooks disable", path: "hooks disable"),
        .init("hooks enable", path: "hooks enable"),
        .init("hooks list", path: "hooks list"),
        .init(
            "hooks test quota_reached --provider codex",
            path: "hooks test",
            options: ["provider": ["codex"]],
            positional: ["quota_reached"]),
        .init("hooks watch", path: "hooks watch"),
        .init("serve", path: "serve"),
        .init(
            "serve --host 0.0.0.0 --allow-plain-http",
            path: "serve",
            options: ["host": ["0.0.0.0"]],
            flags: ["allowPlainHTTP"]),
        .init("serve --port 8080", path: "serve", options: ["port": ["8080"]]),
        .init("serve --request-timeout 0", path: "serve", options: ["requestTimeout": ["0"]]),
        .init("usage", path: "usage"),
        .init("usage --format json --pretty", path: "usage", options: ["format": ["json"]], flags: ["pretty"]),
        .init(
            "usage --provider both --format json",
            path: "usage",
            options: ["provider": ["both"], "format": ["json"]]),
    ]

    @Test(arguments: Self.examples)
    func `documented invocations preserve routing and parsed values`(example: Example) throws {
        let arguments = CodexBarCLI.effectiveArgv(example.command.split(separator: " ").map(String.init))
        let invocation = try Program(descriptors: CodexBarCLI.commandDescriptors()).resolve(arguments: arguments)
        #expect(invocation.path == example.path.split(separator: " ").map(String.init))
        #expect(invocation.parsedValues == ParsedValues(
            positional: example.positional,
            options: example.options,
            flags: example.flags))
    }

    struct Example: Sendable {
        let command: String
        let path: String
        let options: [String: [String]]
        let flags: Set<String>
        let positional: [String]

        init(
            _ command: String,
            path: String,
            options: [String: [String]] = [:],
            flags: Set<String> = [],
            positional: [String] = [])
        {
            self.command = command
            self.path = path
            self.options = options
            self.flags = flags
            self.positional = positional
        }
    }
}

struct CLIStrictParsingTests {
    @Test
    func `dash prefixed option values use the equals form`() throws {
        let invocation = try Program(descriptors: CodexBarCLI.commandDescriptors())
            .resolve(arguments: ["dashboard", "--output=-snapshot.json"])
        #expect(invocation.parsedValues.options["output"] == ["-snapshot.json"])
    }

    @Test(arguments: [
        ["codex-accounts", "promote", "synthetic-account", "extra"],
        ["hooks", "test", "quota_reached", "extra"],
        ["sessions", "focus", "synthetic-session", "extra"],
        ["plugins", "fetch", "synthetic-plugin", "extra"],
    ])
    func `excess positional arguments are rejected before command execution`(arguments: [String]) {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors())
        do {
            _ = try program.resolve(arguments: arguments)
            Issue.record("Expected excess positional argument to fail")
        } catch let error as CommanderProgramError {
            #expect(error.description == "Unexpected argument: extra")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
