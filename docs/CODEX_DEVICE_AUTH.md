# Codex Device Authorization Flow

> Native Swift implementation of OAuth 2.0 Device Authorization Grant for
> Codex / ChatGPT accounts. Authenticates without `codex login`, without a
> local browser callback, and without the Codex CLI being installed at all.

## Why this exists

The legacy "Add Account" path spawned `codex login` as a subprocess, which
relied on:

- The `codex` CLI binary being present on `PATH`.
- The OS having a default browser that can reach `localhost:<port>` for the
  OAuth callback.
- The user being on the same machine as the one running CodexBar.

All three assumptions break in common setups: headless dev boxes, locked-down
enterprise managed Macs, remote SSH sessions, and anyone who just prefers to
finish the sign-in dance on their phone. The device authorization grant is
already used in-house by OpenAI's own tooling for exactly these cases, so we
port it natively to CodexBar and expose it alongside the browser path at
every auth entry point.

## Scope and user-visible surface

Every Codex auth entry point offers **both** Browser and Device Code:

| Entry point | Browser | Device Code |
| --- | --- | --- |
| Preferences → Codex → **Add Account** | ✓ | ✓ |
| Preferences → Codex → **Re-auth** (managed account row) | ✓ | ✓ |
| Preferences → Codex → **Re-auth** (system/live account row) | ✓ | ✓ |
| Menu bar → Codex → **Add Account…** | ✓ | ✓ |

The menu-bar surface becomes a submenu (`Sign in with Browser` / `Sign in
with Device Code`); the Preferences surfaces become `Menu` controls with the
same split.

**Menu bar Device Code opens Preferences first.** The device-auth sheet is
hosted in the Providers tab, so the menu-bar action routes the user there
rather than inventing a second sheet surface. This keeps the sheet
implementation single-sourced and lets SwiftUI's `.sheet(item:)` drive
dismissal automatically when the coordinator clears its session reference.

## Protocol

The code talks to OpenAI's device-auth endpoints directly. All values are
public-facing and already used by the reference
`chatgpt-codex-proxy` project.

| Constant | Value |
| --- | --- |
| Client ID | `app_EMoamEEZ73f0CkXaXp7hrann` |
| Auth host | `https://auth.openai.com` |
| Device-code request | `POST /api/accounts/deviceauth/usercode` |
| Poll endpoint | `POST /api/accounts/deviceauth/token` |
| Token exchange | `POST /oauth/token` |
| Redirect URI (in token exchange) | `https://auth.openai.com/deviceauth/callback` |
| Verification URL shown to user | `https://auth.openai.com/codex/device?user_code=<code>` |
| Default session timeout | 15 minutes |
| Minimum polling interval | 5 seconds (clamped) |

### Step 1 — request device code

```
POST /api/accounts/deviceauth/usercode
Content-Type: application/json

{ "client_id": "app_EMoamEEZ73f0CkXaXp7hrann" }
```

Response (shape we rely on):

```json
{
  "user_code": "ABCD-EFGH",
  "device_auth_id": "<opaque>",
  "interval": 5
}
```

`interval` may arrive as `Int`, `Double`, or `String` depending on the
endpoint's mood — we tolerate all three and clamp to at least 5 seconds
(`CodexDeviceFlow.decodeInterval`). The verification URL is built by
`URLComponents` with a single `URLQueryItem` so user codes with reserved
characters percent-encode correctly.

### Step 2 — poll until the user authorizes

```
POST /api/accounts/deviceauth/token
Content-Type: application/json

{ "device_auth_id": "...", "user_code": "ABCD-EFGH" }
```

- **HTTP 403 / 404** → authorization pending; keep polling.
- **HTTP 200** → user authorized. Body returns `authorization_code` and
  `code_verifier` ready for the token exchange.
- **Body `"error": "authorization_pending"`** → same as 403/404.
- **Body `"error": "slow_down"`** → sleep `interval + 5` seconds, continue.
- **Body `"error": "expired_token" | "access_denied"`** → raise `.timedOut`.

