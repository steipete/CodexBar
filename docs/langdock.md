---
summary: "Langdock personal included-usage limits from a selected Edge, Chrome, or Safari profile."
provider_id: langdock
provider_name: Langdock
provider_source: Selected Edge, Chrome, or Safari profile → personal included session and weekly limits (`web`, macOS).
plugin_scope: Host-owned selected browser profile, live session revalidation, and personal tRPC limits on both engines; no quota history or widgets.
read_when:
  - Setting up Langdock in CodexBar
  - Debugging Langdock profile or cookie access
---

# Langdock

CodexBar reads the personal included-usage limits shown on Langdock's account Usage page. This
provider is disabled by default and supports Microsoft Edge, Google Chrome, and Safari profiles on macOS.

1. Sign in to Langdock in the browser profile you want to monitor.
2. In CodexBar's Langdock provider settings, choose **Browser**, then the signed-in profile under **Browser profile**.
   CodexBar never chooses the first available profile automatically.
3. Enable Langdock, then refresh. The CLI equivalent is
   `codexbar usage --provider langdock --source web`.

`codexbar cookie refresh --provider langdock` uses the configured browser and profile. Edge and Chrome
require `--allow-keychain-prompt` for an explicit interactive retry; Safari does not require that flag.

CodexBar selects that one profile and reads its applicable `langdock.com` and `app.langdock.com`
cookies. Decrypted session values stay in memory and are not cached by CodexBar. The existing
SweetCookieKit importer uses temporary copies of the browser cookie database while reading it;
this provider does not introduce another credential store. It does not switch to another browser or account if the selected profile is missing
or its session expires. For Edge and Chrome, macOS must allow the running CodexBar bundle to read the selected profile and
the browser's Safe Storage Keychain item. Safari cookie files may require **Full Disk Access** for CodexBar;
Safari does not use Chromium's Safe Storage credential. Browser access errors are shown in CodexBar; no administrator
rights or access to the Langdock macOS app are required.

If usage disappears after a restart, verify the saved **Browser** and **Browser profile** selections. For Edge or Chrome, compare the profile
path shown by `edge://version` or `chrome://version` in the same browser window as Langdock. A message that browser cookie
access is blocked calls for a manual Langdock refresh and a check of CodexBar's Keychain access
setting. If CodexBar reports that it cannot read the profile, check **Privacy & Security → Files &
Folders → CodexBar → Microsoft Edge / Google Chrome** for the exact app bundle being run. For Safari, check **Full Disk Access** instead. Development builds must use the matching signing identity before accessing existing Keychain items. A missing cookie store remains a separate
profile or browser-data problem; CodexBar does not try another profile.

Existing Edge configurations remain valid without a new browser selection. The provider config stores
`browserID` (`edge`, `chrome`, or `safari`) and `browserProfileID`. Without `browserID`, legacy selections
remain scoped to Edge. Switching browsers clears the saved profile and requires a new explicit selection.
Chrome and Edge profile IDs are directory paths; Safari IDs are the exact discovered cookie-file paths.
Safari datastore identifiers can be reassigned between files, so CodexBar binds the selection to that file path.
Safari's default and legacy stores are separate from profile-specific WebsiteDataStore files. The current
importer may show a Safari profile's datastore identifier instead of its display name. A profile must have
a discoverable cookie file; CodexBar never uses Safari's browser-wide fallback when a selected file is absent.

Langdock reports a five-hour session percentage and a seven-day weekly percentage. A disabled
session limit hides the session bar. Missing reset dates remain unknown. If Langdock returns a
valid response without included plan usage, CodexBar shows “No included usage limits available.”
Extra Usage, workspace-wide billing, widgets, and stored quota history are outside this integration.
Stored history remains disabled because the usage response does not establish a stable account identity.
Session-bound measurements are also excluded from saved widget snapshots and cloud account exports.

## Session ownership and refreshes

Each refresh checks the selected profile's session before and after the HTTP request. An in-memory
session fingerprint prevents a response from an earlier login from being published after a detected
session change. It is excluded from serialized snapshots and logs. A transient request failure can
retain the last measurement only when the current session still matches; its original age and an
error remain visible. A session change or an unverifiable session clears the old measurement.
Changes in the selected browser are detected on the next refresh; this provider does not monitor browser logins continuously.

CodexBar uses its configured refresh interval. A manual refresh requests another server measurement;
the Langdock page and CodexBar can differ while one is displaying an earlier measurement. The separate
pace/reserve indicator is CodexBar's estimate, not an additional Langdock quota.

## Compatibility and review notes

- The request uses Langdock's internal `usageSettings.getPersonalUsage` web endpoint on
  `https://app.langdock.com`. It is not a documented public API and may change independently of CodexBar.
- Missing `planUsage` is supported. A separately hidden Usage page has not been independently verified;
  the provider does not assume that a successful HTTP response proves page visibility.
- No administrator privileges, manual token entry, or access to the Langdock desktop app are needed.
- The bundled `langdock.ts` plugin owns requests, parsing, and error classification on JavaScriptCore and QuickJS.
  The generic host enforces selected-profile imports and post-request ownership checks; scripts never receive
  cookie values or session fingerprints. The `browserID` and `browserProfileID` provider config fields store the selection.
- The monochrome mark comes from the official [Langdock brand kit](https://langdock.com/brand-kit).
