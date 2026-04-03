---
summary: "Runbook for adding local Codex profile save/switch support and shipping it safely."
read_when:
  - Repeating this workflow in another app
  - Adding local account/profile switching
  - Preparing a clean PR after sensitive-history mistakes
---

# Codex Local Profiles Runbook

## Purpose

This runbook captures how local Codex profile save/switch support was added to CodexBar, how the scope was kept under control, and how the feature was hardened and documented before opening an upstream PR.

Use it as a repeatable pattern for similar work in other local-first macOS apps.

## Problem Being Solved

CodexBar already knew how to observe live Codex account state, but switching between multiple Codex logins was still a manual filesystem workflow.

The goal was to let users:

1. sign into a Codex account once in the Codex app or Codex CLI
2. save that live auth state as a named local profile
3. switch between saved profiles from Settings or the menu bar

This had to work without introducing:

- account-model rewrites
- token leakage
- destructive profile switching
- UI drift from the existing CodexBar design

## Scope Decisions

The implementation stayed intentionally narrow.

Included:

- local save/switch support for Codex auth state
- a separate `Local Profiles` section in Settings
- a `Switch Local Profile` submenu in the Codex menu
- safe switching with confirmations, backups, and path validation

Explicitly excluded:

- multi-account identity rewrites for the existing `Accounts` section
- nicknames or custom secondary labels
- changes to managed Codex account reconciliation
- status-menu redesign outside the local-profile submenu

## Main Implementation Strategy

### 1. Keep the existing `Accounts` area conservative

The first version changed the stock `Accounts` section too much. That was later corrected.

Final rule:

- keep `Accounts` close to stock CodexBar
- add local-profile functionality in a separate sibling `Local Profiles` section

This reduced review risk and made the new workflow feel additive rather than invasive.

### 2. Use the live auth file as the single source of truth

The feature works by treating the current Codex auth state as the canonical live state:

- live auth: `~/.codex/auth.json`
- saved profiles: `~/.codex/profiles/<alias>.json`
- backups before switch: `~/.codex/auth-backups`

That meant no new token format or alternate persistence model was needed.

### 3. Keep execution logic away from the UI

The implementation was split into:

- `Sources/CodexBar/CodexLocalProfileManager.swift`
  ownership of profile discovery, validation, save/switch transaction, backups, and presentation-safe profile state
- `Sources/CodexBar/CodexLocalProfileActionCoordinator.swift`
  ownership of prompts, close/reopen behavior, and user-facing action execution
- Settings and menu views
  ownership of rendering only

This separation was important because the risky parts were filesystem and process operations, not UI.

## Feature Flow

### Save current account

1. Validate that live Codex auth exists and is readable.
2. Reject invalid or duplicate profile aliases.
3. Reject symlinked auth/profile paths.
4. Create `~/.codex/profiles` with private permissions if needed.
5. Copy the current live auth file into `profiles/<alias>.json`.
6. Harden file permissions.

### Switch profile

1. Resolve and validate the requested saved profile path.
2. Detect whether `Codex.app` or `codex` CLI sessions are running.
3. Ask for confirmation before closing those processes.
4. Create a private backup of the current live auth.
5. Replace `~/.codex/auth.json` with the chosen saved profile.
6. Reopen `Codex.app` after a successful switch.
7. Prune older backups after a successful write.

## Safety Controls Added

The most important controls were:

- symlink rejection for auth and saved profiles
- path restriction to the expected `~/.codex/profiles` directory
- private directory/file permissions (`700`/`600`)
- backup creation before switching
- bounded backup pruning to avoid indefinite token copies accumulating
- confirmation before closing Codex app or CLI sessions
- process-detection fix to avoid hanging on `ps` output parsing

## UX Rules That Mattered

### Settings

- `Local Profiles` is separate from `Accounts`
- `Save Current Account…` is hidden when:
  - there is no valid live auth
  - the current live auth already exactly matches a saved profile
