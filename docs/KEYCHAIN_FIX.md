---
summary: "Current and historical engineering notes for CodexBar Keychain prompt containment."
read_when:
  - Auditing Keychain access boundaries
  - Investigating legacy secret migration
  - Comparing old startup-migration guidance with the current architecture
---

# Keychain prompt containment: engineering note

The current design treats Keychain access as an interaction boundary, not as a property that can be fixed by changing
an item's accessibility class. Background work should fail closed, user-initiated work may acknowledge deliberate
interactive access, and all first-party Security.framework item operations route through `KeychainSecurity`.

User-facing behavior and troubleshooting live in [Keychain prompts](keychain-prompts.md).

## Current boundaries

- `KeychainAccessGate` is the global app policy. `KeychainSecurity` applies it centrally before all item reads,
  updates, additions, and deletions, in addition to the independent test-process suppression policy.
- `KeychainNoUIQuery` and the process test guard provide defense in depth for paths that must not display UI.
- Chromium imports use a no-UI preflight and scope the dependency's actual background record read with
  `BrowserCookieKeychainAccessGate.withUserInteractionDisallowed`. A user-initiated explicit retry keeps the one
  acknowledged interactive recovery path.
- Foreign-item readers, including Zed, check the global gate at their ownership boundary and fail closed.
- Claude Code's Keychain item is foreign-owned. Direct reads require explicit, default-off consent and have their own
  prompt policy. Provider-owned CLI fallback is intentionally outside the global Security.framework gate because the
  child executable owns its credential behavior.
- `KeychainCacheStore` retains its existing ACL-creation fallback and disabled-mode in-memory cookie behavior; those
  are separate from this prompt-containment change.

## Unified legacy migration

`CodexBarConfigMigrator` is the single migration owner for retired token, cookie, MiniMax, Kimi, OpenCode, and token-
account stores. It reads every legacy source before cleanup, persists successfully read values idempotently, and only
clears legacy stores after config persistence succeeds and every loader was readable. A loader failure records the
provider/store identity without secret data, blocks all cleanup for that launch, and leaves
`codexbar.legacySecretsMigrationCompleted` unset so the next launch retries.

This ordering matters: “not found” is a successful read with no value, while “unreadable” is a migration failure. The
latter must never be collapsed into absence because doing so could mark migration complete or clear another store
whose value was recovered successfully.

## Retired accessibility migration

Older builds also launched `KeychainMigration` from `HiddenWindowView`. It read, deleted, and recreated a fixed list of
legacy items to change `kSecAttrAccessible`. That path became obsolete once unified config migration owned those same
stores and cleared them. It was retired rather than retained as a shim because it could prompt during launch, marked
itself complete despite errors, and deleted an existing secret before confirming that the replacement add succeeded.

The former completion flag and reset instructions were removed with it. Accessibility such as
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` controls when an item is available; it does not make an unstable or
changed code signature satisfy the item's access-control list.

Apple's [`kSecAttrAccessible`](https://developer.apple.com/documentation/security/ksecattraccessible) API caveat is
important on macOS: the attribute applies to data-protection-keychain items. It is not a repair mechanism for a legacy
file-keychain ACL or for a code-signature/designated-requirement mismatch.

## Safe verification

Routine tests run with `CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1` through `Scripts/test.sh`. Tests use task overrides,
query construction checks, source audits, and store doubles. No test source except the audit itself may contain a
direct Security item API call, and routine verification must not query the real Keychain, import browser cookies, or
launch live provider probes.

Relevant implementation files:

- `Sources/CodexBarCore/KeychainSecurity.swift`
- `Sources/CodexBarCore/KeychainAccessGate.swift`
- `Sources/CodexBarCore/KeychainNoUIQuery.swift`
- `Sources/CodexBarCore/BrowserCookieAccessGate.swift`
- `Sources/CodexBar/Config/CodexBarConfigMigrator.swift`
- `Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift`
