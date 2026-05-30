#!/usr/bin/env bash
set -euo pipefail

APP="/Applications/CodexBar.app"
HELPER="$APP/Contents/Helpers/CodexBarCLI"
TARGETS=("/usr/local/bin/codexbar" "/opt/homebrew/bin/codexbar")

if [[ ! -x "$HELPER" ]]; then
  echo "CodexBarCLI helper not found at $HELPER. Please reinstall CodexBar." >&2
  exit 1
fi

osascript - "$HELPER" <<'APPLESCRIPT'
on run argv
  set helperPath to item 1 of argv
  set installCommand to "set -euo pipefail" & linefeed & ¬
    "HELPER=" & quoted form of helperPath & linefeed & ¬
    "TARGETS=(\"/usr/local/bin/codexbar\" \"/opt/homebrew/bin/codexbar\")" & linefeed & ¬
    "for t in \"${TARGETS[@]}\"; do" & linefeed & ¬
    "  mkdir -p \"$(dirname \"$t\")\"" & linefeed & ¬
    "  ln -sf \"$HELPER\" \"$t\"" & linefeed & ¬
    "  echo \"Linked $t -> $HELPER\"" & linefeed & ¬
    "done"

  do shell script "bash -c " & quoted form of installCommand with administrator privileges
end run
APPLESCRIPT

echo "CodexBar CLI installed. Try: codexbar usage"
