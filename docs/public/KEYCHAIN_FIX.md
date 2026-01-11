# Keychain Permission Prompts Fix

## Problem
During development, every rebuild changed the app's code signature, causing macOS to prompt for keychain access **9+ times** (once per stored credential: Claude cookie, Codex cookie, MiniMax cookie, Copilot token, Zai token, etc.).

## Solution
Changed keychain accessibility from `kSecAttrAccessibleAfterFirstUnlock` to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for all keychain stores.

### Why This Works
- `AfterFirstUnlock`: Items are backed up to iCloud and migrated to other devices, but require keychain prompts when code signature changes
- `AfterFirstUnlockThisDeviceOnly`: Items are **not** backed up or migrated, making them more tolerant of code signature changes during development

### Trade-offs
- ✅ **Zero keychain prompts** on subsequent rebuilds
- ✅ Same security level (requires device unlock)
- ❌ Credentials not backed up to iCloud (acceptable for development)
- ❌ Credentials not migrated to new devices (acceptable for development)

## Implementation

### 1. Updated Keychain Stores
Changed all keychain stores to use `ThisDeviceOnly` accessibility:
- `CookieHeaderStore.swift` (Codex/Claude/Cursor/Factory/Augment cookies)
- `MiniMaxCookieStore.swift` (MiniMax cookies)
- `ZaiTokenStore.swift` (z.ai API token)
- `CopilotTokenStore.swift` (Copilot token)
- `ClaudeOAuthCredentials.swift` (Claude Code OAuth token)

### 2. One-Time Migration
Created `KeychainMigration.swift` to migrate existing keychain items:
- Runs once per app installation (flag stored in UserDefaults)
- Reads existing items, deletes them, re-adds with new accessibility
- Logs migration progress for debugging
- **First launch after update**: one prompt per stored credential (one-time migration)
- **Subsequent rebuilds**: Zero prompts

### 3. Migration Flow
```swift
// In CodexBarApp.init()
KeychainMigration.migrateIfNeeded()

// Migration logic:
1. Check UserDefaults flag "KeychainMigrationV1Completed"
2. If already migrated, skip (log debug message)
3. For each keychain item:
   a. Read existing item
   b. Check current accessibility
   c. If already using ThisDeviceOnly, skip
   d. Delete old item
   e. Re-add with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
4. Set migration flag in UserDefaults
```

## User Experience

### First Launch (After Update)
User sees **one keychain prompt per stored credential** during the one-time migration.

### Subsequent Rebuilds
**Zero prompts!** The migration flag prevents re-running, and the new accessibility level prevents prompts on code signature changes.

## Verification

### Check Migration Status
```bash
# Should output: 1
defaults read com.steipete.codexbar KeychainMigrationV1Completed
```

### View Migration Logs
```bash
# In Console.app, filter by:
# subsystem: com.steipete.codexbar
# category: KeychainMigration

# Or via command line:
log show --predicate 'category == "KeychainMigration"' --last 5m
```

### Reset Migration (Testing)
```bash
# Force migration to run again
defaults delete com.steipete.codexbar KeychainMigrationV1Completed

# Rebuild and launch
./Scripts/compile_and_run.sh
```

## Files Changed

### New Files
- `Sources/CodexBar/KeychainMigration.swift` - One-time migration logic

### Modified Files
- `Sources/CodexBar/CookieHeaderStore.swift` - Changed accessibility
- `Sources/CodexBar/MiniMaxCookieStore.swift` - Changed accessibility
- `Sources/CodexBar/ZaiTokenStore.swift` - Changed accessibility
- `Sources/CodexBar/CopilotTokenStore.swift` - Changed accessibility
- `Sources/CodexBar/CodexBarApp.swift` - Added migration call

## Alternative Approaches Considered

### 1. Keychain Access Groups (Rejected)
- Requires provisioning profile or proper code signing
- Not compatible with ad-hoc signed development builds
- Would work for release builds but not development

### 2. Shared Keychain Service Name (Rejected)
- Doesn't solve the code signature change issue
- Still prompts on every rebuild

### 3. File-Based Storage (Rejected)
- Less secure than keychain
- Requires manual encryption
- Loses integration with macOS security features

## Production Considerations

For **release builds** (notarized, distributed via GitHub/Homebrew):
- The `ThisDeviceOnly` accessibility is still appropriate
- Users won't see prompts because the code signature is stable
- Credentials are still secure (require device unlock)
- Only downside: credentials not backed up to iCloud (acceptable trade-off)

If iCloud backup is desired in the future:
- Could use `kSecAttrAccessibleAfterFirstUnlock` for release builds
- Keep `ThisDeviceOnly` for development builds
- Conditional compilation based on build configuration
