# Multi-Upstream Fork Management Strategy

**Fork:** topoffunnel/CodexBar  
**Upstream 1:** steipete/CodexBar (original)  
**Upstream 2:** nguyenphutrong/quotio (inspiration source)

---

## 🎯 Core Principles

### Fork Independence
- **Your fork is the primary development target**
- Upstream contributions are optional and selective
- You retain full credit for your innovations
- Fork-specific features stay in the fork

### Selective Contribution
- Only contribute universally beneficial changes upstream
- Keep attribution-sensitive improvements in fork
- Submit small, focused PRs to increase merge likelihood
- Don't contribute fork branding or identity

### Best-of-Both-Worlds
- Monitor both upstreams for valuable changes
- Cherry-pick features that enhance your fork
- Adapt patterns without copying code
- Credit sources appropriately

---

## 🌳 Git Repository Structure

### Remote Configuration

```bash
# Your fork (origin)
git remote add origin git@github.com:topoffunnel/CodexBar.git

# Original upstream (steipete)
git remote add upstream git@github.com:steipete/CodexBar.git

# Quotio inspiration source
git remote add quotio git@github.com:nguyenphutrong/quotio.git

# Verify remotes
git remote -v
```

### Branch Strategy

```
main (your fork's stable branch)
├── feature/* (fork-specific features)
├── upstream-sync/* (tracking upstream changes)
├── quotio-inspired/* (features inspired by quotio)
└── upstream-pr/* (branches for upstream PRs)
```

**Branch Types:**
- `main` - Your fork's stable release branch
- `feature/*` - Fork-specific development
- `upstream-sync/*` - Temporary branches for reviewing upstream changes
- `quotio-inspired/*` - Features adapted from quotio patterns
- `upstream-pr/*` - Clean branches for upstream contributions

---

## 🔄 Workflow 1: Monitoring Upstream Changes

### Daily/Weekly Sync Check

```bash
#!/bin/bash
# Scripts/check_upstreams.sh

echo "==> Fetching upstream changes..."
git fetch upstream
git fetch quotio

echo ""
echo "==> Upstream (steipete) changes:"
git log --oneline main..upstream/main --no-merges | head -20

echo ""
echo "==> Quotio changes:"
git log --oneline --all --remotes=quotio/main --since="1 week ago" | head -20

echo ""
echo "==> Files changed in upstream:"
git diff --stat main..upstream/main

echo ""
echo "==> Files changed in quotio (recent):"
git diff --stat quotio/main~10..quotio/main
```

### Automated Monitoring (GitHub Actions)

Create `.github/workflows/upstream-monitor.yml`:

```yaml
name: Monitor Upstreams

on:
  schedule:
    - cron: '0 9 * * 1,4'  # Monday and Thursday at 9 AM
  workflow_dispatch:

jobs:
  check-upstream:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      
      - name: Add upstream remotes
        run: |
          git remote add upstream https://github.com/steipete/CodexBar.git
          git remote add quotio https://github.com/nguyenphutrong/quotio.git
          git fetch upstream
          git fetch quotio
      
      - name: Check for new commits
        id: check
        run: |
          UPSTREAM_NEW=$(git log --oneline main..upstream/main --no-merges | wc -l)
          QUOTIO_NEW=$(git log --oneline --all --remotes=quotio/main --since="1 week ago" | wc -l)
          
          echo "upstream_commits=$UPSTREAM_NEW" >> $GITHUB_OUTPUT
          echo "quotio_commits=$QUOTIO_NEW" >> $GITHUB_OUTPUT
      
      - name: Create issue if changes detected
        if: steps.check.outputs.upstream_commits > 0 || steps.check.outputs.quotio_commits > 0
        uses: actions/github-script@v7
        with:
          script: |
            const upstreamCommits = '${{ steps.check.outputs.upstream_commits }}';
            const quotioCommits = '${{ steps.check.outputs.quotio_commits }}';
            
            const body = `## Upstream Changes Detected
            
            **steipete/CodexBar:** ${upstreamCommits} new commits
            **quotio:** ${quotioCommits} new commits (last week)
            
            Review changes:
            - [steipete commits](https://github.com/steipete/CodexBar/compare/main...upstream/main)
            - [quotio commits](https://github.com/nguyenphutrong/quotio/commits/main)
            
            Run \`./Scripts/review_upstream.sh\` to analyze changes.`;
            
            github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title: 'Upstream Changes Available',
              body: body,
              labels: ['upstream-sync']
            });