> **No explicit deny signal exists.** If the user cancels the dance in the
> browser, the server simply lets the code expire. We surface that as
> `.timedOut` once the 15-minute deadline is reached — this is called out in
> a comment in `pollForTokens` so future readers don't hunt for a deny path.

### Step 3 — exchange the authorization code

```
POST /oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=<auth_code>
&redirect_uri=https://auth.openai.com/deviceauth/callback
&client_id=app_EMoamEEZ73f0CkXaXp7hrann
&code_verifier=<verifier>
```

Response is the standard OAuth envelope:

```json
{
  "access_token": "...",
  "refresh_token": "...",
  "id_token": "...",
  "expires_in": 3600
}
```

### Extracting the ChatGPT account ID

The JWT payload in either `id_token` or `access_token` may carry
`chatgpt_account_id` — either at the top level or nested under the
`https://api.openai.com/auth` claim. `CodexDeviceFlow.extractChatGPTAccountID`
tries `id_token` first, falls back to `access_token`, and returns nil if the
claim is absent in both — **callers must tolerate a missing ID** because not
every workspace embeds it.

The ID is passed through to `CodexOAuthCredentials.accountId`, which is
serialized into `auth.json` as `tokens.account_id` (matching the schema
`codex login` writes).

## Architecture

Four layers, clean separation, test-friendly seams at each boundary:

