# Contributing to CodexBar

Thanks for helping make CodexBar more accurate, private, and reliable. This guide is the contributor entry point; follow the linked docs for provider, development, and release details.

## What to work on

The decision boundary in [VISION.md](VISION.md) is canonical.

Usually welcome as a focused pull request:

- Reproducible bug fixes and parser compatibility fixes.
- Focused tests, performance improvements, and documentation corrections.
- Small UI improvements and provider updates that follow existing descriptor, strategy, settings, and test patterns.

Start an issue and wait for maintainer sign-off before implementing:

- New features, providers that need a new host API, or meaningful UI/UX changes.
- Changes to authentication, browser cookies, Keychain access, privacy, local storage, refresh policy, or releases.
- New dependencies, toolchain changes, broad refactors, or architectural changes.

For a small documentation, test, or clearly bounded bug fix, a direct PR is fine. Link the relevant issue whenever there is one.

## Set up and develop

- macOS app development requires macOS 14+ and Swift 6.2+.
- Read [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for build, test, and local-launch commands.
- Read [docs/provider.md](docs/provider.md) before adding or changing a provider.
- Keep changes small and reuse existing typed helpers and descriptor-driven provider plumbing.

Do not run live account probes, browser-cookie imports, real Keychain reads, or `codexbar usage` against a real account merely to validate a contribution. Use fixtures, parsers, test stores, and no-UI Keychain seams unless the maintainer has explicitly asked for live validation.

## Validate your change

Every code change must pass:

```bash
make check
make test
```

Also run focused tests for the changed provider, parser, CLI, or model when possible. UI changes need a screenshot or recording from the freshly built bundle. Logic changes need enough commands, tests, or redacted output for a reviewer to confirm the behavior without access to your account.

New provider work must include the relevant descriptor and registry wiring, focused tests, icon/docs updates, and any Linux CLI coverage that applies. See the provider authoring checklist for the complete flow.

## Pull request expectations

- Keep the PR to one problem and avoid unrelated formatting or refactors.
- Use a concise PR title: `fix(scope): summary`, `feat(scope): summary`, `docs: summary`, `test: summary`, `refactor(scope): summary`, or `chore: summary`.
- Explain the problem, the change, and the validation in your own words. AI-assisted work is welcome when the author understands and takes responsibility for it; do not submit a generated wall of text in place of evidence.
- Include before/after proof for UI changes and redacted, reproducible proof for behavior changes.
- Never include API keys, cookies, Authorization headers, account files, personal identifiers, or unredacted logs.

The PR template turns these requirements into a review checklist.

## Security and support

- Report security vulnerabilities privately using the process in [SECURITY.md](SECURITY.md), not in a public issue.
- Use [SUPPORT.md](SUPPORT.md) to choose between a bug, a feature, a provider request, and a support question.
- The issue label taxonomy is documented in [docs/ISSUE_LABELING.md](docs/ISSUE_LABELING.md).
