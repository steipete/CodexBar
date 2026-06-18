# PR: feat/manual-credential-json

## Problem

Users need to use manually imported `cliproxyapi` Codex credentials without completing the full CodexBar OAuth flow. The external files use a flat JSON shape, so CodexBar needs a read-only import path that can display usage for those accounts without owning or mutating their tokens.

## Changes

Commits and changed files from `git log -p a4f278d9..feat/manual-credential-json`:

- `7e11eb81` `feat: read-only imported credential (cliproxyapi codex) accounts`
  - `Sources/CodexBar/CodexAccountMenuPresentation.swift`
  - `Sources/CodexBar/ImportedCodexAccountsMenuView.swift`
  - `Sources/CodexBar/MenuContent.swift`
  - `Sources/CodexBar/PreferencesImportedCredentialsSection.swift`
  - `Sources/CodexBar/PreferencesProvidersPane.swift`
  - `Sources/CodexBar/SettingsStore+ConfigPersistence.swift`
  - `Sources/CodexBar/SettingsStore+ImportedCredentials.swift`
  - `Sources/CodexBar/StatusItemController+Animation.swift`
  - `Sources/CodexBar/StatusItemController+CodexStackedMenu.swift`
  - `Sources/CodexBar/StatusItemController+IconObservation.swift`
  - `Sources/CodexBar/StatusItemController+Menu.swift`
  - `Sources/CodexBar/StatusItemController.swift`
  - `Sources/CodexBar/UsageStore+CodexMenuBarMetric.swift`
  - `Sources/CodexBar/UsageStore+HighestUsage.swift`
  - `Sources/CodexBar/UsageStore+ImportedCodexAccounts.swift`
  - `Sources/CodexBar/UsageStore+Refresh.swift`
  - `Sources/CodexBar/UsageStore.swift`
  - `Sources/CodexBarCore/Config/CodexBarConfig.swift`
  - `Sources/CodexBarCore/ImportedCredentials/BorrowedCodexUsageFetcher.swift`
  - `Sources/CodexBarCore/ImportedCredentials/CLIProxyCodexAdapter.swift`
  - `Sources/CodexBarCore/ImportedCredentials/ImportedCredentialSource.swift`
  - `Tests/CodexBarTests/CodexMenuBarMetricAverageTests.swift`
  - `Tests/CodexBarTests/ImportedCodexUsageStoreTests.swift`
  - `Tests/CodexBarTests/ImportedCredentialsTests.swift`
  - `Tests/CodexBarTests/UsageStoreHighestUsageTests.swift`
  - Added imported credential source config, preferences UI, compact imported-account menu rows, flat -> nested `cliproxyapi` Codex credential adaptation, read-only borrowed usage fetch, and imported Codex snapshots in highest-usage/menu-bar metric selection.

- `cfb673be` `fix(menu-bar): restore weekly gauge on codex icon with imported accounts`
  - `Sources/CodexBar/UsageStore+CodexMenuBarMetric.swift`
  - `Tests/CodexBarTests/CodexMenuBarMetricAverageTests.swift`
  - Restored multi-account menu-bar gauge averaging for both primary and secondary Codex lanes, including import-only Codex accounts.

- `471d00e0` `fix(menu-bar): keep the status badge out of the weekly bar (no more "full + extra chunk")`
  - `Sources/CodexBar/IconRenderer.swift`
  - Added a status-badge gutter so the provider service-status badge no longer visually merges with the weekly usage bar.

- `d897d545` `fix(imported-creds): apply the codex-*.json filter to directly-picked file sources too`
  - `Sources/CodexBarCore/ImportedCredentials/CLIProxyCodexAdapter.swift`
  - `Tests/CodexBarTests/ImportedCredentialsTests.swift`
  - Applied the `codex-*.json` filename filter to both directory imports and directly selected file imports.

Feature summary:

- Flat `cliproxyapi` Codex JSON is adapted into in-memory Codex OAuth credential structs.
- Imported credentials are configured through `ImportedCredentialSource` and persisted in CodexBar config.
- Directory imports and direct-file imports both accept only `codex-*.json` files.
- Imported accounts appear as read-only Codex menu rows with source labels, status handling, and usage metrics.
- Active Codex and imported Codex accounts participate together in highest-usage selection.
- The menu-bar icon averages primary and secondary Codex gauge lanes across active + imported accounts.
- `IconRenderer` reserves a status-badge gutter so the status badge cannot look like an extra chunk of weekly usage fill.

## Read-only safety guarantee

Borrowed tokens are NEVER refreshed or written back.

The read-only path calls `CodexOAuthUsageFetcher` directly through `BorrowedCodexUsageFetcher`, bypassing the normal refresh/save strategy used by owned Codex OAuth credentials. That means imported access tokens can be used for usage fetches, but CodexBar does not attempt to rotate, refresh, persist, or repair those credentials.

The borrowed fetch environment is isolated with:

```text
CODEX_HOME=/var/empty
```

That isolation prevents accidental writes into a real Codex home directory while imported credentials are being used. Expired imported credentials are rejected before network fetch.

## Testing

- `swift test`
  - 3427 tests passed.
  - 1 pre-existing MiniMax locale failure was observed and treated as expected for this branch.

Manual verification:

- Add a folder containing valid `codex-*.json` `cliproxyapi` Codex credentials.
- Confirm disabled, expired, malformed, sidecar, and non-Codex files are skipped or shown with the expected status.
- Add a directly selected file and confirm only `codex-*.json` is accepted.
- Confirm imported Codex accounts render as read-only menu rows.
- Confirm usage refreshes fetch current usage without modifying the source JSON files.
- Confirm imported-only Codex accounts can drive the menu-bar icon.
- Confirm active + imported Codex accounts average both primary and weekly gauge lanes.
- Confirm status badges render in the reserved gutter and do not merge into the weekly bar.

## Safety notes

- The `codex-*.json` filter is enforced for both directory and direct-file sources.
- Imported accounts are marked and handled as read-only borrowed credentials.
- Refresh/save logic for owned OAuth credentials is bypassed for imported credentials.
- `CODEX_HOME=/var/empty` is used for borrowed fetches to avoid accidental local Codex state writes.
- Imported account errors are surfaced in menu presentation instead of triggering token repair or write-back.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
