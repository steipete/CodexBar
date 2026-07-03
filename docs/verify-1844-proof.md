# Verification: Claude MCP-only keychain guard

Verification artifact for https://github.com/steipete/CodexBar/pull/1848, related to https://github.com/steipete/CodexBar/issues/1844.

## Scope

This verifies the Phase 1 safety behavior: CodexBar fails closed when `Claude Code-credentials` contains only `mcpOAuth`, and background paths do not invoke delegated `claude /status` refresh. Explicit user Refresh remains able to attempt recovery.

The change does not discover Claude Code 2.1.x's primary OAuth storage location. Issue 1844 must remain open for that work and reporter-environment confirmation.

## Focused regression proof

```bash
swift test --filter ClaudeOAuthTests
swift test --filter ClaudeUsageTests
swift test --filter ClaudeOAuthDelegatedRefreshCoordinatorTests
swift test --filter 'expired claude CLI owner blocks background'
swift test --filter ClaudeOAuthCredentialsStoreSecurityCLITests
swift test --filter ClaudeOAuthCredentialsStoreIsolatedSecurityCLITests
```

Result on macOS arm64: **104 tests passed** (33 + 39 + 12 + 1 + 17 + 2).

The covered behaviors include MCP-only shape detection, background fail-closed behavior, explicit user Refresh recovery, in-flight background/user interaction races, and fail-closed isolated-keychain argument construction.

## Isolated built-bundle proof

```bash
./Scripts/package_app.sh
./Scripts/verify_1844_live.sh
```

The verifier creates a unique temporary directory and places every synthetic credential fixture beneath it. `HOME` and `CFFIXED_USER_HOME` point there. A disposable keychain is passed as an explicit operand to `/usr/bin/security`; CodexBar's general keychain access is disabled so its Security.framework cache cannot read or write the user's login keychain. The script verifies that creating the disposable keychain does not change the user keychain search list.

The packaged `CodexBarCLI` read an expired synthetic Claude credential file plus an MCP-only disposable keychain item. It exited 3 with the expected MCP-only guidance. A synthetic `claude` executable would have written a canary if delegated refresh ran; the canary stayed untouched, and no browser/open child appeared. The packaged `CodexBar.app` binary also stayed running for a five-second isolated smoke with no canary or browser/open child.

No real `~/.claude/.credentials.json`, Claude account, or CodexBar cache keychain item was read or mutated. The default keychain search list was read before and after fixture creation only to prove it remained unchanged.

## Remaining proof

The final local port still requires `make check`, the complete sharded `make test`, and autoreview. A reporter-environment menu Refresh replay remains useful supplementary evidence but is outside this isolated proof and is not grounds to close issue 1844.
