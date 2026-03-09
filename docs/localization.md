# Localization

CodexBar supports full localization using Apple's [String Catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) (`.xcstrings`) format.

## Supported Languages

| Language | Code | Status |
|----------|------|--------|
| English | `en` | Base language |
| Simplified Chinese | `zh-Hans` | Complete |
| Traditional Chinese | `zh-Hant` | Complete |
| Japanese | `ja` | Complete |
| Korean | `ko` | Complete |
| French | `fr` | Complete |
| German | `de` | Complete |
| Spanish | `es` | Complete |

## Architecture

### String Catalogs

Localized strings are stored in two `.xcstrings` files:

- **`Sources/CodexBar/Resources/Localizable.xcstrings`** — Main app (437+ keys)
- **`Sources/CodexBarWidget/Resources/Localizable.xcstrings`** — Widget extension

These are JSON files that map string keys to translations for each supported language.

### How Strings Are Localized

CodexBar uses two localization mechanisms:

1. **SwiftUI automatic localization** — `Text("literal")`, `Label("literal", ...)`, `Button("literal")`, and `Toggle("literal", ...)` automatically look up keys in the String Catalog via `LocalizedStringKey`.

2. **Explicit `String(localized:)`** — Used in contexts where `String` (not `LocalizedStringKey`) is expected: AppKit code (`NSMenuItem`, `NSAlert`), computed properties returning `String`, and string interpolations.

```swift
// SwiftUI automatic — just needs a matching key in .xcstrings
Text("Start at Login")

// Explicit — for String parameters, AppKit, and interpolations
title: String(localized: "API key")
NSMenuItem(title: String(localized: "Settings..."), ...)
Text(String(localized: "Version \(self.versionString)"))
```

### String Interpolation

Strings with dynamic values use Swift string interpolation inside `String(localized:)`. The compiler converts `\(variable)` to `%@` placeholders in the String Catalog:

```swift
// Source code
String(localized: "Quota: \(used) / \(limit)")

// Key in .xcstrings → "Quota: %@ / %@"
// zh-Hans translation → "配额: %@ / %@"
```

### Language Switching

Users can switch the app language in **Preferences → General → Language**. The implementation:

- **`AppLanguage.swift`** — Defines the `AppLanguage` enum with all supported languages and a `.system` option that follows macOS settings.
- **`SettingsStore`** — Persists the language choice in `UserDefaults` (`appLanguage` key) and applies it via `UserDefaults.AppleLanguages` on launch.
- **`PreferencesGeneralPane.swift`** — Provides the language picker UI with a restart prompt.

A restart is required after changing the language because macOS loads localized resources at launch time.

## Packaging

The `Scripts/package_app.sh` script handles two localization-specific tasks:

1. **Compile `.xcstrings` to `.lproj`** — Runs `xcrun xcstringstool compile` to convert String Catalog files into the `.lproj/*.strings` format that macOS requires at runtime.

2. **Declare supported languages** — Injects `CFBundleDevelopmentRegion` and `CFBundleLocalizations` into the app's `Info.plist` so macOS knows which languages are available.

## Adding a New Language

1. Open `Sources/CodexBar/Resources/Localizable.xcstrings` in a text editor or Xcode.
2. For each string key, add a new `localizations` entry with the language code and translated value:
   ```json
   "Start at Login": {
     "localizations": {
       "pt-BR": {
         "stringUnit": {
           "state": "translated",
           "value": "Iniciar no Login"
         }
       }
     }
   }
   ```
3. Add the language code to `CFBundleLocalizations` in `Scripts/package_app.sh`.
4. Add the language to the `AppLanguage` enum in `Sources/CodexBar/AppLanguage.swift`.
5. Repeat for `Sources/CodexBarWidget/Resources/Localizable.xcstrings` if the widget has translatable strings.

## What Is NOT Localized

The following are intentionally kept in English:

- **Provider brand names** — Codex, Claude, Cursor, OpenAI, etc.
- **Technical terms** — API, CLI, MCP, OAuth, Keychain, SSH
- **Product name** — CodexBar
- **URLs and identifiers** — Bundle IDs, file paths, raw values

## Contributing Translations

Translation improvements and corrections are welcome. When submitting changes:

- Edit only the `Localizable.xcstrings` file(s)
- Keep the English (`en`) values unchanged — they serve as the source of truth
- Ensure `%@` placeholders are preserved in the correct order
- Test by switching the app language in Preferences → General → Language