```
┌────────────────────────────────────────────────────────────────────────┐
│  UI                                                                    │
│  ┌──────────────────────────┐   ┌──────────────────────────────────┐   │
│  │ Menu bar submenu /       │   │ Preferences → Codex →            │   │
│  │ Preferences Add button   │   │ Re-auth Menus                    │   │
│  │ (dispatch selectors)     │   │ (SwiftUI callbacks)              │   │
│  └──────────────┬───────────┘   └──────────────────┬───────────────┘   │
│                 │                                  │                   │
│                 ▼                                  ▼                   │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  ManagedCodexAccountCoordinator                                  │  │
│  │   • owns `activeDeviceAuthSession` (drives .sheet(item:))        │  │
│  │   • guards mutual exclusion of auth attempts                     │  │
│  │   • wraps the service Task so Cancel propagates                  │  │
│  └──────────────────────────┬───────────────────────────────────────┘  │
│                             │                                          │
│                             ▼                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  ManagedCodexAccountService                                      │  │
│  │   • makes scoped `CODEX_HOME` (managed path) or uses ambient env │  │
│  │   • calls the device-flow runner                                 │  │
│  │   • writes auth.json via CodexOAuthCredentialsStore.save         │  │
│  │   • reconciles with managed account store (managed path only)    │  │
│  └──────────────────────────┬───────────────────────────────────────┘  │
│                             │                                          │
│                             ▼                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  ManagedCodexDeviceFlowRunning   (protocol, Sendable)            │  │
│  │   DefaultManagedCodexDeviceFlowRunner wraps CodexDeviceFlow      │  │
│  │   Tests inject fakes to assert phase sequences / error mapping   │  │
│  └──────────────────────────┬───────────────────────────────────────┘  │
│                             │                                          │
│                             ▼                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  CodexDeviceFlow           (CodexBarCore, pure networking)       │  │
│  │   • requestDeviceCode()                                          │  │
│  │   • pollForTokens(...) → CodexOAuthCredentials                   │  │
│  │   • JWT extraction, interval decoding, form encoding             │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

### Why four layers and not three

- **`CodexDeviceFlow` is in `CodexBarCore`.** It has no UI, no AppKit, no
  state. That lets it sit in the shared core module next to
  `CodexOAuthCredentials` / `CodexOAuthCredentialsStore` / `CodexHomeScope`
  and be trivially unit-tested against a `URLSession` with a stub protocol.
- **`ManagedCodexDeviceFlowRunning` sits in `CodexBar`** because the service
  (which isn't Sendable-friendly across module boundaries) is the primary
  consumer. It exists purely as an injection seam — the default impl is
  a one-line wrapper. Tests replace it with an in-memory double so service
  tests never touch the network.
- **The service does everything file-system and account-store related.**
  It's where the "managed" and "ambient" paths diverge. The coordinator
  doesn't care about managed homes or `auth.json` paths; it only cares
  about the session and Task lifecycles.
- **The coordinator owns UI state** (`activeDeviceAuthSession`) and
  `@Observable`-publishes it so SwiftUI's `.sheet(item:)` can drive the
  device-auth sheet. It stays out of the service's concerns and never
  touches the file system.

## Two paths: managed vs. ambient

Both paths share `CodexDeviceFlow`, the runner, the session, the sheet, the
error mapping, and the `CodexOAuthCredentialsStore.save(_:env:)` call. They
differ in **where tokens land** and **whether CodexBar's managed account
store is touched**.

### Managed path

Triggered by: **Add Account** (from preferences or menu bar), and **Re-auth**
on a managed account row (`storedAccountID != nil`).

Entry point: `ManagedCodexAccountService.authenticateManagedAccountWithDeviceFlow`.

Flow:

1. Snapshot the managed account set.
2. Mint a scoped `CODEX_HOME` path via `ManagedCodexHomeFactory.makeHomeURL()`
   — a UUID-named directory under
   `~/Library/Application Support/CodexBar/managed-codex-homes/`.
3. Run the device-auth flow.
4. Save tokens to `<scoped home>/auth.json` using
   `CodexOAuthCredentialsStore.save(credentials, env:)` with the env scoped
   via `CodexHomeScope.scopedEnvironment(base:codexHome:)`.
5. Hand off to `reconcileAuthenticatedIdentity(snapshot:homeURL:existingAccountID:)`
   — the same shared helper the CLI browser path uses — which reads the
   identity from the scoped home, resolves workspace metadata, matches
   against existing accounts (by provider ID or email fallback), and
   persists a `ManagedCodexAccountSet` to the store.
6. On failure, the scoped home is removed via `removeManagedHomeIfSafe`;
   on success, any replaced accounts' homes are cleaned up too.

Returns `ManagedCodexAccount`. Identical post-condition to the CLI path.

### Ambient path

Triggered by: **Re-auth** on the system/live account row (`storedAccountID == nil`).

Entry point: `ManagedCodexAccountService.authenticateAmbientCodexAccountWithDeviceFlow`.

Flow:

1. Run the device-auth flow.
2. Save tokens via `CodexOAuthCredentialsStore.save(credentials, env: ProcessInfo.processInfo.environment)`
   — the unmodified process environment, which means
   `CodexHomeScope.ambientHomeURL(env:)` resolves to
   `~/.codex/auth.json` (unless the user has `CODEX_HOME` set).
3. That's it. No managed home, no account-store mutation.

Returns `Void`. Identical post-condition to what `codex login` would
write — just skipping the CLI, browser callback, and process fork.

### The shared reconciliation helper

`ManagedCodexAccountService.reconcileAuthenticatedIdentity(snapshot:homeURL:existingAccountID:)`
is private and shared by the CLI browser path (`authenticateManagedAccount`)
and the managed device path
(`authenticateManagedAccountWithDeviceFlow`). This exists specifically so
that future changes to identity reading, workspace resolution, or account
matching **cannot drift between the two paths**. If you're editing one,
you're editing both by construction.

The ambient path does not use this helper because it has no managed-store
consequences.

## The CodexDeviceAuthSession

`@MainActor @Observable final class CodexDeviceAuthSession: Identifiable`

One instance per auth attempt. Owned by the coordinator, which sets it on
`activeDeviceAuthSession` before kicking off work and clears it in `defer`.
SwiftUI's `.sheet(item:)` in `PreferencesProvidersPane` observes the
coordinator and shows / dismisses the sheet automatically.

### Phase

```swift
enum Phase: Equatable {
    case requestingCode
    case awaitingUser(userCode: String, verificationURL: URL)
    case exchangingTokens
    case failed(String)
}
```

The service pushes `ManagedCodexDeviceFlowProgress` through a `progress`
closure; the coordinator's closure calls `session.applyProgress(_:)` which
maps it to the UI `Phase`. The sheet switches on `phase` and renders:

- `requestingCode` — spinner + "Requesting device code…"
- `awaitingUser(code, url)` — large monospaced code (click to copy, shows
  "Copied!" toast for ~1.5s), link to `auth.openai.com`, status spinner.
- `exchangingTokens` — spinner + "Finishing sign-in…"
- `failed(msg)` — red text. Rarely used; most errors surface as
  `CodexAccountsSectionNotice` on the pane instead of the sheet.

### Cancel

`session.cancel()` invokes a type-erased closure set by `attach(task:)`:

```swift
func attach<Success: Sendable>(task: Task<Success, Error>) {
    self.cancelOwningTask = { task.cancel() }
}
```

The generic is there because the managed path returns
`Task<ManagedCodexAccount, Error>` and the ambient path returns
`Task<Void, Error>`. Cancellation propagates cooperatively: the service
checks `Task.checkCancellation()` between polling iterations in
`CodexDeviceFlow.pollForTokens`, and throws `CancellationError` when the
Task is cancelled.

Callers treat `CancellationError` as a benign user-initiated abort — no
notice is shown, the sheet dismisses, and state returns to idle.

## Error mapping

`CodexDeviceFlow.Error` is the lowest-level type. The service maps it once,
at its seam, to `ManagedCodexAccountServiceError`:

| `CodexDeviceFlow.Error` | `ManagedCodexAccountServiceError` |
| --- | --- |
| `.timedOut` | `.deviceFlowTimedOut` |
| `.requestFailed(status, _)` | `.deviceFlowRequestFailed(status:)` |
| `.invalidResponse` / `.missingTokens` | `.deviceFlowInvalidResponse` |

The pane's `codexAccountsNotice(for:)` translates the service errors to
user-facing `CodexAccountsSectionNotice` strings. `CancellationError` is
intercepted *before* the mapper runs (`catch is CancellationError`) so the
flow silently returns to idle.

Notice tones follow convention:

- `.deviceFlowTimedOut` → **secondary** tone ("Device code expired. Please
  try again.") — not an error, just ran out of clock.
- Everything else → **warning** tone.

`StatusItemController+Actions.presentManagedCodexAccountError` mirrors the
same mapping for menu-bar-triggered flows via its `NSAlert` presentation
(so the exhaustive switch over `ManagedCodexAccountServiceError` covers the
new cases).

## The `auth.json` write

We do not reinvent the wheel here. `CodexOAuthCredentialsStore.save(_:env:)`
already exists, already writes the schema `codex login` produces, and
already handles:

- Merging with any existing `auth.json` content.
- Scoping via `CodexHomeScope.ambientHomeURL(env:)` — same function the
  read path uses, so write and read use identical path resolution.
- Atomic writes via `Data.write(to:options: .atomic)`.
- `last_refresh` ISO-8601 timestamp.

The only CodexBar-specific choice is: **managed path** passes a scoped env;
**ambient path** passes `ProcessInfo.processInfo.environment`. Both call
the same function.

## Testing

Two test files, both under `Tests/CodexBarTests/`:

### `CodexDeviceFlowTests.swift`

Uses `@testable import CodexBarCore` so the test file can reach the
internal `decodeInterval(_:)`, `extractChatGPTAccountID(idToken:accessToken:)`,
and `verificationURL(userCode:)` helpers directly.

Covers:

- Interval decoding across Int / Double / String / malformed inputs, clamp
  behavior.
- JWT extraction (top-level claim, nested `https://api.openai.com/auth`
  claim, fallback from id_token to access_token, nil when absent in both).
