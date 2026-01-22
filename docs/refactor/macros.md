---
summary: "Provider macro refactor ideas and follow-ups."
read_when:
  - Reviewing provider macro ergonomics
  - Planning provider/descriptor refactors
---

# Macro refactor ideas

1. Macro ergonomics + errors
- Emit compile-time errors when a macro is attached to the wrong target or missing `descriptor`/`init`.
- Add a member macro to generate `static let descriptor` from `makeDescriptor()` to remove boilerplate.

2. Descriptor/data shape
- Split ProviderDescriptor into Descriptor + FetchPlan + Branding + CLI files for cleaner deps.
- Move source label into fetch results (strategy-specific).

3. Fetching pipeline
- Return all attempted strategies + errors for debug UI and CLI `--verbose`.

4. Registry order & stability
- Use ProviderDescriptorRegistry registration order for `all`; no sorting by rawValue.
- Use metadata flags (e.g. `isPrimaryProvider`) instead of hard-coded Codex/Claude.

5. Account/identity
- Replace Codex UI special casing with a descriptor flag (e.g. `usesAccountFallback`).
- Enforce provider-keyed identity in snapshots to avoid cross-provider display.

6. Settings + tokens
- Move Zai/Copilot token lookup into strategy-local resolvers (Keychain/env).
- Add optional per-provider settings fields in ProviderSettingsSnapshot.

7. Docs + tests
- Add a minimal provider example in docs/provider.md.
- Add registry completeness + deterministic-order test.
