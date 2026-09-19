# PR #3751 evidence

This directory contains reproducible, non-secret evidence for the v0 provider and
the four-row provider switcher layout.

## v0 live API proof

`pr-3751-v0-cli-output.json` is a redacted capture from the freshly rebuilt local
helper binary. It was run with:

```text
/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI usage --provider v0 --format json --pretty --no-color
```

The response came from `source=api` with `dataConfidence=exact`, and includes both
the billing and rate-limit results. No API key is included.

## Native layout proof

`pr-3751-switcher-native-proof.png` is rendered by the AppKit
`StatusMenuSwitcherLayoutNativeProofTests` test against the current branch. The
companion `pr-3751-switcher-geometry.json` records the measured row geometry:
13 providers are laid out as 3 / 4 / 4 / 3, with the shorter rows centered.

The local `/Applications/CodexBar.app` bundle was rebuilt from this revision and
restarted before collecting the live CLI proof.