- Verification URL encoding for normal and reserved-character user codes.
- End-to-end `pollForTokens` over a `URLProtocol` stub: 403 → 200 →
  token-exchange, asserting the exchange request is form-encoded (not
  JSON) and returns the right credentials.
- `pollForTokens` timeout when deadline is past.
- `pollForTokens` propagating `CancellationError` on `Task.cancel()`.

The `URLProtocol` stub is `CodexDeviceFlowStubURLProtocol`. It follows the
same pattern as `CodexOpenAIWorkspaceStubURLProtocol` used by the
workspace-resolver tests. Call counts are guarded by a `PollCounter`
helper that wraps an `NSLock` so the stub handler can mutate state safely
from a URLSession queue.

### `ManagedCodexAccountServiceDeviceFlowTests.swift`

Uses `@testable import CodexBar`. Injects a `StubManagedCodexDeviceFlowRunner`
so no network traffic flows. Covers:

- Happy path writes `auth.json` with the expected tokens, reports phases in
  order (`requestingCode` → `awaitingUser` → `exchangingTokens`), and the
  returned `ManagedCodexAccount` carries the extracted `providerAccountID`.
- Timeout maps to `ManagedCodexAccountServiceError.deviceFlowTimedOut` and
  the scoped managed home is cleaned up.

