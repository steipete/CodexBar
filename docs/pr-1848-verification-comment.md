## macOS verification (2026-07-03)

Contributor verification for the Phase 1 guard in this PR. Full write-up: [`docs/verify-1844-proof.md`](https://github.com/Yuxin-Qiao/CodexBar/blob/cursor/fix-claude-oauth-background-refresh-1114/docs/verify-1844-proof.md) on the PR branch.

**Environment:** macOS arm64, Claude Code 2.1.193, branch `cursor/fix-claude-oauth-background-refresh-1114` @ `7befb637`

### Integration tests

```bash
swift test --filter ClaudeOAuthTests
swift test --filter ClaudeUsageTests
swift test --filter ClaudeOAuthDelegatedRefreshCoordinatorTests
swift test --filter 'expired claude CLI owner blocks background'
```

**Result:** all selected suites and the targeted storage-owner regression passed on macOS release-linked binaries.

| Behavior | Result |
|----------|--------|
| Background `onlyOnUserAction` suppresses delegated refresh (`securityCLIExperimental`) | Pass |
| Coordinator skips background `claude /status` when keychain is MCP-only | Pass |
| Explicit user Refresh bypasses the MCP-only guard and delegated-refresh cooldown | Pass |
| Explicit user Refresh retries after an in-flight background failure | Pass |
| Expired Claude CLI owner fails fast with `mcpOAuthOnlyKeychain` in background | Pass |

Representative logs:

```text
Claude OAuth delegated refresh skipped: Claude keychain has MCP OAuth state only
Claude OAuth credentials expired; Claude keychain has MCP OAuth state only
```

No delegated CLI touch or `/usr/bin/open` activity is exercised in these tests.

### Keychain fixture E2E

Not completed in unattended automation (macOS Keychain write requires interactive approval). Optional follow-up on a machine with the reporter's keychain shape, or locally via:

```bash
./Scripts/verify_1844_live.sh
```

### Conclusion

Phase 1 code paths are covered by macOS integration tests and demonstrate fail-closed behavior for MCP-only keychain payloads without background delegated CLI refresh.

@clawsweeper re-review
