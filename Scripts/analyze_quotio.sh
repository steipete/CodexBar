#!/bin/bash
# Analyze quotio repository for interesting patterns and features
# Usage: ./Scripts/analyze_quotio.sh [feature-area]

set -e

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

echo ""
echo -e "${GREEN}==> Quotio Repository Analysis${NC}"
echo ""

# Show recent activity
echo -e "${BLUE}Recent Activity (last 30 days):${NC}"
git log --oneline --graph --remotes=quotio/main --since="30 days ago" | head -20
echo ""

# Analyze file structure
echo -e "${BLUE}File Structure:${NC}"
git ls-tree -r --name-only quotio/main | grep -E '\.(swift|md)$' | head -30
echo ""

# Find interesting patterns based on area
case $AREA in
    "providers"|"all")
        echo -e "${BLUE}Provider Implementations:${NC}"
        git ls-tree -r --name-only quotio/main | grep -i provider | head -20
        echo ""
        ;;
esac

case $AREA in
    "ui"|"all")
        echo -e "${BLUE}UI Components:${NC}"
        git ls-tree -r --name-only quotio/main | grep -iE '(view|ui|menu)' | head -20
        echo ""
        ;;
esac

case $AREA in
    "auth"|"all")
        echo -e "${BLUE}Authentication/Session:${NC}"
        git ls-tree -r --name-only quotio/main | grep -iE '(auth|session|cookie|login)' | head -20
        echo ""
        ;;
esac

# Show commit messages for pattern analysis
echo -e "${BLUE}Recent Commit Messages (for pattern analysis):${NC}"
git log --oneline quotio/main --since="60 days ago" | head -30
echo ""

# Create analysis report
REPORT_FILE="quotio-analysis-$(date +%Y%m%d).md"
cat > "$REPORT_FILE" << EOF
# Quotio Analysis Report
**Date:** $(date +%Y-%m-%d)
**Purpose:** Identify patterns and features for CodexBar fork inspiration

## Recent Activity
\`\`\`
$(git log --oneline --graph --remotes=quotio/main --since="30 days ago" | head -20)
\`\`\`

## File Structure
\`\`\`
$(git ls-tree -r --name-only quotio/main | grep -E '\.(swift|md)$' | head -50)
\`\`\`

## Recent Commits
\`\`\`
$(git log --oneline quotio/main --since="60 days ago" | head -30)
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
echo "   ${GREEN}git show quotio/main:path/to/file${NC}"
echo ""
echo "2. Compare implementations:"
echo "   ${GREEN}git diff main quotio/main -- path/to/similar/file${NC}"
echo ""
echo "3. Review commit details:"
echo "   ${GREEN}git log -p quotio/main --since='30 days ago'${NC}"
echo ""
echo "4. Document patterns in:"
echo "   ${GREEN}docs/QUOTIO_ANALYSIS.md${NC}"
echo ""
echo -e "${BLUE}Remember: Adapt patterns, don't copy code!${NC}"

