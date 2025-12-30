# Session Summary

## Overview
This file was stale. `Scripts/build_unsigned.sh` is not present in this checkout. The build flow now uses
`Scripts/compile_and_run.sh` with an automatic ad-hoc signing fallback when a Developer ID identity is missing.

## Build Without Developer ID Signing
- Preferred: `./Scripts/compile_and_run.sh`
  - If codesigning fails with "no identity found", it retries with `CODEXBAR_SIGNING=adhoc`.
- Manual packaging: `CODEXBAR_SIGNING=adhoc ./Scripts/package_app.sh`

## Notes
- Ad-hoc signing disables Sparkle feed checks for the build.
