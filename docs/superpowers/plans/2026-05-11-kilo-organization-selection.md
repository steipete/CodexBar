# Kilo Organization Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let CodexBar users opt in to one or more Kilo organizations from Preferences → Providers → Kilo. Enabled orgs render as stacked cards alongside their personal account in the Kilo menu.

**Architecture:** Add `KiloUsageScope` and `KiloOrganization` types in `CodexBarCore`. Inject `X-KILOCODE-ORGANIZATIONID` header in `KiloUsageFetcher` when a scope is `.organization`. Persist known orgs and enabled-ids in `ProviderConfig` JSON. Mirror the existing tokenAccounts pattern in `UsageStore` to fan out a fetch per enabled scope and store stacked snapshots. Render via the existing stacked-snapshot menu pipeline by surfacing a Kilo-scoped accounts adapter.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`), `swift build` / `swift test` / `make check`, GitHub CLI for PR.

**Spec:** `docs/superpowers/specs/2026-05-11-kilo-organization-selection-design.md`

---

## Pre-flight (lead-only — do BEFORE dispatching tasks)

- [ ] **Step 0.1: Confirm clean working tree on `main`**

```bash
git status
```

Expected output: `nothing to commit, working tree clean` on branch `main` (the spec commit `c24e58a4` is already in).

- [ ] **Step 0.2: Create feature branch**

```bash
git switch -c feat/kilo-organization-selection
```

- [ ] **Step 0.3: Verify Swift toolchain and tests baseline**

```bash
swift build 2>&1 | tail -5
swift test --filter KiloUsageFetcherTests 2>&1 | tail -10
```

Expected: build succeeds, KiloUsageFetcher tests pass.

---

## Task 1: Add `KiloOrganization` data type

**Files:**
- Create: `Sources/CodexBarCore/Providers/Kilo/KiloOrganization.swift`
- Create: `Tests/CodexBarTests/KiloOrganizationTests.swift`

- [ ] **Step 1.1: Write the failing test**

Create `Tests/CodexBarTests/KiloOrganizationTests.swift`:

```swift
import Foundation
import Testing
@testable import CodexBarCore

