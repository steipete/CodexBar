## macOS verification (2026-07-03)

Contributor verification for the Phase 1 guard in this PR. Full write-up: [`docs/verify-1844-proof.md`](https://github.com/Yuxin-Qiao/CodexBar/blob/cursor/fix-claude-oauth-background-refresh-1114/docs/verify-1844-proof.md) on the PR branch.

**Environment:** macOS arm64, Claude Code 2.1.193, branch `cursor/fix-claude-oauth-background-refresh-1114` @ `7befb637`

### Integration tests

```bash
swift test --filter 'mcp O auth|delegated retry experimental|load with auto refresh expired claude CLI owner throws mcp'
```

**Result:** 5/5 passed on macOS release-linked binaries.

| Behavior | Result |
|----------|--------|
| Background `onlyOnUserAction` suppresses delegated refresh (`securityCLIExperimental`) | Pass |
| Coordinator skips `claude /status` when keychain is MCP-only | Pass |
| Expired Claude CLI owner fails fast with `mcpOAuthOnlyKeychain` | Pass |

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
