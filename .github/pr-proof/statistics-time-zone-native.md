# Statistics time zone: native interaction proof

The debug application was freshly built from `7916c6e7d9eb1ca82971af64bab8f92cb089f692` with `CODEXBAR_SIGNING=adhoc ./Scripts/package_app.sh debug`. The following changes add evidence only; the application sources match that build. All screenshots show its real Settings → Usage & Spend window. The original offscreen screenshots remain useful for English/Chinese narrow-layout coverage.

## Isolation and launch

The packaged application was copied to a temporary directory, given the distinct bundle ID `com.example.codexbar.timezoneproof` and display name `CodexBar Time Zone Proof`, and signed ad hoc. Its standard preferences use that distinct domain. `CFFIXED_USER_HOME` points to a temporary home, so Foundation's cache directory and the cost database are isolated from the installed application. `CODEX_HOME` and `CODEXBAR_CONFIG` point to synthetic inputs. Codex alone is enabled for local session history; no account credentials are present.

The child process also receives `SWIFT_TESTING=1`, `CODEXBAR_DISABLE_KEYCHAIN_ACCESS=1`, `CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1`, `CODEXBAR_TEST_CODEX_FILE_ISOLATION=1`, and `CODEXBAR_TEST_SESSION_FILE_ISOLATION=1`. The existing test startup mode suppresses provider background fetching and settings migration. Refresh frequency is Manual, web access is disabled, and iCloud sync is disabled. The installed application's process remains running throughout.

The debug-only `--spend-time-zone-proof` argument opens the normal `SettingsWindowController` at launch, provided the existing test mode and a temporary home are set. It does not substitute a preview, dashboard controller, data loader, picker, or button. This entry is absent from release builds.

## Input and observed behavior

[The synthetic JSONL session](statistics-time-zone-fixture.jsonl) contains one token-count event at `2026-10-02T01:00:00Z`: 1,000,000 input tokens and 100,000 output tokens for `gpt-5.2-codex`. It contains no prompts or private account data. The normal scanner reports 1.1M tokens and a $3.15 list-price estimate in the selected 7-day range.

The initial preference was seeded to `America/Detroit`. Every subsequent time-zone change was made by clicking the real picker or current-zone button. Native accessibility observations are recorded in [the interaction receipt](statistics-time-zone-native.log).

| Action | Selected zone | Nonzero daily bucket | Total |
| --- | --- | --- | --- |
| Open Usage & Spend | America/Detroit | October 1 | $3.15 / 1.1M tokens |
| Select Asia/Shanghai in the menu | Asia/Shanghai | October 2 | $3.15 / 1.1M tokens |
| Close Settings and reopen with Command-comma | Asia/Shanghai | October 2 | $3.15 / 1.1M tokens |
| Quit and cold-launch the application | Asia/Shanghai | October 2 | $3.15 / 1.1M tokens |
| Click Use Mac's current time zone | America/Detroit | October 1 | $3.15 / 1.1M tokens |
| Quit and cold-launch again | America/Detroit | October 1 | $3.15 / 1.1M tokens |

The Mac's current zone remained `America/Detroit` throughout. The Shanghai cold launch therefore also confirms that a saved selection stays pinned independently of the Mac's zone. Reads of `tokenCostUsageBucketTimeZone` in the proof-only preferences domain confirmed `Asia/Shanghai` after the picker and `America/Detroit` after the button. No manual Refresh click was needed for either time-zone change.

## Screenshots

- [Initial Detroit selection](../../docs/screenshots/statistics-time-zone-native-detroit.jpg)
- [Shanghai selection and refreshed chart](../../docs/screenshots/statistics-time-zone-native-shanghai.jpg)
- [Shanghai selection after cold launch](../../docs/screenshots/statistics-time-zone-native-restarted-shanghai.jpg)
- [Current-zone button returns the chart to Detroit](../../docs/screenshots/statistics-time-zone-native-current-zone-button.jpg)
