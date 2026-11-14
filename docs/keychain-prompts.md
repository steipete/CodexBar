---
summary: "Why macOS Keychain prompts appear, how CodexBar limits them, and safe troubleshooting."
read_when:
  - Investigating Chromium Safe Storage or Claude credential prompts
  - Choosing whether to allow or disable Keychain access
  - Collecting safe support details without exposing secrets
---

# Keychain prompts

CodexBar uses several credential sources, but three foreign-owned Keychain items are the common authorization surfaces:

- Chromium cookie import needs the browser's Safe Storage secret to decrypt its cookie database. Examples include
  `Chrome Safe Storage`, `Brave Safe Storage`, and `Microsoft Edge Safe Storage`.
- Claude OAuth repair can read Claude Code's `Claude Code-credentials` item. Direct access to that foreign item is
  off by default and requires explicit consent in Claude's provider settings. The default prompt policy reserves
  interactive repair for a user action.
- Muse Code subscription usage reads the Muse CLI's `ai.meta.dev.credentials` item. Background refreshes and
  the CLI never prompt for it; a manual app refresh may ask once, after an explanation, so **Always Allow** can
  grant later silent reads. This shares the action’s one interactive read with browser imports; a denial
  suppresses another Muse prompt for six hours.

CodexBar does not need the browser or Claude account password. macOS owns the authorization prompt and should name
the requesting app or binary. Never send a Keychain item value, cookie header, OAuth token, API key, or password in a
support report.

## When CodexBar can prompt

Scheduled and settings-triggered Chromium imports never request Keychain interaction, even when a settings change
occurs during a manual refresh. Every import first tries the actual Safe Storage read without UI. A manual refresh
shares one interactive retry across its browser imports and providers; successful no-UI reads do not spend that
allowance. ACL preflight metadata cannot authorize additional prompts. Automatic cookie imports stop reading
browsers once a provider accepts a session; missing or rejected sessions advance to the next browser in the
provider's existing order. Explicit browser/profile selections keep their own scope.

A denied browser prompt suppresses Chromium-family interactive retries for six hours, including repeated Refresh
clicks in the menu or provider settings. Only `codexbar cookie refresh --allow-keychain-prompt` explicitly overrides
that cooldown. An acknowledged Claude repair has its own user-action policy.

Scheduled Chromium imports can recover during that denial cooldown when the current no-UI Safe Storage preflight
explicitly confirms access. Interaction-required, missing, or failed preflights still suppress the import, and the
actual read remains non-interactive. This recovery does not clear the user-initiated denial cooldown or override
disabled Keychain access.

An inconclusive no-UI preflight gets at most three attempts, with a 30 ms pause before each retry. Stable authorization
decisions are never retried. Each distinct preflight can add two 30 ms waits plus the Security calls;
repeated checks within one operation reuse the final result. This applies to generic-password preflights for
browser storage, credential repair, and CodexBar caches, without changing their permission requirements.

Concurrent preflights for the same trusted application and executable share an in-flight code-signature validation.
For the running executable (or its own main app bundle), preflight checks the ACL's signing requirement against the
process's dynamic code identity with default Security flags, avoiding sealed-resource hashing. A bundled CLI helper
only validates its own identity; it cannot authorize its enclosing app. Other paths and ACLs without an available
signing requirement keep the static validator. Requirement mismatches remain confirmed rejections; other dynamic
errors stay inconclusive.
Completed successful validations and transient failures are not retained process-wide: executable and app metadata
cannot detect every change to a sealed resource. The existing short, explicit operation memo can still reuse a
generic-password preflight within that operation; it does not span asynchronous refreshes or deferred work.
The process-local validation memo holds at most 64 confirmed signature rejections for five minutes. Changes to the
executable, enclosing app bundle metadata, bundle version, or main executable invalidate those rejections sooner.
Outside the explicit operation memo, the current Keychain ACL and prompt selector are read on every preflight, and
background secret reads remain non-interactive.

