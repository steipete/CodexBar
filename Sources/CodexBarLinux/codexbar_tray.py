#!/usr/bin/env python3
"""
CodexBar Linux System Tray
A Python-based system tray app that wraps CodexBarCLI for Ubuntu/Linux.
Uses pystray for cross-platform tray support and polls usage periodically.
"""

import json
import os
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

# Try to import GTK/AppIndicator for proper Ubuntu tray support
try:
    import gi
    gi.require_version('Gtk', '3.0')
    gi.require_version('Gdk', '3.0')
    try:
        gi.require_version('AyatanaAppIndicator3', '0.1')
        from gi.repository import AyatanaAppIndicator3 as AppIndicator3
    except ValueError:
        gi.require_version('AppIndicator3', '0.1')
        from gi.repository import AppIndicator3
    from gi.repository import Gtk, Gdk, GLib
    HAS_GTK = True
except (ImportError, ValueError):
    HAS_GTK = False

try:
    import pystray
    from PIL import Image, ImageDraw
except ImportError:
    print("Missing dependencies. Install with: pip install pystray pillow")
    print("On Ubuntu you may also need: sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1")
    sys.exit(1)

# Configuration
REFRESH_INTERVAL_SECONDS = 60
CLI_TIMEOUT_SECONDS = 30


# Provider-specific labels for usage tiers
PROVIDER_LABELS = {
    "antigravity": {"primary": "Claude", "secondary": "Gemini Pro", "tertiary": "Gemini Flash"},
    "claude": {"primary": "Session", "secondary": "Weekly"},
    "codex": {"primary": "Session", "secondary": "Weekly"},
    "copilot": {"primary": "Premium requests", "secondary": "Usage"},
    "windsurf": {"primary": "Credits", "secondary": "Usage"},
    "gemini": {"primary": "Daily", "secondary": "Daily"},
    "cursor": {"primary": "Fast", "secondary": "Slow"},
    "zed": {"primary": "Session", "secondary": "Weekly"},
}

PROVIDER_DISPLAY_NAMES = {
    "codex": "Codex",
    "claude": "Claude",
    "gemini": "Gemini",
    "antigravity": "Antigravity",
    "cursor": "Cursor",
    "factory": "Factory",
    "windsurf": "Windsurf",
    "copilot": "Copilot",
    "zed": "Zed",
}


class UsageData:
    """Parsed usage data from CLI JSON output."""

    def __init__(self, provider: str, primary_percent: float, secondary_percent: Optional[float],
                 tertiary_percent: Optional[float], primary_reset: Optional[str],
                 secondary_reset: Optional[str], tertiary_reset: Optional[str],
                 version: Optional[str], account_email: Optional[str],
                 login_method: Optional[str] = None, updated_at: Optional[str] = None,
                 primary_used_count: Optional[float] = None, primary_total_count: Optional[float] = None,
                 secondary_used_count: Optional[float] = None, secondary_total_count: Optional[float] = None):
        self.provider = provider
        self.primary_percent = primary_percent
        self.secondary_percent = secondary_percent
        self.tertiary_percent = tertiary_percent
        self.primary_reset = primary_reset
        self.secondary_reset = secondary_reset
        self.tertiary_reset = tertiary_reset
        self.version = version
        self.account_email = account_email
        self.login_method = login_method
        self.updated_at = updated_at
        self.primary_used_count = primary_used_count
        self.primary_total_count = primary_total_count
        self.secondary_used_count = secondary_used_count
        self.secondary_total_count = secondary_total_count

    @property
    def primary_remaining(self) -> float:
        return max(0, 100 - self.primary_percent)

    @property
    def secondary_remaining(self) -> Optional[float]:
        if self.secondary_percent is None:
            return None
        return max(0, 100 - self.secondary_percent)

    @property
    def tertiary_remaining(self) -> Optional[float]:
        if self.tertiary_percent is None:
            return None
        return max(0, 100 - self.tertiary_percent)

    def get_labels(self) -> dict:
        return PROVIDER_LABELS.get(self.provider, {"primary": "Primary", "secondary": "Secondary", "tertiary": "Tertiary"})

    def has_primary_counts(self) -> bool:
        return self.primary_used_count is not None and self.primary_total_count is not None

    def has_secondary_counts(self) -> bool:
        return self.secondary_used_count is not None and self.secondary_total_count is not None

    def format_primary_usage(self) -> str:
        """Format primary usage as 'X / Y used' if counts available, else 'X%'"""
        if self.has_primary_counts():
            used = int(self.primary_used_count) if self.primary_used_count == int(self.primary_used_count) else self.primary_used_count
            total = int(self.primary_total_count) if self.primary_total_count == int(self.primary_total_count) else self.primary_total_count
            return f"{used} / {total} used"
        return f"{self.primary_remaining:.0f}%"

    def format_secondary_usage(self) -> Optional[str]:
        """Format secondary usage as 'X / Y used' if counts available, else 'X%'"""
        if self.secondary_percent is None:
            return None
        if self.has_secondary_counts():
            used = int(self.secondary_used_count) if self.secondary_used_count == int(self.secondary_used_count) else self.secondary_used_count
            total = int(self.secondary_total_count) if self.secondary_total_count == int(self.secondary_total_count) else self.secondary_total_count
            return f"{used} / {total} used"
        return f"{self.secondary_remaining:.0f}%"


