---
summary: "CLI refactor plan: JSON-only errors, config validation, SettingsStore split."
read_when:
  - "Refactoring CodexBar CLI error handling or config parsing."
  - "Splitting SettingsStore into smaller files."
  - "Adding config validation or CLI config commands."
---

# CLI Refactor Plan

## Goals
- JSON-only: every error is valid JSON on stdout (no mixed stderr).
- Per-provider errors: provider failures yield provider-scoped error payloads.
- Config validation: warn on invalid fields, unsupported source modes, bad regions.
- Config parity: add CLI command to validate (and optionally dump) config.
- SettingsStore split: files <500 LOC; clear separation (defaults vs config).

## Constraints (keep)
- Provider ordering stays driven by config `providers[]` order.
- Provider enable/disable stays in config (`enabled`).
- No Keychain persistence for provider secrets.
- CLI still supports text output for non-JSON use.

## Error JSON shape
- JSON output remains an array for `usage` and `cost` commands.
- Errors appear as payload entries with `error` set.
- Global/CLI errors use `provider: "cli"` and `source: "cli"`.

```json
{
  "provider": "cli",
  "source": "cli",
  "error": { "code": 1, "message": "...", "kind": "config" }
}
```

## Config validation rules
- `source` must be in provider descriptor `fetchPlan.sourceModes`.
- `apiKey` only valid when provider supports `.api`.
- `cookieSource` only valid when provider supports `.web`/`.auto`.
- `region` only for `zai` or `minimax` with known values.
- `workspaceID` only for `opencode`.
- `tokenAccounts` only for providers in `TokenAccountSupportCatalog`.

## CLI commands
- `codexbar config validate`
  - Prints JSON issues (or text summary).
  - Exit non-zero if any errors.
- (Optional) `codexbar config dump`
  - Prints normalized config JSON.

## Step-by-step implementation guide
1. **Add validation types**
   - `CodexBarConfigIssue` + `CodexBarConfigValidator` in `CodexBarCore/Config`.
   - Keep file <500 LOC.
2. **Hook validation into CLI**
   - New `config validate` command.
   - `--json-only` emits JSON array of issues.
3. **Unify CLI error reporting**
   - Parse `--json-only` early.
   - Route all exits through a JSON-aware reporter.
   - Use provider-scoped errors where possible.
4. **Split CLIEntry.swift**
   - Extract helpers + payload structs into dedicated files (<500 LOC each).
5. **Split SettingsStore.swift**
   - Move config-backed computed properties to `SettingsStore+Config.swift`.
   - Move defaults-backed computed properties to `SettingsStore+Defaults.swift`.
   - Move provider detection to `SettingsStore+ProviderDetection.swift`.
6. **Provider toggles cleanup**
   - Remove unused `ProviderToggleStore` + tests; keep migrator path for legacy toggles.
7. **Tests**
   - CLI json-only error payloads (invalid source, invalid provider selection).
   - Config validation (bad region/source/apiKey field).
   - SettingsStore order/toggle invariants still pass.
8. **Verification**
   - `swift test`, `swiftformat Sources Tests`, `swiftlint --strict`, `pnpm check`.
   - `./Scripts/compile_and_run.sh`.
   - CLI e2e: `codexbar --json-only ...`, `codexbar config validate`.

