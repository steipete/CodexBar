#!/usr/bin/env swift

import Foundation

#if canImport(AppKit)
import AppKit
#endif

// Simple diagnostic script to check Augment cookies in browsers
print("\n========== AUGMENT COOKIE DIAGNOSTICS ==========\n")

let cookieDomains = ["augmentcode.com", "app.augmentcode.com"]
let expectedCookieNames: Set<String> = [
    "session",
    "_session",
    "web_rpc_proxy_session",
    "__Secure-next-auth.session-token",
    "next-auth.session-token",
    "__Secure-authjs.session-token",
    "authjs.session-token",
]

print("Looking for Augment cookies in browsers...")
print("Expected cookie names: \(expectedCookieNames.sorted().joined(separator: ", "))\n")

// Check Safari cookies
print("--- Safari ---")
let safariCookiesPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Cookies/Cookies.binarycookies")

if FileManager.default.fileExists(atPath: safariCookiesPath.path) {
    print("Safari cookies file exists at: \(safariCookiesPath.path)")
    print("Note: Binary cookies file - cannot easily parse without SweetCookieKit")
} else {
    print("Safari cookies file not found")
}

// Check Chrome cookies
print("\n--- Chrome ---")
let chromeCookiesPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cookies")

if FileManager.default.fileExists(atPath: chromeCookiesPath.path) {
    print("Chrome cookies database exists at: \(chromeCookiesPath.path)")
    print("Note: SQLite database - cannot easily parse without SweetCookieKit")
} else {
    print("Chrome cookies database not found")
}

// Check Arc cookies
print("\n--- Arc ---")
let arcCookiesPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Arc/User Data/Default/Cookies")

if FileManager.default.fileExists(atPath: arcCookiesPath.path) {
    print("Arc cookies database exists at: \(arcCookiesPath.path)")
    print("Note: SQLite database - cannot easily parse without SweetCookieKit")
} else {
    print("Arc cookies database not found")
}

print("\n========== INSTRUCTIONS ==========")
print("""
To fix the "No Augment session found" error:

1. Open your browser (Safari, Chrome, or Arc)
2. Go to https://app.augmentcode.com
3. Make sure you're logged in
4. Check the browser's cookies:
   - Safari: Develop → Show Web Inspector → Storage → Cookies
   - Chrome/Arc: DevTools (⌘⌥I) → Application → Cookies
5. Look for one of these cookie names:
   \(expectedCookieNames.sorted().joined(separator: "\n   "))
6. If you don't see any of these cookies, you may need to log out and log back in
7. After confirming cookies exist, click "Refresh Session" in CodexBar

If cookies exist but CodexBar still can't find them:
- Try quitting and reopening your browser
- Browser cookies may take a few seconds to write to disk
- Check that CodexBar has Full Disk Access in System Settings → Privacy & Security
""")

print("\n========== END DIAGNOSTICS ==========\n")

