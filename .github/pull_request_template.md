## Summary

## Why

## Linked issue or maintainer sign-off

## Validation

Commands, focused tests, and redacted reproduction evidence.

## UI proof

Required for visible UI changes: before/after screenshot or recording from the freshly built bundle.

## Provider and privacy impact

State `None` or describe affected providers, source modes, Keychain/cookie/local-data access, and redaction handling.

## Checklist

- [ ] This PR is focused and contains no unrelated changes.
- [ ] I ran `make check` and the relevant focused tests.
- [ ] I ran `make test`, or explained why it was not practical.
- [ ] UI changes include visual proof; logic changes include reproducible evidence.
- [ ] I did not include credentials, cookies, Authorization headers, account files, or unredacted personal data.
- [ ] Provider data remains siloed and this change does not create an unbounded network, PTY, or UI wait.
