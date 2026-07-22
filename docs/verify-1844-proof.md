# Verification: Claude credential ownership boundary

Current CodexBar builds do not read Claude Code's `Claude Code-credentials` Keychain item. Claude Code owns and
periodically replaces that item, including its access-control list, so a grant to another executable cannot be made
durable by a prompt setting.

## Invariant

- Production CodexBar never queries the foreign item through Security.framework or `/usr/bin/security`.
- Prompt preferences cannot reopen that path, including for explicit user actions.
- App Auto obtains subscription usage through owner-mediated Claude CLI first, then Web.
- Explicit token accounts stay authoritative; malformed selected accounts fail closed instead of using ambient data.
- Claude CLI sessions are reusable only while the account-config path, secure-credentials path, active account UUID,
  executable, and complete scrubbed launch environment are unchanged.

Claude CLI subprocesses may access credentials they own. That is expected and is distinct from CodexBar reading the
item itself.

## Proof layers

`Scripts/verify_1844_live.sh` snapshots the exact tracked and untracked source state, rejects concurrent source changes,
packages that source, records every first-party executable hash, and exercises three complementary layers:

1. Unit and source-safety tests prove the ownership boundary under every stored prompt mode and both background and
   user-initiated credential loads. The focused set also covers persisted explicit OAuth with environment-,
   profile-file-, and CodexBar-cache-backed credentials; owner-mediated CLI usage for foreign-Keychain-only state;
   terminal corrupt/unavailable direct-cache handling; source routing; selected-account authority; owner-compatible
   config paths; account-switch invalidation; and CLI-session relaunch when account or launch environment changes.
2. A Release artifact audit verifies that the known foreign service name and direct security CLI markers are absent
   from every first-party executable in the freshly packaged app bundle.
3. A real logged-in Claude CLI-source fetch, isolated from the user's CodexBar account configuration, must return a
   Claude/CLI usage payload within a fixed deadline. The verifier records the helper's process tree and rejects any
   `/usr/bin/security` descendant outside the installed Claude owner's subtree. Process names are normalized for macOS's
   parenthesized zombie rendering before classification. Claude-owned MCP tools remain recorded
   but are not misattributed to CodexBar. A public OSLog canary first proves visibility of the bounded log window; the audit
   then requires zero Keychain prompt or authorization events attributable to CodexBarCLI across securityd, coreauthd,
   authd, SecurityAgent, authorizationhost, CoreServicesUIAgent, and UserNotificationCenter. This is positive route-
   liveness evidence; the tests and Release artifact audit carry the negative proof that no foreign reader exists.

The verifier itself performs no Keychain query. Its visibility canary emits only a public OSLog marker. It invokes the
installed Claude CLI against the live profile; as credential owner, Claude may read or refresh its own Keychain item.
Run it only with explicit consent.

## Run

```bash
./Scripts/verify_1844_live.sh
```

The script requires a locally installed, logged-in Claude CLI and packages a Release bundle itself so the audited
artifacts come from the source under test. It leaves a mode-0700 temporary report directory containing the package and
test logs, Release string audits, process-tree snapshots, CLI output, and bounded unified-log evidence. Treat that
directory as private because the live CLI payload can contain account identity and usage data.

The normal repository gates remain:

```bash
make check
make test
```
