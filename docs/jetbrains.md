---
summary: "JetBrains AI provider notes: local XML quota parsing, IDE auto-detection, and UI mapping."
read_when:
  - Adding or modifying the JetBrains AI provider
  - Debugging JetBrains quota file parsing or IDE detection
  - Adjusting JetBrains menu labels or settings
---

# JetBrains AI provider

JetBrains AI is a local-only provider. We read quota information directly from the IDE's configuration files.

## Data sources + fallback order

1) **IDE auto-detection**
   - macOS: `~/Library/Application Support/JetBrains/`
   - macOS (Android Studio): `~/Library/Application Support/Google/`
   - Linux: `~/.config/JetBrains/`
   - Linux (Android Studio): `~/.config/Google/`
   - Supported IDEs: IntelliJ IDEA, PyCharm, WebStorm, GoLand, CLion, DataGrip, RubyMine, Rider, PhpStorm, RustRover, Android Studio, Fleet, Aqua, DataSpell
   - Selection: most recently modified `AIAssistantQuotaManager2.xml`

2) **Quota file parsing**
   - Path: `<IDE_BASE>/options/AIAssistantQuotaManager2.xml` (macOS/Linux)
   - Format: XML with HTML-encoded JSON attributes

## XML structure

- `quotaInfo` attribute (JSON):
  - `type`: quota type (e.g., "Available")
  - `current`: tokens used
  - `maximum`: total tokens
  - `tariffQuota.available`: remaining tokens
  - `until`: subscription end date
- `nextRefill` attribute (JSON):
  - `type`: refill type (e.g., "Known")
  - `next`: next refill date (ISO-8601)
  - `tariff.amount`: refill amount
  - `tariff.duration`: refill period (e.g., "PT720H")

## Parsing and mapping

- Usage calculation: `tariffQuota.available / maximum * 100` for remaining percent
- Reset date: from `nextRefill.next`, not `quotaInfo.until`
- HTML entity decoding: `&#10;` → newline, `&quot;` → quote

## UI mapping

- Provider metadata:
  - Display: `JetBrains AI`
  - Label: `Current` (primary only)
- Identity: detected IDE name + version (e.g., "IntelliJ IDEA 2025.3")
- Status badge: none (no status page integration)

## Settings

- IDE Picker: auto-detected IDEs list, or "Auto-detect" (default)
- Custom Path: manual base path override (for advanced users)

## Constraints

- Requires JetBrains IDE with AI Assistant enabled
- XML file only exists after AI Assistant usage
- Internal file format; may change between IDE versions

## Key files

- `Sources/CodexBarCore/Providers/JetBrains/JetBrainsStatusProbe.swift`
- `Sources/CodexBarCore/Providers/JetBrains/JetBrainsIDEDetector.swift`
- `Sources/CodexBar/Providers/JetBrains/JetBrainsProviderImplementation.swift`