The tests use `FileManagedCodexAccountStore` against a temp directory
rather than the existing tests' `InMemoryManagedCodexAccountStore` (which
is private to its test file).

### Running the suites

```bash
swift test --filter 'CodexDeviceFlowTests|ManagedCodexAccountServiceDeviceFlowTests'
# Plus regression suites that exercise menu-bar + preferences:
swift test --filter 'CodexAccountsSettingsSectionTests|ManagedCodexAccountCoordinatorTests|StatusMenuCodexSwitcherTests|ManagedCodexAccountServiceTests'
```

As of writing, 47 tests across these 6 suites green.

## File-by-file reference

### `Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexDeviceFlow.swift`

Public `struct CodexDeviceFlow: Sendable`. Owns:

- `DeviceCodeResponse` (public struct with public memberwise init — the
  public init is needed so test/fake runners can construct one).
- `Error` (Sendable + Equatable — Equatable is required by Swift Testing's
  `#expect(throws:)` helper).
- `init(userAgent:urlSession:)` — the session is injectable for tests.
- `requestDeviceCode() async throws -> DeviceCodeResponse`
- `pollForTokens(deviceAuthID:userCode:intervalSeconds:deadline:) async throws -> CodexOAuthCredentials`
  — private `exchangeCode(authorizationCode:codeVerifier:)` does step 3.

Internal helpers (made internal not private so the tests can reach them
via `@testable import`):

- `static func verificationURL(userCode:) -> URL`
- `static func decodeInterval(_ raw: Any?) -> Int`
- `static func extractChatGPTAccountID(idToken:accessToken:) -> String?`

### `Sources/CodexBar/ManagedCodexDeviceFlowRunner.swift`

- `protocol ManagedCodexDeviceFlowRunning: Sendable` — two methods mirror
  `CodexDeviceFlow`.
- `struct DefaultManagedCodexDeviceFlowRunner` — one-line wrapper around
  `CodexDeviceFlow()`. This protocol / default-impl dance mirrors
  `ManagedCodexLoginRunning` / `DefaultManagedCodexLoginRunner` so tests
  can swap fakes without touching the service's other dependencies.

### `Sources/CodexBar/ManagedCodexAccountService.swift`

Extended with:

- `deviceFlowRunner: any ManagedCodexDeviceFlowRunning` stored property
  (with default value in `init`, backward-compatible with existing call
  sites).
- `authenticateManagedAccountWithDeviceFlow(existingAccountID:sessionTimeout:progress:) async throws -> ManagedCodexAccount`
- `authenticateAmbientCodexAccountWithDeviceFlow(sessionTimeout:progress:) async throws -> Void`
- private `reconcileAuthenticatedIdentity(snapshot:homeURL:existingAccountID:) async throws`
  — the shared post-auth helper used by the CLI browser path and the
  managed device path. The CLI path was refactored to call this instead of
  duplicating.
- `ManagedCodexAccountServiceError` gained `.deviceFlowTimedOut`,
  `.deviceFlowRequestFailed(status:)`, and `.deviceFlowInvalidResponse`.
