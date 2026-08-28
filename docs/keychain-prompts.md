---
summary: "Why macOS Keychain prompts appear, how CodexBar limits them, and safe troubleshooting."
read_when:
  - Investigating Chromium Safe Storage or Claude credential prompts
  - Choosing whether to allow or disable Keychain access
  - Collecting safe support details without exposing secrets
---

# Keychain prompts

CodexBar uses several credential sources, but two foreign-owned Keychain items are the common authorization surfaces:

- Chromium cookie import needs the browser's Safe Storage secret to decrypt its cookie database. Examples include
  `Chrome Safe Storage`, `Brave Safe Storage`, and `Microsoft Edge Safe Storage`.
- Claude OAuth repair can read Claude Code's `Claude Code-credentials` item. Direct access to that foreign item is
  off by default and requires explicit consent in Claude's provider settings. The default prompt policy reserves
  interactive repair for a user action.

CodexBar does not need the browser or Claude account password. macOS owns the authorization prompt and should name
the requesting app or binary. Never send a Keychain item value, cookie header, OAuth token, API key, or password in a
support report.

## When CodexBar can prompt

Background CodexBar paths are intended to fail or skip when a Keychain read would require interaction. This includes
scheduled Chromium imports: CodexBar scopes the actual Safe Storage read as non-interactive, not just the preflight.
A user-initiated import or acknowledged Claude repair may attempt interactive authorization because the user has
chosen to continue. Denials temporarily suppress repeated Chromium-family attempts so one browser cannot lead to a
prompt storm across the others.

Provider-owned child processes are a separate boundary. CodexBar may intentionally launch a provider CLI such as
Claude for usage. That executable owns its credential behavior, which CodexBar cannot constrain or fully inspect.

## Why permission can be requested again

Keychain access control evaluates the requesting executable's code signature and designated requirement, not just its
filename or install path. A stable, properly signed CodexBar bundle makes grants more durable, while ad-hoc development
builds or a materially changed identity may need authorization again. The Keychain item's owner can also recreate or
rotate a foreign item. Chromium or Claude Code updates can therefore replace the previous access-control entry even
when CodexBar itself has not changed.

The item's accessibility class controls when its data is available, such as after the first unlock. It does not grant
a changed executable access and does not repair a code-signature ACL mismatch.

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
