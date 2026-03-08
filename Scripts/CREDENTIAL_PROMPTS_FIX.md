# Fix: CodexBar Keeps Asking for Credentials

## Why This Happens

CodexBar's Claude provider tries to read OAuth credentials from Claude CLI's keychain:
- **Keychain Service:** `Claude Code-credentials`
- **Problem:** macOS prompts for access when CodexBar doesn't have cached credentials
- **Why Multiple Prompts:** Clicking "Allow" (session-only) instead of "Always Allow" causes repeated prompts

## Solutions (Choose One)

### ✅ Solution 1: Grant "Always Allow" (Recommended)

**Next time you see the keychain prompt:**
1. Click **"Always Allow"** instead of "Allow"
2. This grants permanent access and stops future prompts
3. ⚠️ Make sure to click "Always Allow" for BOTH prompts if you get two

**Why two prompts?**
- macOS uses different query shapes for OAuth credentials
- Session-only access ("Allow") doesn't cover both shapes
- "Always Allow" covers all query types

---

### 🔧 Solution 2: Switch Claude to Web Cookies

**If you don't want OAuth prompts, use browser cookies instead:**

1. Open CodexBar → **Settings → Providers → Claude**
2. Change **Usage source** from "Auto" to **"Web"**
3. Set **Cookie source** to **"Automatic"** (reads from Safari/Chrome/Firefox)

**Benefits:**
- No keychain prompts
- Still gets usage data from claude.ai cookies
- Works with any browser signed into Claude

**Manual cookie option:**
- Set Cookie source to "Manual"
- Paste a `sessionKey` cookie from claude.ai
- Get it from: DevTools → Application → Cookies → `sessionKey`

---

### 🚫 Solution 3: Disable Claude Provider

**If you're not using Claude:**

1. Open CodexBar → **Settings → Providers**
2. Uncheck **Claude**
3. No more prompts!

---

### 🛠️ Solution 4: Clear and Recache (Advanced)

**Reset the OAuth cache and let CodexBar rebuild it:**

```bash
# Stop CodexBar
./Scripts/stop_codexbar.sh

# Clear the OAuth cache
security delete-generic-password -s "com.steipete.codexbar.cache" -a "oauth.claude" 2>/dev/null

# Start CodexBar
./Scripts/start_codexbar.sh
```

Next prompt: Click **"Always Allow"**

---

## Quick Commands

### Stop CodexBar
```bash
./Scripts/stop_codexbar.sh
```

### Start CodexBar
```bash
./Scripts/start_codexbar.sh
```

### Check What's Running
```bash
ps aux | grep -i codex | grep -v grep
```

### View Keychain Logs (Debug)
```bash
log show --predicate 'subsystem == "com.steipete.codexbar" && category CONTAINS "keychain"' --last 5m
```

---

## Understanding the Architecture

**Claude Usage Data Sources (in order):**
1. **OAuth API** (via Claude CLI keychain) ← Causes prompts
2. **Web API** (browser cookies) ← No prompts
3. **CLI PTY** (runs `claude` command) ← Fallback

**What CodexBar Reads From Keychain:**
- Claude OAuth tokens: `Claude Code-credentials` (Claude CLI's keychain)
- Cached cookies: `com.steipete.codexbar.cache` (CodexBar's own cache)
- Legacy items: `com.steipete.CodexBar` (old format, migrated once)

---

## Prevention: Set Up Before First Run

**To avoid prompts entirely:**

1. **Login to Claude CLI first:**
   ```bash
   claude login
   ```

2. **Grant keychain access when prompted** (click "Always Allow")

3. **Then start CodexBar:**
   ```bash
   ./Scripts/start_codexbar.sh
   ```

This pre-authorizes the keychain access so CodexBar inherits it.

---

## Still Having Issues?

Check keychain cooldown status:
```bash
defaults read com.steipete.codexbar claudeOAuthKeychainDeniedUntil
```

If prompts persist after "Always Allow", check Keychain Access.app:
1. Open **Keychain Access.app**
2. Search: **"Claude Code"**
3. Double-click the entry
4. **Access Control** tab
5. Ensure **CodexBar** is in the "Always allow access" list

---

## Related Files

- `Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift`
- `Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthKeychainAccessGate.swift`
- `docs/KEYCHAIN_FIX.md` - Full technical documentation
