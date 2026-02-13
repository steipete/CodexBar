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

## Preferences notes
- Advanced: “Disable Keychain access” turns off browser cookie import; paste Cookie headers manually in Providers.
- Providers → Claude: “Keychain prompt policy” controls Claude OAuth prompt behavior (Never / Only on user action /
  Always allow prompts).
- When “Disable Keychain access” is enabled in Advanced, the Claude keychain prompt policy remains visible but is
  inactive.

## Widgets (high level)
- Widget entries mirror the menu card; detailed pipeline in `docs/widgets.md`.

See also: `docs/widgets.md`.
