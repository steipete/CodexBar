---
summary: "CodeRabbit provider data source: CodeRabbit CLI usage and billing period limits."
read_when:
  - Debugging CodeRabbit usage fetch
  - Updating CodeRabbit CLI handling
  - Adjusting CodeRabbit provider UI/menu behavior
---

# CodeRabbit provider

CodexBar monitors CodeRabbit review activity, usage billing state, and billing period reset dates via the local `coderabbit` CLI.

## Data source

**CLI probe** — executes one bounded `coderabbit usage` command locally. It does not combine a second auth-status report, which could describe a different login after an account switch:

```text
coderabbit usage
```

Example CLI output:
```text
CodeRabbit Usage — current billing period

Organization  : Example Org
Usage billing : inactive
User          : example-user
Your reviews  : 25
Period resets : 2026-09-30
```

### Authentication

Authentication is handled via the CodeRabbit CLI:

```bash
coderabbit auth login
```

The CLI owns authentication and credential storage. CodexBar does not read or change those credential files. The usage command requires a hosted CodeRabbit login; self-hosted logins are not supported by the upstream command.

## Snapshot mapping

| CodeRabbit field | CodexBar display |
| --- | --- |
| `Your reviews` | Detail row: Reviews count |
| `Period resets` | Billing period reset detail; not a subscription-renewal claim |
| `Organization` | Identity organization |
| `Usage billing` | Detail row: Billing state (active/inactive) |
| `Plan` (only if the usage report supplies it) | Plan badge |

The integration stays native because the plugin sandbox cannot execute local programs. HTTP or filesystem capabilities are not added to JavaScript for this provider. Reports have no documented quota denominator, so CodexBar shows review counts without a percentage bar or a fabricated spending balance.

See the [official CLI reference](https://docs.coderabbit.ai/cli/reference#usage-command). Set `CODERABBIT_CLI_PATH` for an explicit executable; an invalid override fails rather than selecting a different installation.

## Key files

- `Sources/CodexBarCore/Providers/CodeRabbit/CodeRabbitCLIProbe.swift` - CLI execution probe
- `Sources/CodexBarCore/Providers/CodeRabbit/CodeRabbitUsageParser.swift` - Output parser
- `Sources/CodexBarCore/Providers/CodeRabbit/CodeRabbitUsageSnapshot.swift` - Usage models & snapshot mapping
- `Sources/CodexBarCore/Providers/CodeRabbit/CodeRabbitProviderDescriptor.swift` - Provider metadata and fetch strategies
- `Sources/CodexBar/Providers/CodeRabbit/CodeRabbitProviderImplementation.swift` - App registration
- `TestsLinux/CodeRabbitUsageTests.swift` - Unit tests for parser and probe
