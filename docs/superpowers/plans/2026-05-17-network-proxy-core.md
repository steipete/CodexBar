# Network Proxy Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add invisible network proxy configuration support to CodexBar's config model and validation so the next UI PR can build on a stable, testable core.

**Architecture:** Keep proxy state as a codable value inside `CodexBarConfig`, validate it centrally in `CodexBarConfigValidator`, and rely on the existing `CodexBarConfigStore` save/load path to persist it unchanged. Do not touch transport wiring, password storage, or any Settings UI in this PR.

**Tech Stack:** Swift 6, Foundation, existing `CodexBarCore` config types, XCTest-style unit tests in `Tests/CodexBarTests`.

---

### Task 1: Add proxy config model to `CodexBarCore`

**Files:**
- Create: `/Users/sergey-selderey/Projects/CodexBar/Sources/CodexBarCore/Config/NetworkProxyConfiguration.swift`
- Modify: `/Users/sergey-selderey/Projects/CodexBar/Sources/CodexBarCore/Config/CodexBarConfig.swift:1-220`
- Modify: `/Users/sergey-selderey/Projects/CodexBar/Tests/CodexBarTests/ConfigValidationTests.swift`

- [ ] **Step 1: Write the failing test**

Add a round-trip test that encodes and decodes a config with proxy data:

```swift
func testNetworkProxyConfigEncodesAndDecodes() throws {
    let config = CodexBarConfig(
        providers: [],
        networkProxy: NetworkProxyConfiguration(
            enabled: true,
            scheme: .http,
            host: "proxy.example.com",
            port: "8080",
            username: "codex"))

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: data)

    #expect(decoded.networkProxy?.enabled == true)
    #expect(decoded.networkProxy?.scheme == .http)
    #expect(decoded.networkProxy?.host == "proxy.example.com")
    #expect(decoded.networkProxy?.port == "8080")
    #expect(decoded.networkProxy?.username == "codex")
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter ConfigValidationTests/testNetworkProxyConfigEncodesAndDecodes`

Expected: fail because `networkProxy` is not yet part of the config model.

- [ ] **Step 3: Implement the model**

Add this type:

```swift
import Foundation

public enum NetworkProxyScheme: String, CaseIterable, Codable, Sendable {
    case http
    case socks5
}

public struct NetworkProxyConfiguration: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var scheme: NetworkProxyScheme
    public var host: String
    public var port: String
    public var username: String

    public init(enabled: Bool, scheme: NetworkProxyScheme, host: String, port: String, username: String) {
        self.enabled = enabled
        self.scheme = scheme
        self.host = host
        self.port = port
        self.username = username
    }

    public var trimmedHost: String { self.host.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedPort: String { self.port.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedUsername: String { self.username.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var resolvedPort: Int? {
        guard let port = Int(self.trimmedPort), (1...65535).contains(port) else { return nil }
        return port
    }

    public var isActive: Bool {
        self.enabled && !self.trimmedHost.isEmpty && self.resolvedPort != nil
    }
}
```

Update `CodexBarConfig` to store:

```swift
public var networkProxy: NetworkProxyConfiguration?
```

and extend its initializer to accept `networkProxy: NetworkProxyConfiguration? = nil`.

- [ ] **Step 4: Run the test and confirm it passes**

