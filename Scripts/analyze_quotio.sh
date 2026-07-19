#!/usr/bin/env bash
# Analyze quotio repository for interesting patterns and features
# Usage: ./Scripts/analyze_quotio.sh [feature-area]

set -euo pipefail

AREA=${1:-all}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}==> Fetching latest quotio...${NC}"
git fetch quotio 2>/dev/null || {
    echo -e "${YELLOW}Adding quotio remote...${NC}"
    git remote add quotio https://github.com/nguyenphutrong/quotio.git
    git fetch quotio
}
remote_default_branch() {
    local remote=$1
    local branch=""
    local candidate

    branch=$(git symbolic-ref -q --short "refs/remotes/${remote}/HEAD" 2>/dev/null | sed "s#^${remote}/##" || true)
    if [ -z "$branch" ]; then
        branch=$(git remote show "$remote" 2>/dev/null | awk '/HEAD branch/ {print $NF; exit}' || true)
    fi
    if [ -n "$branch" ] && git rev-parse --verify -q "${remote}/${branch}" >/dev/null; then
        echo "$branch"
        return 0
    fi

    for candidate in main master; do
        if git rev-parse --verify -q "${remote}/${candidate}" >/dev/null; then
            echo "$candidate"
            return 0
        fi
    done

    echo -e "${RED}Error: Could not resolve default branch for remote '$remote'.${NC}" >&2
    exit 1
}

QUOTIO_BRANCH=$(remote_default_branch quotio)
QUOTIO_REF="quotio/${QUOTIO_BRANCH}"

echo ""
echo -e "${GREEN}==> Quotio Repository Analysis (${QUOTIO_REF})${NC}"
echo ""

# Show recent activity
echo -e "${BLUE}Recent Activity (last 30 days):${NC}"
git log --oneline --graph "$QUOTIO_REF" --since="30 days ago" | head -20 || true
echo ""

# Analyze file structure
echo -e "${BLUE}File Structure:${NC}"
git ls-tree -r --name-only "$QUOTIO_REF" | grep -E '\.(swift|md)$' | head -30 || true
echo ""

# Find interesting patterns based on area
case $AREA in
    "providers"|"all")
        echo -e "${BLUE}Provider Implementations:${NC}"
        git ls-tree -r --name-only "$QUOTIO_REF" | grep -i provider | head -20 || true
        echo ""
        ;;
esac

case $AREA in
    "ui"|"all")
        echo -e "${BLUE}UI Components:${NC}"
        git ls-tree -r --name-only "$QUOTIO_REF" | grep -iE '(view|ui|menu)' | head -20 || true
        echo ""
        ;;
esac

case $AREA in
    "auth"|"all")
        echo -e "${BLUE}Authentication/Session:${NC}"
        git ls-tree -r --name-only "$QUOTIO_REF" | grep -iE '(auth|session|cookie|login)' | head -20 || true
        echo ""
        ;;
esac

# Show commit messages for pattern analysis
echo -e "${BLUE}Recent Commit Messages (for pattern analysis):${NC}"
git log --oneline "$QUOTIO_REF" --since="60 days ago" | head -30 || true
echo ""

# Create analysis report
REPORT_FILE="quotio-analysis-$(date +%Y%m%d).md"
cat > "$REPORT_FILE" << EOF
# Quotio Analysis Report
**Date:** $(date +%Y-%m-%d)
**Purpose:** Identify patterns and features for CodexBar fork inspiration
**Source ref:** \`$QUOTIO_REF\`

## Recent Activity
\`\`\`
$(git log --oneline --graph "$QUOTIO_REF" --since="30 days ago" | head -20 || true)
\`\`\`

## File Structure
\`\`\`
$(git ls-tree -r --name-only "$QUOTIO_REF" | grep -E '\.(swift|md)$' | head -50 || true)
\`\`\`

## Recent Commits
\`\`\`
$(git log --oneline "$QUOTIO_REF" --since="60 days ago" | head -30 || true)
\`\`\`

## Areas of Interest

### Providers
- [ ] Review provider implementations
- [ ] Compare with CodexBar approach
- [ ] Identify improvements

### UI/UX
- [ ] Menu bar organization
- [ ] Settings layout
- [ ] Status indicators

### Authentication
- [ ] Session management
- [ ] Cookie handling
- [ ] OAuth flows

### Multi-Account
- [ ] Account switching
- [ ] Account storage
- [ ] UI patterns

## Action Items
- [ ] Review specific files of interest
- [ ] Document patterns (not code)
- [ ] Create implementation plan
- [ ] Implement independently

## Notes
Remember: We're looking for PATTERNS and IDEAS, not copying code.
All implementations must be original and follow CodexBar conventions.
EOF

echo -e "${GREEN}Analysis report saved to: $REPORT_FILE${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo ""
echo "1. View specific files:"
echo "   ${GREEN}git show $QUOTIO_REF:path/to/file${NC}"
echo ""
echo "2. Compare implementations:"
echo "   ${GREEN}git diff main $QUOTIO_REF -- path/to/similar/file${NC}"
echo ""
echo "3. Review commit details:"
echo "   ${GREEN}git log -p $QUOTIO_REF --since='30 days ago'${NC}"
echo ""
echo "4. Document patterns in:"
echo "   ${GREEN}docs/QUOTIO_ANALYSIS.md${NC}"
echo ""
echo -e "${BLUE}Remember: Adapt patterns, don't copy code!${NC}"
