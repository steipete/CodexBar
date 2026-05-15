#!/usr/bin/env bash
# Check for new changes in upstream repositories
# Usage: ./Scripts/check_upstreams.sh [upstream|quotio|all]

set -euo pipefail

TARGET=${1:-all}
DAYS=${2:-7}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}==> Fetching upstream changes...${NC}"
if [ "$TARGET" = "all" ] || [ "$TARGET" = "upstream" ]; then
    git fetch upstream 2>/dev/null || {
        echo -e "${YELLOW}Adding upstream remote...${NC}"
        git remote add upstream https://github.com/steipete/CodexBar.git
        git fetch upstream
    }
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "quotio" ]; then
    git fetch quotio 2>/dev/null || {
        echo -e "${YELLOW}Adding quotio remote...${NC}"
        git remote add quotio https://github.com/nguyenphutrong/quotio.git
        git fetch quotio
    }
fi

echo ""

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

# Check upstream (steipete)
if [ "$TARGET" = "all" ] || [ "$TARGET" = "upstream" ]; then
    echo -e "${BLUE}==> Upstream (steipete/CodexBar) changes:${NC}"
    UPSTREAM_BRANCH=$(remote_default_branch upstream)
    UPSTREAM_REF="upstream/${UPSTREAM_BRANCH}"
    
    UPSTREAM_COUNT=$(git log --oneline "main..${UPSTREAM_REF}" --no-merges 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$UPSTREAM_COUNT" -gt 0 ]; then
        echo -e "${GREEN}Found $UPSTREAM_COUNT new commits${NC}"
        echo ""
        git log --oneline --graph "main..${UPSTREAM_REF}" --no-merges | head -20 || true
        echo ""
        echo -e "${YELLOW}Files changed:${NC}"
        git diff --stat "main..${UPSTREAM_REF}" | tail -20 || true
    else
        echo -e "${GREEN}No new commits (up to date)${NC}"
    fi
    echo ""
fi

# Check quotio
if [ "$TARGET" = "all" ] || [ "$TARGET" = "quotio" ]; then
    echo -e "${BLUE}==> Quotio changes (last $DAYS days):${NC}"
    QUOTIO_BRANCH=$(remote_default_branch quotio)
    QUOTIO_REF="quotio/${QUOTIO_BRANCH}"
    
    QUOTIO_COUNT=$(git log --oneline "$QUOTIO_REF" --since="$DAYS days ago" 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$QUOTIO_COUNT" -gt 0 ]; then
        echo -e "${GREEN}Found $QUOTIO_COUNT commits in last $DAYS days${NC}"
        echo ""
        git log --oneline --graph "$QUOTIO_REF" --since="$DAYS days ago" | head -20 || true
        echo ""
        echo -e "${YELLOW}Recent file changes:${NC}"
        # Show changes from last 10 commits
        git diff --stat "${QUOTIO_REF}~10..${QUOTIO_REF}" 2>/dev/null | tail -20 || echo "Unable to show diff"
    else
        echo -e "${GREEN}No new commits in last $DAYS days${NC}"
    fi
    echo ""
fi

# Summary
echo -e "${BLUE}==> Summary${NC}"
if [ "$TARGET" = "all" ] || [ "$TARGET" = "upstream" ]; then
    echo "Upstream commits: $UPSTREAM_COUNT"
fi
if [ "$TARGET" = "all" ] || [ "$TARGET" = "quotio" ]; then
    echo "Quotio commits (${DAYS}d): $QUOTIO_COUNT"
fi

echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  Review upstream: ./Scripts/review_upstream.sh upstream"
echo "  Review quotio:   ./Scripts/review_upstream.sh quotio"
echo "  Detailed diff:   git diff main..<resolved-remote>/<default-branch>"
echo "  View quotio:     ./Scripts/analyze_quotio.sh"