struct KiloOrganizationTests {
    @Test
    func `decodes from canonical Kilo profile payload`() throws {
        let json = #"""
        { "id": "org_123", "name": "Acme Corp", "role": "owner" }
        """#
        let data = Data(json.utf8)
        let org = try JSONDecoder().decode(KiloOrganization.self, from: data)
        #expect(org.id == "org_123")
        #expect(org.name == "Acme Corp")
        #expect(org.role == "owner")
    }

    @Test
    func `decodes when role missing`() throws {
        let json = #"""
        { "id": "org_xyz", "name": "No Role Org" }
        """#
        let data = Data(json.utf8)
        let org = try JSONDecoder().decode(KiloOrganization.self, from: data)
        #expect(org.role == nil)
    }

    @Test
    func `equality covers all stored fields`() {
        let a = KiloOrganization(id: "org_1", name: "A", role: "member")
        let b = KiloOrganization(id: "org_1", name: "A", role: "member")
        let differentRole = KiloOrganization(id: "org_1", name: "A", role: "owner")
        #expect(a == b)
        #expect(a != differentRole)
    }
}
```

- [ ] **Step 1.2: Run test to verify it fails**

```bash
swift test --filter KiloOrganizationTests 2>&1 | tail -10
```

Expected: compile error "cannot find 'KiloOrganization' in scope".

- [ ] **Step 1.3: Create the type**

Create `Sources/CodexBarCore/Providers/Kilo/KiloOrganization.swift`:

```swift
import Foundation

public struct KiloOrganization: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let role: String?

    public init(id: String, name: String, role: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
    }
}
```

- [ ] **Step 1.4: Run tests, verify pass**

```bash
swift test --filter KiloOrganizationTests 2>&1 | tail -10
```

Expected: all 3 tests pass.

- [ ] **Step 1.5: Commit**

```bash
git add Sources/CodexBarCore/Providers/Kilo/KiloOrganization.swift \
        Tests/CodexBarTests/KiloOrganizationTests.swift
git commit -m "feat(kilo): add KiloOrganization model"
```

---

## Task 2: Add `KiloUsageScope` enum

**Files:**
- Create: `Sources/CodexBarCore/Providers/Kilo/KiloUsageScope.swift`
- Modify: `Tests/CodexBarTests/KiloOrganizationTests.swift`

- [ ] **Step 2.1: Append failing tests**

Append to `Tests/CodexBarTests/KiloOrganizationTests.swift`:

```swift
struct KiloUsageScopeTests {
    @Test
    func `personal scope identifier is stable`() {
        let scope: KiloUsageScope = .personal
        #expect(scope.scopeIdentifier == "personal")
    }

    @Test
    func `organization scope identifier prefixes id`() {
        let scope: KiloUsageScope = .organization(id: "org_42", name: "Acme")
        #expect(scope.scopeIdentifier == "org:org_42")
    }

    @Test
    func `organizationID is nil for personal`() {
        #expect(KiloUsageScope.personal.organizationID == nil)
    }

    @Test
    func `organizationID returns id for organization`() {
        let scope: KiloUsageScope = .organization(id: "org_42", name: "Acme")
        #expect(scope.organizationID == "org_42")
    }

    @Test
    func `displayName falls back to Personal for personal`() {
        #expect(KiloUsageScope.personal.displayName == "Personal")
    }

    @Test
    func `displayName uses org name for organization`() {
        let scope: KiloUsageScope = .organization(id: "org_42", name: "Acme")
        #expect(scope.displayName == "Acme")
    }
}
```

- [ ] **Step 2.2: Run test, verify it fails**

```bash
swift test --filter KiloUsageScopeTests 2>&1 | tail -10
```

Expected: compile error "cannot find 'KiloUsageScope' in scope".

- [ ] **Step 2.3: Create the type**

Create `Sources/CodexBarCore/Providers/Kilo/KiloUsageScope.swift`:

```swift
import Foundation

public enum KiloUsageScope: Sendable, Hashable, Equatable {
    case personal
    case organization(id: String, name: String)

    public var scopeIdentifier: String {
        switch self {
        case .personal:
            "personal"
        case let .organization(id, _):
            "org:\(id)"
        }
    }

    public var organizationID: String? {
        switch self {
        case .personal:
            nil
        case let .organization(id, _):
            id
        }
    }

    public var displayName: String {
        switch self {
        case .personal:
            "Personal"
        case let .organization(_, name):
            name
        }
    }
}
```

- [ ] **Step 2.4: Run tests, verify pass**

```bash
swift test --filter KiloUsageScopeTests 2>&1 | tail -10
```

Expected: all 6 tests pass.

- [ ] **Step 2.5: Commit**

```bash
git add Sources/CodexBarCore/Providers/Kilo/KiloUsageScope.swift \
        Tests/CodexBarTests/KiloOrganizationTests.swift
git commit -m "feat(kilo): add KiloUsageScope enum"
```

---

## Task 3: Inject org header in `KiloUsageFetcher.fetchUsage`

**Files:**
- Modify: `Sources/CodexBarCore/Providers/Kilo/KiloUsageFetcher.swift`
- Modify: `Tests/CodexBarTests/KiloUsageFetcherTests.swift`

- [ ] **Step 3.1: Append failing test for header injection**

Append the following inside `struct KiloUsageFetcherTests` in `Tests/CodexBarTests/KiloUsageFetcherTests.swift`:

```swift
    @Test
    func `request builder adds org header for organization scope`() throws {
        let baseURL = try #require(URL(string: "https://kilo.example/trpc"))
        let request = try KiloUsageFetcher._buildRequestForTesting(
            baseURL: baseURL,
            apiKey: "test-token",
            scope: .organization(id: "org_42", name: "Acme"))
        #expect(request.value(forHTTPHeaderField: "X-KILOCODE-ORGANIZATIONID") == "org_42")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test
    func `request builder omits org header for personal scope`() throws {
        let baseURL = try #require(URL(string: "https://kilo.example/trpc"))
        let request = try KiloUsageFetcher._buildRequestForTesting(
            baseURL: baseURL,
            apiKey: "test-token",
            scope: .personal)
        #expect(request.value(forHTTPHeaderField: "X-KILOCODE-ORGANIZATIONID") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }
```

- [ ] **Step 3.2: Run test, verify it fails**

```bash
swift test --filter KiloUsageFetcherTests 2>&1 | tail -15
```

Expected: compile error — `_buildRequestForTesting` not found.

- [ ] **Step 3.3: Refactor `KiloUsageFetcher` to accept scope and extract request builder**

In `Sources/CodexBarCore/Providers/Kilo/KiloUsageFetcher.swift`:

Replace the existing `public static func fetchUsage(apiKey:environment:)` signature (around line 258) with the scoped version, and extract the request building into a testable helper. The new code:

```swift
    public static func fetchUsage(
        apiKey: String,
        scope: KiloUsageScope = .personal,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> KiloUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KiloUsageError.missingCredentials
        }

        let baseURL = KiloSettingsReader.apiURL(environment: environment)
        let request = try self.makeRequest(baseURL: baseURL, apiKey: apiKey, scope: scope)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw KiloUsageError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KiloUsageError.networkError("Invalid response")
        }

        if let mapped = self.statusError(for: httpResponse.statusCode) {
            throw mapped
        }

        guard httpResponse.statusCode == 200 else {
            throw KiloUsageError.apiError(httpResponse.statusCode)
        }

        return try self.parseSnapshot(data: data)
    }

    static func _buildRequestForTesting(
        baseURL: URL,
        apiKey: String,
        scope: KiloUsageScope) throws -> URLRequest
    {
        try self.makeRequest(baseURL: baseURL, apiKey: apiKey, scope: scope)
    }

    private static func makeRequest(
        baseURL: URL,
        apiKey: String,
        scope: KiloUsageScope) throws -> URLRequest
    {
        let batchURL = try self.makeBatchURL(baseURL: baseURL)
        var request = URLRequest(url: batchURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let orgId = scope.organizationID {
            request.setValue(orgId, forHTTPHeaderField: "X-KILOCODE-ORGANIZATIONID")
        }
        return request
    }
```

Then delete the old inline `var request = URLRequest(url: batchURL)` setup that lived in `fetchUsage` (it's now in `makeRequest`).

- [ ] **Step 3.4: Run tests, verify pass**

```bash
swift test --filter KiloUsageFetcherTests 2>&1 | tail -15
```

Expected: all KiloUsageFetcher tests pass (existing + 2 new).

- [ ] **Step 3.5: Commit**

```bash
git add Sources/CodexBarCore/Providers/Kilo/KiloUsageFetcher.swift \
        Tests/CodexBarTests/KiloUsageFetcherTests.swift
git commit -m "feat(kilo): scope KiloUsageFetcher.fetchUsage with org header"
```

---

## Task 4: Add `fetchOrganizations` to `KiloUsageFetcher`

**Files:**
- Modify: `Sources/CodexBarCore/Providers/Kilo/KiloUsageFetcher.swift`
- Modify: `Tests/CodexBarTests/KiloUsageFetcherTests.swift`

- [ ] **Step 4.1: Append failing parse tests**

Append inside `struct KiloUsageFetcherTests`:

```swift
    @Test
    func `parseOrganizations decodes tRPC array shape`() throws {
        let json = #"""
        [
          {
            "result": {
              "data": {
                "json": [
                  { "id": "org_1", "name": "Alpha", "role": "owner" },
                  { "id": "org_2", "name": "Beta", "role": "member" }
                ]
              }
            }
          }
        ]
        """#
        let orgs = try KiloUsageFetcher._parseOrganizationsForTesting(Data(json.utf8))
        #expect(orgs.count == 2)
        #expect(orgs[0].id == "org_1")
        #expect(orgs[0].name == "Alpha")
        #expect(orgs[0].role == "owner")
        #expect(orgs[1].id == "org_2")
        #expect(orgs[1].role == "member")
    }

    @Test
    func `parseOrganizations decodes profile REST shape`() throws {
        let json = #"""
        {
          "user": { "email": "test@example.com" },
          "organizations": [
            { "id": "org_42", "name": "Gamma" }
          ]
        }
        """#
        let orgs = try KiloUsageFetcher._parseOrganizationsForTesting(Data(json.utf8))
        #expect(orgs.count == 1)
        #expect(orgs[0].id == "org_42")
        #expect(orgs[0].role == nil)
    }

    @Test
    func `parseOrganizations returns empty for no orgs`() throws {
        let json = #"""
        { "user": { "email": "x@y" }, "organizations": [] }
        """#
        let orgs = try KiloUsageFetcher._parseOrganizationsForTesting(Data(json.utf8))
        #expect(orgs.isEmpty)
    }
```

- [ ] **Step 4.2: Run, verify fail**

```bash
swift test --filter KiloUsageFetcherTests 2>&1 | tail -10
```

Expected: compile error — `_parseOrganizationsForTesting` undefined.

- [ ] **Step 4.3: Add organization fetching logic**

Append to `Sources/CodexBarCore/Providers/Kilo/KiloUsageFetcher.swift` (inside the `KiloUsageFetcher` struct):

```swift
    public static func fetchOrganizations(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> [KiloOrganization]
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KiloUsageError.missingCredentials
        }

        let baseURL = KiloSettingsReader.apiURL(environment: environment)
        let trpcRequest = try self.makeOrgListTRPCRequest(baseURL: baseURL, apiKey: apiKey)

        do {
            let (data, response) = try await URLSession.shared.data(for: trpcRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw KiloUsageError.networkError("Invalid response")
            }
            if httpResponse.statusCode == 404 {
                return try await self.fetchOrganizationsRESTFallback(apiKey: apiKey)
            }
            if let mapped = self.statusError(for: httpResponse.statusCode) {
                throw mapped
            }
            return try self.parseOrganizations(data: data)
        } catch let error as KiloUsageError {
            throw error
        } catch {
            throw KiloUsageError.networkError(error.localizedDescription)
        }
    }

    static func _parseOrganizationsForTesting(_ data: Data) throws -> [KiloOrganization] {
        try self.parseOrganizations(data: data)
    }

    private static func makeOrgListTRPCRequest(
        baseURL: URL,
        apiKey: String) throws -> URLRequest
    {
        let endpoint = baseURL.appendingPathComponent("user.getOrganizations")
        let inputData = try JSONSerialization.data(
            withJSONObject: ["0": ["json": NSNull()]] as [String: Any])
        guard let inputString = String(data: inputData, encoding: .utf8),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw KiloUsageError.parseFailed("Invalid org list endpoint")
        }
        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: inputString),
        ]
        guard let url = components.url else {
            throw KiloUsageError.parseFailed("Invalid org list endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func fetchOrganizationsRESTFallback(apiKey: String) async throws -> [KiloOrganization] {
        guard let url = URL(string: "https://api.kilo.ai/api/profile") else {
            throw KiloUsageError.parseFailed("Invalid REST fallback URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KiloUsageError.networkError("Invalid response")
        }
        if let mapped = self.statusError(for: httpResponse.statusCode) {
            throw mapped
        }
        guard httpResponse.statusCode == 200 else {
            throw KiloUsageError.apiError(httpResponse.statusCode)
        }
        return try self.parseOrganizations(data: data)
    }

    private static func parseOrganizations(data: Data) throws -> [KiloOrganization] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw KiloUsageError.parseFailed("Invalid JSON")
        }

        // tRPC batch shape: [ { result: { data: { json: [orgs] } } } ]
        if let entries = root as? [[String: Any]],
           let first = entries.first,
           let resultObject = first["result"] as? [String: Any]
        {
            if let dataObject = resultObject["data"] as? [String: Any],
               let payload = dataObject["json"] as? [[String: Any]]
            {
                return self.decodeOrganizations(payload)
            }
            if let payload = resultObject["data"] as? [[String: Any]] {
                return self.decodeOrganizations(payload)
            }
        }

        // REST profile shape: { user: ..., organizations: [orgs] }
        if let dictionary = root as? [String: Any] {
            if let orgs = dictionary["organizations"] as? [[String: Any]] {
                return self.decodeOrganizations(orgs)
            }
            // Some single-procedure tRPC shapes flatten to { result: { data: { json: { organizations: [...] }}}}
            if let resultObject = dictionary["result"] as? [String: Any],
               let dataObject = resultObject["data"] as? [String: Any]
            {
                if let payload = dataObject["json"] as? [[String: Any]] {
                    return self.decodeOrganizations(payload)
                }
                if let payload = dataObject["json"] as? [String: Any],
                   let orgs = payload["organizations"] as? [[String: Any]]
                {
                    return self.decodeOrganizations(orgs)
                }
            }
        }

        return []
    }

    private static func decodeOrganizations(_ raw: [[String: Any]]) -> [KiloOrganization] {
        raw.compactMap { item -> KiloOrganization? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let name = (item["name"] as? String).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? id
            let role = (item["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedRole = (role?.isEmpty ?? true) ? nil : role
            return KiloOrganization(id: id, name: name.isEmpty ? id : name, role: normalizedRole)
        }
    }
```

- [ ] **Step 4.4: Run tests, verify pass**

```bash
swift test --filter KiloUsageFetcherTests 2>&1 | tail -15
```

Expected: all 3 new parse tests pass plus prior tests.

- [ ] **Step 4.5: Commit**

```bash
git add Sources/CodexBarCore/Providers/Kilo/KiloUsageFetcher.swift \
        Tests/CodexBarTests/KiloUsageFetcherTests.swift
git commit -m "feat(kilo): add fetchOrganizations with REST fallback"
```

---

## Task 5: Extend `ProviderConfig` with `kiloOrganizations`

**Files:**
- Modify: `Sources/CodexBarCore/Config/CodexBarConfig.swift`
- Tests: covered indirectly via Task 6 SettingsStore tests.

- [ ] **Step 5.1: Add fields to `ProviderConfig`**

In `Sources/CodexBarCore/Config/CodexBarConfig.swift`, inside `public struct ProviderConfig`:

After the existing `public var quotaWarnings: QuotaWarningConfig?` line, add:

```swift
    public var kiloKnownOrganizations: [KiloOrganization]?
    public var kiloEnabledOrganizationIDs: [String]?
```

Then extend the `init` signature with these matching parameters (defaulted to `nil`) and assign them in the body. Match the existing init ordering pattern — add the two new parameters at the bottom of the init parameter list:

```swift
    public init(
        id: UsageProvider,
        enabled: Bool? = nil,
        source: ProviderSourceMode? = nil,
        extrasEnabled: Bool? = nil,
        apiKey: String? = nil,
        cookieHeader: String? = nil,
        cookieSource: ProviderCookieSource? = nil,
        region: String? = nil,
        workspaceID: String? = nil,
        enterpriseHost: String? = nil,
        tokenAccounts: ProviderTokenAccountData? = nil,
        codexActiveSource: CodexActiveSource? = nil,
        quotaWarnings: QuotaWarningConfig? = nil,
        kiloKnownOrganizations: [KiloOrganization]? = nil,
        kiloEnabledOrganizationIDs: [String]? = nil)
    {
        self.id = id
        self.enabled = enabled
        self.source = source
        self.extrasEnabled = extrasEnabled
        self.apiKey = apiKey
        self.cookieHeader = cookieHeader
        self.cookieSource = cookieSource
        self.region = region
        self.workspaceID = workspaceID
        self.enterpriseHost = enterpriseHost
        self.tokenAccounts = tokenAccounts
        self.codexActiveSource = codexActiveSource
        self.quotaWarnings = quotaWarnings
        self.kiloKnownOrganizations = kiloKnownOrganizations
        self.kiloEnabledOrganizationIDs = kiloEnabledOrganizationIDs
    }
```

The implicit `Codable` conformance will pick up the new optional fields automatically.

- [ ] **Step 5.2: Build to verify schema compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 5.3: Commit**

```bash
git add Sources/CodexBarCore/Config/CodexBarConfig.swift
git commit -m "feat(kilo): persist kilo organizations in ProviderConfig"
```

---

## Task 6: Extend `SettingsStore` with Kilo orgs accessors

**Files:**
- Modify: `Sources/CodexBar/Providers/Kilo/KiloSettingsStore.swift`
- Create: `Tests/CodexBarTests/KiloSettingsStoreTests.swift`

- [ ] **Step 6.1: Write failing tests**

Create `Tests/CodexBarTests/KiloSettingsStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct KiloSettingsStoreTests {
    private func makeSettings() -> SettingsStore {
        let env = ProviderConfigEnvironment(
            configFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "kilo-org-settings-test-\(UUID().uuidString).json"),
            environment: [:])
        return SettingsStore(providerConfigEnvironment: env)
    }

    @Test
    func `defaults to empty known organizations and empty enabled ids`() {
        let settings = self.makeSettings()
        #expect(settings.kiloKnownOrganizations.isEmpty)
        #expect(settings.kiloEnabledOrganizationIDs.isEmpty)
    }

    @Test
    func `setting known organizations persists them`() {
        let settings = self.makeSettings()
        let orgs = [
            KiloOrganization(id: "org_1", name: "Alpha", role: "owner"),
            KiloOrganization(id: "org_2", name: "Beta", role: "member"),
        ]
        settings.kiloKnownOrganizations = orgs
        #expect(settings.kiloKnownOrganizations == orgs)
    }

    @Test
    func `setting enabled org ids persists them`() {
        let settings = self.makeSettings()
        settings.kiloEnabledOrganizationIDs = ["org_1", "org_2"]
        #expect(settings.kiloEnabledOrganizationIDs == ["org_1", "org_2"])
    }

    @Test
    func `setKiloKnownOrganizations prunes stale enabled ids`() {
        let settings = self.makeSettings()
        settings.kiloKnownOrganizations = [
            KiloOrganization(id: "org_1", name: "Alpha", role: nil),
            KiloOrganization(id: "org_2", name: "Beta", role: nil),
        ]
        settings.kiloEnabledOrganizationIDs = ["org_1", "org_2"]
        settings.setKiloKnownOrganizationsPruningEnabled(
            [KiloOrganization(id: "org_2", name: "Beta", role: nil)])
        #expect(settings.kiloKnownOrganizations.map(\.id) == ["org_2"])
        #expect(settings.kiloEnabledOrganizationIDs == ["org_2"])
    }
}
```

- [ ] **Step 6.2: Run, verify fail**

```bash
swift test --filter KiloSettingsStoreTests 2>&1 | tail -10
```

Expected: compile error — missing properties.

- [ ] **Step 6.3: Add accessors to `KiloSettingsStore`**

Append to `Sources/CodexBar/Providers/Kilo/KiloSettingsStore.swift`:

```swift
extension SettingsStore {
    var kiloKnownOrganizations: [KiloOrganization] {
        get { self.configSnapshot.providerConfig(for: .kilo)?.kiloKnownOrganizations ?? [] }
        set {
            self.updateProviderConfig(provider: .kilo) { entry in
                entry.kiloKnownOrganizations = newValue.isEmpty ? nil : newValue
            }
        }
    }

    var kiloEnabledOrganizationIDs: [String] {
        get { self.configSnapshot.providerConfig(for: .kilo)?.kiloEnabledOrganizationIDs ?? [] }
        set {
            let cleaned = Array(LinkedHashSet(newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }))
            self.updateProviderConfig(provider: .kilo) { entry in
                entry.kiloEnabledOrganizationIDs = cleaned.isEmpty ? nil : cleaned
            }
            self.logProviderModeChange(
                provider: .kilo,
                field: "enabledOrganizations",
                value: cleaned.joined(separator: ","))
        }
    }

    func setKiloKnownOrganizationsPruningEnabled(_ orgs: [KiloOrganization]) {
        self.kiloKnownOrganizations = orgs
        let validIDs = Set(orgs.map(\.id))
        let pruned = self.kiloEnabledOrganizationIDs.filter { validIDs.contains($0) }
        if pruned != self.kiloEnabledOrganizationIDs {
            self.kiloEnabledOrganizationIDs = pruned
        }
    }

    func kiloIsOrganizationEnabled(_ orgID: String) -> Bool {
        self.kiloEnabledOrganizationIDs.contains(orgID)
    }

    func setKiloOrganization(_ orgID: String, enabled: Bool) {
        var current = self.kiloEnabledOrganizationIDs
        if enabled {
            guard !current.contains(orgID) else { return }
            current.append(orgID)
        } else {
            current.removeAll { $0 == orgID }
        }
        self.kiloEnabledOrganizationIDs = current
    }
}

// Small order-preserving set used to dedupe enabled IDs without sorting.
private struct LinkedHashSet<Element: Hashable>: Sequence {
    private var seen: Set<Element> = []
    private var ordered: [Element] = []

    init<S: Sequence>(_ sequence: S) where S.Element == Element {
        for element in sequence where self.seen.insert(element).inserted {
            self.ordered.append(element)
        }
    }

    func makeIterator() -> IndexingIterator<[Element]> {
        self.ordered.makeIterator()
    }
}
```

- [ ] **Step 6.4: Run tests, verify pass**

```bash
swift test --filter KiloSettingsStoreTests 2>&1 | tail -10
```

Expected: all 4 tests pass.

- [ ] **Step 6.5: Commit**

```bash
git add Sources/CodexBar/Providers/Kilo/KiloSettingsStore.swift \
        Tests/CodexBarTests/KiloSettingsStoreTests.swift
git commit -m "feat(kilo): settings accessors for known + enabled organizations"
```

---

## Task 7: Wire scoped fetching into Kilo strategies

**Files:**
- Modify: `Sources/CodexBarCore/Providers/Kilo/KiloProviderDescriptor.swift`
- Modify: `Sources/CodexBar/UsageStore+Refresh.swift`
- Create: `Sources/CodexBar/Providers/Kilo/UsageStore+KiloOrgRefresh.swift`

The `ProviderFetchStrategy` returns one `UsageSnapshot`, so we keep the existing strategy returning the personal scope. Org snapshots are fanned out at the UsageStore layer, mirroring `refreshTokenAccounts`.

- [ ] **Step 7.1: Add scope-aware overload to the AP strategies (no-op call path so they still build)**

This task does NOT change `KiloAPIFetchStrategy.fetch`. The strategy continues to fetch the personal scope. The fan-out is added at the UsageStore layer below. Skip directly to step 7.2.

- [ ] **Step 7.2: Add a Kilo scope account adapter**

The codebase already has `TokenAccountUsageSnapshot` for stacked rendering. We mirror that for Kilo scopes.

Create `Sources/CodexBar/Providers/Kilo/UsageStore+KiloOrgRefresh.swift`:

```swift
import CodexBarCore
import Foundation

struct KiloScopeSnapshot: Identifiable, Equatable {
    let id: String // KiloUsageScope.scopeIdentifier
    let scope: KiloUsageScope
    let snapshot: UsageSnapshot?
    let errorMessage: String?
    let sourceLabel: String?

    static func == (lhs: KiloScopeSnapshot, rhs: KiloScopeSnapshot) -> Bool {
        lhs.id == rhs.id
            && lhs.snapshot?.updatedAt == rhs.snapshot?.updatedAt
            && lhs.errorMessage == rhs.errorMessage
            && lhs.sourceLabel == rhs.sourceLabel
    }
}

extension UsageStore {
    var kiloEnabledScopes: [KiloUsageScope] {
        var scopes: [KiloUsageScope] = [.personal]
        let enabled = self.settings.kiloEnabledOrganizationIDs
        guard !enabled.isEmpty else { return scopes }
        let knownByID = Dictionary(
            uniqueKeysWithValues: self.settings.kiloKnownOrganizations.map { ($0.id, $0) })
        for id in enabled {
            if let org = knownByID[id] {
                scopes.append(.organization(id: org.id, name: org.name))
            }
        }
        return scopes
    }

    func shouldFanOutKiloScopes() -> Bool {
        self.kiloEnabledScopes.count > 1
    }

    func refreshKiloScopes() async {
        let scopes = self.kiloEnabledScopes
        guard scopes.count > 1 else {
            await MainActor.run { self.kiloScopeSnapshots = [] }
            return
        }
        let apiKey = self.settings.configSnapshot.providerConfig(for: .kilo)?.sanitizedAPIKey
            ?? ProcessInfo.processInfo.environment[KiloSettingsReader.apiTokenKey]
        guard let resolvedKey = apiKey, !resolvedKey.isEmpty else {
            await MainActor.run {
                self.kiloScopeSnapshots = scopes.map {
                    KiloScopeSnapshot(
                        id: $0.scopeIdentifier,
                        scope: $0,
                        snapshot: nil,
                        errorMessage: "Kilo API credentials missing.",
                        sourceLabel: nil)
                }
            }
            return
        }

        let env = ProcessInfo.processInfo.environment
        let results: [KiloScopeSnapshot] = await withTaskGroup(of: KiloScopeSnapshot.self) { group in
            for scope in scopes {
                group.addTask {
                    do {
                        let raw = try await KiloUsageFetcher.fetchUsage(
                            apiKey: resolvedKey,
                            scope: scope,
                            environment: env)
                        var snapshot = raw.toUsageSnapshot()
                        snapshot = snapshot.replacingIdentityOrganization(scope.displayName)
                        return KiloScopeSnapshot(
                            id: scope.scopeIdentifier,
                            scope: scope,
                            snapshot: snapshot,
                            errorMessage: nil,
                            sourceLabel: "api")
                    } catch {
                        return KiloScopeSnapshot(
                            id: scope.scopeIdentifier,
                            scope: scope,
                            snapshot: nil,
                            errorMessage: (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription,
                            sourceLabel: nil)
                    }
                }
            }
            var collected: [KiloScopeSnapshot] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // Preserve the order from `scopes` (personal first, then enabled orgs in order).
        let resultByID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        let ordered = scopes.compactMap { resultByID[$0.scopeIdentifier] }

        await MainActor.run {
            self.kiloScopeSnapshots = ordered
        }
    }
}

extension UsageSnapshot {
    fileprivate func replacingIdentityOrganization(_ org: String) -> UsageSnapshot {
        let baseIdentity = self.identity
        let newIdentity = ProviderIdentitySnapshot(
            providerID: baseIdentity?.providerID ?? .kilo,
            accountEmail: baseIdentity?.accountEmail,
            accountOrganization: org,
            loginMethod: baseIdentity?.loginMethod)
        return UsageSnapshot(
            primary: self.primary,
            secondary: self.secondary,
            tertiary: self.tertiary,
            providerCost: self.providerCost,
            updatedAt: self.updatedAt,
            identity: newIdentity)
    }
}
```

- [ ] **Step 7.3: Add the `kiloScopeSnapshots` stored property to `UsageStore`**

In `Sources/CodexBar/UsageStore.swift`, find the closest place where Codex-related published properties live (e.g. near `codexAccountSnapshots`) and add:

```swift
    @Published var kiloScopeSnapshots: [KiloScopeSnapshot] = []
```

Choose a location adjacent to existing per-provider stacked snapshot arrays. The exact line is around `codexAccountSnapshots: [CodexAccountUsageSnapshot] = []` — add directly below it.

- [ ] **Step 7.4: Invoke fan-out from `refreshProvider`**

In `Sources/CodexBar/UsageStore+Refresh.swift`, find the existing `tokenAccounts` fan-out block in `refreshProvider`:

```swift
        let tokenAccounts = self.tokenAccounts(for: provider)
        if self.shouldFetchAllTokenAccounts(provider: provider, accounts: tokenAccounts) {
            await self.refreshTokenAccounts(provider: provider, accounts: tokenAccounts)
            return
        }
```

Insert directly above it (before line 55):

```swift
        if provider == .kilo, self.shouldFanOutKiloScopes() {
            await self.refreshKiloScopes()
            // Continue to also fetch the personal snapshot through the regular path
            // so the existing single-card render keeps working when only personal is shown.
            // The presence of multi-element kiloScopeSnapshots triggers stacked rendering.
        }
```

- [ ] **Step 7.5: Reset `kiloScopeSnapshots` when Kilo is disabled or single-scope**

Inside the existing disabled-provider branch of `refreshProvider` (the block that runs when `!spec.isEnabled()`), add inside the `MainActor.run`:

```swift
                if provider == .kilo {
                    self.kiloScopeSnapshots = []
                }
```

Also at the start of the regular fetch path (just before `let fetchContext = spec.makeFetchContext()`), add:

```swift
        if provider == .kilo, !self.shouldFanOutKiloScopes() {
            await MainActor.run { self.kiloScopeSnapshots = [] }
        }
```

- [ ] **Step 7.6: Build to confirm wiring compiles**

```bash
swift build 2>&1 | tail -15
```

Expected: succeeds. If `UsageSnapshot.replacingIdentityOrganization` clashes with an existing extension, rename to `withAccountOrganization` and update the call site.

- [ ] **Step 7.7: Commit**

```bash
git add Sources/CodexBar/UsageStore.swift \
        Sources/CodexBar/UsageStore+Refresh.swift \
        Sources/CodexBar/Providers/Kilo/UsageStore+KiloOrgRefresh.swift
git commit -m "feat(kilo): fan out usage fetch per enabled scope"
```

---

## Task 8: Surface scope snapshots in menu rendering

**Files:**
- Modify: `Sources/CodexBar/StatusItemController+MenuCardModel.swift` (or the file that produces Kilo menu rows)
- Modify: `Sources/CodexBar/MenuDescriptor.swift` if needed

The menu currently renders one Kilo card. Add a branch: when `kiloScopeSnapshots` has 2+ entries, render one card per scope.

- [ ] **Step 8.1: Locate the Kilo menu-row producer**

```bash
grep -n "case \\.kilo" Sources/CodexBar/StatusItemController*.swift Sources/CodexBar/Menu*.swift 2>&1 | head -15
```

This points at the rendering site. Open whichever file produces the per-provider row group for Kilo.

- [ ] **Step 8.2: Insert scope-fan-out in the Kilo row builder**

At the location that produces the Kilo `MenuCardModel` (or the equivalent NSMenu items), guard:

```swift
if !self.kiloScopeSnapshots.isEmpty, self.kiloScopeSnapshots.count > 1 {
    return self.kiloScopeSnapshots.map { scope -> MenuCardModel in
        self.makeKiloMenuCard(
            snapshot: scope.snapshot,
            errorMessage: scope.errorMessage,
            sourceLabel: scope.sourceLabel,
            scopeName: scope.scope.displayName)
    }
}
```

If a helper named `makeKiloMenuCard(...)` does not exist, factor the existing inline Kilo card construction into one, taking the four parameters above. Reuse the same code path used by Claude's stacked tokenAccount rendering as a structural reference.

- [ ] **Step 8.3: Verify visually using CLI snapshot test (no UI required)**

```bash
swift test --filter CLIRendererTests 2>&1 | tail -15
swift test --filter MenuCardModelTests 2>&1 | tail -15
```

Existing tests must continue to pass.

- [ ] **Step 8.4: Build**

```bash
swift build 2>&1 | tail -5
```

Expected: success.

- [ ] **Step 8.5: Commit**

```bash
git add Sources/CodexBar/StatusItemController+MenuCardModel.swift \
        Sources/CodexBar/MenuDescriptor.swift
git commit -m "feat(kilo): render one menu card per enabled scope"
```

---

## Task 9: Preferences pane — Organizations section

**Files:**
- Modify: `Sources/CodexBar/Providers/Kilo/KiloProviderImplementation.swift`
- Possibly modify: `Sources/CodexBar/PreferencesProviderDetailView.swift` and `Sources/CodexBarCore/Providers/ProviderDescriptor.swift` if a new descriptor variant is needed.

If a multi-toggle descriptor is not yet supported, surface the org list using a `ProviderSettingsFieldDescriptor.kind = .info`-style wrapper combined with action buttons, OR add a new descriptor variant. Pick the minimum needed.

- [ ] **Step 9.1: Add an org-section descriptor type**

Search first to see whether the existing `ProviderSettingsFieldDescriptor` already has a list/toggle kind:

```bash
grep -n "enum Kind\|case info\|case toggleList\|case checkboxList" \
    Sources/CodexBarCore/Providers/ProviderDescriptor.swift \
    Sources/CodexBar/PreferencesProviderDetailView.swift 2>&1 | head -20
```

If a toggle-list kind exists, reuse it. Otherwise, add a new `ProviderSettingsOrganizationsDescriptor` in `Sources/CodexBarCore/Providers/ProviderDescriptor.swift`:

```swift
public struct ProviderSettingsOrganizationsDescriptor: Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let entries: () -> [Entry]
    public let onToggle: @MainActor (String, Bool) -> Void
    public let onRefresh: @MainActor () async -> RefreshOutcome
    public let canRefresh: () -> Bool

    public struct Entry: Sendable, Identifiable {
        public let id: String
        public let title: String
        public let subtitle: String?
        public let isEnabled: Bool
        public let isLocked: Bool

        public init(id: String, title: String, subtitle: String?, isEnabled: Bool, isLocked: Bool) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.isEnabled = isEnabled
            self.isLocked = isLocked
        }
    }

    public struct RefreshOutcome: Sendable {
        public let success: Bool
        public let errorMessage: String?

        public init(success: Bool, errorMessage: String? = nil) {
            self.success = success
            self.errorMessage = errorMessage
        }
    }

    public init(
        id: String,
        title: String,
        subtitle: String?,
        entries: @escaping () -> [Entry],
        onToggle: @escaping @MainActor (String, Bool) -> Void,
        onRefresh: @escaping @MainActor () async -> RefreshOutcome,
        canRefresh: @escaping () -> Bool)
    {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.entries = entries
        self.onToggle = onToggle
        self.onRefresh = onRefresh
        self.canRefresh = canRefresh
    }
}
```

Then add an optional `settingsOrganizations:` slot to whatever protocol `ProviderImplementation` exposes (e.g. add `func settingsOrganizations(context: ProviderSettingsContext) -> ProviderSettingsOrganizationsDescriptor?`). Default the protocol method to `nil`.

- [ ] **Step 9.2: Implement `settingsOrganizations` in `KiloProviderImplementation`**

In `Sources/CodexBar/Providers/Kilo/KiloProviderImplementation.swift`:

```swift
    @MainActor
    func settingsOrganizations(
        context: ProviderSettingsContext) -> ProviderSettingsOrganizationsDescriptor?
    {
        ProviderSettingsOrganizationsDescriptor(
            id: "kilo-organizations",
            title: "Organizations",
            subtitle: "Show usage for organizations you belong to. Personal account is always shown.",
            entries: {
                var entries: [ProviderSettingsOrganizationsDescriptor.Entry] = [
                    .init(
                        id: "personal",
                        title: "Personal account",
                        subtitle: nil,
                        isEnabled: true,
                        isLocked: true),
                ]
                for org in context.settings.kiloKnownOrganizations {
                    entries.append(
                        .init(
                            id: org.id,
                            title: org.name,
                            subtitle: org.role,
                            isEnabled: context.settings.kiloIsOrganizationEnabled(org.id),
                            isLocked: false))
                }
                return entries
            },
            onToggle: { orgID, enabled in
                guard orgID != "personal" else { return }
                context.settings.setKiloOrganization(orgID, enabled: enabled)
            },
            onRefresh: {
                let apiKey = context.settings.kiloAPIToken.isEmpty
                    ? ProcessInfo.processInfo.environment[KiloSettingsReader.apiTokenKey] ?? ""
                    : context.settings.kiloAPIToken
                guard !apiKey.isEmpty else {
                    return .init(success: false,
                        errorMessage: "Set the Kilo API key first.")
                }
                do {
                    let orgs = try await KiloUsageFetcher.fetchOrganizations(apiKey: apiKey)
                    context.settings.setKiloKnownOrganizationsPruningEnabled(orgs)
                    return .init(success: true)
                } catch let error as LocalizedError {
                    return .init(success: false,
                        errorMessage: error.errorDescription ?? "Failed to load organizations.")
                } catch {
                    return .init(success: false,
                        errorMessage: error.localizedDescription)
                }
            },
            canRefresh: {
                !context.settings.kiloAPIToken.isEmpty
                    || !(ProcessInfo.processInfo.environment[KiloSettingsReader.apiTokenKey] ?? "").isEmpty
            })
    }
```

- [ ] **Step 9.3: Render the new descriptor in `PreferencesProviderDetailView`**

In `Sources/CodexBar/PreferencesProviderDetailView.swift`, follow the existing pattern used by `settingsTokenAccounts`. Add a stored property `settingsOrganizations: ProviderSettingsOrganizationsDescriptor?`, source it from the provider implementation, and render it as a SwiftUI section under the API key:

```swift
if let descriptor = self.settingsOrganizations {
    Section(descriptor.title) {
        if let subtitle = descriptor.subtitle {
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(descriptor.entries(), id: \.id) { entry in
            Toggle(isOn: Binding(
                get: { entry.isEnabled },
                set: { newValue in descriptor.onToggle(entry.id, newValue) }))
            {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                    if let subtitle = entry.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(entry.isLocked)
        }
        HStack {
            Button("Refresh organizations") {
                Task {
                    let result = await descriptor.onRefresh()
                    if !result.success, let message = result.errorMessage {
                        self.kiloOrganizationsErrorMessage = message
                    } else {
                        self.kiloOrganizationsErrorMessage = nil
                    }
                }
            }
            .disabled(!descriptor.canRefresh())
            Spacer()
            if let message = self.kiloOrganizationsErrorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
```

Add `@State private var kiloOrganizationsErrorMessage: String?` near other `@State` properties in the view.

- [ ] **Step 9.4: Build and verify**

```bash
swift build 2>&1 | tail -10
```

Expected: success. If type mismatches arise, follow them and align signatures.

- [ ] **Step 9.5: Commit**

```bash
git add Sources/CodexBarCore/Providers/ProviderDescriptor.swift \
        Sources/CodexBar/Providers/Kilo/KiloProviderImplementation.swift \
        Sources/CodexBar/PreferencesProviderDetailView.swift
git commit -m "feat(kilo): Preferences organizations section with refresh + toggles"
```

---

## Task 10: Update Kilo docs

**Files:**
- Modify: `docs/kilo.md`

- [ ] **Step 10.1: Add a "Organizations" section**

Append to `docs/kilo.md`:

```markdown
## Organizations

CodexBar can show usage for any Kilo organization the API key belongs to.

- Open Preferences → Providers → Kilo, set the API key, then click **Refresh
  organizations**.
- Toggle the organizations you want to display alongside Personal. Personal is
  always shown.
- When at least one organization is enabled, the menu renders one Kilo card per
  enabled scope.
- The CodexBar fetcher sends the standard `X-KILOCODE-ORGANIZATIONID` header on
  every usage call to scope the response to that organization.
- CLI source mode (`auth.json`): the header is applied to CLI-resolved tokens
  as well. If a CLI token isn't authorized for the chosen organization, that
  card surfaces an unauthorized error while Personal and other enabled scopes
  continue to render normally.
```

- [ ] **Step 10.2: Commit**

```bash
git add docs/kilo.md
git commit -m "docs(kilo): document organization selection"
```

---

## Task 11: Repo-wide validation

- [ ] **Step 11.1: Run the full unit test suite**

```bash
swift test 2>&1 | tail -30
```

Expected: all tests pass. If new failures appear in unrelated tests (network-flaky, etc.), record and rerun.

- [ ] **Step 11.2: Run `make check`**

```bash
make check 2>&1 | tail -30
```

Expected: swiftformat + swiftlint clean. Fix any reported issues by applying suggestions inline and re-running.

- [ ] **Step 11.3: Build release config to ensure no debug-only types leaked**

```bash
swift build -c release 2>&1 | tail -10
```

Expected: success.

- [ ] **Step 11.4: Commit any lint/format fixups**

```bash
git status
git diff --stat
git add -A
git commit -m "chore: swiftformat/swiftlint fixups for kilo orgs work"
```

(Skip if no diff.)

---

## Task 12: Open the PR (lead-only — runs after all build tasks land)

- [ ] **Step 12.1: Ensure a fork exists for `noefabris`**

```bash
gh repo view noefabris/CodexBar --json url 2>&1 | head -5
```

If 404, fork:

```bash
gh repo fork steipete/CodexBar --remote=false --clone=false
```

- [ ] **Step 12.2: Add fork as a remote (if missing) and push**

```bash
git remote get-url fork 2>/dev/null || git remote add fork https://github.com/noefabris/CodexBar.git
git push -u fork feat/kilo-organization-selection
```

- [ ] **Step 12.3: Create the PR**

```bash
gh pr create \
  --repo steipete/CodexBar \
  --base main \
  --head noefabris:feat/kilo-organization-selection \
  --title "Add Kilo organization selection (usage stacking)" \
  --body "$(cat <<'EOF'
## Summary
- Adds Kilo organization selection to Preferences → Providers → Kilo.
- Refresh button fetches `user.getOrganizations` (with `/api/profile` REST fallback).
- Each enabled organization is fetched in parallel with the personal account using the standard `X-KILOCODE-ORGANIZATIONID` header.
- The Kilo menu now stacks one card per enabled scope (Personal + each chosen org), reusing the existing multi-snapshot rendering pattern.

## Design doc
- `docs/superpowers/specs/2026-05-11-kilo-organization-selection-design.md`
- `docs/superpowers/plans/2026-05-11-kilo-organization-selection.md`

## Test plan
- [x] `swift test` passes
- [x] `make check` clean
- [x] `swift build -c release` succeeds
- [ ] Manual: launch app, set Kilo API key, hit Refresh organizations, toggle orgs, observe stacked menu cards
- [ ] Manual: revoke org permission and confirm only that scope errors out

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Capture the printed PR URL.

- [ ] **Step 12.4: Report the PR URL back to the user**

---

## Self-review checklist

- [x] Each spec section has at least one task implementing it.
- [x] Task 4 covers both tRPC and REST org-discovery shapes (spec §2).
- [x] Task 7 fan-out covers both API and CLI source modes — the strategy resolves the token, then `refreshKiloScopes` reuses the same API key transport.
- [x] Persistence covered by Task 5 + 6.
- [x] UI section covered by Task 9.
- [x] Menu rendering covered by Task 8.
- [x] Tests written before implementation per TDD in Tasks 1–6.
- [x] No placeholders ("TBD", "fill in later", etc.).
- [x] Types stay consistent: `KiloOrganization`, `KiloUsageScope`, `KiloScopeSnapshot` referenced consistently across tasks.
- [x] Out-of-scope items from spec (menu switcher, multi-key auth, widget) intentionally absent.

If during execution any task uncovers an actual gap not covered above (e.g. existing tests that mock `KiloUsageFetcher.fetchUsage(apiKey:environment:)` without `scope`), update them to use `scope: .personal` explicitly — keep the default-parameter migration path even though tests typically pass it explicitly.
