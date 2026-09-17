# Share snapshot reporting date

The shared card displayed September 17 during a September 16 native proof. The dashboard chart deliberately extends to the next day's start, but the share payload used that chart endpoint as its human-facing “Data through” date. [Original native proof](https://github.com/Chipagosfinest/CodexBar/actions/runs/35083394374).

The builder now names the last included civil day using the currency group's calendar and carries its timezone into the common image/text formatter. Chart intervals, spend totals, and token totals remain unchanged. The date describes the selected reporting window, not the last observed usage event.

Seven real-dashboard regression cases cover UTC, UTC+14, Los Angeles, spring/fall DST, Santiago's midnight DST transition, and year-end. The focused ShareStats and provider-architecture run passes 57 tests in three suites. The unchanged model-family sanitizer's architecture anchor moves with the new payload field; its reason, provider IDs, and fingerprint are preserved.

The optional `CODEXBAR_SHARE_STATS_SCREENSHOT_DIR` fixture renders both states with the production renderer. The before payload recreates the old next-day boundary and current-timezone formatter inputs; the after payload comes from the corrected builder. With `TZ=America/Los_Angeles`, identical synthetic September 16 usage produces a September 17 before footer and September 16 after footer. Both complete images were visually inspected; they contain synthetic aggregate usage only.

Primary API reference: [Apple Calendar dateInterval(of:for:)](https://developer.apple.com/documentation/foundation/calendar/dateinterval(of:for:)). The calculation uses an instant inside the chart boundary and the calendar's start of day, rather than assuming every day lasts 24 hours.

![Synthetic September 16 snapshot with corrected footer](https://github.com/user-attachments/assets/1b0efe48-0581-479d-82ab-43225d932778)