- New `enum ManagedCodexDeviceFlowProgress` for the progress closure.
- Private `static func mapDeviceFlowError(_:) -> ManagedCodexAccountServiceError`.

The two public methods share no direct code beyond `reconcileAuthenticatedIdentity`;
they're kept intentionally parallel rather than collapsed because their
pre-conditions (scoped home vs. ambient env) and post-conditions (managed
store update vs. none) diverge substantially.

### `Sources/CodexBar/ManagedCodexAccountCoordinator.swift`

Extended with:

- `private(set) var activeDeviceAuthSession: CodexDeviceAuthSession?` —
  observable, drives `.sheet(item:)`.
- `authenticateManagedAccountWithDeviceFlow(existingAccountID:sessionTimeout:) async throws -> ManagedCodexAccount`
- `authenticateAmbientCodexAccountWithDeviceFlow(sessionTimeout:) async throws -> Void`

Guard semantics:

- The managed device method uses the existing `isAuthenticatingManagedAccount`
  guard so the CLI browser path and the managed device path are mutually
  exclusive.
- The ambient device method guards on `activeDeviceAuthSession != nil`
  (preventing overlap with the managed device sheet). The pane additionally
  toggles `isAuthenticatingLiveCodexAccount` around the call, matching the
  existing ambient browser re-auth semantics.

### `Sources/CodexBar/CodexDeviceAuthSession.swift`

`@MainActor @Observable final class CodexDeviceAuthSession: Identifiable`.
See "The CodexDeviceAuthSession" section above. The `attach(task:)` method
is generic to support both return types (`ManagedCodexAccount` and `Void`).

### `Sources/CodexBar/CodexDeviceAuthSheetView.swift`

SwiftUI sheet, fixed 420×320. No business logic — pure rendering over
`CodexDeviceAuthSession.phase`. The "Copied!" toast is local `@State`
with a 1.5s fade.

### `Sources/CodexBar/PreferencesCodexAccountsSection.swift`

- `CodexAccountsSectionView` gained `addAccountViaDeviceCode: () -> Void`
  and `reauthenticateAccountViaDeviceCode: (CodexVisibleAccount) -> Void`
  callbacks.
- The bare "Add Account" button became a `Menu` with Browser / Device
  Code options.
- Every Re-auth button in `CodexAccountsSectionRowView` is a `Menu` with
  the same two options — both managed and system rows show the menu.

### `Sources/CodexBar/PreferencesProvidersPane.swift`

- `addManagedCodexAccountViaDeviceFlow()` — calls the managed coordinator.
- `reauthenticateCodexAccountViaDeviceFlow(_:)` — branches on
  `storedAccountID`: managed path if present, ambient path (with
  `isAuthenticatingLiveCodexAccount` toggling) if nil.
- `.sheet(item: ...)` attached to the root HStack, bound to
  `coordinator.activeDeviceAuthSession`.
- `codexAccountsNotice(for:)` extended with the three new service error
  cases (`.deviceFlowTimedOut` → `.secondary` tone; others → `.warning`).
  `CancellationError` falls through to the empty-notice branch.

### `Sources/CodexBar/MenuDescriptor.swift`

- `MenuAction` gained `addCodexAccountViaDeviceCode`.
- `actionsSection(...)` special-cases Codex: when the provider is `.codex`
  and `loginMenuAction` returns `.addCodexAccount`, the entry is emitted
  as a `.submenu` with two `SubmenuItem`s (Browser + Device Code) instead
  of a single `.action`.
- `systemImageName` returns the same "plus" icon for both actions.

### `Sources/CodexBar/StatusItemController+MenuActionMapping.swift`

Wires `.addCodexAccountViaDeviceCode` to `#selector(self.addManagedCodexAccountViaDeviceCodeFromMenu(_:))`.

### `Sources/CodexBar/StatusItemController+Actions.swift`

