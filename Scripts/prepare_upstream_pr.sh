#!/bin/bash
# Prepare a clean branch for upstream PR submission
# Usage: ./Scripts/prepare_upstream_pr.sh <feature-name>

set -e

FEATURE_NAME=$1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ -z "$FEATURE_NAME" ]; then
    echo -e "${RED}Error: Feature name required${NC}"
    echo "Usage: ./Scripts/prepare_upstream_pr.sh <feature-name>"
    echo ""
    echo "Examples:"
    echo "  ./Scripts/prepare_upstream_pr.sh fix-cursor-bonus"
    echo "  ./Scripts/prepare_upstream_pr.sh improve-cookie-handling"
    exit 1
fi

BRANCH_NAME="upstream-pr/$FEATURE_NAME"

echo -e "${BLUE}==> Fetching latest upstream...${NC}"
git fetch upstream

echo -e "${BLUE}==> Creating upstream PR branch from upstream/main...${NC}"
git checkout upstream/main
git checkout -b "$BRANCH_NAME"

echo ""
echo -e "${GREEN}==> Branch created: $BRANCH_NAME${NC}"
echo ""
echo -e "${YELLOW}⚠️  IMPORTANT: This branch is for UPSTREAM submission${NC}"
echo ""
echo -e "${BLUE}Guidelines for upstream PRs:${NC}"
echo ""
echo "✅ DO include:"
echo "  - Bug fixes that affect all users"
echo "  - Performance improvements"
echo "  - Provider enhancements (generic)"
echo "  - Documentation improvements"
echo "  - Test coverage"
echo ""
echo "❌ DO NOT include:"
echo "  - Fork branding (About.swift, PreferencesAboutPane.swift)"
echo "  - Fork-specific features (multi-account, etc.)"
echo "  - References to topoffunnel.com"
echo "  - Experimental features"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo ""
echo "1. Cherry-pick your commits (clean, no fork branding):"
echo "   ${GREEN}git cherry-pick <commit-hash>${NC}"
echo ""
echo "2. Or manually apply changes:"
echo "   ${GREEN}# Edit files${NC}"
echo "   ${GREEN}git add <files>${NC}"
echo "   ${GREEN}git commit -m 'fix: description'${NC}"
echo ""
echo "3. Ensure tests pass:"
echo "   ${GREEN}swift test${NC}"
echo ""
echo "4. Review changes:"
echo "   ${GREEN}git diff upstream/main${NC}"
echo ""
echo "5. Push to your fork:"
echo "   ${GREEN}git push origin $BRANCH_NAME${NC}"
echo ""
echo "6. Create PR on GitHub:"
echo "   ${GREEN}https://github.com/steipete/CodexBar/compare/main...topoffunnel:$BRANCH_NAME${NC}"
echo ""
echo -e "${YELLOW}Remember: Keep PRs small and focused for better merge chances!${NC}"

