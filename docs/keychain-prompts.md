---
summary: "Safe troubleshooting for macOS Keychain and browser Safe Storage prompts."
read_when:
  - Investigating Chrome Safe Storage or browser Safe Storage prompts
  - Explaining prompts that appear after uninstalling CodexBar
  - Collecting safe support details without exposing secrets
---

# Keychain prompts

CodexBar can trigger macOS Keychain prompts when an enabled provider imports browser cookies, reads a provider-owned
OAuth item, or uses a CodexBar-owned cache entry. Chromium browser cookie import commonly asks for the browser's
Safe Storage item, such as "Chrome Safe Storage", "Brave Safe Storage", or "Microsoft Edge Safe Storage".

CodexBar does not need your browser password. macOS owns the prompt, and the prompt should identify the app or binary
that is requesting access. For support reports, include that requesting app/path when possible and do not paste
passwords, cookie headers, OAuth tokens, API keys, or Keychain item values.

Before a Keychain read that may require interaction, CodexBar shows an explanation of the item and its purpose.
**Learn More** opens this page without dismissing that explanation or starting the macOS prompt. Choose **OK** only
when you are ready to continue, or use the opt-out below.

## If the prompt appears after uninstalling CodexBar

Deleting `CodexBar.app` prevents a new process from launching from that bundle, but it does not terminate a process
that is already running from it. That process can continue to request Keychain access until it quits. If macOS still
shows a prompt such as "CodexBar wants to use your confidential information stored in 'Chrome Safe Storage'", the
usual causes are:

- A CodexBar process or bundled helper is still running.
- CodexBar is still enabled in Login Items and relaunched from an existing install.
- Another copy of `CodexBar.app` exists elsewhere on the machine.
- The uninstall path did not remove the same copy that launched the process. Finder, Homebrew cask, Sparkle updates,
  and manually copied apps can leave different install paths in play.
- The prompt is naming the requesting binary, not proving that the copy you deleted is the one still running.

Safe checks:

```bash
pgrep -fl 'CodexBar|CodexBarCLI'
ls -ld /Applications/CodexBar.app
brew info --cask codexbar
mdfind 'kMDItemCFBundleIdentifier == "com.steipete.codexbar"'
```

Also check:

- **Activity Monitor**: search for `CodexBar` and `CodexBarCLI`.
- **System Settings -> General -> Login Items**: remove CodexBar if it remains listed.
- **Keychain prompt screenshot**: capture the full prompt, especially any requesting app/path details. Redact user
  names or unrelated window contents if needed, but do not include secrets.

If you find a still-running process, quit CodexBar from the menu if possible, or quit it from Activity Monitor. If you
find another installed copy, confirm whether that copy is the one macOS names in the prompt before changing anything
else.

## Stop CodexBar from using Keychain

If CodexBar is still installed and you want it to stop all Keychain access:

1. Open **CodexBar -> Settings -> Advanced**.
2. In **Keychain access**, enable **Disable Keychain access**.
3. Relaunch CodexBar.

This disables Keychain reads and writes from CodexBar. Browser-cookie-based providers will be skipped because
CodexBar can no longer decrypt browser cookies. Manual cookie headers, API keys, and CLI/OAuth flows that do not rely
on Keychain can still work where the provider supports them.

## Browser Safe Storage prompts

For normal browser-cookie import prompts, either allow CodexBar in the Keychain item's Access Control list or disable
Keychain access:

1. Open **Keychain Access.app**.
2. Select the `login` keychain.
3. Search for the item named in the prompt, for example `Chrome Safe Storage`.
4. Open the item, choose **Access Control**, and add `CodexBar.app` under "Always allow access by these applications".
5. Relaunch CodexBar.

Avoid "Allow all applications" unless you intentionally want every app to access that item. Do not paste or share the
item's secret value when asking for help.

## What to include in a support issue

- CodexBar version and install source: GitHub release, Homebrew cask, Sparkle update, or another source.
- macOS version.
- The uninstall method if this happened after uninstalling.
- Whether Activity Monitor or `pgrep` still shows CodexBar.
- Whether System Settings -> General -> Login Items still lists CodexBar.
- Whether `/Applications/CodexBar.app`, Homebrew cask metadata, or Spotlight finds another copy.
- A screenshot of the Keychain prompt showing the requested item and requesting app/path, with secrets redacted.
