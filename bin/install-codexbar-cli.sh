#!/bin/sh -p
# -p blocks inherited functions and startup hooks before validation; it does not elevate privileges.
set -eu

APP="/Applications/CodexBar.app"
HELPER="$APP/Contents/Helpers/CodexBarCLI"

if [ ! -x "$HELPER" ]; then
  /bin/echo "CodexBarCLI helper not found at $HELPER. Please reinstall CodexBar." >&2
  exit 1
fi

# Clear startup hooks and exported functions before entering the administrator shell.
/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/osascript - "$HELPER" <<'APPLESCRIPT'
on run argv
  set helperPath to item 1 of argv
  set installCommand to "set -eu" & linefeed & ¬
    "/bin/mkdir -p /usr/local/bin /opt/homebrew/bin" & linefeed & ¬
    "/bin/ln -sf " & quoted form of helperPath & " /usr/local/bin/codexbar" & linefeed & ¬
    "/bin/ln -sf " & quoted form of helperPath & " /opt/homebrew/bin/codexbar"

  do shell script installCommand with administrator privileges
end run
APPLESCRIPT

/bin/echo "CodexBar CLI installed. Try: codexbar usage"