class CodexBarTray:
    """Main tray application controller."""

    def __init__(self):
        self.usage_data: dict[str, UsageData] = {}
        self.last_error: Optional[str] = None
        self.last_update: Optional[datetime] = None
        self.running = True
        self.icon: Optional[pystray.Icon] = None
        self.cli_path = self._find_cli()

    def _find_cli(self) -> str:
        """Find the CodexBarCLI executable."""
        candidates = [
            Path(__file__).parent.parent.parent / ".build" / "release" / "CodexBarCLI",
            Path.home() / ".local" / "bin" / "codexbar",
            Path("/usr/local/bin/codexbar"),
        ]
        for path in candidates:
            if path.exists() and os.access(path, os.X_OK):
                return str(path)
        return "codexbar"

    def _create_icon_image(self) -> Image.Image:
        """Create a dynamic tray icon based on usage levels."""
        size = 22
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        usage = next(iter(self.usage_data.values()), None) if self.usage_data else None

        if usage:
            bar_width, bar_gap, bar_height = 6, 4, 18
            start_x = (size - (2 * bar_width + bar_gap)) // 2
            start_y = (size - bar_height) // 2

            # Primary bar
            primary_fill = int(bar_height * (usage.primary_remaining / 100))
            draw.rectangle([start_x, start_y, start_x + bar_width, start_y + bar_height],
                           outline=(200, 200, 200, 255))
            if primary_fill > 0:
                fill_y = start_y + bar_height - primary_fill
                color = self._get_color(usage.primary_remaining)
                draw.rectangle([start_x + 1, fill_y, start_x + bar_width - 1, start_y + bar_height - 1],
                               fill=color)

            # Secondary bar
            if usage.secondary_remaining is not None:
                sec_x = start_x + bar_width + bar_gap
                secondary_fill = int(bar_height * (usage.secondary_remaining / 100))
                draw.rectangle([sec_x, start_y, sec_x + bar_width, start_y + bar_height],
                               outline=(200, 200, 200, 255))
                if secondary_fill > 0:
                    fill_y = start_y + bar_height - secondary_fill
                    color = self._get_color(usage.secondary_remaining)
                    draw.rectangle([sec_x + 1, fill_y, sec_x + bar_width - 1, start_y + bar_height - 1],
                                   fill=color)
        else:
            draw.ellipse([4, 4, size - 4, size - 4], outline=(150, 150, 150, 255))
            draw.text((size // 2 - 2, size // 2 - 6), "?", fill=(150, 150, 150, 255))

        return img

    def _get_color(self, remaining: float) -> tuple:
        """Get color based on remaining percentage."""
        if remaining > 50:
            return (76, 175, 80, 255)  # Green
        elif remaining > 20:
            return (255, 193, 7, 255)  # Amber
        return (244, 67, 54, 255)  # Red

    def _fetch_usage(self):
        """Fetch usage data from CodexBarCLI."""
        all_data = []
        errors = []

        # Fetch each provider separately with appropriate source
        # Claude: use oauth (gets plan info from credentials file)
        # All others: use cli
        provider_sources = [
            ("claude", "oauth"),
            ("codex", "cli"),
            ("gemini", "cli"),
            ("antigravity", "cli"),
            ("cursor", "cli"),
            ("copilot", "cli"),
            ("windsurf", "cli"),
        ]

        for provider, source in provider_sources:
            try:
                result = subprocess.run(
                    [self.cli_path, "usage", "--provider", provider, "--format", "json", "--source", source],
                    capture_output=True, text=True, timeout=CLI_TIMEOUT_SECONDS,
                )
                if result.stdout.strip():
                    data = json.loads(result.stdout)
                    all_data.extend(data)
                elif result.stderr.strip():
                    # Skip errors for providers that aren't configured
                    err = result.stderr.strip().split("\n")[0]
                    skip_patterns = ["not installed", "not found", "no session", "no token", "not configured"]
                    if not any(p in err.lower() for p in skip_patterns):
                        errors.append(f"{provider}: {err}")
            except subprocess.TimeoutExpired:
                errors.append(f"{provider}: timeout")
            except json.JSONDecodeError:
                pass  # Skip invalid JSON
            except FileNotFoundError:
                self.last_error = f"CLI not found: {self.cli_path}"
                self.last_update = datetime.now()
                return
            except Exception as e:
                errors.append(f"{provider}: {e}")

        if all_data:
            self._parse_usage_data(all_data)
            self.last_error = None
        elif errors:
            self.last_error = "; ".join(errors[:2])  # Show first 2 errors

        self.last_update = datetime.now()

    def _parse_usage_data(self, data: list):
        """Parse the JSON response from CLI."""
        self.usage_data.clear()
        for item in data:
            provider = item.get("provider", "unknown")
            usage = item.get("usage", {})
            primary = usage.get("primary", {})
            secondary = usage.get("secondary")
            tertiary = usage.get("tertiary")
            self.usage_data[provider] = UsageData(
                provider=provider,
                primary_percent=primary.get("usedPercent", 0),
                secondary_percent=secondary.get("usedPercent") if secondary else None,
                tertiary_percent=tertiary.get("usedPercent") if tertiary else None,
                primary_reset=primary.get("resetDescription"),
                secondary_reset=secondary.get("resetDescription") if secondary else None,
                tertiary_reset=tertiary.get("resetDescription") if tertiary else None,
                version=item.get("version"),
                account_email=usage.get("accountEmail"),
                primary_used_count=primary.get("usedCount"),
                primary_total_count=primary.get("totalCount"),
                secondary_used_count=secondary.get("usedCount") if secondary else None,
                secondary_total_count=secondary.get("totalCount") if secondary else None,
            )

    def _build_menu(self) -> pystray.Menu:
        """Build the tray menu."""
        items = []

        # Usage entries for each provider
        if self.usage_data:
            for provider, usage in self.usage_data.items():
                display_name = PROVIDER_DISPLAY_NAMES.get(provider, provider.capitalize())
                labels = usage.get_labels()

                # Primary usage - use count format if available
                primary_label = labels.get("primary", "Session")
                primary_text = usage.format_primary_usage()
                items.append(pystray.MenuItem(f"{display_name}: {primary_label} {primary_text}", None, enabled=False))
                if usage.primary_reset:
                    items.append(pystray.MenuItem(f"  └ {usage.primary_reset}", None, enabled=False))

                # Secondary usage - use count format if available
                if usage.secondary_remaining is not None:
                    secondary_label = labels.get("secondary", "Weekly")
                    secondary_text = usage.format_secondary_usage()
                    items.append(pystray.MenuItem(f"  {secondary_label}: {secondary_text}", None, enabled=False))
                    if usage.secondary_reset:
                        items.append(pystray.MenuItem(f"    └ {usage.secondary_reset}", None, enabled=False))

                # Tertiary usage (e.g., Gemini Flash for Antigravity)
                if usage.tertiary_remaining is not None:
                    tertiary_label = labels.get("tertiary", "Tertiary")
                    items.append(pystray.MenuItem(f"  {tertiary_label}: {usage.tertiary_remaining:.0f}%", None, enabled=False))
                    if usage.tertiary_reset:
                        items.append(pystray.MenuItem(f"    └ {usage.tertiary_reset}", None, enabled=False))

                if usage.account_email:
                    items.append(pystray.MenuItem(f"  Account: {usage.account_email}", None, enabled=False))

                items.append(pystray.Menu.SEPARATOR)
        else:
            items.append(pystray.MenuItem("No usage data", None, enabled=False))
            items.append(pystray.Menu.SEPARATOR)

        # Error status
        if self.last_error:
            items.append(pystray.MenuItem(f"⚠ {self.last_error[:50]}", None, enabled=False))
            items.append(pystray.Menu.SEPARATOR)

        # Last update time
        if self.last_update:
            update_str = self.last_update.strftime("%H:%M:%S")
            items.append(pystray.MenuItem(f"Updated: {update_str}", None, enabled=False))

        # Actions
        items.append(pystray.Menu.SEPARATOR)
        items.append(pystray.MenuItem("Refresh Now", self._on_refresh))
        items.append(pystray.MenuItem("Quit", self._on_quit))

        return pystray.Menu(*items)

    def _on_refresh(self, icon, item):
        """Handle refresh action."""
        threading.Thread(target=self._refresh_and_update, daemon=True).start()

    def _on_quit(self, icon, item):
        """Handle quit action."""
        self.running = False
        if self.icon:
            self.icon.stop()

    def _refresh_and_update(self):
        """Fetch usage and update the icon."""
        self._fetch_usage()
        if self.icon:
            self.icon.icon = self._create_icon_image()
            self.icon.menu = self._build_menu()

    def _background_refresh_loop(self):
        """Background thread that periodically refreshes usage data."""
        while self.running:
            self._refresh_and_update()
            # Sleep in small increments to allow quick shutdown
            for _ in range(REFRESH_INTERVAL_SECONDS):
                if not self.running:
                    break
                time.sleep(1)

    def run(self):
        """Start the tray application."""
        print(f"CodexBar Linux Tray starting...")
        print(f"Using CLI: {self.cli_path}")

        # Initial fetch
        self._fetch_usage()

        # Create the tray icon
        self.icon = pystray.Icon(
            "codexbar",
            self._create_icon_image(),
            "CodexBar",
            self._build_menu()
        )

        # Start background refresh thread
        refresh_thread = threading.Thread(target=self._background_refresh_loop, daemon=True)
        refresh_thread.start()

        # Run the icon (blocking)
        self.icon.run()


class GtkTray:
    """GTK+AppIndicator-based tray for better Ubuntu/GNOME support."""

    def __init__(self):
        self.usage_data: dict[str, UsageData] = {}
        self.last_error: Optional[str] = None
        self.last_update: Optional[datetime] = None
        self.running = True
        self.cli_path = self._find_cli()
        self.indicator = None
        self.menu = None
        self.icon_path = "/tmp/codexbar_icon.png"

    def _find_cli(self) -> str:
        """Find the CodexBarCLI executable."""
        candidates = [
            Path(__file__).parent.parent.parent / ".build" / "release" / "CodexBarCLI",
            Path.home() / ".local" / "bin" / "codexbar",
            Path("/usr/local/bin/codexbar"),
        ]
        for path in candidates:
            if path.exists() and os.access(path, os.X_OK):
                return str(path)
        return "codexbar"

    def _create_icon(self):
        """Create and save the icon to a temp file."""
        size = 22
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        usage = next(iter(self.usage_data.values()), None) if self.usage_data else None

        if usage:
            bar_width, bar_gap, bar_height = 6, 4, 18
            start_x = (size - (2 * bar_width + bar_gap)) // 2
            start_y = (size - bar_height) // 2

            # Primary bar
            primary_fill = int(bar_height * (usage.primary_remaining / 100))
            draw.rectangle([start_x, start_y, start_x + bar_width, start_y + bar_height],
                           outline=(200, 200, 200, 255))
            if primary_fill > 0:
                fill_y = start_y + bar_height - primary_fill
                color = self._get_color(usage.primary_remaining)
                draw.rectangle([start_x + 1, fill_y, start_x + bar_width - 1, start_y + bar_height - 1],
                               fill=color)

            # Secondary bar
            if usage.secondary_remaining is not None:
                sec_x = start_x + bar_width + bar_gap
                secondary_fill = int(bar_height * (usage.secondary_remaining / 100))
                draw.rectangle([sec_x, start_y, sec_x + bar_width, start_y + bar_height],
                               outline=(200, 200, 200, 255))
                if secondary_fill > 0:
                    fill_y = start_y + bar_height - secondary_fill
                    color = self._get_color(usage.secondary_remaining)
                    draw.rectangle([sec_x + 1, fill_y, sec_x + bar_width - 1, start_y + bar_height - 1],
                                   fill=color)
        else:
            draw.ellipse([4, 4, size - 4, size - 4], outline=(150, 150, 150, 255))
            draw.text((size // 2 - 2, size // 2 - 6), "?", fill=(150, 150, 150, 255))

        img.save(self.icon_path)

    def _get_color(self, remaining: float) -> tuple:
        if remaining > 50:
            return (76, 175, 80, 255)
        elif remaining > 20:
            return (255, 193, 7, 255)
        return (244, 67, 54, 255)

    def _fetch_usage(self):
        """Fetch usage data from CodexBarCLI."""
        all_data = []
        errors = []

        # Fetch each provider separately with appropriate source
        # Claude: use oauth (gets plan info from credentials file)
        # All others: use cli
        provider_sources = [
            ("claude", "oauth"),
            ("codex", "cli"),
            ("gemini", "cli"),
            ("antigravity", "cli"),
            ("cursor", "cli"),
            ("copilot", "cli"),
            ("windsurf", "cli"),
        ]

        for provider, source in provider_sources:
            try:
                result = subprocess.run(
                    [self.cli_path, "usage", "--provider", provider, "--format", "json", "--source", source],
                    capture_output=True, text=True, timeout=CLI_TIMEOUT_SECONDS,
                )
                if result.stdout.strip():
                    data = json.loads(result.stdout)
                    all_data.extend(data)
                elif result.stderr.strip():
                    # Skip errors for providers that aren't configured
                    err = result.stderr.strip().split("\n")[0]
                    skip_patterns = ["not installed", "not found", "no session", "no token", "not configured"]
                    if not any(p in err.lower() for p in skip_patterns):
                        errors.append(f"{provider}: {err}")
            except subprocess.TimeoutExpired:
                errors.append(f"{provider}: timeout")
            except json.JSONDecodeError:
                pass  # Skip invalid JSON
            except FileNotFoundError:
                self.last_error = f"CLI not found: {self.cli_path}"
                self.last_update = datetime.now()
                return
            except Exception as e:
                errors.append(f"{provider}: {e}")

        if all_data:
            self._parse_usage_data(all_data)
            self.last_error = None
        elif errors:
            self.last_error = "; ".join(errors[:2])  # Show first 2 errors

        self.last_update = datetime.now()

    def _parse_usage_data(self, data: list):
        self.usage_data.clear()
        for item in data:
            provider = item.get("provider", "unknown")
            usage = item.get("usage", {})
            primary = usage.get("primary", {})
            secondary = usage.get("secondary")
            tertiary = usage.get("tertiary")
            self.usage_data[provider] = UsageData(
                provider=provider,
                primary_percent=primary.get("usedPercent", 0),
                secondary_percent=secondary.get("usedPercent") if secondary else None,
                tertiary_percent=tertiary.get("usedPercent") if tertiary else None,
                primary_reset=primary.get("resetDescription"),
                secondary_reset=secondary.get("resetDescription") if secondary else None,
                tertiary_reset=tertiary.get("resetDescription") if tertiary else None,
                version=item.get("version"),
                account_email=usage.get("accountEmail"),
                login_method=usage.get("loginMethod"),
                updated_at=usage.get("updatedAt"),
                primary_used_count=primary.get("usedCount"),
                primary_total_count=primary.get("totalCount"),
                secondary_used_count=secondary.get("usedCount") if secondary else None,
                secondary_total_count=secondary.get("totalCount") if secondary else None,
            )

    def _format_relative_time(self, updated_at_str: Optional[str]) -> str:
        """Format updated_at as relative time like 'just now', '2m ago', etc."""
        if not updated_at_str:
            return ""
        try:
            # Parse ISO format: 2025-12-27T14:20:49Z - strip timezone for simple comparison
            clean = updated_at_str.replace("Z", "").split("+")[0].split(".")[0]
            dt = datetime.fromisoformat(clean)
            now = datetime.utcnow()
            seconds = int((now - dt).total_seconds())
            if seconds < 0:
                seconds = 0
            if seconds < 60:
                return "just now"
            elif seconds < 3600:
                return f"{seconds // 60}m ago"
            elif seconds < 86400:
                return f"{seconds // 3600}h ago"
            else:
                return f"{seconds // 86400}d ago"
        except Exception:
            return ""

    def _make_bar(self, remaining_pct: float) -> str:
        """Create a compact Unicode progress bar (8 chars)."""
        filled = int((remaining_pct / 100) * 8)
        return "█" * filled + "░" * (8 - filled)

    def _provider_icon(self, provider: str) -> str:
        """Get emoji icon for provider."""
        icons = {
            "codex": "🤖",
            "claude": "🟠",
            "antigravity": "🚀",
            "gemini": "💎",
            "cursor": "⚡",
            "zed": "⚛",
            "factory": "🏭",
            "copilot": "🐙",
            "windsurf": "🌊",
        }
        return icons.get(provider.lower(), "●")

    def _build_menu(self):
        """Build GTK menu - ultra compact layout."""
        menu = Gtk.Menu()

        if self.usage_data:
            for provider, usage in self.usage_data.items():
                icon = self._provider_icon(provider)
                name = PROVIDER_DISPLAY_NAMES.get(provider, provider.capitalize())
                labels = usage.get_labels()

                # Header: "🤖 Codex (Pro) • user@email.com • just now"
                parts = [f"{icon} {name}"]
                if usage.login_method:
                    parts[0] += f" ({usage.login_method})"
                if usage.account_email:
                    parts.append(usage.account_email)
                updated = self._format_relative_time(usage.updated_at)
                if updated:
                    parts.append(updated)
                header = " • ".join(parts)
                item = Gtk.MenuItem(label=header)
                item.set_sensitive(False)
                menu.append(item)

                # Primary: "  Session: ████████ 83%  in 3h" or "  Credits: 45 / 100 used  in 3h"
                bar = self._make_bar(usage.primary_remaining)
                reset = usage.primary_reset.replace("Resets ", "") if usage.primary_reset else ""
                primary_label = labels.get("primary", "Session")
                # Use count format for providers with counts (Windsurf, Copilot)
                if usage.has_primary_counts():
                    usage_text = usage.format_primary_usage()
                    line = f"    {primary_label}: {bar} {usage_text}"
                else:
                    pct = f"{usage.primary_remaining:.0f}%"
                    line = f"    {primary_label}: {bar} {pct:>3}"
                if reset:
                    line += f"  {reset}"
                item = Gtk.MenuItem(label=line)
                item.set_sensitive(False)
                menu.append(item)

                # Secondary
                if usage.secondary_remaining is not None:
                    bar = self._make_bar(usage.secondary_remaining)
                    reset = usage.secondary_reset.replace("Resets ", "") if usage.secondary_reset else ""
                    sec_label = labels.get("secondary", "Weekly")
                    # Use count format for providers with counts
                    if usage.has_secondary_counts():
                        usage_text = usage.format_secondary_usage()
                        line = f"    {sec_label}: {bar} {usage_text}"
                    else:
                        pct = f"{usage.secondary_remaining:.0f}%"
                        line = f"    {sec_label}: {bar} {pct:>3}"
                    if reset:
                        line += f"  {reset}"
                    item = Gtk.MenuItem(label=line)
                    item.set_sensitive(False)
                    menu.append(item)

                # Tertiary
                if usage.tertiary_remaining is not None:
                    pct = f"{usage.tertiary_remaining:.0f}%"
                    bar = self._make_bar(usage.tertiary_remaining)
                    reset = usage.tertiary_reset.replace("Resets ", "") if usage.tertiary_reset else ""
                    ter_label = labels.get("tertiary", "Tertiary")
                    line = f"    {ter_label}: {bar} {pct:>3}"
                    if reset:
                        line += f"  {reset}"
                    item = Gtk.MenuItem(label=line)
                    item.set_sensitive(False)
                    menu.append(item)

                menu.append(Gtk.SeparatorMenuItem())
        else:
            item = Gtk.MenuItem(label="No usage data")
            item.set_sensitive(False)
            menu.append(item)
            menu.append(Gtk.SeparatorMenuItem())

        if self.last_error:
            item = Gtk.MenuItem(label=f"⚠ {self.last_error[:40]}")
            item.set_sensitive(False)
            menu.append(item)
            menu.append(Gtk.SeparatorMenuItem())

        refresh_item = Gtk.MenuItem(label="↻ Refresh")
        refresh_item.connect("activate", self._on_refresh)
        menu.append(refresh_item)

        cli_item = Gtk.MenuItem(label="📋 Copy CLI")
        cli_item.connect("activate", self._on_copy_cli_command)
        menu.append(cli_item)

        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", self._on_quit)
        menu.append(quit_item)

        menu.show_all()
        return menu

    def _on_refresh(self, widget):
        threading.Thread(target=self._refresh_and_update, daemon=True).start()

    def _on_copy_cli_command(self, widget):
        """Copy the CLI command to clipboard."""
        cmd = f"{self.cli_path} usage --provider all --format json --pretty"
        try:
            clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
            clipboard.set_text(cmd, -1)
            clipboard.store()
        except Exception:
            # Fallback: print to terminal
            print(f"CLI command: {cmd}")

    def _on_quit(self, widget):
        self.running = False
        Gtk.main_quit()

    def _refresh_and_update(self):
        self._fetch_usage()
        self._create_icon()
        GLib.idle_add(self._update_indicator)

    def _update_indicator(self):
        if self.indicator:
            self.indicator.set_icon_full(self.icon_path, "CodexBar")
            self.indicator.set_menu(self._build_menu())
        return False

    def _background_refresh(self):
        while self.running:
            time.sleep(REFRESH_INTERVAL_SECONDS)
            if self.running:
                self._refresh_and_update()

    def run(self):
        print("CodexBar Linux Tray starting (GTK backend)...")
        print(f"Using CLI: {self.cli_path}")

        self._fetch_usage()
        self._create_icon()

        self.indicator = AppIndicator3.Indicator.new(
            "codexbar",
            self.icon_path,
            AppIndicator3.IndicatorCategory.APPLICATION_STATUS
        )
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        self.indicator.set_menu(self._build_menu())

        threading.Thread(target=self._background_refresh, daemon=True).start()

        Gtk.main()


def main():
    """Entry point."""
    # Prefer GTK/AppIndicator backend on Linux for better menu support
    if HAS_GTK:
        print("Using GTK/AppIndicator backend")
        tray = GtkTray()
    else:
        print("Using pystray backend (menu support may be limited)")
        tray = CodexBarTray()

    try:
        tray.run()
    except KeyboardInterrupt:
        print("\nShutting down...")
        tray.running = False


if __name__ == "__main__":
    main()
