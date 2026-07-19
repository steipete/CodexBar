#!/usr/bin/env bash
# Create a review branch for upstream changes
# Usage: ./Scripts/review_upstream.sh [upstream|quotio]

set -euo pipefail

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

ensure_remote() {
    local remote=$1
    local url=$2
    local origin_url

    if git remote get-url "$remote" >/dev/null 2>&1; then
        echo "$remote"
        return 0
    fi

    if [ "$remote" = "upstream" ] && git remote get-url origin >/dev/null 2>&1; then
        origin_url=$(git remote get-url origin)
        case "$origin_url" in
            https://github.com/steipete/CodexBar|https://github.com/steipete/CodexBar.git|git@github.com:steipete/CodexBar.git)
                echo -e "${YELLOW}Remote 'upstream' missing; using origin for steipete/CodexBar.${NC}" >&2
                echo "origin"
                return 0
                ;;
            *)
                echo -e "${YELLOW}Remote 'upstream' missing; origin is not steipete/CodexBar, adding upstream.${NC}" >&2
                ;;
        esac
    fi

    echo -e "${YELLOW}Adding $remote remote...${NC}" >&2
    git remote add "$remote" "$url"
    echo "$remote"
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

case "$UPSTREAM" in
    upstream) REMOTE=$(ensure_remote upstream "https://github.com/steipete/CodexBar.git") ;;
    quotio) REMOTE=$(ensure_remote quotio "https://github.com/nguyenphutrong/quotio.git") ;;
esac

echo -e "${BLUE}==> Fetching latest from $UPSTREAM...${NC}"
git fetch "$REMOTE" --prune
REMOTE_BRANCH=$(remote_default_branch "$REMOTE")
REMOTE_REF="${REMOTE}/${REMOTE_BRANCH}"

echo -e "${BLUE}==> Creating review branch for $UPSTREAM (${REMOTE_REF})...${NC}"
git switch main
git switch -c "$BRANCH_NAME"

echo ""
echo -e "${GREEN}==> Commits to review:${NC}"
git log --oneline --graph "main..${REMOTE_REF}" | head -30 || true

echo ""
echo -e "${GREEN}==> File changes summary:${NC}"
git diff --stat "main..${REMOTE_REF}"

echo ""
echo -e "${YELLOW}==> Review branch created: $BRANCH_NAME${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo ""
echo "1. Review commits in detail:"
echo "   ${GREEN}git log -p main..$REMOTE_REF${NC}"
echo ""
echo "2. View specific files:"
echo "   ${GREEN}git show $REMOTE_REF:path/to/file${NC}"
echo ""
echo "3. Cherry-pick specific commits:"
echo "   ${GREEN}git cherry-pick <commit-hash>${NC}"
echo ""
echo "4. Or merge all changes:"
echo "   ${GREEN}git merge $REMOTE_REF${NC}"
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
git log --oneline "main..${REMOTE_REF}" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
echo "File changes:" >> "$LOG_FILE"
git diff --stat "main..${REMOTE_REF}" >> "$LOG_FILE"

echo -e "${GREEN}Review log saved to: $LOG_FILE${NC}"