- `@objc addManagedCodexAccountViaDeviceCodeFromMenu(_:)` — opens
  Preferences → Providers (so the sheet has somewhere to render) and
  then calls `coordinator.authenticateManagedAccountWithDeviceFlow()`.
- `presentManagedCodexAccountError(_:)` exhaustive switch updated for
  the three new service errors.

### `Sources/CodexBar/MenuContent.swift`

Exhaustive switch over `MenuAction` in `perform(_:)` extended for
`.addCodexAccountViaDeviceCode`. The `MenuActions` struct gained a
matching closure field. *(`MenuContent` is currently unreferenced
production code but the switch is compile-checked, so keeping it
consistent prevents a future refactor from surprising us.)*

## Extending this

### I'm adding a new caller of device auth

Prefer reusing the coordinator methods:

```swift
_ = try await coordinator.authenticateManagedAccountWithDeviceFlow(
    existingAccountID: /* nil for new account, UUID for re-auth */)

// or

try await coordinator.authenticateAmbientCodexAccountWithDeviceFlow()
```

Both handle the sheet lifecycle and cancellation. If you need a custom UI
instead of the Preferences-hosted sheet, build your own session and own
its lifecycle — but you'll lose the `.sheet(item:)` auto-dismiss wiring.

### I want to test my new caller

Inject a fake `ManagedCodexDeviceFlowRunning` into
`ManagedCodexAccountService` when constructing it (the designated init
takes one explicitly). See `ManagedCodexAccountServiceDeviceFlowTests.swift`
for a fake that returns fixed credentials or throws a chosen
`CodexDeviceFlow.Error`.

### I need to surface a new phase / progress step

Add a case to `ManagedCodexDeviceFlowProgress`, thread it through the two
service methods, map it to `CodexDeviceAuthSession.Phase` in
`applyProgress(_:)`, and render it in `CodexDeviceAuthSheetView.contentArea`.
The compiler's exhaustiveness check will point you at every site that
needs updating.

### The protocol changed upstream

`CodexDeviceFlow` is the single place to update. Constants are at the
top of the file (`clientID`, `authBaseURL`, `redirectURI`). The three
endpoint paths are string-literal inline in `requestDeviceCode`,
`pollForTokens`, and `exchangeCode` respectively. Adjust there; the
tests mock at the `URLProtocol` layer so they don't constrain path
shapes.

### I want to disable the device-code option somewhere

The menu-bar submenu can be switched back to a single action by changing
the `targetProvider == .codex` branch in `MenuDescriptor.actionsSection`.
Individual preferences surfaces can hide the Menu by swapping it back
to a plain `Button` in `PreferencesCodexAccountsSection`.

## Known non-goals

- **No deep-link handler.** The user always types / pastes the code into
  their browser; CodexBar doesn't register a URL scheme or intercept the
  callback URL. This is deliberate — one of the whole points of device
  flow is that the verification can happen on a device other than the one
  running CodexBar.
- **No background retry on timeout.** If the 15-minute window expires, the
  user must re-initiate. We surface this as a secondary-tone notice rather
  than auto-retrying to avoid rewriting `auth.json` under the user
  unexpectedly.
- **No key-rotation handling.** The client ID is hard-coded. If OpenAI
  rotates it, update `CodexDeviceFlow.clientID`.
- **No device-code auth for providers other than Codex.** The analogous
  Copilot flow (`CopilotDeviceFlow`) is a separate implementation using
  the GitHub device flow — the protocols overlap but aren't identical.

## Historical note on the shape

An earlier iteration of this work considered making the managed and
ambient paths share a single method with a `scope: .managed | .ambient`
parameter. We kept them parallel instead because (a) the
post-conditions differ substantially (one updates the managed account
store, one doesn't), (b) the return types differ (`ManagedCodexAccount`
vs. `Void`), and (c) the progress callback is the same shape in both
but the coordinator-level orchestration isn't (guards, lifecycle,
session ownership). The only bit that *should* stay shared is identity
reconciliation, which is why `reconcileAuthenticatedIdentity` is a
private helper on the service.
