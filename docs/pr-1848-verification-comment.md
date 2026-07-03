## Maintainer verification (2026-07-03)

Local current-main port of https://github.com/steipete/CodexBar/pull/1848. This fixes the background browser-launch regression in https://github.com/steipete/CodexBar/issues/1844; primary OAuth storage discovery remains tracked by https://github.com/steipete/CodexBar/issues/1823.

### Focused regression proof

```bash
swift test --filter ClaudeOAuthTests
swift test --filter ClaudeUsageTests
swift test --filter ClaudeOAuthDelegatedRefreshCoordinatorTests
swift test --filter 'expired claude CLI owner blocks background'
swift test --filter ClaudeOAuthCredentialsStoreSecurityCLITests
swift test --filter ClaudeOAuthCredentialsStoreIsolatedSecurityCLITests
swift test --filter ClaudeOAuthCredentialsStoreMCPOnlyGuardTests
```

Result: **105 tests passed** (33 + 39 + 12 + 1 + 17 + 2 + 1).

| Behavior | Result |
|----------|--------|
| Background `onlyOnUserAction` suppresses delegated refresh with `securityCLIExperimental` | Pass |
| MCP-only background guard prevents `claude /status` touch | Pass |
| Explicit user Refresh bypasses the MCP-only guard and cooldown | Pass |
| Explicit user Refresh retries after an in-flight background failure | Pass |
| Expired Claude CLI-owned credentials fail closed with `mcpOAuthOnlyKeychain` | Pass |
| Isolated keychain path is accepted only with general keychain access disabled | Pass |
| Standard Security.framework reader fails closed in background while explicit Refresh delegates | Pass |

### Isolated built-bundle proof

```bash
./Scripts/package_app.sh
./Scripts/verify_1844_live.sh
```

The verifier used only synthetic data under a unique temporary directory:

- disposable `HOME` and `CFFIXED_USER_HOME`
- disposable keychain passed directly to `/usr/bin/security`
- general Security.framework/cache keychain access disabled
- isolated `.claude/.credentials.json` and CodexBar config
- synthetic `claude` executable that records benign discovery separately from `/status` touch

The packaged `CodexBarCLI` exited 3 with the MCP-only guidance, no `/status` or browser/open canary appeared, and the user keychain search list was unchanged. The packaged `CodexBar.app` then exercised the synthetic CLI with `--version`, stayed running for five seconds after discovery, and still sent no `/status` or browser/open touch.

For the explicit recovery path, I launched the same isolated built app, selected the real Claude tab, and clicked Refresh. Before the click the invocation log contained only `--version`; after the click it received `/status`, while the browser/open canary remained untouched. This proves user Refresh remains interaction-aware without weakening the background guard.

Final local gates passed: `make check`, all 45 `make test` shards, exact-SHA autoreview, and source-blind behavior validation.
