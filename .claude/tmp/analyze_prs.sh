#!/bin/bash
set -e
REPO=$(gh repo view --json owner,name -q '.owner.login + "/" + .name')
PRS_FILE=".claude/tmp/open_prs.json"
REPORT=".claude/tmp/pr_report.md"

echo "# Open PRs Report for ${REPO}" > "$REPORT"
echo "Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$REPORT"
echo "" >> "$REPORT"

echo "## Summary" >> "$REPORT"
echo "" >> "$REPORT"

echo "| # | Title | Author | Draft | Mergeable | State | Reviews | Checks |" >> "$REPORT"
echo "|---|---|---|---|---|---|---|---|" >> "$REPORT"

for row in $(jq -r '.[] | @base64' "$PRS_FILE"); do
  _jq() { echo "${row}" | base64 --decode | jq -r "${1}"; }
  num=$(_jq '.number')
  title=$(_jq '.title')
  author=$(_jq '.author.login')
  draft=$(_jq '.isDraft')
  mergeable=$(_jq '.mergeable')
  state=$(_jq '.mergeStateStatus')
  reviews=$(_jq '.reviewDecision')
  
  # Get check status
  checks=$(gh pr checks "$num" --repo "$REPO" --json name,state,conclusion --jq '[.[] | select(.state=="COMPLETED") | .conclusion] | if length == 0 then "none" elif all(. == "SUCCESS") then "pass" elif any(. == "FAILURE") then "fail" elif any(. == "PENDING" or . == "IN_PROGRESS") then "pending" else "unknown" end' 2>/dev/null || echo "unknown")
  
  # Truncate title
  if [ "${#title}" -gt 55 ]; then
    title="${title:0:52}..."
  fi
  
  echo "| #${num} | ${title} | @${author} | ${draft} | ${mergeable} | ${state} | ${reviews} | ${checks} |" >> "$REPORT"
done

echo "" >> "$REPORT"
echo "## Conflicting PRs" >> "$REPORT"
echo "" >> "$REPORT"
jq -r '.[] | select(.mergeable == "CONFLICTING") | "- **#\(.number)** \(.title) — branch `\(.headRefName)` by @\(.author.login)"' "$PRS_FILE" >> "$REPORT" || true

echo "" >> "$REPORT"
echo "## Unstable / Failing Checks PRs" >> "$REPORT"
echo "" >> "$REPORT"

