# PR #1848 live verification proof (2026-07-03)

**Branch:** `cursor/fix-claude-oauth-background-refresh-1114`  
**Machine:** macOS arm64, Claude Code **2.1.193**

## Phase 1 — macOS integration tests ✅ PASS

```bash
./Scripts/verify_1844_live.sh   # or swift test --filter 'mcp O auth|delegated ...'
```

5/5 tests passed on real macOS binaries. Representative logs:

```
Claude keychain security CLI output is MCP OAuth only; falling back
Claude OAuth delegated refresh skipped: Claude keychain has MCP OAuth state only
Claude OAuth credentials expired; Claude keychain has MCP OAuth state only
```

| Behavior | Status |
|----------|--------|
| Background `onlyOnUserAction` blocks delegated refresh (securityCLI reader) | ✅ |
| Coordinator skips `claude /status` for MCP-only keychain | ✅ |
| Expired CLI owner fails fast with `mcpOAuthOnlyKeychain` | ✅ |
| No delegated CLI touch in coordinator test (counter = 0) | ✅ |

## Phase 2 — Keychain fixture E2E ⏸ skipped (headless)

Installing a temporary `Claude Code-credentials` item requires macOS Keychain UI approval. Automated agent runs receive `authorization was canceled`.

**To complete Phase 2 locally** (one Keychain Allow click):

```bash
git checkout fix-claude-oauth-1844
./Scripts/verify_1844_live.sh
# Click Allow if Keychain prompts
```

Expected: CLI probe fails closed with MCP-only messaging; no `/usr/bin/open` / Firefox child processes.

## Packaged app

Fix branch builds to `CodexBar.app` (2026-07-03). CLI helper:

`CodexBar.app/Contents/Helpers/CodexBarCLI`

## Verdict

**Merge-ready for Phase 1 guard:** integration tests prove the production code paths fail closed without delegated CLI touch or browser launch when the security CLI reader sees MCP-only keychain payloads.

Full reporter-state E2E remains optional follow-up on a host with real `mcpOAuth`-only corruption (or after manual Keychain fixture install).