Muse Code also checks the item's explicit signing-team partition list before reading its login token. A missing
team uses the same explained manual-refresh allowance; unreadable partition metadata or signing identity stops
before the secret read. The Muse CLI can reset that list on token refresh; see [Muse authentication](muse.md#authentication).

Provider-owned child processes are a separate boundary. CodexBar may intentionally launch a provider CLI such as
Claude for usage. That executable owns its credential behavior, which CodexBar cannot constrain or fully inspect.

Startup migration reads legacy provider tokens and saved cookies only after a successful noninteractive access
preflight, using explicit no-UI queries. Unavailable credentials remain intact and migration cleanup stays pending.
Choose **Refresh** for the affected provider to retry importing its missing credentials. The global Refresh retries
enabled providers; the existing Settings Refresh action can also retry its specifically chosen disabled provider.
An explicit retry can explain and request one Keychain grant, shared with the action's browser
imports; a denial suppresses another legacy-credential prompt for six hours. Settings changes and scheduled refreshes
cannot request that grant. Temporary Keychain failures still need the login Keychain to be unlocked before retrying.
Only credentials used by the chosen source or enabled optional web details are retried; saved-cookie recovery requires
the Manual cookie source. Cancellation stops authorization and prevents the returned credential from being imported.
Recovery preserves current settings, skips selected token accounts, and does not delete legacy credentials. Fields
already configured at startup or imported during this app session are not reimported after you clear them.

## Why permission can be requested again

Keychain access control evaluates the requesting executable's code signature and designated requirement, not just its
filename or install path. A stable, properly signed CodexBar bundle makes grants more durable, while ad-hoc development
builds or a materially changed identity may need authorization again. The Keychain item's owner can also recreate or
rotate a foreign item. Chromium or Claude Code updates can therefore replace the previous access-control entry even
when CodexBar itself has not changed.

The item's accessibility class controls when its data is available, such as after the first unlock. It does not grant
a changed executable access and does not repair a code-signature ACL mismatch.

If a CodexBar-owned cache item's legacy ACL rejects the installed app, reads share a five-minute preflight cooldown.
When fresh cache data becomes available, CodexBar can delete and recreate its own item using no-UI queries. A failed
replacement is attempted at most once per cooldown; a failed retry starts another cooldown even if the old item is
already gone. Successful replacement clears the rejection immediately, including when another first-party process wins
the add race. Cache clearing honors an existing repair cooldown and uses no-UI deletion without requiring decrypt access.
Signature validation during preflight has a bounded wait. If macOS stalls inside validation, preflight returns an
inconclusive result so the caller can release its cache locks and the refresh cycle can finish. Timed-out validations
retain their worker slots until they actually return; retries cannot create an unlimited queue of blocked workers.
Foreign items are never recreated this way. A direct delete that is only temporarily unavailable stays retryable; it does
not establish a stale ACL. A temporarily locked Keychain or an incomplete ACL preflight also remains retryable sooner and
is not replaced.

## Allow Once and Always Allow

- **Allow Once** authorizes the current request or session. A later explicit import or repair may ask again.
- **Always Allow** adds the current CodexBar identity to that item's access control and is the better choice when you
  intentionally use automatic browser import or Claude's direct Keychain repair.
- **Deny** leaves the source unavailable. CodexBar should fail soft and use another configured source where possible.

Only authorize a prompt whose requested item and requesting app match the action you just started. Avoid “Allow all
applications.” In Keychain Access, adding only the installed, stably signed `CodexBar.app` is the narrower grant.

## Disable CodexBar Keychain access

Open **CodexBar → Settings → Advanced** and enable **Disable Keychain access**. The stored setting is applied
immediately; relaunching is useful when diagnosing another already-running copy.

Startup resolves the local preference, falling back to the current shared app-group preference only when no local
value is stored, before legacy credential migration. While access is disabled, permitted file-backed and manual-default
imports can still be saved, but legacy credential cleanup and migration completion remain pending for a later launch
with access enabled.

This setting blocks CodexBar-owned Security.framework item reads and writes, including foreign-item readers such as
Zed, and disables Chromium Safe Storage decryption. Browser-cookie import that needs Keychain is skipped. It does not
promise that a provider-owned CLI launched by CodexBar will avoid its own credential store; Claude's owner-CLI policy
is intentionally unchanged.

Alternatives depend on the provider:

- Paste a Cookie header manually instead of importing it from a browser.
- Configure an API key or OAuth/device flow that does not depend on browser Safe Storage.
- Use a supported file-backed or local provider source.
- For Claude, leave direct foreign-item consent off and choose a CLI, Web, or usable credentials-file path.

## CLI and external dashboards

On macOS, set `CODEXBAR_DISABLE_KEYCHAIN_ACCESS=1` in the environment of a separately launched CLI:

```sh
CODEXBAR_DISABLE_KEYCHAIN_ACCESS=1 /absolute/path/to/codexbar usage --provider claude --json
```

Ordinary `usage` and `cards` fetches already use noninteractive browser-cookie access, including when run
from a terminal: they do not authorize a Chrome Safe Storage prompt. A browser requiring a new grant is
skipped; an existing grant can still be used without UI. The six-hour denial cooldown remains in force
across CLI invocations. Only an explicit `cookie refresh --allow-keychain-prompt` can bypass that cooldown.

The environment opt-out is stronger: it also blocks already-authorized CodexBar Keychain reads.
This blocks CodexBar's Security.framework item operations and Keychain-dependent Chromium cookie decryption.
An unavailable browser session can fall back to another configured source. If none succeeds, `usage --json`
returns a provider error and a nonzero exit status; it does not retry with an interactive browser prompt.
For web-only troubleshooting, use `--source web`, then configure a manual cookie or explicitly refresh cookies
from a terminal if you want to grant access. A provider-owned CLI, such as Claude Code, can still
use its own credential store and may prompt. Existing manual credentials, file-backed credentials, and other
supported sources may still be used. See [Claude source setup](claude.md) and the [CLI guide](cli.md).

Use the path to the CLI your dashboard or service actually runs. Configure the variable in that launcher's
environment so it applies to future invocations. An export in a different terminal does not configure an
already-running dashboard or service.

For a `launchd` job, add this entry to the job plist's top-level dictionary. If it already has an
`EnvironmentVariables` dictionary, add the variable to that dictionary instead:

```xml
<key>EnvironmentVariables</key>
<dict>
    <key>CODEXBAR_DISABLE_KEYCHAIN_ACCESS</key>
    <string>1</string>
</dict>
```

Reload the job's configuration and restart it using the service's normal setup procedure.

The app's Advanced preference can also affect compatible CLI builds through shared preferences. The environment
variable requests the control explicitly for the selected CLI invocation. Only the exact value `1` activates it;
`0` leaves the saved preferences in force.

For an unexpected prompt, first check how your terminal resolves `codexbar`:

```sh
command -v codexbar
codexbar --version
```

A dashboard or service may use a different PATH or an absolute executable path. Check its configured path and
record the output of that executable's `--version` command too.

## Safe troubleshooting

If a prompt appears unexpectedly, first read the full item name and requesting app/path. Quit CodexBar, then check for
another running or installed copy:

```bash
pgrep -fl 'CodexBar|CodexBarCLI'
ls -ld /Applications/CodexBar.app
brew info --cask codexbar
mdfind 'kMDItemCFBundleIdentifier == "com.steipete.codexbar"'
```

Also inspect **Activity Monitor** and **System Settings → General → Login Items**. Deleting an app does not terminate
an already-running process, and another copy may have launched from a different path. Do not use command-line tools to
dump Keychain contents while troubleshooting.

For a support report, include:

- CodexBar and macOS versions, installation source, and whether this is a development build.
- The provider action immediately before the prompt and whether it was automatic or explicitly initiated.
- The requested item name and requesting app/path from the prompt.
- Whether Activity Monitor, Login Items, Homebrew, or Spotlight found another CodexBar copy.
- A screenshot of only the prompt, with usernames and unrelated content redacted and no secret values shown.

## Authoritative references

- Apple: [If you're asked for access to your keychain on Mac](https://support.apple.com/en-ie/guide/keychain-access/kyca1243/mac)
- Apple: [TN3127 — Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
- Apple: [TN3137 — On Mac keychains](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- Chromium: [official macOS build and source instructions](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md)
