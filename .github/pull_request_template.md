## Summary

<!-- Briefly state the user-visible or maintainer-visible change. -->

## Why

<!-- Explain the problem and why this is the right scope. -->

## Linked issue or maintainer sign-off

<!--
Use `Fixes #123`, `Closes #123`, or `Resolves #123` when this PR completely
addresses an issue. This creates GitHub's closing link and closes the issue on
merge to the default branch.

Use `Refs #123` only for related context that does not fully resolve the issue.
If no issue applies, write `No linked issue: <reason>` or describe the requested
maintainer sign-off.
-->

## Validation

<!-- List commands, focused tests, and redacted reproduction evidence. -->

## UI proof

<!-- For visible UI changes, include before/after proof from a freshly built bundle. Otherwise say `Not applicable`. -->

## Provider and privacy impact

<!-- State `None` or describe providers, source modes, Keychain/cookie/local-data access, and redaction handling. -->

## Checklist

- [ ] This PR is focused and contains no unrelated changes.
- [ ] I ran `make check` and the relevant focused tests.
- [ ] I ran `make test`, or explained why it was not practical.
- [ ] UI changes include visual proof; logic changes include reproducible evidence.
- [ ] I did not include credentials, cookies, Authorization headers, account files, or unredacted personal data.
- [ ] Provider data remains siloed and this change does not create an unbounded network, PTY, or UI wait.
