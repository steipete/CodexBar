# Linux and Mac desktop comparison

This comparison uses the Mac implementation in this checkout, not a claim that
the two apps have matching interfaces.

| Area | Mac implementation | Linux desktop |
| --- | --- | --- |
| Settings | Sidebar with General, Providers, Menu, Menu Bar, and other panes (`PreferencesView.swift`) | General, Providers, Advanced tabs; fewer controls fit better in tiled windows |
| Usage layout | Adaptive metric/reset rows (`UsageMenuCardHeaderAndUsageSectionView.swift`) | Wrapping labels, compact cards, quota, reset countdown, pace and provider details |
| Refresh | Interval and refresh-on-open preferences (`PreferencesGeneralPane.swift`) | Interval and optional refresh-on-open; Usage and Spending refresh independently |
| Provider accounts | Provider ordering and login/account actions (`PreferencesProvidersPane.swift`) | CLI-discovered provider picker and ordered custom list; account selection; Codex/Claude sign-in and confirmed sign-out through a terminal |
| Tray | Configurable icons, layout and pace color (`PreferencesMenuBarPane.swift`) | Two quota meters for the first displayed provider, low-quota/stale styling, optional static icon, and usage tooltip; Omarchy shares display preferences |
| Display preferences | Reset format, pace visibility, warning markers (`PreferencesMenuPane.swift`) | Used/remaining quota, countdown/absolute/both reset formats, pace visibility and warning colors |
| Local costs | Cost summaries and fetch status (`PreferencesMenuPane.swift`) | Separate Spending tab with daily history, coverage and token totals; retains stale data on failure |
| Startup | Start-at-login toggle (`PreferencesGeneralPane.swift`) | Immediate start-at-login control backed by XDG autostart |

Omarchy colors can follow its current theme, with the system palette as fallback.
Other Linux desktops use Qt's system palette. Source builds and a tested portable
archive installer are available; the archive requires compatible system Qt/glibc
libraries and a separately installed CodexBar CLI.

Mac-only managed account profiles, token-account editing, browser credential
imports, advanced menu-bar layout/pace coloring, and macOS-specific surfaces remain
outside this Linux frontend. The Linux sign-in controls operate on the provider
CLI's active session; they do not create or switch saved Mac profiles. KDE/GNOME
sessions and distro-native packages still need separate compatibility work.
