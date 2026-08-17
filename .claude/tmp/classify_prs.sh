#!/bin/bash
REPO=$(gh repo view --json owner,name -q '.owner.login + "/" + .name')
PRS_FILE=".claude/tmp/open_prs.json"

# Conflicting PRs
jq -r '.[] | select(.mergeable == "CONFLICTING") | "\(.number)|\(.headRefName)|\(.author.login)|\(.headRepositoryOwner.login)"' "$PRS_FILE" | while IFS='|' read -r num branch author owner; do
  if [ "$owner" = "steipete" ]; then
    echo "PR #$num ($branch by @$author) — same-repo branch — can rebase locally"
  else
    echo "PR #$num ($branch by @$author) — fork branch — needs author/maintainer action"
  fi
done

echo ""
echo "Failing checks PRs:"
jq -r '.[] | select(.mergeable != "CONFLICTING") | "\(.number)|\(.headRefName)|\(.author.login)|\(.headRepositoryOwner.login)|\(.isDraft)"' "$PRS_FILE" | while IFS='|' read -r num branch author owner draft; do
  checks=$(gh pr checks "$num" --repo "$REPO" --json state,bucket 2>/dev/null || echo "[]")
  hasFailure=$(echo "$checks" | jq '[.[].state] | any(. == "FAILURE")')
  if [ "$hasFailure" = "true" ]; then
    if [ "$owner" = "steipete" ]; then
      echo "PR #$num ($branch by @$author, draft=$draft) — same-repo branch — can investigate locally"
    else
      echo "PR #$num ($branch by @$author, draft=$draft) — fork branch — needs author/maintainer action"
    fi
  fi
done
