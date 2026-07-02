# Portable UI preferences decision

Issue: [#1282](https://github.com/steipete/CodexBar/issues/1282)

## Recommendation

Use a separate `preferences.json` beside CodexBar's resolved `config.json`, with `CODEXBAR_PREFERENCES` as an explicit path override. Do not place UI preferences inside `config.json`: provider configuration can contain API keys, cookie headers, and other credentials, so encouraging users to commit that file to dotfiles would create an avoidable secret-disclosure trap.

Portable preferences should be opt-in by file presence. CodexBar must not create or populate the file during an upgrade. This keeps existing installs on UserDefaults and avoids silently exporting a user's device state.

## Proposed precedence and writes

1. An explicit, valid key in `preferences.json` wins.
2. An omitted key preserves the existing UserDefaults value.
3. If neither exists, the current code default applies.

An empty document therefore changes nothing. Invalid values should be logged and ignored per key rather than rejecting every preference.

Recommended UI-write behavior: when the portable file exists, changing a portable setting writes the file and mirrors UserDefaults as a local fallback. External file changes should update only the in-memory portable subset. Both behaviors need owner approval before runtime wiring because they establish a new synchronization and conflict contract.

## Phase-one portable whitelist

- refresh cadence;
- usage bars as used or remaining;
- reset-time presentation and provider changelog links;
- menu bar display mode, branding, critter visibility, and highest-usage choice;
- merged-menu and switcher presentation;
- Overview provider selection;
- provider-list sort presentation;
- app language;
- blink and weekly-limit confetti presentation.

The prototype schema is sparse and versioned. Unknown provider IDs survive normalization so a newer machine does not erase a synced selection merely because an older CodexBar build cannot render that provider yet.

## Explicit exclusions

- `launchAtLogin`: OS registration, not a portable preference;
- terminal app, window frames, last-selected provider/menu, and provider-detection completion: device/session state;
- debug, logging, browser, keychain, and authentication controls: security or diagnostics state;
- `hidePersonalInfo`: syncing an explicit `false` could unexpectedly reveal identity on another screen;
- historical tracking, cost scanning, notifications, and storage-footprint collection: performance, retention, or permission choices;
- provider credentials, cookies, account routing, and token accounts: remain in the existing protected provider config path.

## Migration and failure behavior

- no automatic migration or file creation;
- malformed JSON leaves UserDefaults active and surfaces one actionable diagnostic;
- missing/invalid individual values fall back without rewriting the source file;
- future schema versions must preserve unknown keys or refuse writes rather than destructively downgrading;
- deletion disables portable overrides immediately and returns to UserDefaults;
- documentation must warn that `config.json` is secret-bearing and should not be committed wholesale.

## Maintainer choice

1. **Recommended:** separate, file-presence opt-in `preferences.json`; explicit keys override UserDefaults; UI changes dual-write while active.
2. Put a `preferences` block in `config.json`. Fewer files, but materially easier to leak provider secrets through dotfiles.
3. Export/import only. No live synchronization conflicts, but edits on one Mac do not declaratively update another.

This branch supplies the versioned schema, normalization, resolver, path contract, and state tests. It intentionally does not connect the store to `SettingsStore` until the storage, precedence, and write-back choices above are approved.