```

---

## 🔍 Workflow 2: Reviewing & Incorporating Changes

### Step 1: Review Upstream Changes

```bash
#!/bin/bash
# Scripts/review_upstream.sh

UPSTREAM=${1:-upstream}  # 'upstream' or 'quotio'

echo "==> Creating review branch for $UPSTREAM..."
git checkout main
git checkout -b upstream-sync/$UPSTREAM-$(date +%Y%m%d)

echo "==> Fetching latest..."
git fetch $UPSTREAM

echo "==> Showing commits to review:"
git log --oneline --graph main..$UPSTREAM/main | head -30

echo ""
echo "==> Detailed diff:"
git diff main..$UPSTREAM/main --stat

echo ""
echo "Next steps:"
echo "1. Review commits: git log -p main..$UPSTREAM/main"
echo "2. Cherry-pick specific commits: git cherry-pick <commit-hash>"
echo "3. Or merge all: git merge $UPSTREAM/main"
echo "4. Test thoroughly"
echo "5. Merge to main: git checkout main && git merge upstream-sync/$UPSTREAM-$(date +%Y%m%d)"
```

### Step 2: Selective Cherry-Picking

```bash
# Review individual commits
git log -p main..upstream/main

# Cherry-pick specific valuable commits
git cherry-pick <commit-hash>

# If conflicts, resolve and continue
git cherry-pick --continue

# Or abort if not suitable
git cherry-pick --abort
```

### Step 3: Quotio Pattern Adaptation

```bash
# Create inspiration branch
git checkout -b quotio-inspired/feature-name

# View quotio implementation (read-only)
git show quotio/main:path/to/file.swift

# Implement similar pattern in your codebase
# (write your own code, don't copy)

# Commit with attribution
git commit -m "feat: implement feature inspired by quotio

Inspired by quotio's approach to [feature]:
https://github.com/nguyenphutrong/quotio/commit/abc123

Implemented independently with CodexBar-specific patterns."
```

---

## 📤 Workflow 3: Contributing to Upstream

### Identifying Upstream-Suitable Changes

**✅ Good for Upstream:**
- Bug fixes that affect all users
- Performance improvements
- Provider enhancements (non-fork-specific)
- Documentation improvements
- Test coverage additions
- Dependency updates

**❌ Keep in Fork:**
- Fork branding/attribution
- Multi-account management (major architectural change)
- Fork-specific UI customizations
- Experimental features
- topoffunnel.com-specific integrations

### Creating Upstream PR Branch

```bash
#!/bin/bash
# Scripts/prepare_upstream_pr.sh

FEATURE_NAME=$1

if [ -z "$FEATURE_NAME" ]; then
  echo "Usage: ./Scripts/prepare_upstream_pr.sh <feature-name>"
  exit 1
fi

echo "==> Creating upstream PR branch..."
git checkout upstream/main
git checkout -b upstream-pr/$FEATURE_NAME

echo "==> Branch created: upstream-pr/$FEATURE_NAME"
echo ""
echo "Next steps:"
echo "1. Cherry-pick your commits (without fork branding)"
echo "2. Remove any fork-specific code"
echo "3. Ensure tests pass"
echo "4. Push: git push origin upstream-pr/$FEATURE_NAME"
echo "5. Create PR to steipete/CodexBar from GitHub UI"
```

### Cleaning Commits for Upstream

```bash
# Start from upstream's main
git checkout upstream/main
git checkout -b upstream-pr/fix-cursor-bonus

# Cherry-pick your fix (without fork branding)
git cherry-pick <your-commit-hash>

# If commit includes fork branding, amend it
git commit --amend

# Remove fork-specific changes
git reset HEAD~1
# Manually stage only upstream-suitable changes
git add <files>
git commit -m "fix: correct Cursor bonus credits calculation

Fixes issue where bonus credits were incorrectly calculated.

Tested with multiple account types."

# Push to your fork
git push origin upstream-pr/fix-cursor-bonus

