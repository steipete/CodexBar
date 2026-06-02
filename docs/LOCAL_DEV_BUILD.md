---
summary: "Why running a SwiftPM dev build of CodexBar triggers repeated 'CodexBar wants to use CodexBarCache in your keychain' prompts, and what to do about it."
read_when:
  - You see repeated macOS keychain prompts while running a local dev build of CodexBar
  - You want to know why 'Always Allow' does not stick between rebuilds
  - You are deciding between the dev build and the installed release app for local work
---

# Local dev builds and the "CodexBarCache" keychain prompt

If you are running a SwiftPM dev build of CodexBar (typically at
`…/CodexBar/.build/<arch>-apple-macosx/debug/CodexBar`) and macOS repeatedly
shows:

> CodexBar wants to use your confidential information stored in
> "CodexBarCache" in your keychain.

this document explains why. Current CodexBar dev builds automatically disable
keychain access for that process when this risky launch mode is detected, so
you should not get trapped in the recurring prompt loop.

## Why

`com.steipete.codexbar.cache` is a CodexBar-owned keychain service that
stores session cookies and OAuth credentials. Each item has a macOS
keychain Access Control List (ACL) whose **trusted-apps list** is anchored
to the **code identity** of the binary that originally wrote the item —
bundle identifier, Team identifier, and CD hash.

A SwiftPM dev build is **ad-hoc signed**: it has no Team identifier and its
binary identity changes on every rebuild. The keychain item's trusted-apps
list does not match the dev build's identity, so `SecItemCopyMatching`
returns `errSecAuthFailed` and macOS displays a keychain prompt to
re-evaluate the ACL. Clicking "Allow" for an ad-hoc identity is a no-op in
practice: the next rebuild has a different binary identity, and the
trusted-apps list is anchored to the previous one. Hence the *recurring*
prompt.

The same is true in the opposite direction: if you click "Always Allow"
on a dev build's prompt, the dev build's identity is added to the
trusted-apps list — and the next time you launch the properly-signed
release app (`/Applications/CodexBar.app`), the release app is *not* in
that list, so the release app is prompted instead.

The release app at `/Applications/CodexBar.app` is Developer ID signed
with Team identifier `Y5PE65HELJ` and a stable CD hash, so its keychain
access is identity-stable.

## Workarounds

Pick the one that matches what you are doing.

### 1. For normal use: launch the installed release app

```sh
open /Applications/CodexBar.app
```

This is the binary the keychain ACL was written to trust. It does not
trigger this prompt.

### 2. For local dev that needs UI / runtime validation: use `compile_and_run.sh`

```sh
./Scripts/compile_and_run.sh
```

This script (per `AGENTS.md` line 36 and PR #888) detects a stable local
signing identity, signs the app bundle with that identity, packages it,
and relaunches it from `CodexBar.app`. That gives local runtime validation
a stable signing identity instead of a fresh ad-hoc identity on every rebuild.

Avoid running `.build/<config>/debug/CodexBar` directly when you are
about to touch the keychain.

For a long-term stable setup that does not require re-trusting the
self-signed certificate on every macOS update, see
`docs/DEVELOPMENT_SETUP.md` — it describes creating a persistent
"CodexBar Development" certificate and setting `APP_IDENTITY`.

### 3. Last-resort: turn off Keychain access in Advanced

`Preferences → Advanced → Keychain access → Disable Keychain access`

This sets `debugDisableKeychainAccess` to `true`, which `KeychainAccessGate.isDisabled`
honors app-wide (see `KeychainPromptCoordinator.swift` and the
`keychainDisabled` argument in every provider implementation under
`Sources/CodexBar/Providers/`). When enabled:

- CodexBar no longer reads or writes any keychain items.
- Browser-cookie-based providers (which need the macOS "Safe Storage"
  keychain item to decrypt Chromium cookies) are skipped.
- Claude/Codex OAuth via the CLI still works (it reads `~/.claude/...` and
  `~/.codex/...` config files, not the keychain).
- Per `docs/KEYCHAIN_FIX.md`, this is the steipete-acknowledged
  last-resort workaround for exactly this case.

## Self-protection

As of the patch that introduced this doc, when CodexBar detects at
startup that it is running from a SwiftPM dev build or is ad-hoc signed,
it disables keychain access for that process and emits a one-shot `os_log`
warning pointing back to this file. The warning's `eventMessage` begins
with the exact phrase:

```
Ad-hoc dev build detected
```

To find it in the system log (subsystem `com.steipete.codexbar`):

```sh
/usr/bin/log show --last 10m --style compact --info \
  --predicate 'subsystem == "com.steipete.codexbar" AND \
    eventMessage CONTAINS[c] "Ad-hoc dev build detected"' 2>/dev/null
```

The same line is also written to `~/.codexbar/.../CodexBar.log` and is
visible in Console.app under the `com.steipete.codexbar` subsystem.

If you are running `/Applications/CodexBar.app` you will *not* see this
hint and keychain access is not auto-disabled. The guard only fires for
ad-hoc / dev-build binaries.

## References

- `docs/KEYCHAIN_FIX.md` — CodexBar keychain behavior and the `Disable Keychain access` toggle
- `docs/DEVELOPMENT_SETUP.md` — stable signing-cert setup for persistent local dev
- `Sources/CodexBarCore/KeychainCacheStore.swift` — `com.steipete.codexbar.cache` write/read
- `Sources/CodexBarCore/KeychainAccessPreflight.swift` — preflight + no-UI read
- `Sources/CodexBar/KeychainPromptCoordinator.swift` — prompt coordination and the new dev-build self-diagnosis log
- `Scripts/compile_and_run.sh` — dev build script (per `AGENTS.md` line 36)
- `AGENTS.md` lines 24, 34, 36 — CI and dev-loop rules
- GitHub issue #1056 — the upstream-tracking issue for this dev-build failure mode