- first-time onboarding is shown only when there are no saved profiles
- a small always-visible `info.circle` help affordance lives in Settings only

### Menu bar

- `Switch Local Profile` stays minimal
- no extra help icon or long instructions in the menu
- when no live auth exists, the submenu remains discoverable but non-actionable

## Multi-Account Model

The implementation supports more than two Codex accounts without a hard-coded limit.

Expected workflow:

1. Sign into account A in the Codex app or Codex CLI.
2. Save it in CodexBar.
3. Sign into account B.
4. Save it in CodexBar.
5. Repeat for accounts C, D, and beyond.
6. After that, switching happens entirely inside CodexBar.

Practical limit:

- implementation: no enforced limit
- UX: the settings list and menu become the limiting factor before storage does

## Testing Strategy

Coverage focused on stable seams instead of fragile live-AppKit behavior.

Added or updated tests around:

- profile save/switch manager behavior
- path safety and symlink rejection
- backup pruning
- settings section state and visibility rules
- menu submenu state and save visibility

Representative files:

- `Tests/CodexBarTests/CodexLocalProfileManagerTests.swift`
- `Tests/CodexBarTests/CodexAccountsSettingsSectionTests.swift`
- `Tests/CodexBarTests/StatusMenuCodexLocalProfilesTests.swift`
- `Tests/CodexBarTests/CodexProfileStoreTests.swift`

## Verification Workflow Used

Normal checks:

- `./Scripts/lint.sh lint`
- `swift build`
- `./Scripts/compile_and_run.sh`

Additional clean-branch validation:

- `swift build --scratch-path /tmp/codexbar-local-profile-manager-clean-build`

Known repo limitation during this work:

- `swift test --filter CodexAccountsSettingsSectionTests` compiled the touched local-profile files but still hit unrelated pre-existing `SettingsStoreTests` / Swift Testing baseline failures outside this feature area

## PR Hygiene Lessons

### Keep the public diff clean

One test fixture accidentally included a machine-specific local path during development. It was not a credential, but it still should not have been published.

Best practice from this incident:

1. run a branch-diff scrub before opening a PR
2. check for usernames, local paths, emails, and secret-like strings
3. if something slips into a published PR branch, prefer replacing the branch with a clean rebuilt branch rather than leaving the old history active

### What the cleanup looked like

1. sanitize the live branch locally
2. close the old draft PR
3. delete the old remote branch
4. create a fresh branch from current upstream `main`
5. squash-merge the final clean feature state
6. open a fresh draft PR from the new clean branch

This is the safest response when you want the public branch history to stop exposing an avoidable identifier.

## Transferable Rules for Other Projects

If you build a similar feature elsewhere, keep these rules:

- use one canonical live auth state instead of inventing parallel token stores
- keep risky filesystem/process logic out of the UI layer
- add save gating so the main CTA only appears when it is actually useful
- separate new workflows from existing account-management UI when possible
- test presentation via stable state builders, not brittle live menu construction
- scrub the full diff before publishing, not just the final files

## Files Most Relevant to This Feature

- `Sources/CodexBar/CodexLocalProfileActionCoordinator.swift`
- `Sources/CodexBar/CodexLocalProfileManager.swift`
- `Sources/CodexBar/PreferencesCodexAccountsSection.swift`
- `Sources/CodexBar/PreferencesProvidersPane.swift`
- `Sources/CodexBar/StatusItemController+CodexLocalProfilesMenu.swift`
- `Sources/CodexBar/StatusItemController+Actions.swift`
- `Sources/CodexBarCore/Providers/Codex/CodexProfileStore.swift`
- `Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift`

## When To Reuse This Runbook

Reuse this runbook when a feature:

- switches between local saved credentials
- modifies live auth/config files on disk
- closes companion apps or CLIs during switching
- needs to remain visually conservative in an established UI

For broader CodexBar architecture and development notes, see `docs/codexbar-project-guide.md`.
