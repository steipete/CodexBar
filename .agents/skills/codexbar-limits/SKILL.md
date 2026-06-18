---
name: codexbar-limits
description: Safely inspect installed CodexBar provider limits, quotas, credits, and usage from any working directory. Use when an agent needs read-only CodexBar status via the CodexBar CLI, with stable JSON output and identity redaction by default.
---

# CodexBar Limits

Use this skill when the user wants current CodexBar provider quotas, usage
windows, credits, or enabled-provider summaries from any working directory.

The helper is intentionally read-only. It delegates to the installed
CodexBar CLI, keeps stdout JSON separate from stderr noise, and returns a
stable wrapper envelope instead of passing raw CodexBar payloads by default.

CodexBar is commonly installed with `brew install --cask codexbar` or by
downloading `CodexBar.app` from GitHub Releases. The helper auto-detects the
CLI in this order:

- `CODEXBAR_LIMITS_CODEXBAR`, when set to a `codexbar` or `CodexBarCLI` binary
- `codexbar` on `PATH`
- Homebrew symlinks in `/opt/homebrew/bin` and `/usr/local/bin`
- `CodexBar.app/Contents/Helpers/CodexBarCLI` in `/Applications`,
  `~/Applications`, and Homebrew cask rooms

If detection fails, open CodexBar and use Preferences > Advanced > Install CLI,
or set `CODEXBAR_LIMITS_CODEXBAR` to the bundled `CodexBarCLI` path.
Set `CODEXBAR_LIMITS_TIMEOUT` to change the per-CodexBar-command timeout; the
default is 120 seconds.

Start with:

```bash
skill_dir="$HOME/.agents/skills/codexbar-limits"
"$skill_dir/scripts/codexbar-limits" --help
"$skill_dir/scripts/codexbar-limits" doctor --json
```

## Workflow

1. Run `doctor --json` first. It verifies whether CodexBar is installed,
   reports the detected binary path/source, reports provider inventory, and
   surfaces config-validation issues without attempting auth repair.
2. Run `providers --json` to see stable provider IDs, display names, and which
   providers are currently enabled.
3. Prefer safe default reads:
   - `usage --enabled --json` for machine-readable data
   - `summary` for a quick human-readable snapshot
4. Use `usage --provider <provider-id> --json` when the user asks about one
   provider.
5. Use `usage --all --json` only when you need the full provider sweep. It may
   exit nonzero while still returning partial usage data in the JSON envelope if
   some live providers fail.
6. Treat `--raw` and `--include-identities` as sensitive:
   - `--raw` includes sanitized upstream payloads under `raw`
   - `--include-identities` exposes identity-bearing fields such as account
     emails and organization names
   - obvious token, cookie, bearer, and secret-looking values stay masked
7. Do not use this skill for auth repair, config writes, provider
   enable/disable, or API-key storage. Those are out of scope here.
8. If a live provider probe times out, treat `upstream_timeout` as a real
   upstream/runtime condition. Narrow to `providers --json`, one
   `usage --provider <id> --json` call, or rerun with a larger
   `CODEXBAR_LIMITS_TIMEOUT` only when the user expects a long fetch.

## Helper Commands

```bash
skill_dir="$HOME/.agents/skills/codexbar-limits"
"$skill_dir/scripts/codexbar-limits" doctor --json
"$skill_dir/scripts/codexbar-limits" providers --json
"$skill_dir/scripts/codexbar-limits" usage --enabled --json
"$skill_dir/scripts/codexbar-limits" usage --all --json
"$skill_dir/scripts/codexbar-limits" usage --provider codex --json
"$skill_dir/scripts/codexbar-limits" summary
```

Each JSON command returns a stable envelope with at least:

- `ok`
- `command`
- `codexbar_available`
- `codexbar`
- `providers`
- `usage`
- `errors`
- `warnings`
- `redacted`

`redacted` reports whether identity redaction is active. By default, provider
usage values such as account emails and provider IDs are masked.

## Examples

```bash
skill_dir="$HOME/.agents/skills/codexbar-limits"
"$skill_dir/scripts/codexbar-limits" doctor --json
"$skill_dir/scripts/codexbar-limits" usage --enabled --json
"$skill_dir/scripts/codexbar-limits" usage --provider codex --json
```

Sensitive examples, use only after an explicit user request:

```bash
skill_dir="$HOME/.agents/skills/codexbar-limits"
"$skill_dir/scripts/codexbar-limits" usage --provider codex --json --raw
"$skill_dir/scripts/codexbar-limits" usage --provider codex --json --include-identities
```
