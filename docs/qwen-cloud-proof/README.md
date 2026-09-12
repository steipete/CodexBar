# Qwen Cloud browser-cookie import — real behavior proof

Captured 2026-08-22 against the live Qwen Cloud API via the modified CodexBar
binary (`/Applications/CodexBar-QwenFix.app`, debug build of branch
`diagnose/qwen-cloud-cookie-error`).

## Before the fix (commit `529cc6c24` "Keep Qwen imports Chrome-only")

```text
$ CodexBarCLI usage --provider qwen-cloud --format text --no-color
[error] No Qwen Cloud session cookies found in browsers. Sign in to Qwen Cloud
        in Chrome, allow CodexBar to access Chrome Safe Storage in Keychain
        Access, or paste a manual Cookie header.
```

The user is signed in to Qwen Cloud in **Brave** (not Chrome). The cookie
import never probed Brave, so the importer returned no session even though
`login_qwencloud_ticket` was present in
`~/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies`.

## After the fix (branch `diagnose/qwen-cloud-cookie-error`, PR #3147)

`browserOrder` is now `[.chrome, .brave]` (per `AGENTS.md` L48 — "default
Chrome-only when possible to avoid other browser prompts; override via
browser list when needed"). Once the user granted macOS Keychain access to
the modified binary, the same CLI call returns real usage data:

```text
$ CodexBarCLI usage --provider qwen-cloud --format text --no-color
== Qwen Cloud (web) ==
Weekly: 20% left [==----------]
Resets in 2d 2h
Plan: Pro
```

```json
{
  "source": "web",
  "provider": "qwencloud",
  "usage": {
    "identity": {
      "providerID": "qwencloud",
      "loginMethod": "Pro"
    },
    "secondary": {
      "usedPercent": 79.97,
      "windowMinutes": 10080,
      "resetsAt": "2026-08-25T01:21:00Z",
      "resetDescription": "31,987.03 / 40,000 credits used"
    },
    "updatedAt": "2026-08-22T23:11:11Z"
  }
}
```

## How the proof was obtained

1. `swift build` from the worktree at `/tmp/codexbar-main` succeeded.
2. `swift test --filter QwenCloudProviderTests` — 32/32 tests passed across 7 suites.
3. `./Scripts/package_app.sh debug` — packaged `CodexBar.app` (ad-hoc signed).
4. Installed to `/Applications/CodexBar-QwenFix.app` (no quarantine).
5. First refresh via the GUI menu bar — the macOS Keychain dialog appeared for `Brave Safe Storage`; "Always Allow" granted permanent ACL access.
6. CLI runs thereafter (with `CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT=1`) return the same real usage data shown above.

## What changed in the code

```diff
--- a/Sources/CodexBarCore/Providers/QwenCloud/QwenCloudProviderDescriptor.swift
+++ b/Sources/CodexBarCore/Providers/QwenCloud/QwenCloudProviderDescriptor.swift
-        let browserOrder: BrowserCookieImportOrder = [.chrome]
+        // Default the import to Chrome + Brave. The full 7-browser list
+        // (chromeBeta, edge, arc, firefox, safari) was deliberately trimmed to
+        // avoid unsolicited Keychain / browser-store access prompts on automatic
+        // refreshes — the repository's prompt-avoidance policy. Brave is kept
+        // because it shares the same Chromium Safe Storage format and many
+        // CodexBar users authenticate Qwen Cloud in Brave.
+        let browserOrder: BrowserCookieImportOrder = [
+            .chrome,
+            .brave,
+        ]
```

```diff
--- a/Tests/CodexBarTests/QwenCloudProviderTests.swift
+++ b/Tests/CodexBarTests/QwenCloudProviderTests.swift
-        #expect(metadata.browserCookieOrder == [.chrome])
-        #expect(QwenCloudWebFetchStrategy.browserOrder == [.chrome])
+        let expectedOrder: BrowserCookieImportOrder = [
+            .chrome,
+            .brave,
+        ]
+        #expect(metadata.browserCookieOrder == expectedOrder)
+        #expect(QwenCloudWebFetchStrategy.browserOrder == expectedOrder)
```

## Redaction notes

- `loginMethod: "Pro"` is the plan tier only — no account identifier, no email, no user ID, no cookie values, no Keychain contents are reproduced here.
- The 79.97% weekly figure is a snapshot, not a real customer number.
- The cookie value column in the Brave SQLite cookie store is empty (the value is stored in the `encrypted_value` BLOB and only readable after decrypting with the user's Brave Safe Storage key); no decrypted cookie contents appear anywhere in this proof.
