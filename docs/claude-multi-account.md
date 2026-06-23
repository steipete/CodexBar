# Claude multi-account support (fork feature)

Branch: `feat/claude-multi-account`

Lets CodexBar track **several Claude accounts at once**, each read and refreshed
independently — the way Copilot/Codex multi-account already works, now for Claude.
Built on the existing token-account system; **single-account users are unaffected**
(legacy raw tokens parse unchanged).

## What it does

- **Auto-discovery** — finds every Claude Code login on the machine by enumerating
  the real `Claude Code-credentials*` Keychain services (attributes-only, so the
  enumeration itself doesn't prompt) plus any `~/.claude*/.credentials.json` files.
- **Per-account refresh** — each account is read **and OAuth-refreshed from its own
  source** at fetch time, so secondary accounts don't go stale. Rotated tokens are
  written back **only to secondary sources** (never the default `Claude
  Code-credentials` item), so we never race Claude Code's own refresh of it.
- **Email de-dup + labels** — many Keychain slots can hold the *same* login (one
  account across several config dirs). Discover fetches each account's email
  (OAuth profile endpoint), **collapses duplicate-email entries to one tab**, and
  labels it `email · Plan` (e.g. `you@gmail.com · Max`). Revoked/stale entries are
  skipped.
- **Self-cleaning** — re-running Discover removes its own previously auto-added
  entries and re-adds only the live ones; manually pasted accounts are preserved.

## How to use

Settings → **Providers → Claude → Multiple accounts → "Discover accounts"**.
Approve the Keychain prompts. Set the menu layout to **stacked** to see all
accounts at once; each tab is an account switcher.

## How it works (key files)

| File | Role |
|------|------|
| `CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeCredentialSource.swift` | Encodes a token-account `token` as either a raw token or a refreshable **source pointer** (Keychain service / file), base64-JSON round-trip-safe. |
| `…/ClaudeAccountDiscovery.swift` | Enumerates real Keychain services + `~/.claude*` dirs → candidate accounts (pure `assemble()` is unit-tested). |
| `…/ClaudeCredentialResolver.swift` | Reads + refreshes a source at fetch time; `fetchAccountEmail` for labels/de-dup; safe write-back. |
| `CodexBarCore/TokenAccountSupport.swift` | `envOverride` passes a source descriptor via `CODEXBAR_CLAUDE_SOURCE`. |
| `CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift` | OAuth load resolves the descriptor → per-account creds. |
| `CodexBar/Providers/Claude/ClaudeSettingsStore.swift` | Treats a descriptor as OAuth in the settings snapshot. |
| `CodexBar/Providers/Claude/ClaudeProviderImplementation.swift` | The "Discover accounts" button (discover → validate → de-dup by email → register). |

Display/fetch/menu plumbing is reused unchanged — it's provider-agnostic.

## Tests

`swift test --filter "ClaudeCredential|ClaudeAccountDiscovery|TokenAccount"` —
unit tests for the source encoding, discovery `assemble()`, the refresh-failure
classifier, and write-back policy; full Claude/TokenAccount suite stays green.

## Known limitations

- **Cost / token chart is machine-wide, not per-account.** CodexBar estimates
  Claude cost from local Claude Code logs, which aren't tagged by account, so the
  same cost shows on every Claude tab. (Upstream behavior; not addressed here.)
- **A revoked account must be re-logged in** (`CLAUDE_CONFIG_DIR=… claude` →
  `/login`); no app can read a revoked refresh token. Once re-logged, Discover
  picks it up.
