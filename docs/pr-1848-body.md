## Summary

Fixes the background browser-launch regression in https://github.com/steipete/CodexBar/issues/1844: when Claude Code stores only MCP OAuth state in `Claude Code-credentials` (no `claudeAiOauth`), CodexBar no longer runs background delegated `claude /status` refresh—which can launch the default browser via `/usr/bin/open`.

**Scope:** fail-closed safety guard for both keychain readers. Discovery of Claude Code 2.1.x's primary OAuth storage location remains tracked by https://github.com/steipete/CodexBar/issues/1823.

## Problem

On Claude Code 2.1.x, the `Claude Code-credentials` keychain item may contain only `mcpOAuth`. CodexBar then fails to parse Claude OAuth credentials, treats the session as expired, and may periodically attempt delegated CLI refresh. That path can open the user's default browser from the background.

Contributing issues on `main`:

1. Delegated refresh used `ClaudeOAuthKeychainPromptPreference.current()`, which becomes `.always` when the experimental security CLI reader is active—so `onlyOnUserAction` did not suppress background repair.
2. Delegated refresh could still invoke `claude /status` even when the keychain shape could not succeed.

## Changes

1. **Honor stored keychain prompt mode for delegated refresh** across all keychain read strategies (including `securityCLIExperimental`). Background refresh with `onlyOnUserAction` fails closed with existing user-action guidance instead of calling `claude /status`.
2. **Detect MCP-only keychain payloads through both keychain readers** via `ClaudeOAuthCredentialsError.mcpOAuthOnlyKeychain`, skip delegated CLI touch, and fail fast during expired Claude CLI credential load.
3. **Split security CLI read paths**: `readRawClaudeKeychainPayloadViaSecurityCLIIfEnabled` vs parsed credential load.
4. **Isolated verification helper**: the production `/usr/bin/security` reader can target a disposable keychain only while all general keychain access is disabled. `Scripts/verify_1844_live.sh` combines that keychain with disposable `HOME`, `CFFIXED_USER_HOME`, credentials, config, and a synthetic `claude` fixture that distinguishes benign CLI discovery from `/status` touch.

## Tests

- Updated: background delegated-refresh suppression with experimental reader
- Added: MCP-only parse/shape detection
- Added: coordinator test—background MCP-only guard plus explicit Refresh recovery
- Added: store test—expired CLI owner fails closed in background and delegates on explicit Refresh
- Added: fail-closed tests for the isolated-keychain argument seam
- Added: standard Security.framework reader regression—background fails closed while explicit Refresh delegates

## Verification

- [x] Focused macOS integration tests (2026-07-03) — details in `docs/verify-1844-proof.md`
- [x] Release-built `CodexBar.app` and packaged `CodexBarCLI` isolated live proof
- [x] Real Claude-tab Refresh click against the isolated built app
- [x] Final `make check`, 45-shard `make test`, and autoreview on the local port

### Commands

```bash
make check
swift test --filter ClaudeOAuthTests
swift test --filter ClaudeUsageTests
swift test --filter ClaudeOAuthDelegatedRefreshCoordinatorTests
swift test --filter 'expired claude CLI owner blocks background'
swift test --filter ClaudeOAuthCredentialsStoreMCPOnlyGuardTests
./Scripts/verify_1844_live.sh
```

Fixes https://github.com/steipete/CodexBar/issues/1844. Primary OAuth storage discovery remains tracked by https://github.com/steipete/CodexBar/issues/1823.
