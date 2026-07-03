## Summary

Partial fix related to https://github.com/steipete/CodexBar/issues/1844: when Claude Code stores only MCP OAuth state in `Claude Code-credentials` (no `claudeAiOauth`), CodexBar no longer runs background delegated `claude /status` refresh—which can launch the default browser via `/usr/bin/open`.

**Scope:** Phase 1 guard only. Does not discover Claude Code 2.1.x's primary OAuth storage location.

## Problem

On Claude Code 2.1.x, the `Claude Code-credentials` keychain item may contain only `mcpOAuth`. CodexBar then fails to parse Claude OAuth credentials, treats the session as expired, and may periodically attempt delegated CLI refresh. That path can open the user's default browser from the background.

Contributing issues on `main`:

1. Delegated refresh used `ClaudeOAuthKeychainPromptPreference.current()`, which becomes `.always` when the experimental security CLI reader is active—so `onlyOnUserAction` did not suppress background repair.
2. Delegated refresh could still invoke `claude /status` even when the keychain shape could not succeed.

## Changes

1. **Honor stored keychain prompt mode for delegated refresh** across all keychain read strategies (including `securityCLIExperimental`). Background refresh with `onlyOnUserAction` fails closed with existing user-action guidance instead of calling `claude /status`.
2. **Detect MCP-only keychain payloads** via `ClaudeOAuthCredentialsError.mcpOAuthOnlyKeychain`, skip delegated CLI touch, and fail fast during expired Claude CLI credential load.
3. **Split security CLI read paths**: `readRawClaudeKeychainPayloadViaSecurityCLIIfEnabled` vs parsed credential load.
4. **Isolated verification helper**: the production `/usr/bin/security` reader can target a disposable keychain only while all general keychain access is disabled. `Scripts/verify_1844_live.sh` combines that keychain with disposable `HOME`, `CFFIXED_USER_HOME`, credentials, config, and a synthetic `claude` touch canary.

## Tests

- Updated: background delegated-refresh suppression with experimental reader
- Added: MCP-only parse/shape detection
- Added: coordinator test—background MCP-only guard plus explicit Refresh recovery
- Added: store test—expired CLI owner fails closed in background and delegates on explicit Refresh
- Added: fail-closed tests for the isolated-keychain argument seam

## Verification

- [x] Focused macOS integration tests (2026-07-03) — details in `docs/verify-1844-proof.md`
- [x] Release-built `CodexBar.app` and packaged `CodexBarCLI` isolated live proof
- [ ] Final `make check`, sharded `make test`, and autoreview on the local port
- [ ] Optional: Menu Refresh screenshot on a host with the reporter's keychain shape

### Commands

```bash
make check
swift test --filter ClaudeOAuthTests
swift test --filter ClaudeUsageTests
swift test --filter ClaudeOAuthDelegatedRefreshCoordinatorTests
swift test --filter 'expired claude CLI owner blocks background'
./Scripts/verify_1844_live.sh
```

Related: https://github.com/steipete/CodexBar/issues/1844 (Phase 1 only; the issue must remain open for primary OAuth storage discovery and reporter-environment confirmation.)
