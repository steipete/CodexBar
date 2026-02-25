---
summary: "Menu bar UI, icon rendering, and menu layout details."
read_when:
  - Changing menu layout, icon rendering, or UI copy
  - Updating menu card or provider-specific UI
---

# UI & icon

## Menu bar
- LSUIElement app: no Dock icon; status item uses custom NSImage.
- Merge Icons toggle combines providers into one status item with a switcher.
- When Overview has selected providers, the switcher includes an Overview tab that renders up to 3 provider rows.
- Overview row order follows provider order; selecting a row jumps to that provider detail card.

## Icon rendering
- 18×18 template image.
- Top bar = 5-hour window; bottom hairline = weekly window.
- Fill represents percent remaining by default; “Show usage as used” flips to percent used.
- Dimmed when last refresh failed; status overlays render incident indicators.
- Advanced: menu bar can show provider branding icons with a percent label instead of critter bars.

## Menu card
- Session + weekly rows with resets (countdown by default; optional absolute clock display).
- Codex-only: Credits + “Buy Credits…” in-card action.
- Web-only rows (when OpenAI cookies are enabled): code review remaining, usage breakdown submenu.
- Token accounts: optional account switcher bar or stacked account cards (up to 6) when multiple manual tokens exist.

## Pace tracking

Pace compares your actual usage against an even-consumption budget that would spread your allowance evenly across the reset window.

- **On pace** – usage matches the expected rate.
- **X% in deficit** – you're consuming faster than the even rate; at this pace you'll run out before the window resets.
- **X% in reserve** – you're consuming slower than the even rate; you have headroom to spare.

When usage is in deficit, the right-hand label shows an estimated "Runs out in …" countdown. When usage will last until the reset, it shows "Lasts until reset".

Pace is calculated for Codex and Claude weekly windows only and is hidden when less than 3% of the window has elapsed.

## Preferences notes
- Advanced: “Disable Keychain access” turns off browser cookie import; paste Cookie headers manually in Providers.
- Display: “Overview tab providers” controls which providers appear in Merge Icons → Overview (up to 3).
- If no providers are selected for Overview, the Overview tab is hidden.
- Providers → Claude: “Keychain prompt policy” controls Claude OAuth prompt behavior (Never / Only on user action /
  Always allow prompts).
- When “Disable Keychain access” is enabled in Advanced, the Claude keychain prompt policy remains visible but is
  inactive.

## Widgets (high level)
- Widget entries mirror the menu card; detailed pipeline in `docs/widgets.md`.

See also: `docs/widgets.md`.
