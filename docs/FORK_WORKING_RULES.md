# Fork working rules

This repository is a private downstream copy of upstream `steipete/CodexBar`.

## Main rule
Design changes so future upstream syncs stay easy.

When choosing between two implementations, prefer the one that is easier to merge with future upstream changes.

## Prefer
- additive changes
- localized changes
- minimal diffs
- isolated helpers
- feature flags or settings when possible
- preserving upstream file structure and naming unless there is a strong reason not to

## Avoid
- broad refactors without a clear payoff
- unnecessary renames or file moves
- formatting churn unrelated to the feature
- invasive edits in likely upstream hotspot files unless necessary
- changing shared abstractions more than needed for the feature

## Working lens
Before making a change, ask:
1. Is this the smallest change that solves the problem?
2. How likely is this area to change upstream?
3. Can this be implemented in a more isolated way?
4. Will this make future merges or rebases harder?

## Goal
Keep this fork easy to evolve while still being able to regularly import improvements from upstream CodexBar.