# Create PR to steipete/CodexBar via GitHub UI
```

---

## 🏷️ Commit Message Strategy

### Fork Commits (Keep Everything)

```
feat: add multi-account management for Augment

Implements account switching UI and storage.
Fork-specific feature for topoffunnel.com users.

Co-authored-by: Brandon Charleson <brandon@topoffunnel.com>
```

### Upstream-Bound Commits (Generic)

```
fix: correct Cursor bonus credits calculation

The bonus credits were being added instead of subtracted
from the total usage calculation.

Tested with Pro and Team accounts.
```

### Quotio-Inspired Commits (Attribution)

```
feat: implement session persistence inspired by quotio

Adds automatic session restoration on app restart.

Inspired by quotio's approach:
https://github.com/nguyenphutrong/quotio/blob/main/...

Implemented independently using CodexBar patterns.
```

---

## 📋 Decision Matrix: What Goes Where?

| Change Type | Fork | Upstream | Notes |
|------------|------|----------|-------|
| Bug fix (universal) | ✅ | ✅ | Submit to upstream |
| Bug fix (fork-specific) | ✅ | ❌ | Keep in fork |
| Performance improvement | ✅ | ✅ | Submit to upstream |
| New provider support | ✅ | ✅ | Submit to upstream |
| Provider enhancement | ✅ | Maybe | Depends on scope |
| UI improvement (generic) | ✅ | ✅ | Submit to upstream |
| UI improvement (fork brand) | ✅ | ❌ | Keep in fork |
| Multi-account feature | ✅ | ❌ | Too large for upstream |
| Documentation | ✅ | ✅ | Submit to upstream |
| Tests | ✅ | ✅ | Submit to upstream |
| Fork branding | ✅ | ❌ | Never upstream |
| Experimental feature | ✅ | ❌ | Prove it first |

---

## 🔐 Protecting Your Attribution

### Separate Commits Strategy

```bash
# Make changes in feature branch
git checkout -b feature/my-improvement

# Commit 1: Core improvement (upstream-suitable)
git add Sources/CodexBarCore/...
git commit -m "feat: improve cookie handling"

# Commit 2: Fork-specific enhancements
git add Sources/CodexBar/About.swift
git commit -m "feat: add fork attribution for improvement"

# Merge to main (both commits)
git checkout main
git merge feature/my-improvement

# For upstream PR: cherry-pick only commit 1
git checkout upstream/main
git checkout -b upstream-pr/cookie-handling
git cherry-pick <commit-1-hash>  # Only the core improvement
```

### Maintaining Fork Identity

Keep these files fork-specific (never upstream):
- `Sources/CodexBar/About.swift` (your attribution)
- `Sources/CodexBar/PreferencesAboutPane.swift` (fork sections)
- `README.md` (fork notice)
- `docs/FORK_*.md` (fork documentation)
- `FORK_STATUS.md`

---

## 🤖 Automation Scripts

All automation scripts are located in `Scripts/`:

- **check_upstreams.sh** - Check for new commits in both upstreams
- **review_upstream.sh** - Create review branch for upstream changes
- **prepare_upstream_pr.sh** - Prepare clean branch for upstream PR
- **analyze_quotio.sh** - Analyze quotio for patterns and features

GitHub Actions workflow: `.github/workflows/upstream-monitor.yml`

---

## 📖 Practical Examples

### Example 1: Weekly Upstream Check

```bash
# Monday morning routine
./Scripts/check_upstreams.sh

# If changes found, review them
./Scripts/review_upstream.sh upstream

# Cherry-pick valuable commits
git cherry-pick abc123
git cherry-pick def456

# Test
./Scripts/compile_and_run.sh

# Merge to main
git checkout main
git merge upstream-sync/upstream-20260104
```

### Example 2: Contributing Bug Fix Upstream

```bash
# You fixed a bug in your fork
git log --oneline -5
# abc123 fix: correct Cursor bonus credits
# def456 feat: add fork attribution

# Prepare upstream PR (only the fix, not attribution)
./Scripts/prepare_upstream_pr.sh fix-cursor-bonus

# Cherry-pick only the fix
git cherry-pick abc123

# Review - ensure no fork branding
git diff upstream/main

