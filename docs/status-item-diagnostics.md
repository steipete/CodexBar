---
summary: "Opt-in startup traces for missing Tahoe menu bar items."
read_when:
  - Investigating missing status items or Control Center hosting
  - Preparing a diagnostic build for issue 3377
---

# Status-item startup diagnostics

Launch with `CODEXBAR_STATUS_ITEM_DIAGNOSTICS=1` to write newline-delimited JSON to stdout, capped at 128 records per process. Logging defaults off. Tracing adds no UI, permission requests, or recovery behavior, reads no credentials, and captures no pixels. Normal startup still includes configured provider refreshes.

Stages: `will-finish-launching`, `did-finish-launching`, `created` (zero width), `named`, `sized`, `rendered`, `startup-check` (about two seconds), and `settled` (about 15 seconds). A startup recreation adds `startup-recovery-check` immediately after rendering the replacement. Both check stages include `context.startupAge` (seconds since scheduling) and `context.recoveryEligible` (the actual recovery decision). Later creation/recovery can add records within the cap. Timestamps use system uptime.

Records include autosave identity, visibility, length, main-thread/running state, activation policy (`0` regular, `1` accessory, `2` prohibited), AppKit button/window numbers and frames, and screen frames. Rendered/check/settled records add expected visibility and the `VisibleCC` default. Recognized empty SwiftUI Settings windows include number, geometry, and visibility, without titles; size alone does not identify a window.

`menuBarHosts` contains the layer-25 window count, sorted window numbers, counts by owner, unnamed count, and autosave-name candidates (number, owner, Quartz bounds, onscreen state). It includes Control Center/Control Centre and MenuBarAgent, which hosts status items on macOS 27. Older captures called this field `controlCenter` and excluded MenuBarAgent; a zero count in those captures does not establish a macOS 27 hosting failure. It excludes other apps' window titles and provider/account content. `windowQuerySucceeded=false` means the query failed, not zero windows.

A named match is only a **candidate**: names can collide or be redacted, and AppKit/Quartz coordinates differ. Do not infer hosting/rendered pixels from a match or trigger recovery from an empty match. Compare the full host window-number set and owner counts before creation and after settling, plus AppKit and candidate Quartz geometry. AppKit/WindowServer queries can perturb timing-sensitive failures; report if tracing changes the symptom.

For a missing AppKit window, check the startup age and recovery decision, then compare the replacement's immediate
`startup-recovery-check` with the later `settled` sample. Eligibility is not proof that the replacement was hosted or
rendered. The existing recovery check uses button width and window presence, not window height; preserve zero-height
frames in reports and compare them with a healthy item on the same OS before attributing them to a failed host.

## Reporter capture

Use a maintainer-signed diagnostic app. For #3377, preserve the production `com.steipete.codexbar` identity and Developer ID; an ordinary debug package has a different identity and serves only as a control. Do not reset preferences or move group containers.

Quit the existing CodexBar instance once before starting the diagnostic copy, so two instances do not compete
for the same autosave name. Then launch the supplied app through LaunchServices (adjust the app path), avoiding
the terminal's process responsibility being inherited by a directly executed app:

```sh
umask 077
open -a /path/to/CodexBar.app \
  --env CODEXBAR_STATUS_ITEM_DIAGNOSTICS=1 \
  --stdout "$HOME/Desktop/codexbar-status-items.jsonl"
```

Wait at least 20 seconds. Record whether the icon appeared, whether Bartender was running, and whether the
allow-list toggle remained on. Quit the diagnostic app normally, then return to the installed app.
No persistent environment or settings change is needed.
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
diagnostic_bin_dir="$(swift build --configuration debug --show-bin-path)"
mkdir -p .build/control-center-diagnostic
codesign -d --entitlements :- /Applications/CodexBar.app \
  > .build/control-center-diagnostic/entitlements.plist 2>/dev/null
ditto /Applications/CodexBar.app .build/control-center-diagnostic/CodexBar.app
cp "$diagnostic_bin_dir/CodexBar" .build/control-center-diagnostic/CodexBar.app/Contents/MacOS/CodexBar
install_name_tool -add_rpath '@executable_path/../Frameworks' \
  .build/control-center-diagnostic/CodexBar.app/Contents/MacOS/CodexBar
for bundle in "$diagnostic_bin_dir"/*.bundle; do
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
