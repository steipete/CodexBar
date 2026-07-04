# Verification: Claude MCP-only keychain guard

Verification artifact for https://github.com/steipete/CodexBar/pull/1848, related to https://github.com/steipete/CodexBar/issues/1844.

## Scope

This verifies the safety behavior: CodexBar fails closed through both keychain readers when `Claude Code-credentials` contains only `mcpOAuth`, and background paths do not invoke delegated `claude /status` refresh. Explicit user Refresh remains able to attempt recovery.

The change does not discover Claude Code 2.1.x's primary OAuth storage location. That broader provider-auth work remains tracked by https://github.com/steipete/CodexBar/issues/1823.

## Focused regression proof

```bash
swift test --filter ClaudeOAuthTests
swift test --filter ClaudeUsageTests
swift test --filter ClaudeOAuthDelegatedRefreshCoordinatorTests
swift test --filter 'expired claude CLI owner blocks background'
swift test --filter ClaudeOAuthCredentialsStoreSecurityCLITests
swift test --filter ClaudeOAuthCredentialsStoreIsolatedSecurityCLITests
swift test --filter ClaudeOAuthCredentialsStoreMCPOnlyGuardTests
```

Result on macOS arm64: **105 tests passed** (33 + 39 + 12 + 1 + 17 + 2 + 1).

The covered behaviors include MCP-only shape detection through both keychain readers, background fail-closed behavior, explicit user Refresh recovery, in-flight background/user interaction races, and fail-closed isolated-keychain argument construction.

## Isolated built-bundle proof

```bash
./Scripts/package_app.sh
./Scripts/verify_1844_live.sh
```

The verifier creates a unique temporary directory and places every synthetic credential fixture beneath it. `HOME` and `CFFIXED_USER_HOME` point there. A disposable keychain is passed as an explicit operand to `/usr/bin/security`; CodexBar's general keychain access is disabled so its Security.framework cache cannot read or write the user's login keychain. The script verifies that creating the disposable keychain does not change the user keychain search list.

The packaged `CodexBarCLI` read an expired synthetic Claude credential file plus an MCP-only disposable keychain item. It exited 3 with the expected MCP-only guidance. A synthetic `claude` executable distinguishes benign discovery (`--version`) from an interactive `/status` touch. The packaged `CodexBar.app` exercised that exact CLI fixture, stayed running for five seconds after discovery, and never sent `/status`; the status and browser/open canaries stayed untouched.

No real `~/.claude/.credentials.json`, Claude account, or CodexBar cache keychain item was read or mutated. The default keychain search list was read before and after fixture creation only to prove it remained unchanged.

## Isolated user-Refresh replay

The release-built app was also launched with the same disposable HOME, credentials, config, keychain, and classified Claude CLI fixture. Before interaction, the invocation log contained only `claude --version`; no `/status` or browser/open canary appeared. Using the real menu, the Claude tab was selected and Refresh was clicked. The fixture then received `/status`, proving the explicit user path still delegates, while the browser/open canary remained untouched. Cleanup deleted the disposable keychain and restored the user's previously running CodexBar app.

## Final local gates

`make check` passed, all 45 `make test` shards passed, exact-SHA autoreview reported no accepted/actionable findings, and the source-blind behavior contract passed.
