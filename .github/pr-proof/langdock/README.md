# Langdock menu presentation proof

Rendered from production `UsageMenuCardView` with synthetic parser responses, a fixed clock, English
localization, and no account information. These images demonstrate presentation, not a live browser
import or packaged-app acceptance.

Packaged-build identities, the controlled host attempt, recovery, and remaining acceptance cases
are recorded in [acceptance.md](acceptance.md).

- `langdock-active.png`: session 23% and weekly 54% used.
- `langdock-weekly-only.png`: disabled session limits leave the weekly value visible.
- `langdock-stale.png`: a transient HTTP 503 leaves the retained values and their original 15-minute age visible.

Regenerate in a macOS graphical session with the repository's isolated test environment:

```sh
CODEXBAR_LANGDOCK_PROOF_DIR=/tmp/codexbar-langdock-proof \
  ./Scripts/test_fast.sh --filter LangdockScreenshotRenderTests
```

The rendering test skips without the explicit output-directory environment variable. Parser, session,
and menu-model assertions run independently without browser-cookie or Keychain access.
