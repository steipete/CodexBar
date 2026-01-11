# Fork Setup & Initial Configuration

**One-time setup for managing your CodexBar fork with multiple upstreams**

---

## 🎯 Quick Setup

### Step 1: Configure Git Remotes

```bash
# Verify your fork is origin
git remote -v
# Should show: origin  git@github.com:topoffunnel/CodexBar.git

# Add upstream (steipete's original)
git remote add upstream https://github.com/steipete/CodexBar.git

# Add quotio (inspiration source)
git remote add quotio https://github.com/nguyenphutrong/quotio.git

# Fetch all remotes
git fetch --all

# Verify setup
git remote -v
# Should show:
# origin    git@github.com:topoffunnel/CodexBar.git (fetch/push)
# upstream  https://github.com/steipete/CodexBar.git (fetch/push)
# quotio    https://github.com/nguyenphutrong/quotio.git (fetch/push)
```

### Step 2: Test Automation Scripts

```bash
# Make scripts executable (if not already)
chmod +x Scripts/*.sh

# Test upstream monitoring
./Scripts/check_upstreams.sh

# Should show:
# - Number of new commits in upstream
# - Number of new commits in quotio
# - File change summary
```

### Step 3: Initial Upstream Review

```bash
# Check what's new in upstream
./Scripts/check_upstreams.sh upstream

# Review changes in detail
./Scripts/review_upstream.sh upstream

# This creates a review branch: upstream-sync/upstream-YYYYMMDD
```

### Step 4: Initial Quotio Analysis

```bash
# Analyze quotio repository
./Scripts/analyze_quotio.sh

# Creates: quotio-analysis-YYYYMMDD.md
# Review the file for interesting patterns
```

---

## ⚠️ Critical Discovery: Upstream Removed Augment

**IMPORTANT:** Upstream (steipete) has removed the Augment provider in recent commits!

```
Files changed:
 .../Providers/Augment/AugmentStatusProbe.swift     | 627 deletions
 Tests/CodexBarTests/AugmentStatusProbeTests.swift  |  88 deletions
```

**This validates our fork strategy:**
- ✅ Your fork preserves Augment support
- ✅ You can continue developing Augment features
- ✅ Upstream changes won't break your Augment work
- ✅ You maintain features important to your users

**Action Required:**
When syncing with upstream, you'll need to:
1. Cherry-pick valuable changes (Vertex AI improvements, bug fixes)
2. **Avoid** merging commits that remove Augment
3. Keep your Augment implementation separate

---

## 🔄 Regular Workflow

### Weekly Upstream Check (Recommended: Monday)

```bash
# Check for new changes
./Scripts/check_upstreams.sh

# If changes found, review them
./Scripts/review_upstream.sh upstream

# Cherry-pick valuable commits (skip Augment removal)
git cherry-pick <commit-hash>

# Test
./Scripts/compile_and_run.sh

# Merge to main
git checkout main
git merge upstream-sync/upstream-$(date +%Y%m%d)
```

### Weekly Quotio Review (Recommended: Thursday)

```bash
# Analyze recent quotio changes
./Scripts/analyze_quotio.sh

# Review specific files of interest
git show quotio/main:path/to/interesting/file.swift

# Document patterns in docs/QUOTIO_ANALYSIS.md
```

---

## 📋 Selective Sync Strategy

### What to Sync from Upstream

✅ **DO sync:**
- Bug fixes (non-Augment)
- Performance improvements
- New provider support (Vertex AI, etc.)
- Documentation improvements
- Test improvements
- Dependency updates

❌ **DON'T sync:**
- Augment provider removal
- Changes that conflict with fork features
- Breaking changes without careful review

### How to Cherry-Pick Selectively

```bash
# Review upstream commits
git log --oneline main..upstream/main

# Example output:
# 001019c style: fix swiftformat violations ✅ SYNC
# e4f1e4c feat(vertex): add token cost tracking ✅ SYNC
# 202efde fix(vertex): disable double-counting ✅ SYNC
# 0c2f888 docs: add Vertex AI documentation ✅ SYNC
# 3c4ca30 feat(vertexai): token cost tracking ✅ SYNC
# abc123d refactor: remove Augment provider ❌ SKIP

# Cherry-pick the good ones
git cherry-pick 001019c
git cherry-pick e4f1e4c
git cherry-pick 202efde
git cherry-pick 0c2f888
git cherry-pick 3c4ca30
# Skip abc123d (Augment removal)
```

