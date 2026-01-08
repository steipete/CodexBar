# Quotio Comparison & Enhancement Opportunities

**Date:** 2026-01-04  
**Source:** https://github.com/nguyenphutrong/quotio

## Overview

Quotio is a similar macOS menu bar app for AI quota tracking with **2k stars** and **117 forks**. It has a broader scope (proxy server + quota tracking) but shares many features with CodexBar.

---

## Key Differences

### Architecture
- **Quotio**: Manages a local proxy server (`CLIProxyAPI`) that routes requests to multiple AI providers
- **CodexBar**: Direct provider monitoring only (no proxy layer)
- **Implication**: Quotio is more complex but offers request routing/failover

### Provider Support
**Quotio supports:**
- Gemini, Claude, OpenAI Codex, Qwen, Vertex AI, iFlow, Antigravity, Kiro, GitHub Copilot
- **IDE monitoring**: Cursor, Trae (auto-detected, monitor-only)

**CodexBar supports:**
- Codex, Claude, Cursor, Gemini, Antigravity, Droid/Factory, Copilot, z.ai, Kiro, Vertex AI, **Augment**

**Unique to CodexBar:**
- Augment (we just added!)
- z.ai
- Droid/Factory

**Unique to Quotio:**
- Qwen, iFlow
- Trae IDE monitoring

---

## Features We Should Consider

### 1. **Auto-Warmup Scheduling** ⭐⭐⭐
**What:** Automatically trigger 1-token model invocations on a schedule to keep accounts "warm"
**Why:** Prevents cold-start delays, maintains session freshness
**Implementation:** 
- Interval-based (15min-4h) or daily scheduling
- Per-account model selection
- Progress tracking in UI
**Effort:** Medium (requires background task scheduler)
**Value:** High for providers with session timeouts (Claude, Augment)

### 2. **Account Switching for Antigravity** ⭐⭐
**What:** Switch active Antigravity account by injecting OAuth tokens into IDE's SQLite database
**Why:** Allows multi-account workflows without manual IDE logout/login
**Implementation:**
- Read/write to `~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb`
- Protobuf encode/decode for OAuth tokens
- Process management (close IDE → backup → inject → restart)
**Effort:** High (complex SQLite + protobuf + process management)
**Value:** Medium (niche use case, but powerful for multi-account users)

### 3. **Standalone Quota Mode** ⭐
**What:** View quotas without running proxy server
**Why:** Lighter weight, faster startup for quick checks
**Implementation:** Already how CodexBar works! (We don't have a proxy)
**Effort:** N/A (we already do this)
**Value:** N/A (already implemented)

### 4. **Smart Routing Strategies** ⭐⭐
**What:** Round Robin or Fill First routing for multi-account setups
**Why:** Optimize quota usage across accounts
**Implementation:** Would require proxy layer (not applicable to CodexBar's architecture)
**Effort:** Very High (requires proxy server)
**Value:** Low for CodexBar (out of scope)

### 5. **Custom Provider Support** ⭐⭐⭐
**What:** User-defined AI providers with OpenAI-compatible, Claude, Gemini, Codex API configs
**Why:** Extensibility for new/custom providers without code changes
**Implementation:**
- `CustomProvider` model with API type, base URL, auth
- YAML config generation
- UI for add/edit/delete custom providers
**Effort:** Medium-High
**Value:** High (future-proofs the app, community can add providers)

### 6. **Multilingual Support** ⭐
**What:** English, Vietnamese, Chinese, French
**Why:** Broader user base
**Implementation:** `.xcstrings` localization (we already have infrastructure)
**Effort:** Medium (translation work)
**Value:** Medium (depends on target audience)

---

## UI/UX Learnings

### Menu Bar Design
- **Quotio**: Custom provider icons in menu bar, quota overview popup
- **CodexBar**: Two-bar meter icon, detailed menu card
- **Takeaway**: Both approaches valid; CodexBar's meter is more info-dense

### Settings Organization
- **Quotio**: Dashboard, Providers, Agents, Quota, Logs, Settings tabs
- **CodexBar**: Settings → Providers with per-provider toggles
- **Takeaway**: Quotio's tab-based navigation is cleaner for complex apps

### Quota Display
- **Quotio**: Grid layout with tier badges (Pro/Ultra/Free), inline refresh
- **CodexBar**: List-based with session/weekly bars
- **Takeaway**: Tier badges are a nice visual touch

---

## Recommended Enhancements for CodexBar

### Priority 1: Auto-Warmup Scheduling ⭐⭐⭐
**Why:** Keeps sessions alive, prevents auth failures
**Implementation:**
1. Add `WarmupScheduler` service with interval/daily modes
2. Per-provider warmup config in Settings
3. Background task to trigger minimal API calls (1-token requests)
4. UI to show last warmup time + next scheduled warmup

**Providers that benefit:**
- Claude (session expires)
- Augment (session expires)
- Codex (session expires)

### Priority 2: Custom Provider Framework ⭐⭐⭐
**Why:** Community extensibility, future-proof
**Implementation:**
1. `CustomProvider` model (name, icon, API type, base URL, auth)
2. Settings UI for CRUD operations
3. Generic quota fetcher that adapts to API type
4. Save to UserDefaults or JSON file

**Benefits:**
- Users can add new providers without waiting for releases
- Easier to experiment with beta/internal APIs

### Priority 3: Enhanced Antigravity Support ⭐⭐
**Why:** Quotio's account switching is powerful
**Implementation:**
1. Add `AntigravityAccountSwitcher` service
2. SQLite database read/write for token injection
3. Process manager for IDE restart
4. UI confirmation dialog with progress states

**Complexity:** High, but valuable for power users

---

## What NOT to Adopt

### ❌ Proxy Server Layer
- **Why:** Out of scope for CodexBar's mission (monitoring, not routing)
- **Complexity:** Very high (server management, request routing, failover)
- **Maintenance:** Ongoing burden

### ❌ Agent Configuration
- **Why:** Quotio auto-configures CLI tools (Claude Code, OpenCode, etc.) to use its proxy
- **Relevance:** Not applicable without proxy layer

---

## Conclusion

**Top 3 Enhancements:**
1. **Auto-Warmup Scheduling** - Keeps sessions alive, prevents auth failures
2. **Custom Provider Framework** - Future-proof, community-driven extensibility
3. **Enhanced Antigravity Account Switching** - Power user feature

**Quick Wins:**
- Tier badges in quota display (visual polish)
- Tab-based settings navigation (if app grows more complex)

**Skip:**
- Proxy server layer (out of scope)
- Agent configuration (requires proxy)

