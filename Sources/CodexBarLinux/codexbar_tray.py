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
    "gemini": {"primary": "Daily", "secondary": "Daily"},
    "cursor": {"primary": "Fast", "secondary": "Slow"},
    "zed": {"primary": "Session", "secondary": "Weekly"},
}


class UsageData:
    """Parsed usage data from CLI JSON output."""

    def __init__(self, provider: str, primary_percent: float, secondary_percent: Optional[float],
                 tertiary_percent: Optional[float], primary_reset: Optional[str],
                 secondary_reset: Optional[str], tertiary_reset: Optional[str],
                 version: Optional[str], account_email: Optional[str]):
        self.provider = provider
        self.primary_percent = primary_percent
        self.secondary_percent = secondary_percent
        self.tertiary_percent = tertiary_percent
        self.primary_reset = primary_reset
        self.secondary_reset = secondary_reset
        self.tertiary_reset = tertiary_reset
        self.version = version
        self.account_email = account_email

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
        try:
            # Use --source cli which works for all providers on Linux
            result = subprocess.run(
                [self.cli_path, "usage", "--provider", "all", "--format", "json", "--source", "cli"],
                capture_output=True, text=True, timeout=CLI_TIMEOUT_SECONDS,
            )
            if result.stdout.strip():
                data = json.loads(result.stdout)
                self._parse_usage_data(data)
                self.last_error = None
            elif result.stderr.strip():
                self.last_error = result.stderr.strip().split("\n")[0]
        except subprocess.TimeoutExpired:
            self.last_error = "CLI timeout"
        except json.JSONDecodeError as e:
            self.last_error = f"JSON parse error: {e}"
        except FileNotFoundError:
            self.last_error = f"CLI not found: {self.cli_path}"
        except Exception as e:
            self.last_error = str(e)
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
            )

    def _build_menu(self) -> pystray.Menu:
        """Build the tray menu."""
        items = []

        # Usage entries for each provider
        if self.usage_data:
            for provider, usage in self.usage_data.items():
                display_name = provider.capitalize()
                labels = usage.get_labels()

                # Primary usage
                primary_label = labels.get("primary", "Session")
                primary_pct = f"{usage.primary_remaining:.0f}%"
                items.append(pystray.MenuItem(f"{display_name}: {primary_label} {primary_pct}", None, enabled=False))
                if usage.primary_reset:
                    items.append(pystray.MenuItem(f"  └ {usage.primary_reset}", None, enabled=False))

                # Secondary usage
                if usage.secondary_remaining is not None:
                    secondary_label = labels.get("secondary", "Weekly")
                    items.append(pystray.MenuItem(f"  {secondary_label}: {usage.secondary_remaining:.0f}%", None, enabled=False))
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
        try:
            # Use --source cli which works for all providers on Linux
            result = subprocess.run(
                [self.cli_path, "usage", "--provider", "all", "--format", "json", "--source", "cli"],
                capture_output=True, text=True, timeout=CLI_TIMEOUT_SECONDS,
            )
            if result.stdout.strip():
                data = json.loads(result.stdout)
                self._parse_usage_data(data)
                self.last_error = None
            elif result.stderr.strip():
                self.last_error = result.stderr.strip().split("\n")[0]
        except subprocess.TimeoutExpired:
            self.last_error = "CLI timeout"
        except json.JSONDecodeError as e:
            self.last_error = f"JSON parse error: {e}"
        except FileNotFoundError:
            self.last_error = f"CLI not found: {self.cli_path}"
        except Exception as e:
            self.last_error = str(e)
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
            )

    def _build_menu(self):
        """Build GTK menu."""
        menu = Gtk.Menu()

        if self.usage_data:
            for provider, usage in self.usage_data.items():
                display_name = provider.capitalize()
                labels = usage.get_labels()

                # Primary usage
                primary_label = labels.get("primary", "Session")
                primary_pct = f"{usage.primary_remaining:.0f}%"
                item = Gtk.MenuItem(label=f"{display_name}: {primary_label} {primary_pct}")
                item.set_sensitive(False)
                menu.append(item)

                if usage.primary_reset:
                    item = Gtk.MenuItem(label=f"  └ {usage.primary_reset}")
                    item.set_sensitive(False)
                    menu.append(item)

                # Secondary usage
                if usage.secondary_remaining is not None:
                    secondary_label = labels.get("secondary", "Weekly")
                    item = Gtk.MenuItem(label=f"  {secondary_label}: {usage.secondary_remaining:.0f}%")
                    item.set_sensitive(False)
                    menu.append(item)
                    if usage.secondary_reset:
                        item = Gtk.MenuItem(label=f"    └ {usage.secondary_reset}")
                        item.set_sensitive(False)
                        menu.append(item)

                # Tertiary usage (e.g., Gemini Flash for Antigravity)
                if usage.tertiary_remaining is not None:
                    tertiary_label = labels.get("tertiary", "Tertiary")
                    item = Gtk.MenuItem(label=f"  {tertiary_label}: {usage.tertiary_remaining:.0f}%")
                    item.set_sensitive(False)
                    menu.append(item)
                    if usage.tertiary_reset:
                        item = Gtk.MenuItem(label=f"    └ {usage.tertiary_reset}")
                        item.set_sensitive(False)
                        menu.append(item)

                menu.append(Gtk.SeparatorMenuItem())
        else:
            item = Gtk.MenuItem(label="No usage data")
            item.set_sensitive(False)
            menu.append(item)
            menu.append(Gtk.SeparatorMenuItem())

        if self.last_error:
            item = Gtk.MenuItem(label=f"⚠ {self.last_error[:50]}")
            item.set_sensitive(False)
            menu.append(item)
            menu.append(Gtk.SeparatorMenuItem())

        if self.last_update:
            item = Gtk.MenuItem(label=f"Updated: {self.last_update.strftime('%H:%M:%S')}")
            item.set_sensitive(False)
            menu.append(item)

        menu.append(Gtk.SeparatorMenuItem())

        refresh_item = Gtk.MenuItem(label="Refresh Now")
        refresh_item.connect("activate", self._on_refresh)
        menu.append(refresh_item)

        cli_item = Gtk.MenuItem(label="Copy CLI Command")
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