---

## 🎨 Quotio Pattern Learning

### Ethical Guidelines

**DO:**
- ✅ Analyze their architecture and patterns
- ✅ Learn from their UX decisions
- ✅ Understand their approach to problems
- ✅ Implement similar concepts independently
- ✅ Credit inspiration in commits

**DON'T:**
- ❌ Copy code verbatim
- ❌ Use their assets or branding
- ❌ Violate their license
- ❌ Claim their work as yours

### Analysis Workflow

```bash
# 1. Fetch latest quotio
git fetch quotio

# 2. Analyze structure
./Scripts/analyze_quotio.sh

# 3. Review specific areas
git show quotio/main:path/to/AccountManager.swift

# 4. Document patterns (not code!)
# Edit docs/QUOTIO_ANALYSIS.md

# 5. Implement independently
# Create feature branch
git checkout -b quotio-inspired/multi-account

# 6. Commit with attribution
git commit -m "feat: multi-account management

Inspired by quotio's account switching pattern:
https://github.com/nguyenphutrong/quotio/...

Implemented independently using CodexBar architecture."
```

---

## 🚀 Contributing to Upstream

### When to Contribute

**Good candidates:**
- Universal bug fixes
- Performance improvements
- Documentation improvements
- Test coverage
- Provider enhancements (non-fork-specific)

**Keep in fork:**
- Augment provider (they removed it)
- Multi-account management (major change)
- Fork branding
- Experimental features

### Contribution Workflow

```bash
# 1. Prepare clean branch from upstream
./Scripts/prepare_upstream_pr.sh fix-cursor-bonus

# 2. Cherry-pick your fix (without fork branding)
git cherry-pick <your-commit-hash>

# 3. Review - ensure no fork-specific code
git diff upstream/main

# 4. Test
swift test

# 5. Push to your fork
git push origin upstream-pr/fix-cursor-bonus

# 6. Create PR on GitHub
# Go to: https://github.com/steipete/CodexBar
# Click "New Pull Request"
# Select: base: steipete:main <- compare: topoffunnel:upstream-pr/fix-cursor-bonus
```

---

## 🤖 Automated Monitoring

### GitHub Actions Setup

The workflow `.github/workflows/upstream-monitor.yml` will:
- Run Monday and Thursday at 9 AM UTC
- Check for new commits in both upstreams
- Create/update GitHub issue with summary
- Provide links to review changes

**To enable:**
1. Push the workflow file to your fork
2. Enable GitHub Actions in repository settings
3. Issues will be created automatically

**Manual trigger:**
```bash
# Via GitHub UI: Actions → Monitor Upstream Changes → Run workflow
```

---

## 📊 Verification Checklist

After setup, verify:

- [ ] All three remotes configured (origin, upstream, quotio)
- [ ] Scripts are executable
- [ ] `./Scripts/check_upstreams.sh` runs successfully
- [ ] Can create review branch with `./Scripts/review_upstream.sh`
- [ ] Can analyze quotio with `./Scripts/analyze_quotio.sh`
- [ ] GitHub Actions workflow is present
- [ ] Understand Augment removal in upstream
- [ ] Know how to cherry-pick selectively
- [ ] Know when to contribute upstream vs keep in fork

---

## 🔗 Next Steps

1. **Review Current Upstream Changes**
   ```bash
   ./Scripts/review_upstream.sh upstream
   ```

2. **Decide on Sync Strategy**
   - Which commits to cherry-pick?
   - How to handle Augment removal?
   - See `docs/UPSTREAM_STRATEGY.md`

3. **Start Quotio Analysis**
   ```bash
   ./Scripts/analyze_quotio.sh
   # Then edit docs/QUOTIO_ANALYSIS.md
   ```

4. **Update Fork Roadmap**
   - Review `docs/FORK_ROADMAP.md`
   - Adjust based on upstream changes
   - Plan fork-specific features

---

**Setup Complete!** You now have a robust system for managing your fork while learning from multiple sources.

