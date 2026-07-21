---
summary: "Current Keychain ownership boundaries, Claude routing, and prompt troubleshooting."
read_when:
  - Investigating Keychain prompts
  - Auditing Claude credential ownership
  - Comparing legacy Keychain behavior with the current architecture
---

# Keychain ownership: current state

## Invariant

CodexBar reads only credentials it owns or that the user explicitly supplies to CodexBar. Production code never reads
Claude Code's `Claude Code-credentials` item through Security.framework or `/usr/bin/security`, regardless of prompt
mode or the global Keychain setting.

Claude Code replaces that item during some token refreshes. Replacement also replaces the item's ACL, which is why an
“Always Allow CodexBar” grant eventually failed and the password prompt returned. A durable fix must remove the
cross-owner read, not tune prompt timing.

## Current Keychain surfaces

- Browser cookie import can read a browser-owned Safe Storage key after the user enables that source.
- CodexBar-owned cache and legacy-migration entries remain under CodexBar services.
- Provider CLIs can access their own credentials in their own subprocesses. CodexBar does not inspect the secret.
- The global **Disable Keychain access** setting disables CodexBar's remaining reads and writes, primarily browser
  cookie import and CodexBar-owned caches.

## Claude routing

- App Auto: noninteractive owner check (`claude auth status --json`) → Claude CLI usage → bounded Web fallback.
- CLI runtime Auto: Web → Claude CLI.
- Explicit token accounts are authoritative: Admin API keys route to Admin API, session cookies route to Web, and
  user-supplied OAuth access tokens route to OAuth.
- A persisted app-level OAuth source from an older build migrates to Auto. Ambient OAuth bootstrap from Claude Code's
  Keychain item is not available.
- Account-switch invalidation uses only a hash of the account UUID in Claude's owner-selected config file. It honors
  `.config.json` precedence plus literal `CLAUDE_CONFIG_DIR` and stores neither the UUID nor the config path.
- Credential-file routing also honors `CLAUDE_SECURESTORAGE_CONFIG_DIR`; profile caches and reusable CLI processes
  are scoped to the same owner paths and launch environment.

Legacy Claude Keychain helper code remains compiled for compatibility tests, but the Release ownership gate denies it
before a Security.framework query or `/usr/bin/security` process can start. Debug tests can open the gate only while a
task-local synthetic credential fixture is installed.

## Interpreting a prompt

If a current build shows a prompt for `Claude Code-credentials`:

1. Read the requesting application or binary shown by macOS.
2. If it is CodexBar, quit older running copies, remove duplicate installs, and update/relaunch the app.
3. If it is the Claude executable, Claude Code owns that authentication request.
4. Do not add CodexBar to the Claude item or choose “Allow all applications”; the grant is unnecessary and cannot
   survive owner replacement of the item.

Browser Safe Storage prompts are separate. See [Keychain prompts](keychain-prompts.md) for browser-specific steps and
safe support diagnostics.

## Verification

The ownership suite covers every historical prompt mode with global Keychain access enabled and asserts that both raw
readers, credential presence checks, and direct ownership decisions fail closed. Routing tests cover Auto, selected
token accounts, logged-out CLI preflight, and account switches during in-flight refreshes.

For an opt-in local owner check without exposing secrets:

```bash
LIVE_CLAUDE_KEYCHAIN_PROOF=1 \
CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 \
swift test --filter ClaudeKeychainLiveProofTests
```

The live test invokes only `claude auth status --json`, verifies the production denial, and does not print credential
payloads.
