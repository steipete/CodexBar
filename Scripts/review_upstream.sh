#!/bin/bash
# Create a review branch for upstream changes
# Usage: ./Scripts/review_upstream.sh [upstream|quotio]

set -e

UPSTREAM=${1:-upstream}
DATE=$(date +%Y%m%d)
BRANCH_NAME="upstream-sync/${UPSTREAM}-${DATE}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$UPSTREAM" != "upstream" ] && [ "$UPSTREAM" != "quotio" ]; then
    echo -e "${RED}Error: Must specify 'upstream' or 'quotio'${NC}"
    echo "Usage: ./Scripts/review_upstream.sh [upstream|quotio]"
    exit 1
fi

echo -e "${BLUE}==> Creating review branch for $UPSTREAM...${NC}"
git checkout main
git checkout -b "$BRANCH_NAME"

echo -e "${BLUE}==> Fetching latest from $UPSTREAM...${NC}"
git fetch "$UPSTREAM"

echo ""
echo -e "${GREEN}==> Commits to review:${NC}"
git log --oneline --graph main.."$UPSTREAM"/main | head -30

echo ""
echo -e "${GREEN}==> File changes summary:${NC}"
git diff --stat main.."$UPSTREAM"/main

echo ""
echo -e "${YELLOW}==> Review branch created: $BRANCH_NAME${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo ""
echo "1. Review commits in detail:"
echo "   ${GREEN}git log -p main..$UPSTREAM/main${NC}"
echo ""
echo "2. View specific files:"
echo "   ${GREEN}git show $UPSTREAM/main:path/to/file${NC}"
echo ""
echo "3. Cherry-pick specific commits:"
echo "   ${GREEN}git cherry-pick <commit-hash>${NC}"
echo ""
echo "4. Or merge all changes:"
echo "   ${GREEN}git merge $UPSTREAM/main${NC}"
echo ""
echo "5. Test thoroughly:"
echo "   ${GREEN}./Scripts/compile_and_run.sh${NC}"
echo ""
echo "6. If satisfied, merge to main:"
echo "   ${GREEN}git checkout main && git merge $BRANCH_NAME${NC}"
echo ""
echo "7. Or discard review branch:"
echo "   ${GREEN}git checkout main && git branch -D $BRANCH_NAME${NC}"
echo ""

# Create a review log file
LOG_FILE="upstream-review-${UPSTREAM}-${DATE}.txt"
echo "=== Upstream Review: $UPSTREAM @ $DATE ===" > "$LOG_FILE"
echo "" >> "$LOG_FILE"
echo "Commits:" >> "$LOG_FILE"
git log --oneline main.."$UPSTREAM"/main >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
echo "File changes:" >> "$LOG_FILE"
git diff --stat main.."$UPSTREAM"/main >> "$LOG_FILE"

echo -e "${GREEN}Review log saved to: $LOG_FILE${NC}"