# Push and create PR
git push origin upstream-pr/fix-cursor-bonus
# Then create PR on GitHub to steipete/CodexBar
```

### Example 3: Learning from Quotio

```bash
# Analyze quotio
./Scripts/analyze_quotio.sh

# Review their multi-account implementation
git show quotio/main:path/to/AccountManager.swift

# Document patterns in docs/QUOTIO_ANALYSIS.md
# Then implement independently in your fork

# Commit with attribution
git commit -m "feat: implement multi-account management

Inspired by quotio's account switching pattern:
https://github.com/nguyenphutrong/quotio/...

Implemented independently using CodexBar's architecture."
```

---

## 🎓 Best Practices

### For Fork Development
1. **Commit often** - Small, focused commits
2. **Separate concerns** - Fork branding in separate commits
3. **Test thoroughly** - Every change
4. **Document decisions** - Why you chose this approach
5. **Credit sources** - When inspired by others

### For Upstream Contributions
1. **Start small** - Bug fixes before features
2. **One thing per PR** - Focused changes
3. **Follow their style** - Match upstream conventions
4. **Include tests** - Prove it works
5. **Be patient** - Maintainers are busy

### For Multi-Upstream Sync
1. **Check weekly** - Stay current
2. **Review carefully** - Understand before merging
3. **Test everything** - Upstream changes may break your fork
4. **Document conflicts** - How you resolved them
5. **Keep attribution** - Credit all sources

---

## 🔧 Troubleshooting

### Merge Conflicts

```bash
# During upstream merge
git merge upstream/main
# CONFLICT in Sources/CodexBar/About.swift

# Keep your fork version for branding files
git checkout --ours Sources/CodexBar/About.swift
git add Sources/CodexBar/About.swift

# Merge other files manually
# Then continue
git commit
```

### Accidentally Pushed Fork Branding to Upstream PR

```bash
# Oops! Pushed fork branding to upstream PR branch
git checkout upstream-pr/my-feature

# Reset to before the bad commit
git reset --hard HEAD~1

# Re-apply changes without branding
# ... make changes ...
git commit -m "fix: proper commit"

# Force push (only safe on PR branches)
git push origin upstream-pr/my-feature --force
```

### Lost Track of Upstream Changes

```bash
# See what you've merged from upstream
git log --oneline --graph --all --grep="upstream"

# See what's still pending
git log --oneline main..upstream/main

# Create a tracking branch
git checkout -b upstream-tracking upstream/main
git log --oneline upstream-tracking..main
```

---

## 📊 Success Metrics

### Fork Health
- ✅ Builds without errors
- ✅ All tests passing
- ✅ No regressions from upstream merges
- ✅ Fork-specific features working
- ✅ Documentation up to date

### Upstream Relationship
- ✅ PRs are small and focused
- ✅ PRs get merged (or constructive feedback)
- ✅ Maintain good relationship with maintainer
- ✅ Credit given appropriately
- ✅ No fork branding in upstream PRs

### Multi-Source Learning
- ✅ Regular upstream monitoring
- ✅ Quotio patterns documented
- ✅ Independent implementations
- ✅ Proper attribution
- ✅ Best-of-both-worlds achieved

---

## 🗓️ Recommended Schedule

### Weekly
- Monday: Check upstreams (`./Scripts/check_upstreams.sh`)
- Thursday: Review quotio (`./Scripts/analyze_quotio.sh`)

### Monthly
- Review upstream PRs you submitted
- Update QUOTIO_ANALYSIS.md with new findings
- Sync with upstream main
- Update fork documentation

### Quarterly
- Major feature planning
- Upstream contribution strategy review
- Fork roadmap update
- Community engagement

---

## 📞 Getting Help

### Upstream Issues
- Check their issue tracker first
- Ask in discussions if available
- Be respectful and patient
- Provide minimal reproduction

### Fork Issues
- Document in your fork's issues
- Reference upstream if relevant
- Track in FORK_STATUS.md
- Update roadmap as needed

### Quotio Questions
- Review their documentation
- Check their issue tracker
- Don't ask them to help with your fork
- Credit them when you adapt patterns

---

**Remember:** Your fork is independent. Upstream contributions are optional. Learn from others, but implement independently. Credit sources appropriately.

