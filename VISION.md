# Vision

CodexBar is the menu bar control surface for AI provider limits, credits, spend, status, and reset windows. It should keep adding useful provider coverage while preserving fast refreshes, privacy-first local data handling, and shared provider-driven UI instead of one-off surfaces.

## Merge by Default

- Performance improvements, unless they add too much complexity.
- Bug fixes with clear cause and bounded risk.
- New model/provider support that follows existing descriptor, strategy, settings, and test patterns.
- Small UI or UX tweaks.
- Documentation fixes.

## Needs Sign-Off

- New features.
- Package, dependency, or toolchain changes.
- Broad refactors or architecture changes.
- Changes that add meaningful maintenance complexity.
- Behavior changes that affect provider auth, data storage, releases, or user privacy.
- Provider additions that need new host APIs, bespoke UI, broad filesystem access, or unclear auth/privacy behavior.

## Platform Scope

- macOS is the home of the UI: the menu bar app, widgets, and any future native surfaces.
- The CLI (`codexbar`) is cross-platform: macOS and Linux are supported today, with feature parity for usage, cost, serve, and hooks wherever platform APIs allow.
- Windows is an aspiration, not a commitment: if Swift's Windows support matures enough to stop fighting us, shipping the CLI (and eventually more) there would be welcome. Contributions keeping the core portable are valued now.
- Desktop-environment integrations beyond macOS (KDE widgets, GNOME extensions, etc.) belong in separate, community-maintained projects consuming `codexbar serve` or `codexbar usage --json`; we link good ones from the README rather than absorbing them.
