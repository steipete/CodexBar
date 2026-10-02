---
summary: "Langdock personal included-usage limits from a selected Microsoft Edge profile."
read_when:
  - Setting up Langdock in CodexBar
  - Debugging Langdock profile or cookie access
---

# Langdock

CodexBar reads the personal included-usage limits shown on Langdock's account Usage page. This
provider is disabled by default and supports macOS Edge profiles only.

1. Sign in to Langdock in the Edge profile you want to monitor.
2. In CodexBar's Langdock provider settings, enter that profile's directory path as **Edge profile ID**.
   The path must identify the exact Edge profile that owns the Langdock session.
3. Enable Langdock, then refresh. The CLI equivalent is
   `codexbar usage --provider langdock --source web`.

CodexBar selects that one profile and reads its applicable `langdock.com` and `app.langdock.com`
cookies. Decrypted session values stay in memory and are not cached by CodexBar. The existing
SweetCookieKit importer uses temporary copies of the browser cookie database while reading it;
this provider does not introduce another credential store. It does not switch to another Edge account if the selected profile is missing
or its session expires. macOS must allow the running CodexBar bundle to read the Edge profile and
the Edge Safe Storage Keychain item. Browser access errors are shown in CodexBar; no administrator
rights or access to the Langdock macOS app are required.

If usage disappears after a restart, verify the saved **Edge profile ID** against the profile
path shown by `edge://version` in the same Edge window as Langdock. A message that Edge cookie
access is blocked calls for a manual Langdock refresh and a check of CodexBar's Keychain access
setting. If CodexBar reports that it cannot read the profile, check **Privacy & Security → Files &
Folders → CodexBar → Microsoft Edge** for the exact app bundle being run. Local ad hoc signed
builds may need a renewed macOS grant after rebuilding. A missing cookie store remains a separate
profile or browser-data problem; CodexBar does not try another profile.

Langdock reports a five-hour session percentage and a seven-day weekly percentage. A disabled
session limit hides the session bar. Missing reset dates remain unknown. If Langdock returns a
valid response without included plan usage, CodexBar shows “No included usage limits available.”
Extra Usage, workspace-wide billing, widgets, and stored quota history are outside this integration.
Stored history remains disabled because the usage response does not establish a stable account identity.

## Session ownership and refreshes

Each refresh checks the selected profile's session before and after the HTTP request. An in-memory
session fingerprint prevents a response from an earlier login from being published after a detected
session change. It is excluded from serialized snapshots and logs. A transient request failure can
retain the last measurement only when the current session still matches; its original age and an
error remain visible. A session change or an unverifiable session clears the old measurement.
Changes in Edge are detected on the next refresh; this provider does not monitor browser logins continuously.

CodexBar uses its configured refresh interval. A manual refresh requests another server measurement;
the Langdock page and CodexBar can differ while one is displaying an earlier measurement. The separate
pace/reserve indicator is CodexBar's estimate, not an additional Langdock quota.

## Compatibility and review notes

- The request uses Langdock's internal `usageSettings.getPersonalUsage` web endpoint on
  `https://app.langdock.com`. It is not a documented public API and may change independently of CodexBar.
- Missing `planUsage` is supported. A separately hidden Usage page has not been independently verified;
  the provider does not assume that a successful HTTP response proves page visibility.
- No administrator privileges, manual token entry, or access to the Langdock desktop app are needed.
- The profile-specific browser-host entry point and native implementation require maintainer architecture
  review under [VISION.md](../VISION.md). The generic plugin cookie broker does not provide this exact
  profile/session ownership contract.
- The monochrome mark comes from the official [Langdock brand kit](https://langdock.com/brand-kit).
