#!/bin/bash
# Check for new changes in upstream repositories
# Usage: ./Scripts/check_upstreams.sh [upstream|quotio|all]

set -e

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

# Check upstream (steipete)
if [ "$TARGET" = "all" ] || [ "$TARGET" = "upstream" ]; then
    echo -e "${BLUE}==> Upstream (steipete/CodexBar) changes:${NC}"
    
    UPSTREAM_COUNT=$(git log --oneline main..upstream/main --no-merges 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$UPSTREAM_COUNT" -gt 0 ]; then
        echo -e "${GREEN}Found $UPSTREAM_COUNT new commits${NC}"
        echo ""
        git log --oneline --graph main..upstream/main --no-merges | head -20
        echo ""
        echo -e "${YELLOW}Files changed:${NC}"
        git diff --stat main..upstream/main | tail -20
    else
        echo -e "${GREEN}No new commits (up to date)${NC}"
    fi
    echo ""
fi

# Check quotio
if [ "$TARGET" = "all" ] || [ "$TARGET" = "quotio" ]; then
    echo -e "${BLUE}==> Quotio changes (last $DAYS days):${NC}"
    
    QUOTIO_COUNT=$(git log --oneline --all --remotes=quotio/main --since="$DAYS days ago" 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$QUOTIO_COUNT" -gt 0 ]; then
        echo -e "${GREEN}Found $QUOTIO_COUNT commits in last $DAYS days${NC}"
        echo ""
        git log --oneline --graph --remotes=quotio/main --since="$DAYS days ago" | head -20
        echo ""
        echo -e "${YELLOW}Recent file changes:${NC}"
        # Show changes from last 10 commits
        git diff --stat quotio/main~10..quotio/main 2>/dev/null | tail -20 || echo "Unable to show diff"
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
echo "  Detailed diff:   git diff main..upstream/main"
echo "  View quotio:     git log -p quotio/main~10..quotio/main"

