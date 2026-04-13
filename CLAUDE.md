# Repository Notes

## Build, Test, Run
- Dev loop: `./Scripts/compile_and_run.sh`
- Quick verification: `swiftformat Sources Tests`, `swiftlint --strict`, `swift build`, `swift test`
- Package app: `./Scripts/package_app.sh`

## Coding Conventions
- SwiftFormat and SwiftLint are required; keep explicit `self`.
- Prefer small typed structs/enums and existing provider patterns over new abstractions.
- Reuse shared provider settings descriptors instead of adding custom provider-only UI.

## Provider Notes
- Keep provider identity and plan data siloed by provider.
- Moonshot is the official Moonshot platform provider and is separate from Kimi K2.
- Moonshot uses `GET /v1/users/me/balance` on `api.moonshot.ai` or `api.moonshot.cn`, exposes a Region picker, and renders balance-only/no-limit semantics.
