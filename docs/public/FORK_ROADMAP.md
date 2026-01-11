# CodexBar Fork Roadmap

This document outlines the development roadmap for the CodexBar fork maintained by Brandon Charleson.

## ✅ Phase 1: Fork Identity (COMPLETE)

**Status:** Completed Jan 4, 2026

**Achievements:**
- Established dual attribution in About section
- Updated README with fork notice and enhancements
- Created comprehensive Augment provider documentation
- App builds and runs successfully

**Commit:** `da3d13e` - "feat: establish fork identity with dual attribution"

---

## 🔧 Phase 2: Enhanced Augment Diagnostics

**Goal:** Fix persistent cookie disconnection issues with better logging and diagnostics

**Tasks:**
1. **Replace print() with proper logging**
   - Use `CodexBarLog.logger("augment")` throughout
   - Add structured metadata for debugging
   - Follow patterns from Claude/Cursor providers

2. **Enhanced Cookie Diagnostics**
   - Log cookie expiration times
   - Track cookie refresh attempts
   - Add cookie domain filtering diagnostics
   - Log browser source priority

3. **Session Keepalive Monitoring**
   - Add keepalive status to debug pane
   - Log refresh attempts and success/failure
   - Track time until next refresh
   - Add manual "Force Refresh" button

4. **Debug Pane Improvements**
   - Add "Cookie Status" section showing:
     - Current cookies and expiration
     - Last successful import
     - Browser source used
     - Keepalive status
   - Add "Test Connection" button
   - Show detailed error messages

**Files to Modify:**
- `Sources/CodexBarCore/Providers/Augment/AugmentStatusProbe.swift`
- `Sources/CodexBarCore/Providers/Augment/AugmentSessionKeepalive.swift`
- `Sources/CodexBar/UsageStore.swift` (debug pane)

---

## 🎯 Phase 3: Quotio Feature Analysis

**Goal:** Identify and cherry-pick valuable features from Quotio without copying code

**Analysis Areas:**
1. **Multi-Account Management**
   - How Quotio handles multiple accounts per provider
   - Account switching UI patterns
   - Account status indicators

2. **OAuth Flow Improvements**
   - Quotio's OAuth implementation patterns
   - Token refresh mechanisms
   - Error handling strategies

3. **UI/UX Patterns**
   - Menu bar organization
   - Settings layout
   - Status indicators
   - Notification patterns

4. **Session Management**
   - How Quotio handles session persistence
   - Cookie refresh strategies
   - Automatic reconnection logic

**Deliverable:** `docs/QUOTIO_ANALYSIS.md` with:
- Feature comparison matrix
- Implementation recommendations
- Priority ranking
- Effort estimates

---

## 🔄 Phase 4: Upstream Sync Workflow

**Goal:** Set up automated workflow to sync with upstream while maintaining fork changes

**Tasks:**
1. **Create Sync Script**
   - `Scripts/sync_upstream.sh`
   - Fetch upstream changes
   - Show diff summary
   - Interactive merge/rebase

2. **Conflict Resolution Guide**
   - Document common conflict areas
   - Resolution strategies
   - Testing checklist

3. **Automated Checks**
   - CI workflow to detect upstream changes
   - Weekly sync reminders
   - Compatibility testing

**Files to Create:**
- `Scripts/sync_upstream.sh`
- `docs/UPSTREAM_SYNC.md`
- `.github/workflows/upstream-sync-check.yml`

---

## 🚀 Phase 5: Multi-Account Management Foundation

**Goal:** Implement multi-account support for providers (starting with Augment)

**Features:**
1. **Account Management UI**
   - Add/remove accounts per provider
   - Account nicknames/labels
   - Active account indicator
   - Quick account switching

2. **Account Storage**
   - Keychain-based account storage
   - Account metadata (email, plan, last used)
   - Secure credential isolation

3. **Account Switching**
   - Switch active account from menu
   - Preserve per-account usage history
   - Automatic account selection based on quota

4. **UI Enhancements**
   - Account dropdown in menu bar
   - Per-account usage display
   - Account health indicators

**Implementation Plan:**
1. Start with Augment provider (already has cookie infrastructure)
2. Create `AccountManager` service
3. Update `UsageStore` to handle multiple accounts
4. Add account switcher to menu bar
5. Extend to other providers (Claude, Cursor, etc.)

**Files to Create:**
- `Sources/CodexBarCore/AccountManager.swift`
- `Sources/CodexBarCore/Providers/Augment/AugmentAccountManager.swift`
- `Sources/CodexBar/AccountSwitcherView.swift`

---

## 📋 Future Enhancements

### Short Term (1-2 weeks)
- [ ] Augment cookie issue resolution (Phase 2)
- [ ] Quotio feature analysis (Phase 3)
- [ ] Upstream sync workflow (Phase 4)

### Medium Term (1-2 months)
- [ ] Multi-account management (Phase 5)
- [ ] Enhanced notification system
- [ ] Usage history tracking
- [ ] Export usage data

### Long Term (3+ months)
- [ ] Custom provider API
- [ ] Usage predictions/alerts
- [ ] Cost optimization suggestions
- [ ] Team usage aggregation

---

## 🤝 Upstream Contribution Strategy

**When to Contribute Upstream:**
- Bug fixes that benefit all users
- Provider improvements (non-fork-specific)
- Documentation improvements
- Performance optimizations

**When to Keep in Fork:**
- Multi-account management (major architectural change)
- Fork-specific branding/attribution
- Experimental features
- Features specific to topoffunnel.com users

**PR Guidelines:**
- Keep PRs focused and small
- Include comprehensive tests
- Follow upstream coding style
- Document breaking changes
- Be patient with review process

---

## 📊 Success Metrics

**Technical:**
- Zero cookie disconnection issues
- < 1 second menu bar response time
- 100% test coverage for new features
- Zero regressions from upstream syncs

**User:**
- Positive feedback from topoffunnel.com users
- Active usage metrics
- Feature requests and engagement
- Community contributions

---

## 🔗 Related Documentation

- [Augment Provider](augment.md) - Augment-specific documentation
- [Development Guide](DEVELOPMENT.md) - Build and test instructions
- [Provider Authoring](provider.md) - How to create new providers
- [Upstream Sync](UPSTREAM_SYNC.md) - Syncing with original repository (TBD)
- [Quotio Analysis](QUOTIO_ANALYSIS.md) - Feature comparison (TBD)

