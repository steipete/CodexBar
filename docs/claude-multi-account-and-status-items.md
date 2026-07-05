---
summary: "Accepted design for Claude subscription accounts and per-account menu bar items."
read_when:
  - Reviewing Claude multi-account support
  - Designing per-account status items
  - Evaluating claude-swap integration
---

# Claude multi-account and status item decision

Status: **Phase 1 account display implemented; Phase 2 explicit account activation accepted.**

Related: [#1756](https://github.com/steipete/CodexBar/issues/1756),
[#1268](https://github.com/steipete/CodexBar/issues/1268), and the bounded Claude sign-in repair in
[#1811](https://github.com/steipete/CodexBar/pull/1811).

## Accepted direction

1. Use an opt-in `claude-swap` adapter as the first Claude subscription multi-account source.
2. Normalize its results behind a provider-neutral account snapshot before adding any status item UI.
3. Make per-account status items opt-in, replace the provider item for that provider, cap selection at four, and keep
   them mutually exclusive with Merge Icons.
4. Allow an explicit click on an inactive account card to invoke exactly `cswap --switch-to <slot> --json`. Keep
   automatic switching and session launching out of scope.

This solves the durable OAuth refresh problem without making CodexBar a second credential vault. It also avoids a
Claude-only status item implementation that would need to be redesigned for Codex and other providers.

![Proposed multi-account settings and status items](screenshots/claude-multi-account-status-items-proposal.svg)

## Current architecture and gap

CodexBar has three account concepts today:

- The ambient Claude OAuth credential is routed from CodexBar's cache, Claude Code's credentials file, or Claude
  Code's Keychain item. It represents one active credential. Claude Code-owned expired credentials delegate refresh
  back to the CLI; CodexBar-owned cached credentials can refresh directly.
- `ProviderTokenAccount` stores a label and one token plus optional provider metadata. It has no refresh token or
  expiry model. Claude entries therefore work for session cookies, Admin API keys, or short-lived OAuth access tokens,
  but they are not durable multi-subscription OAuth sessions.
- `TokenAccountUsageSnapshot` and `CodexAccountUsageSnapshot` separately project multi-account usage into menus.
  Status items remain provider-scoped: `StatusItemIdentity` has only `merged` and `provider`, and
  `statusItems` is keyed by `UsageProvider`.

The recently merged [#1800](https://github.com/steipete/CodexBar/pull/1800) scopes Claude OAuth history to the routed
Keychain identity. [#1776](https://github.com/steipete/CodexBar/pull/1776) prevents CLI-runtime usage refreshes from
delegating credential repair to Claude Code, while app and user-initiated repair remain available. Both changes improve
single-active-account correctness; neither discovers or displays multiple subscriptions.

The closed [#1707](https://github.com/steipete/CodexBar/pull/1707) should not be revived. It coupled account discovery,
credential resolution, provider routing, menu rendering, and animation across a large patch while broadening
Keychain and prompt behavior. The safer seam is a credential-free usage adapter first.

## Source options

| Option | Credential ownership | Durability | Risk | Recommendation |
| --- | --- | --- | --- | --- |
| First-party OAuth account vault | CodexBar | High | New login, refresh, storage, revocation, migration, and security surface | Defer |
| Bounded `claude-swap` adapter | `claude-swap` | High | External executable and schema dependency | **Phase 1–2** |
| Discover Claude Code Keychain entries | Claude Code / ambiguous | Unknown | Undocumented enumeration; prompt and identity hazards | Reject |
| Existing token accounts | CodexBar config | Low for OAuth | Access token expires without refresh metadata | Keep for current cookie/API-key uses |

As of [`claude-swap` v0.18.0](https://github.com/realiti4/claude-swap/releases/tag/v0.18.0),
`cswap --list --json` still returns a versioned object with `schemaVersion: 1`, an active account number, account slots,
redaction-sensitive email labels, 5-hour and 7-day usage percentages, and reset timestamps. Handled failures return an
error object and non-zero exit. Direct switching returns the same versioned envelope. CodexBar does not need
`--token-status`, credential files, Keychain access, or raw OAuth values for display or explicit activation.

## Phase 1 adapter contract

- Disabled by default. User chooses an executable path and enables “Read accounts from claude-swap.”
- Execute exactly the argument array `cswap --list --json`. Never invoke a shell or accept config-defined passthrough
  arguments.
- Require `schemaVersion == 1`; reject unknown versions and partial top-level shapes.
- Bound runtime and stdout, terminate on timeout, and retain the last successful snapshot with a stale marker.
- Parse only slot number, active state, usage status, 5-hour/7-day percentages, and reset timestamps.
- Treat email as display-only sensitive data. Never log or persist it. Respect Hide Personal Info.
- Use the source-issued numeric slot for identity (`claude-swap:<slot>`), not email or credential-derived values.
- CodexBar never reads `claude-swap` storage, Claude Code storage, environment credentials, or Keychain entries. The
  subprocess remains solely responsible for its own credential access. The adapter copies only allow-listed
  usage/identity fields into its model and never logs or persists raw stdout.
- Never run `auto`, `run`, `--switch`, `--switch-to`, `--add-account`, export, import, purge, or any other command in
  Phase 1.
- Isolate adapter failure from ambient Claude usage. Users without `claude-swap` see no behavior change.

The executable is an optional external dependency, not a bundled component. Preferences should show detected version,
last refresh, adapter errors, and a link to the upstream project; CodexBar should not install or update it.

## Phase 2 explicit activation contract

- Only an explicit click on an inactive, actionable account card can start a switch.
- Derive the numeric slot from the already validated account snapshot and execute exactly
  `cswap --switch-to <slot> --json`; never accept free-form arguments or invoke a shell.
- Serialize switches, validate `schemaVersion == 1` and the returned target slot, and bound captured output.
- Once launched, let the external credential transaction reach its natural exit without forced timeout or
  cancellation. If the adapter setting changes, hide its UI state and discard its result when the original
  configuration is no longer current.
- Refresh ambient Claude usage and the adapter account list after completion. Show switch errors independently from
  list-refresh errors and preserve the last successful usage snapshots.
- Keep expired, missing, unknown, and Keychain-inaccessible credential slots non-actionable. Never auto-switch, launch
  sessions, add/import/export/purge accounts, or mutate credentials directly.

## Provider-neutral account model

Introduce one projection used by menus and status items rather than teaching status item code about Claude OAuth:

```swift
struct ProviderAccountUsageSnapshot: Identifiable {
    let id: ProviderAccountIdentity
    let provider: UsageProvider
    let displayLabel: String
    let isActive: Bool
    let canActivate: Bool
    let snapshot: UsageSnapshot?
    let error: String?
    let sourceLabel: String?
}

struct ProviderAccountIdentity: Hashable {
    let source: String
    let opaqueID: String
}
```

Adapters own identity conversion. UI receives a user alias or privacy-safe ordinal when personal information is hidden.
No provider may fill identity, plan, or usage fields using another provider's data.

Existing `TokenAccountUsageSnapshot` and `CodexAccountUsageSnapshot` can migrate behind this projection in small,
separately reviewed steps. Their credential and refresh logic stays source-specific.

## Per-account status item behavior

Proposed setting under each provider's Accounts section:

- `One provider icon` (default; current behavior)
- `Selected account icons`, with up to four account checkboxes

Selecting account icons replaces that provider's aggregate item; it does not add duplicates. Account items use a
stable `StatusItemIdentity.account(provider:source:opaqueID:)`, preserve existing provider autosave names, and open the
provider menu focused on that account. A short user alias or ordinal badge distinguishes otherwise identical provider
icons. Hide Personal Info replaces labels with `Account 1`, `Account 2`, and so on.

Merge Icons continues to mean exactly one status item. Account-icon controls are disabled while it is enabled, with a
button to turn Merge Icons off. Existing users and status item positions remain unchanged until they opt in.

The alternative proposed in the #1268 discussion is a per-account toggle that adds selected account items, leaves
unselected accounts under the provider item, and coexists with Merge Icons. That is more granular, but it creates
duplicate provider/account items, makes “Merge Icons” no longer mean one item, and multiplies autosave and recovery
states. The replacement mode above is the recommendation; if maintainers prefer the additive mode, grouping and Merge
Icons semantics must be decided before implementation.

## UI proof

The mock above shows the recommended mode and its Merge Icons conflict. It is intentionally a decision artifact, not
an implementation screenshot. The following packaged synthetic-account proof verifies the bounded current behavior:
the account action is now named “Sign in with Claude Code…” and no longer claims it will add a durable CodexBar account.
No real credential, browser session, or provider call was used.

![Packaged synthetic Claude sign-in proof](screenshots/claude-sign-in-synthetic-proof.png)

## Accepted decisions

1. The optional external `claude-swap` dependency is accepted for exact `cswap --list --json` execution and explicit
   `cswap --switch-to <slot> --json` activation.
2. Automatic switching, account add/import/export/purge, and session launching stay out of scope.
3. Provider-neutral account snapshots land before any per-account status item work.
4. Per-account status items are capped at four and mutually exclusive with Merge Icons.
5. Status item labels use aliases or privacy-safe ordinals, never email identity.

Any further change to these decisions requires a new product/auth review before implementation because it changes
storage, status item migration, process authority, or the credential boundary.

## Implementation and validation sequence

1. Add fixtures for schema v1, error payloads, unknown versions, invalid percentages/timestamps, output limits, and
   process timeout. Use a fake executable only.
2. Add the opt-in adapter and provider-neutral projection. Verify no credential reads and no impact on ambient Claude.
3. Add settings-state and menu-model tests. Keep AppKit status item creation out of headless tests.
4. Add status item identity/migration tests, then implement account items behind the opt-in setting.
5. Add exact-argv, strict switch-result, serialization, and refresh tests using a fake executable only.
6. Run focused tests, `make check`, `make test`, packaged synthetic proof, and macOS UI proof with redacted fixtures.

No credential import, automatic switching, session launching, or compatibility shim is part of this proposal.
