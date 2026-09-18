# Overview share stats

Date: 2026-09-15

CodexBar exposes its existing local usage snapshot from the menu-bar Overview as a native command labeled
**Share Usage Snapshot…**. The command uses the standard Share symbol and opens the existing preview before anything
is copied or saved. Settings continues to use the same preview and payload factory.

The preview turns **Copy Image** into **Image copied** with a checkmark after the pasteboard accepts the PNG, then
returns to its resting label. This follows Apple's guidance that menu labels describe their command and may use a
standard symbol to clarify it, and that symbol animation should reinforce an event. It also follows the product
principle “animate the truthful delta”: the confirmation appears only after the isolated export boundary reports
success. Reduced Motion removes the explicit animation while preserving the semantic label and status text.

The image remains a local, aggregate-only 1200 × 630 PNG. The payload excludes projects and account identity, reduces
model identifiers to recognized public families, and admits subscription names only through provider-owned plan-label
allowlists. An isolated named-pasteboard test verifies both PNG and TIFF representations without modifying the user's
general pasteboard.

Sources:

- [Apple Human Interface Guidelines: Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- [Apple Human Interface Guidelines: SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- [Apple SwiftUI: ContentTransition](https://developer.apple.com/documentation/swiftui/contenttransition)
- [Apple Xcode: Preparing your app’s text for translation](https://developer.apple.com/documentation/xcode/preparing-your-apps-text-for-translation) (consulted 2026-09-16; share-flow strings are present in every supported app catalog with locale-specific translations.)
