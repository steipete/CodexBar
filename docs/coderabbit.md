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

**CLI probe** — executes `coderabbit usage` (and optionally `coderabbit auth status`) locally to fetch:

```text
coderabbit usage
```

Example CLI output:
```text
CodeRabbit Usage — current billing period

Organization  : MonkeyMed
Usage billing : inactive
User          : MonkeyMed
Your reviews  : 25
Period resets : 2026-09-30
```

### Authentication

Authentication is handled via the CodeRabbit CLI:

```bash
coderabbit auth login
```

Credentials are saved in `~/.coderabbit/auth.json`.

## Snapshot mapping

| CodeRabbit field | CodexBar display |
| --- | --- |
| `Your reviews` | Detail row: Reviews count |
| `Period resets` | Billing period reset date & countdown |
| `Organization` | Identity organization |
| `Usage billing` | Detail row: Billing state (active/inactive) |
| `Plan` (from auth status) | Identity login method / plan badge |

## Key files

- `Sources/CodexBarCore/Providers/CodeRabbit/CodeRabbitCLIProbe.swift` - CLI execution probe
- `Sources/CodexBarCore/Providers/CodeRabbit/CodeRabbitUsageParser.swift` - Output parser
- `Sources/CodexBarCore/Providers/CodeRabbit/CodeRabbitUsageSnapshot.swift` - Usage models & snapshot mapping
- `Sources/CodexBarCore/Providers/CodeRabbit/CodeRabbitProviderDescriptor.swift` - Provider metadata and fetch strategies
- `Sources/CodexBar/Providers/CodeRabbit/CodeRabbitProviderImplementation.swift` - App registration
- `Tests/CodexBarTests/CodeRabbitUsageParserTests.swift` - Unit tests for parser and probe
