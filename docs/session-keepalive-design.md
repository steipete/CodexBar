# Session Keepalive Enhancement Design

**Date:** 2026-01-04  
**Feature:** Proactive session management for all providers  
**Inspiration:** Quotio's "Auto-Warmup" feature

---

## Problem Statement

**Current State:**
- Augment has reactive keepalive (checks every 5min, refreshes when cookies near expiry)
- Other providers (Claude, Codex) have no automatic session management
- Users experience auth failures when sessions expire during idle periods
- Manual re-authentication is disruptive to workflow

**Pain Points:**
1. **Session expiration during idle time** - User comes back to expired session
2. **No proactive refresh** - We only react to expiration, don't prevent it
3. **Provider-specific logic** - Each provider needs custom keepalive code
4. **No user control** - Can't configure refresh intervals or disable keepalive

---

## Proposed Solution: Unified Session Keepalive System

### Alternative Names (Better than "Warmup")
1. **Session Keepalive** ✅ (current Augment terminology)
2. **Session Refresh** (more accurate - we're refreshing, not warming)
3. **Auto-Refresh** (simple, user-friendly)
4. **Session Maintenance** (professional, clear intent)
5. **Stay Alive** (casual, friendly)

**Recommendation:** **"Session Keepalive"** - already used in codebase, technically accurate

---

## Architecture

### 1. Core Components

#### `SessionKeepaliveManager` (New)
```swift
@MainActor
public final class SessionKeepaliveManager {
    // Unified scheduler for all providers
    private var scheduledTasks: [Provider: Task<Void, Never>] = [:]
    
    // Per-provider configuration
    private var configs: [Provider: KeepaliveConfig] = [:]
    
    // Start keepalive for a provider
    func start(provider: Provider, config: KeepaliveConfig)
    
    // Stop keepalive for a provider
    func stop(provider: Provider)
    
    // Force immediate refresh
    func forceRefresh(provider: Provider) async
}
```

#### `KeepaliveConfig` (New)
```swift
public struct KeepaliveConfig {
    enum Mode {
        case interval(TimeInterval)  // Every X seconds
        case daily(hour: Int, minute: Int)  // Daily at specific time
        case beforeExpiry(buffer: TimeInterval)  // X seconds before expiry
    }
    
    let mode: Mode
    let enabled: Bool
    let minRefreshInterval: TimeInterval  // Rate limiting
}
```

### 2. Provider Integration

#### Augment (Existing - Refactor)
- **Current:** `AugmentSessionKeepalive` (standalone actor)
- **New:** Integrate with `SessionKeepaliveManager`
- **Strategy:** `beforeExpiry(buffer: 300)` - refresh 5min before cookie expiry
- **Action:** Ping session endpoint + re-import cookies

#### Claude (New)
- **Strategy:** `interval(1800)` - refresh every 30 minutes
- **Action:** Run `/status` command via CLI to keep session alive
- **Fallback:** OAuth token refresh if CLI unavailable

#### Codex (New)
- **Strategy:** `interval(3600)` - refresh every hour
- **Action:** OAuth token refresh using refresh token
- **Benefit:** Prevents "session expired" errors during long coding sessions

#### Cursor, Gemini, etc. (Future)
- **Strategy:** TBD based on provider auth mechanism
- **Extensible:** Protocol-based design allows easy addition

---

## Implementation Plan

### Phase 1: Core Infrastructure (Week 1)
1. Create `SessionKeepaliveManager` actor
2. Define `KeepaliveConfig` model
3. Add UserDefaults persistence for per-provider configs
4. Create Settings UI for keepalive configuration

### Phase 2: Provider Integration (Week 2)
1. **Augment:** Refactor existing `AugmentSessionKeepalive` to use new manager
2. **Claude:** Implement CLI-based keepalive
3. **Codex:** Implement OAuth token refresh keepalive

### Phase 3: UI & Polish (Week 3)
1. Settings → Providers → [Provider] → "Session Keepalive" section
2. Toggle: Enable/Disable
3. Mode picker: Interval / Daily / Before Expiry
4. Status indicator: Last refresh time, next scheduled refresh
5. Manual "Refresh Now" button

---

## Settings UI Design

```
Settings → Providers → Augment

┌─────────────────────────────────────────┐
│ Session Keepalive                       │
├─────────────────────────────────────────┤
│ ☑ Keep session alive automatically      │
│                                         │
│ Mode: ⦿ Before Expiry                   │
│       ○ Every 30 minutes                │
│       ○ Daily at 9:00 AM                │
│                                         │
│ Last refresh: 2 minutes ago             │
│ Next refresh: in 3 minutes              │
│                                         │
│ [Refresh Now]                           │
└─────────────────────────────────────────┘
```

---

## Key Differences from Quotio's "Warmup"

| Aspect | Quotio Warmup | CodexBar Keepalive |
|--------|---------------|-------------------|
| **Purpose** | Trigger 1-token API calls to reset quota counters | Refresh auth sessions to prevent expiration |
| **Target** | Antigravity only (quota reset) | All providers (session management) |
| **Action** | Make minimal API request (costs 1 token) | Refresh auth tokens/cookies (free) |
| **Benefit** | Faster quota resets during peak hours | Uninterrupted access, no auth failures |
| **Cost** | Consumes tokens | No cost (just auth refresh) |

**Why different?**
- Quotio has a proxy server that routes requests → warmup keeps quota fresh
- CodexBar monitors providers directly → keepalive prevents auth expiration

---

## Benefits

### For Users
1. **No more "session expired" errors** during active work
2. **Seamless experience** - auth just works
3. **Configurable** - control refresh frequency per provider
4. **Transparent** - see when last refresh happened

### For Developers
1. **Unified system** - one manager for all providers
2. **Extensible** - easy to add new providers
3. **Testable** - clear separation of concerns
4. **Maintainable** - centralized keepalive logic

---

## Technical Considerations

### Rate Limiting
- Minimum 2-minute interval between refreshes (prevent API abuse)
- Exponential backoff on failures
- Max 3 retry attempts before disabling

### Error Handling
- Log failures but don't crash
- Notify user if keepalive fails repeatedly
- Automatic disable after 5 consecutive failures

### Performance
- Background tasks use `.utility` priority
- No blocking of main thread
- Minimal memory footprint

### Privacy
- No data sent to external servers
- All refresh actions are local (CLI, OAuth, cookie import)
- User can disable entirely

---

## Next Steps

1. **Review this design** - Get feedback on architecture
2. **Prototype core manager** - Build `SessionKeepaliveManager`
3. **Integrate Augment** - Refactor existing keepalive
4. **Add Claude support** - Implement CLI-based refresh
5. **Build Settings UI** - Per-provider configuration
6. **Test & iterate** - Ensure reliability

---

## Open Questions

1. **Should keepalive be enabled by default?**
   - Pro: Better UX out of the box
   - Con: Users might not want automatic refreshes
   - **Recommendation:** Enabled by default, easy to disable

2. **What's the default refresh interval?**
   - Augment: 5min before expiry (existing)
   - Claude: 30min interval
   - Codex: 60min interval
   - **Recommendation:** Conservative defaults, user-configurable

3. **Should we show keepalive status in menu bar?**
   - Pro: Transparency, user knows it's working
   - Con: Clutters UI
   - **Recommendation:** Show in Settings only, not menu bar

