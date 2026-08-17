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

echo "| # | Title | Author | Draft | Mergeable | State | Reviews | Checks Summary |" >> "$REPORT"
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
  
  # Get check status summary
  checks_raw=$(gh pr checks "$num" --repo "$REPO" --json state,bucket 2>/dev/null || echo "[]")
  if [ "$checks_raw" = "[]" ]; then
    checks="none"
  else
    checks=$(echo "$checks_raw" | jq -r '
      if length == 0 then "none"
      elif [.[].state] | all(. == "SUCCESS") then "pass"
      elif [.[].state] | any(. == "FAILURE") then "fail"
      elif [.[].state] | any(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == "WAITING") then "pending"
      elif [.[].state] | any(. == "SKIPPED" or . == "NEUTRAL") then "neutral"
      else "unknown"
      end
    ')
  fi
  
  # Truncate title
  if [ "${#title}" -gt 55 ]; then
    title="${title:0:52}..."
  fi
  
  echo "| #${num} | ${title} | @${author} | ${draft} | ${mergeable} | ${state} | ${reviews} | ${checks} |" >> "$REPORT"
done

echo "" >> "$REPORT"
echo "## Conflicting PRs (need rebase/merge conflict resolution)" >> "$REPORT"
echo "" >> "$REPORT"
jq -r '.[] | select(.mergeable == "CONFLICTING") | "- **#\(.number)** \(.title) — `\(.headRefName)` by @\(.author.login) — \(.url)"' "$PRS_FILE" >> "$REPORT" || true
if ! jq -e '.[] | select(.mergeable == "CONFLICTING")' "$PRS_FILE" >/dev/null 2>&1; then
  echo "None" >> "$REPORT"
fi

echo "" >> "$REPORT"
echo "## Unstable / Failing Checks PRs" >> "$REPORT"
echo "" >> "$REPORT"
# We'll fill this later with separate script
