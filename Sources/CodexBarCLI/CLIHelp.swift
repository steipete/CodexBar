import CodexBarCore
import Foundation

extension CodexBarCLI {
    static func usageHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar usage [--format text|json]
                       [--json]
                       [--json-only]
                       [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
                       [--provider \(ProviderHelp.list)]
                       [--account <label>] [--account-index <index>] [--all-accounts]
                       [--no-credits] [--no-color] [--pretty] [--status] [--source <auto|web|cli|oauth|api>]
                       [--web-timeout <seconds>] [--web-debug-dump-html] [--antigravity-plan-debug] [--augment-debug]

        Description:
          Print usage from enabled providers as text (default) or JSON. Honors your in-app toggles.
          Output format: use --json (or --format json) for JSON on stdout; use --json-output for JSON logs on stderr.
          Source behavior is provider-specific:
          - Codex: OpenAI web dashboard (usage limits, credits remaining, code review remaining, usage breakdown).
            Auto falls back to Codex CLI only when cookies are missing.
          - Claude: claude.ai API.
            Auto falls back to Claude CLI only when cookies are missing.
          - Kilo: app.kilo.ai API.
            Auto falls back to Kilo CLI when API credentials are missing or unauthorized.
          Token accounts are loaded from ~/.codexbar/config.json.
          Use --account or --account-index to select a specific token account.
          Use --all-accounts to fetch every token account, or every visible Codex account for Codex.
          Account selection requires a single provider.

        Global flags:
          -h, --help      Show help
          -V, --version   Show version
          -v, --verbose   Enable verbose logging
          --no-color      Disable ANSI colors in text output
          --log-level <trace|verbose|debug|info|warning|error|critical>
          --json-output   Emit machine-readable logs (JSONL) to stderr

        Examples:
          codexbar usage
          codexbar usage --provider claude
          codexbar usage --provider gemini
          codexbar usage --format json --provider all --pretty
          codexbar usage --provider all --json
          codexbar usage --status
          codexbar usage --provider codex --source web --format json --pretty
        """
    }

    static func costHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar cost [--format text|json]
                       [--json]
                       [--json-only]
                       [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
                       [--provider \(ProviderHelp.list)]
                       [--no-color] [--pretty] [--refresh]

        Description:
          Print local token cost usage from Claude/Codex native logs plus supported pi sessions.
          This does not require web or CLI access and uses cached scan results unless --refresh is provided.

        Examples:
          codexbar cost
          codexbar cost --provider claude --format json --pretty
        """
    }

    static func serveHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar serve [--port <port>] [--refresh-interval <seconds>]
                         [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>]
                         [-v|--verbose]

        Description:
          Start a foreground localhost-only HTTP server that exposes existing CLI JSON payloads.
          The server binds to 127.0.0.1 only in this initial version.

        Endpoints:
          GET /health
          GET /usage
          GET /usage?provider=claude
          GET /usage?provider=all
          GET /cost
          GET /cost?provider=codex

        Examples:
          codexbar serve
          codexbar serve --port 8080 --refresh-interval 60
          curl http://127.0.0.1:8080/usage?provider=all
        """
    }

    static func configHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar config validate [--format text|json]
                                 [--json]
                                 [--json-only]
                                 [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>]
                                 [-v|--verbose]
                                 [--pretty]
          codexbar config dump [--format text|json]
                             [--json]
                             [--json-only]
                             [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>]
                             [-v|--verbose]
                             [--pretty]
          codexbar config providers [--format text|json] [--json] [--json-only] [--pretty]
          codexbar config enable --provider <name> [--format text|json] [--json] [--json-only] [--pretty]
          codexbar config disable --provider <name> [--format text|json] [--json] [--json-only] [--pretty]
          codexbar config set-api-key --provider <name> (--api-key <key>|--stdin)
                                    [--no-enable]
                                    [--format text|json] [--json] [--json-only] [--pretty]

        Description:
          Validate or print the CodexBar config file (default: validate).
          providers lists persistent provider enablement.
          enable/disable updates the same provider toggle used by Settings.
          set-api-key stores a provider API key in ~/.codexbar/config.json and enables that provider by default.

        Examples:
          codexbar config validate --format json --pretty
          codexbar config dump --pretty
          codexbar config providers
          codexbar config enable --provider grok
          codexbar config disable --provider cursor
          printf '%s' "$ELEVENLABS_API_KEY" | codexbar config set-api-key --provider elevenlabs --stdin
        """
    }

    static func cacheHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar cache clear <--cookies|--cost|--all>
                              [--provider <name>]
                              [--format text|json]
                              [--json]
                              [--json-only]
                              [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>]
                              [-v|--verbose]
                              [--pretty]

        Description:
          Clear cached data. Use --cookies to clear browser cookie caches (stored in Keychain),
          --cost to clear cost usage scan caches, or --all for both.
          Optionally specify --provider with --cookies to clear cookies for a single provider only.

        Examples:
          codexbar cache clear --cookies
          codexbar cache clear --cookies --provider claude
          codexbar cache clear --cost
          codexbar cache clear --all
          codexbar cache clear --all --format json --pretty
        """
    }

    static func diagnoseHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar diagnose --provider minimax --format json
                           [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>]
                           [-v|--verbose]
                           [--pretty]

        Description:
          Run a MiniMax diagnostic fetch and print a safe JSON export for issue reporting.
          The export is redacted and omits raw API tokens, cookies, auth headers, emails,
          account IDs, org IDs, raw responses, and billing-history records.

        Examples:
          codexbar diagnose --provider minimax --format json --pretty
        """
    }

    static func rootHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar [--format text|json]
                  [--json]
                  [--json-only]
                  [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
                  [--provider \(ProviderHelp.list)]
                  [--account <label>] [--account-index <index>] [--all-accounts]
                  [--no-credits] [--no-color] [--pretty] [--status] [--source <auto|web|cli|oauth|api>]
                  [--web-timeout <seconds>] [--web-debug-dump-html] [--antigravity-plan-debug] [--augment-debug]
          codexbar cost [--format text|json]
                       [--json]
                       [--json-only]
                       [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
                       [--provider \(ProviderHelp.list)] [--no-color] [--pretty] [--refresh]
          codexbar serve [--port <port>] [--refresh-interval <seconds>]
                       [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>] [-v|--verbose]
          codexbar config <validate|dump|providers> [--format text|json]
                                        [--json]
                                        [--json-only]
                                        [--json-output] [--log-level <trace|verbose|debug|info|warning|error|critical>]
                                        [-v|--verbose]
                                        [--pretty]
          codexbar config enable --provider <name>
          codexbar config disable --provider <name>
          codexbar config set-api-key --provider <name> (--api-key <key>|--stdin)
          codexbar cache clear <--cookies|--cost|--all> [--provider <name>]
          codexbar diagnose --provider minimax --format json [--pretty]

        Global flags:
          -h, --help      Show help
          -V, --version   Show version
          -v, --verbose   Enable verbose logging
          --no-color      Disable ANSI colors in text output
          --log-level <trace|verbose|debug|info|warning|error|critical>
          --json-output   Emit machine-readable logs (JSONL) to stderr

        Examples:
          codexbar
          codexbar --format json --provider all --pretty
          codexbar --provider all --json
          codexbar --provider gemini
          codexbar cost --provider claude --format json --pretty
          codexbar serve --port 8080
          codexbar config validate --format json --pretty
          codexbar config enable --provider grok
          codexbar config set-api-key --provider elevenlabs --stdin
          codexbar cache clear --cookies
          codexbar diagnose --provider minimax --format json --pretty
        """
    }
}
