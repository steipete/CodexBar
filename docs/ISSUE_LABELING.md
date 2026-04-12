---
summary: "Issue labeling policy for triage, prioritization, and backlog hygiene."
read_when:
  - Triageing GitHub issues
  - Adding or updating issue labels
  - Organizing the backlog
---

# Issue labeling guide

This repo uses labels to make the issue tracker easier to scan by:

- **type** — what kind of issue is this?
- **priority** — how urgent is it?
- **area** — what subsystem is affected?
- **provider** — which provider/service is involved?
- **workflow state** — what kind of follow-up is needed?

The goal is not to perfectly label everything. The goal is to make open issues easy to sort into:

- what is broken now,
- what needs maintainer attention,
- what is accepted backlog,
- and what belongs to a specific provider or subsystem.

## Labeling rules

For most open issues, aim to apply:

- **1 type label**
- **1 priority label**
- **1 workflow label**
- **1 area label**
- **0–1 provider labels**

That means most issues should end up with **3–5 labels max**.

## Type labels

Use the existing GitHub-style labels:

- `bug` — broken behavior, crash, mismatch, false negative, bad parsing, auth failure
- `enhancement` — feature request, UX improvement, support for a new workflow
- `documentation` — docs, onboarding, missing setup guidance
- `question` — only for issues that are primarily asking for clarification or support

Avoid using `question` as a generic fallback when the issue is actually a bug or feature request.

## Priority labels

- `priority:high` — crashes, install failures, auth/account breakage, provider unusable, severe resource issues
- `priority:medium` — real issue or good feature request, but not urgent
- `priority:low` — minor polish, optional UX improvements, long-tail backlog

## Workflow labels

- `needs-triage` — new issue that has not been categorized yet
- `needs-repro` — needs logs, screenshots, exact steps, or a current repro
- `needs-design` — valid request, but needs a product/UX decision before implementation
- `blocked-upstream` — likely caused or limited by upstream provider behavior
- `accepted` — intentionally kept open as part of the backlog/roadmap

## Area labels

- `area:auth-keychain` — keychain prompts, login state, token refresh, account switching
- `area:install-distribution` — Homebrew, packaging, launch/install failures, binary detection
- `area:usage-accuracy` — usage %, reset windows, plan parsing, cost/token math
- `area:performance` — CPU, battery, memory, background sessions/process churn
- `area:ui-ux` — menu bar behavior, settings, copy, visual layout, interaction polish
- `area:widget` — widget registration, app groups, widget gallery visibility
- `area:docs-onboarding` — setup docs, onboarding docs, missing instructions
- `area:notifications` — threshold alerts, prompt waiting, quota notifications
- `area:export-integration` — Prometheus, HTTP server mode, external integrations
- `area:accounts` — multiple accounts, account discovery, account switching UX

## Provider labels

Only apply one when a provider is clearly the main subject:

- `provider:claude`
- `provider:codex`
- `provider:cursor`
- `provider:copilot`
- `provider:gemini`
- `provider:alibaba`
- `provider:factory`
- `provider:antigravity`
- `provider:opencode`
- `provider:zai`
- `provider:openrouter`

Not every issue needs a provider label.

## Close-time labels

These are mostly useful when resolving issues, not as backlog-organizing labels:

- `duplicate`
- `invalid`
- `wontfix`
- `stale`

## Recommended minimum viable label set

If starting from a sparse tracker, add these first:

### Priority
- `priority:high`
- `priority:medium`
- `priority:low`

### Workflow
- `needs-triage`
- `needs-repro`
- `needs-design`
- `accepted`

### Area
- `area:auth-keychain`
- `area:install-distribution`
- `area:usage-accuracy`
- `area:performance`
- `area:ui-ux`
- `area:widget`
- `area:docs-onboarding`

### Provider
- `provider:claude`
- `provider:codex`
- `provider:cursor`
- `provider:copilot`

This smaller set already gives most of the value.

## Examples

### Example 1 — severe Claude keychain issue
Issue: repeated Claude keychain prompts, user can’t keep the app running normally.

Suggested labels:
- `bug`
- `priority:high`
- `area:auth-keychain`
- `provider:claude`

### Example 2 — roadmap feature
Issue: multiple account support.

Suggested labels:
- `enhancement`
- `priority:high`
- `area:accounts`
- `needs-design`

### Example 3 — needs better repro
Issue: generic usage mismatch with unclear screenshots and no exact values.

Suggested labels:
- `bug`
- `priority:medium`
- `area:usage-accuracy`
- `needs-repro`

### Example 4 — accepted backlog UI request
Issue: show burn rate / pacing indicators.

Suggested labels:
- `enhancement`
- `priority:medium`
- `area:usage-accuracy`
- `accepted`

## Suggested rollout

1. **Create the new labels**
2. **Backfill the top-priority open issues first**
   - all `priority:high` bugs
   - major roadmap items
   - maintainer-triage issues
3. **Apply labels to new issues at intake**
4. **Backfill older backlog issues gradually**

## Practical guidance

- Prefer **fewer, clearer labels** over many vague labels.
- Do not label everything `question`.
- Do not use both `needs-repro` and `accepted` on the same issue unless there is a strong reason.
- If an issue is provider-specific, add the provider label early.
- If an issue is obviously real and intended to stay open, add `accepted` so it doesn’t look abandoned.

## Current workflow-specific labels

These already exist and should stay scoped to their current purpose:

- `upstream-sync`
- `needs-review`
- `changes requested`

They should not replace the general issue triage labels above.
