# Governance

CodexBar is maintained as a public, community-facing project. This document explains
how decisions are made, how responsibilities are assigned, and how the project avoids
depending on any one person's undocumented knowledge.

## Scope

This is a lightweight governance model. It applies to code, documentation, releases,
security-sensitive behavior, and project operations. Provider terms of service,
platform policies, and the project's security reporting process still apply.

## Roles

### Contributors

Contributors can open issues, propose pull requests, review changes when invited, and
help reproduce reports. A contribution does not create a commitment to merge or
maintain it.

### Maintainers

Maintainers are people with repository write or administrative access who accept
responsibility for reviewing changes, making final technical decisions, and preserving
the project's quality and safety. At least one maintainer must remain accountable for
each merged change, even when the author is a maintainer.

The maintainer who merges a change is responsible for confirming that the required
review, validation, and release implications have been addressed. Emergency bypasses
of normal controls must be documented in a follow-up issue or pull request.

### Functional owners

Maintainers may assign functional ownership for high-risk areas. An owner is not a
separate permission level; it is an explicit responsibility to review, document, and
keep an area healthy.

High-risk areas include:

- release signing, notarization, update feeds, and package distribution;
- provider authentication, browser cookies/local storage, Keychain access, and local
  credential files;
- security reporting and coordinated disclosure;
- CI, build tooling, and repository automation.

Owners should be recorded in `CODEOWNERS` when the project has enough active
maintainers to enforce path-specific review without blocking routine work.

## How decisions are made

### Routine changes

Routine fixes, tests, documentation updates, and contained provider improvements are
decided through a pull request. The author supplies the problem statement, the
validation performed, and any user-visible or privacy impact. Maintainers decide based
on correctness, scope, maintenance cost, and evidence.

### Significant changes

Changes that alter product direction, supported-provider boundaries, stored data,
credential access, release behavior, or ongoing operational cost should start with an
issue or design note before implementation. The proposal should state:

1. the user problem and non-goals;
2. alternatives and their tradeoffs;
3. security, privacy, and compatibility impact;
4. validation and rollback strategy; and
5. the maintainer responsible for the final decision.

Maintainers should seek rough consensus when practical. When consensus is not reached,
the responsible maintainer makes and records the decision with its rationale. A later
proposal with new evidence may revisit it.

### Security reports

Suspected vulnerabilities must be reported through GitHub's private vulnerability
reporting flow, not through a public issue. The maintainer coordinating the report owns
acknowledgement, triage, remediation planning, and safe disclosure coordination.

## Merge and release expectations

The default branch should be protected by repository rules that require a pull request,
passing required checks, and resolved review conversations. Until a repository setting
can enforce a control, maintainers must apply it manually and record exceptions.

Before merging a high-risk change, the responsible maintainer confirms that:

- validation covers the changed behavior and any relevant failure path;
- provider data, credentials, and identities remain isolated by provider;
- CI or release changes use the least permission required; and
- user-facing behavior has a safe rollback or containment path.

Before publishing a release, the release owner confirms the intended tag, signed and
notarized artifacts where applicable, checksums, update metadata, distribution assets,
and rollback instructions. A second maintainer should verify releases when practical.

## Maintainer continuity

New maintainers are invited after sustained, trustworthy contributions that demonstrate
technical judgment, respectful collaboration, and follow-through on reviews or
operational work. The project should avoid concentrating release, security, and CI
knowledge in one person:

- document recurring operational steps in the repository;
- keep sensitive credentials out of public documentation and rotate access when roles
  change;
- name a backup owner for release and security coordination when possible; and
- communicate reduced maintenance capacity rather than silently abandoning reports.

## Updating this policy

Changes to this document require a public pull request. Material changes to maintainer
responsibilities, security handling, or the decision process should include the reason
for the change and an opportunity for contributor feedback before adoption.
