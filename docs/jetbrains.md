---
summary: "JetBrains AI provider notes: local XML and log quota parsing, IDE auto-detection, and UI mapping."
read_when:
  - Adding or modifying the JetBrains AI provider
  - Debugging JetBrains quota file parsing or IDE detection
  - Adjusting JetBrains menu labels or settings
---

# JetBrains AI provider

JetBrains AI is a local-only provider. We read quota information from the IDE's configuration and quota log records.

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

3) **IDE log (fresher quota state)**
   - The IDE logs every quota refresh but persists the XML rarely; the XML can stay weeks behind the
     "monthly credits left" value shown in the IDE (observed with AI Assistant 262.10968.x)
   - Path: `~/Library/Logs/<vendor>/<IDE>/idea.log` (macOS), `~/.cache/<vendor>/<IDE>/log/idea.log` (Linux)
   - Reads at most 4 MiB, ending at the file size captured when opened, even if the file grows during the read.
     A partial first line is discarded; an unfinished final line rejects the tail. Only parsed quota/refill
     fields leave the reader; unrelated log text is never retained, persisted, or sent over the network
   - Accepts only complete `Available` monthly quota records with finite, nonnegative numbers. A malformed,
     truncated, unknown, or changed latest quota state falls back to XML rather than reusing older log quota
   - With an XML source selected, only that IDE installation's log is eligible. Other IDEs may use different
     accounts, and these records have no account marker to prove equivalence. Their logs never replace its XML
   - A newer log replaces the quota and refill as one snapshot; an absent or malformed log refill leaves the
     reset date unavailable instead of borrowing it from XML. IDE name/version come from the same installation
   - If no IDE has quota XML, auto-detect can use the latest valid log with that log's own IDE identity.
     A selected custom path stays confined to that installation; nonstandard config locations use XML only
   - Used only when its timestamp is strictly newer than the XML's known modification date; missing logs,
     unreadable tails, unsupported records, and unknown XML modification dates preserve XML

## XML structure

- `quotaInfo` attribute (JSON):
  - `type`: quota type (e.g., "Available")
  - `current`: tokens used
  - `maximum`: total tokens (monthly tariff + top-up credits)
  - `tariffQuota.current` / `tariffQuota.maximum` / `tariffQuota.available`: monthly credits used / granted / remaining
  - `topUpQuota.current` / `topUpQuota.maximum` / `topUpQuota.available`: purchased top-up credits
  - `until`: subscription end date
- `nextRefill` attribute (JSON):
  - `type`: refill type (e.g., "Known")
  - `next`: next refill date (ISO-8601)
  - `tariff.amount`: refill amount
  - `tariff.duration`: refill period (e.g., "PT720H")

## Parsing and mapping

- Usage calculation: `tariffQuota.current / tariffQuota.maximum * 100` for used percent, matching the IDE's
  "monthly credits left" display; top-up credits are not included in this monthly percentage
- For XML, if either monthly value is missing or non-finite, use the top-level `current` / `maximum` together and derive
  the remaining total from them; never combine monthly and total balances
- Top-up credits: `topUpQuota.available` becomes a `Top-up credits` detail section with one
  `Remaining` row ("54.90 credits"); no usage bar. JetBrains spends top-ups only after the monthly quota is
  used up, and its own account page draws the top-up bar as full or empty only, so a ratio would invent meaning.
  Quota units convert to IDE credits at 100,000 units per credit (1,000,000 = 10.00 monthly credits); one
  AI Credit is $1 USD per [JetBrains licensing docs](https://www.jetbrains.com/help/ai-assistant/licensing-and-subscriptions.html),
  so no separate currency value is shown. Missing or non-finite `available`/`maximum`, negative balances,
  or zero maxima hide the section; a missing balance is never reconstructed from `current`. The log's optional
  `topUpQuota=QuotaDetails(...)` group maps the same way
- Reset date: from `nextRefill.next`, not `quotaInfo.until`
- HTML entity decoding: `&#10;` → newline, `&quot;` → quote

## UI mapping

- Provider metadata:
  - Display: `JetBrains AI`
  - Label: `Current` (monthly credits only)
  - Detail section: `Top-up credits` → `Remaining` (purchased credits, shown only when present)
  - Menu bar Balance element: the same remaining top-up credits, alongside the unchanged monthly percentage
- Identity: detected IDE name + version (e.g., "IntelliJ IDEA 2025.3")
- Status badge: none (no status page integration)
- Source detail: `local`; no Version row because this provider has no CLI version detector

## Settings

- IDE Picker: auto-detected IDEs list, or "Auto-detect" (default)
- Custom Path: manual base path override (for advanced users)

## Constraints

- Requires JetBrains IDE with AI Assistant enabled
- XML file only exists after AI Assistant usage
- Internal file format; may change between IDE versions
- `idea.log` line format is not a stable interface either; parsing fails soft back to the XML

## Key files

- `Sources/CodexBarCore/Providers/JetBrains/JetBrainsStatusProbe.swift`
- `Sources/CodexBarCore/Providers/JetBrains/JetBrainsQuotaLogReader.swift`
- `Sources/CodexBarCore/Providers/JetBrains/JetBrainsIDEDetector.swift`
- `Sources/CodexBar/Providers/JetBrains/JetBrainsProviderImplementation.swift`