Run: `swift test --filter ConfigValidationTests/testNetworkProxyConfigEncodesAndDecodes`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexBarCore/Config/NetworkProxyConfiguration.swift Sources/CodexBarCore/Config/CodexBarConfig.swift
git commit -m "feat(proxy): add network proxy config model"
```

### Task 2: Validate proxy config centrally

**Files:**
- Modify: `/Users/sergey-selderey/Projects/CodexBar/Sources/CodexBarCore/Config/CodexBarConfigValidation.swift:1-260`
- Modify: `/Users/sergey-selderey/Projects/CodexBar/Tests/CodexBarTests/ConfigValidationTests.swift`

- [ ] **Step 1: Write the failing test**

Add a validation test that asserts missing host and invalid port are reported:

```swift
func testNetworkProxyValidationReportsMissingHostAndInvalidPort() {
    let config = CodexBarConfig(
        providers: [],
        networkProxy: NetworkProxyConfiguration(
            enabled: true,
            scheme: .http,
            host: "   ",
            port: "not-a-port",
            username: "codex"))

    let issues = CodexBarConfigValidator.validate(config)
    #expect(issues.contains(where: { $0.field == "networkProxy.host" && $0.code == "proxy_host_missing" }))
    #expect(issues.contains(where: { $0.field == "networkProxy.port" && $0.code == "proxy_port_invalid" }))
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter ConfigValidationTests/testNetworkProxyValidationReportsMissingHostAndInvalidPort`

Expected: fail because the validator does not yet inspect `networkProxy`.

- [ ] **Step 3: Implement validation**

Add a dedicated proxy validation branch to `CodexBarConfigValidator.validate(_:)`:

```swift
if let proxy = config.networkProxy {
    self.validateNetworkProxy(proxy, issues: &issues)
}
```

Use exact issue payloads:

```swift
CodexBarConfigIssue(
    severity: .error,
    provider: nil,
    field: "networkProxy.host",
    code: "proxy_host_missing",
    message: "Network proxy host is required when proxy is enabled.")
```

```swift
CodexBarConfigIssue(
    severity: .error,
    provider: nil,
    field: "networkProxy.port",
    code: "proxy_port_invalid",
    message: "Network proxy port must be a number between 1 and 65535.")
```

Keep validation gated behind `proxy.enabled` so disabled configs stay quiet.

- [ ] **Step 4: Run the test and confirm it passes**

Run: `swift test --filter ConfigValidationTests/testNetworkProxyValidationReportsMissingHostAndInvalidPort`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexBarCore/Config/CodexBarConfigValidation.swift Tests/CodexBarTests/ConfigValidationTests.swift
git commit -m "feat(proxy): validate network proxy config"
```

### Task 3: Verify config store round-trip and keep scope invisible

**Files:**
- Modify: `/Users/sergey-selderey/Projects/CodexBar/Tests/CodexBarTests/ConfigValidationTests.swift`

- [ ] **Step 1: Write the failing test**

Add a store round-trip test that writes a config with proxy settings and reloads it from disk:

```swift
func testConfigStoreRoundTripsNetworkProxy() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = CodexBarConfigStore(fileURL: tempDirectory.appendingPathComponent("config.json"))
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let config = CodexBarConfig(
        providers: [],
        networkProxy: NetworkProxyConfiguration(
            enabled: true,
            scheme: .socks5,
            host: "127.0.0.1",
            port: "1080",
            username: "codex"))

    try store.save(config)
    let loaded = try store.load()

    #expect(loaded?.networkProxy?.scheme == .socks5)
    #expect(loaded?.networkProxy?.host == "127.0.0.1")
    #expect(loaded?.networkProxy?.port == "1080")
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter ConfigValidationTests/testConfigStoreRoundTripsNetworkProxy`

Expected: fail until the config model persists `networkProxy`.

- [ ] **Step 3: Keep the store implementation unchanged unless the test proves otherwise**

`CodexBarConfigStore` should already serialize and deserialize the new optional field once the model includes it. Do not add migration logic, password handling, or UI side effects.

- [ ] **Step 4: Run the test and confirm it passes**

Run: `swift test --filter ConfigValidationTests/testConfigStoreRoundTripsNetworkProxy`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/CodexBarTests/ConfigValidationTests.swift
git commit -m "test(proxy): cover config round-trip"
```

### Task 4: Final verification and PR prep

**Files:**
- Review: `/Users/sergey-selderey/Projects/CodexBar/Sources/CodexBarCore/Config/CodexBarConfig.swift`
- Review: `/Users/sergey-selderey/Projects/CodexBar/Sources/CodexBarCore/Config/CodexBarConfigValidation.swift`
- Review: `/Users/sergey-selderey/Projects/CodexBar/Tests/CodexBarTests/ConfigValidationTests.swift`

- [ ] **Step 1: Run the focused test set**

Run:

```bash
swift test --filter ConfigValidationTests
swift test --filter ConfigValidationTests/testConfigStoreRoundTripsNetworkProxy
swift test --filter ConfigValidationTests/testNetworkProxyConfigEncodesAndDecodes
```

Expected: all pass.

- [ ] **Step 2: Sanity-check the diff**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors and only the intended files changed.

- [ ] **Step 3: Commit the branch state**

```bash
git add Sources/CodexBarCore/Config/CodexBarConfig.swift Sources/CodexBarCore/Config/CodexBarConfigValidation.swift Tests/CodexBarTests/ConfigValidationTests.swift
git commit -m "feat(proxy): add invisible proxy config core"
```

- [ ] **Step 4: Prepare the follow-up visible PR**

Write a short PR description that explicitly says this is only the invisible config core and that Settings UI and transport wiring will follow in a separate PR.
