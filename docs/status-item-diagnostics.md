---
summary: "Opt-in startup traces for missing Tahoe menu bar items."
read_when:
  - Investigating missing status items or Control Center hosting
  - Preparing a diagnostic build for issue 3377
---

# Status-item startup diagnostics

Set `CODEXBAR_STATUS_ITEM_DIAGNOSTICS=1` when launching a build containing this diagnostic.
It writes newline-delimited JSON to stdout, capped at 128 records per process. No logging is enabled by default.
There is no new UI, permission request, or recovery behavior. The trace does not read credentials or capture pixels.
Normal application startup still runs normally, including configured provider refreshes.

The stages are `will-finish-launching`, `did-finish-launching`, `created` (zero width), `named`, `sized`,
`rendered`, `startup-check` (about two seconds), and `settled` (about 15 seconds). Later creation/recovery can
produce additional creation records within the cap. Timestamps use system uptime.

Each record includes the autosave identity, visibility, length, main-thread and application-running state,
activation policy (`0` regular, `1` accessory, `2` prohibited), AppKit button/window number and frames,
and screen frames. Rendered/check/settled records also include expected visibility and the `VisibleCC` default.
Recognized empty SwiftUI Settings windows are listed by number, geometry, and visibility, without titles.
This lets us identify a reported 900×450 window instead of inferring its purpose from its size.

`controlCenter` contains the total layer-25 window count, sorted window numbers, unnamed-window count,
and all candidates matching the item's autosave name (number, Quartz bounds, onscreen state).
Other applications' window titles and provider/account content are never included. `windowQuerySucceeded=false`
means the window-server query failed, not that Control Center has zero windows.

A named match is a **candidate**, not proof of hosting or rendered pixels: names can collide, window names can
be redacted, and AppKit and Quartz use different coordinate systems. An empty match must not trigger recovery
by itself. Compare the whole Control Center window-number set before creation and after settling, and compare
AppKit geometry to the candidate Quartz geometry. The trace itself queries AppKit and WindowServer, so it can
perturb a timing-sensitive failure; report if enabling it changes the symptom.

## Reporter capture

Use a maintainer-signed diagnostic app containing this change. For #3377, it must keep the production
`com.steipete.codexbar` identity and Developer ID; the ordinary debug package has a different bundle identity
and is only a separate control experiment. Do not reset preferences or move group containers for this capture.

Quit the existing CodexBar instance once before starting the diagnostic copy, so two instances do not compete
for the same autosave name. Then run the supplied app executable directly (adjust the app path):

```sh
umask 077
CODEXBAR_STATUS_ITEM_DIAGNOSTICS=1 \
  /path/to/CodexBar.app/Contents/MacOS/CodexBar > "$HOME/Desktop/codexbar-status-items.jsonl"
```

Wait at least 20 seconds. Record whether the icon appeared, whether Bartender was running, and whether the
allow-list toggle remained on. Quit the diagnostic app normally or end this foreground run with Control-C,
then return to the installed app. No persistent environment or settings change is needed.
Inspect the JSON file before sharing it; send it with the build commit and the observed symptom. Do not attach
unrelated application logs. Repeat once with Bartender already quit only if the first capture is inconclusive.

## Maintainer build recipe

Build **debug only** from the diagnostic commit. A local control build can use
`CODEXBAR_SIGNING=identity ./Scripts/package_app.sh debug`; it does not relaunch the app, but its
`com.steipete.codexbar.debug` identity cannot establish a fix for the production identity.

For the reporter's production-identity comparison, stage a copy of a current official signed bundle and replace
only its main executable and SwiftPM resources. The template must use this checkout's dependency versions.
Run these commands in the diagnostic checkout; no command launches or overwrites the installed app:

```sh
swift build --configuration debug --jobs 2 --product CodexBar
mkdir -p .build/control-center-diagnostic
codesign -d --entitlements :- /Applications/CodexBar.app \
  > .build/control-center-diagnostic/entitlements.plist 2>/dev/null
ditto /Applications/CodexBar.app .build/control-center-diagnostic/CodexBar.app
cp .build/debug/CodexBar .build/control-center-diagnostic/CodexBar.app/Contents/MacOS/CodexBar
install_name_tool -add_rpath '@executable_path/../Frameworks' \
  .build/control-center-diagnostic/CodexBar.app/Contents/MacOS/CodexBar
for bundle in .build/debug/*.bundle; do
  ditto "$bundle" ".build/control-center-diagnostic/CodexBar.app/Contents/Resources/$(basename "$bundle")"
done
/usr/libexec/PlistBuddy -c "Set :CodexGitCommit $(git rev-parse HEAD)" \
  .build/control-center-diagnostic/CodexBar.app/Contents/Info.plist
codesign --force --timestamp --options runtime \
  --entitlements .build/control-center-diagnostic/entitlements.plist \
  --sign 'Developer ID Application: Peter Steinberger (Y5PE65HELJ)' \
  .build/control-center-diagnostic/CodexBar.app
codesign --verify --deep --strict .build/control-center-diagnostic/CodexBar.app
```

Use the normal [notarization instructions](RELEASING.md) for any externally delivered artifact, without
publishing a release or updating the appcast. Do not give a reporter an unsigned/ad-hoc replacement or tell them
to bypass Gatekeeper. The recipe requires the maintainer's signing identity; a reporter should receive the
finished signed/notarized artifact. Building and tracing are diagnostics, not a demonstrated fix for #3377.
