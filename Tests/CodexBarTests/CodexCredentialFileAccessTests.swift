import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct CodexCredentialFileAccessTests {
    private final class IO: @unchecked Sendable {
        private let lock = NSLock()
        private var operations: [CodexCredentialFileAccess.Operation] = []
        private var paths: [String] = []
        let files: [String: Data]?
        let bytes = Data(
            #"{"tokens":{"access_token":"synthetic","refresh_token":"fixture"},"personal_access_token":"fixture-pat"}"#
                .utf8)

        init(files: [String: Data]? = nil) {
            self.files = files
        }

        func call(_ operation: CodexCredentialFileAccess.Operation, _ url: URL) throws -> Data {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.operations.append(operation)
            if operation == .read || operation == .existence { self.paths.append(url.path) }
            if operation == .read, let files {
                guard let data = files[url.path] else { throw CocoaError(.fileReadNoSuchFile) }
                return data
            }
            return operation == .metadata ? Data(url.standardizedFileURL.path.utf8) : self.bytes
        }

        var targets: [String] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.paths
        }

        var calls: [CodexCredentialFileAccess.Operation] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.operations
        }
    }

    @Test
    func `all ambient entry points deny before IO regardless of credential environment`() throws {
        let io = IO()
        let home = URL(fileURLWithPath: "/fictitious-codex-user")
        let environments: [[String: String]] = [
            [:], ["CODEX_HOME": ""], ["CODEX_HOME": " \n "], ["HOME": home.path],
            ["CODEX_HOME": "/inherited-codex-home"],
            ["XDG_DATA_HOME": "/fictitious-opencode-data"],
            ["CODEX_HOME": "/fictitious/managed-codex-homes/id", "HOME": home.path],
            ["CODEX_HOME": "/fictitious/managed-store-unreadable"],
            ["CODEX_HOME": "/fictitious/profile", "HOME": home.path],
            ["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS": "1", "LIVE_TEST": "1"],
        ]
        try CodexCredentialFileAccess.withFixtureScope(.init()) {
            try CodexCredentialFileAccess.$testIO.withValue(io.call) {
                let credentials = try CodexOAuthCredentialsStore.parse(data: io.bytes)
                for environment in environments {
                    #expect(throws: CodexOAuthCredentialsError.self) {
                        try CodexOAuthCredentialsStore.load(env: environment)
                    }
                    #expect(throws: CodexOAuthCredentialsError.self) {
                        try CodexOAuthCredentialsStore.loadOAuthTokens(env: environment)
                    }
                    #expect(throws: CodexOAuthCredentialsError.self) {
                        try CodexOAuthCredentialsStore.loadPAT(env: environment)
                    }
                    #expect(throws: CodexOAuthCredentialsError.self) {
                        try CodexOAuthCredentialsStore.loadPATResolvingScopedHome(env: environment)
                    }
                    for external in [false, true] {
                        #expect(throws: CodexOAuthCredentialsError.self) {
                            try CodexOAuthCredentialsStore.loadForUsage(
                                env: environment, allowExternalSources: external)
                        }
                    }
                    #expect(throws: CodexOAuthCredentialsError.self) {
                        try CodexOAuthCredentialsStore.save(credentials, env: environment)
                    }
                    #expect(UsageFetcher(environment: environment).loadAccountInfo().email == nil)
                    #expect(CodexAuthFingerprint.fingerprint(env: environment) == nil)
                }
                #expect(CodexAuthFingerprint.fingerprint(homePath: home.path) == nil)
                #expect(try DefaultCodexAuthMaterialReader().readAuthData(homeURL: home) == nil)
                #expect(throws: CodexOAuthCredentialsError.self) {
                    try DefaultCodexLiveAuthSwapper().swapLiveAuthData(io.bytes, liveHomeURL: home)
                }
                #expect(throws: CodexOAuthCredentialsError.self) {
                    try CodexCredentialFileAccess
                        .createDirectory(forCredentialAt: home.appendingPathComponent("auth.json"))
                }
                for operation in [CodexCredentialFileAccess.Operation.read, .existence, .metadata, .directory, .write] {
                    #expect(io.calls.filter { $0 == operation }.isEmpty)
                }
            }
        }
    }

    @Test
    func `explicit file fixtures allow synthetic reads and whole write substitution`() throws {
        let io = IO()
        let home = URL(fileURLWithPath: "/fictitious-owned-fixture")
        let auth = home.appendingPathComponent("auth.json")
        try CodexCredentialFileAccess.$testIO.withValue(io.call) {
            try CodexCredentialFileAccess.withFixtureScope(.init(files: [auth])) {
                let env = ["CODEX_HOME": home.path]
                let credentials = try CodexOAuthCredentialsStore.load(env: env)
                #expect(credentials.accessToken == "synthetic")
                #expect(try CodexOAuthCredentialsStore.loadOAuthTokens(env: env) == credentials)
                #expect(try CodexOAuthCredentialsStore.loadPAT(env: env).token == "fixture-pat")
                #expect(try CodexOAuthCredentialsStore.loadForUsage(env: env) == credentials)
                #expect(CodexAuthFingerprint.fingerprint(env: env) == CodexAuthFingerprint.fingerprint(data: io.bytes))
                #expect(try DefaultCodexAuthMaterialReader().readAuthData(homeURL: home) == io.bytes)
                try CodexOAuthCredentialsStore.save(credentials, env: env)
                try DefaultCodexLiveAuthSwapper().swapLiveAuthData(io.bytes, liveHomeURL: home)
                #expect(!CodexCredentialFileAccess.permits(home.appendingPathComponent("other.json")))
            }
        }
        #expect(io.calls.count(where: { $0 == .write }) == 2)
        #expect(io.calls.contains(.existence))
        #expect(io.calls.contains(.read))
        #expect(!CodexCredentialFileAccess.permits(auth))
    }

    @Test
    func `and child detection ignores keychain and live permissions`() {
        for process in ["swiftpm-testing-helper", "CodexBarPackageTests", "example.xctest"] {
            #expect(CodexCredentialFileAccess.isTestContext(
                processName: process, environment: ["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS": "1", "LIVE_TEST": "1"]))
        }
        #expect(CodexCredentialFileAccess.isTestContext(
            processName: "codexbar", environment: [CodexCredentialFileAccess.isolationEnvironmentKey: "1"]))
        #expect(!CodexCredentialFileAccess.isTestContext(processName: "codexbar", environment: [:]))
        #expect(!CodexCredentialFileAccess.isTestContext(
            processName: "codexbar", environment: ["CODEX_HOME": "/fictitious", "HOME": "/fictitious"]))
    }

    @Test
    func `task scopes clean up and detached tasks fail closed unless explicitly scoped`() async {
        let first = URL(fileURLWithPath: "/fictitious-first/auth.json")
        let second = URL(fileURLWithPath: "/fictitious-second/auth.json")
        let io = IO()
        await CodexCredentialFileAccess.$testIO.withValue(io.call) {
            let firstScope = CodexCredentialFileAccess.FixtureScope(files: [first])
            let secondScope = CodexCredentialFileAccess.FixtureScope(files: [second])
            await withTaskGroup(of: Void.self) { group in
                for (scope, allowed, denied) in [(firstScope, first, second), (secondScope, second, first)] {
                    group.addTask {
                        await CodexCredentialFileAccess.withFixtureScope(scope) {
                            await Task.yield()
                            #expect(CodexCredentialFileAccess.permits(allowed))
                            #expect(!CodexCredentialFileAccess.permits(denied))
                            let detachedDenied = await Task.detached {
                                !CodexCredentialFileAccess.permits(allowed)
                            }.value
                            #expect(detachedDenied)
                            let detachedAllowed = await Task.detached {
                                CodexCredentialFileAccess.$testIO.withValue(io.call) {
                                    CodexCredentialFileAccess.withFixtureScope(scope) {
                                        CodexCredentialFileAccess.permits(allowed)
                                    }
                                }
                            }.value
                            #expect(detachedAllowed)
                        }
                    }
                }
            }
            enum Expected: Error { case stop }
            #expect(throws: Expected.stop) {
                try CodexCredentialFileAccess.withFixtureScope(firstScope) { throw Expected.stop }
            }
        }
        #expect(!CodexCredentialFileAccess.permits(first))
        #expect(!CodexCredentialFileAccess.permits(second))
    }

    @Test
    func `external fallback visits only authorized native legacy and OpenCode candidates`() throws {
        let home = URL(fileURLWithPath: "/fictitious-fixture-home")
        let native = home.appendingPathComponent(".codex/auth.json").path
        let legacy = home.appendingPathComponent(".config/codex/auth.json").path
        let oauth = IO().bytes
        let external = Data(#"{"openai":{"type":"oauth","access":"external-fixture"}}"#.utf8)
        for configured in [false, true] {
            let dataHome = configured ? home.appendingPathComponent("xdg") : home.appendingPathComponent(".local/share")
            let openCode = dataHome.appendingPathComponent("opencode/auth.json").path
            let env = configured ? ["XDG_DATA_HOME": dataHome.path] : [:]
            for winner in [native, legacy, openCode] {
                let files = [native: oauth, legacy: oauth, openCode: external].filter { key, _ in
                    winner == native || (winner == legacy ? key != native : key == openCode)
                }
                let io = IO(files: files)
                let credentials = try CodexCredentialFileAccess.$testIO.withValue(io.call) {
                    try CodexOAuthCredentialsStore._loadForUsageForTesting(
                        env: env, homeDirectory: home, allowExternalSources: true)
                }
                #expect(credentials
                    .source == (winner == native ? .codexHome : winner == legacy ? .legacyCodexHome : .openCode))
                #expect(io.targets == (winner == native ? [native] : winner == legacy ? [native, legacy] : [
                    native,
                    legacy,
                    openCode,
                ]))
            }
        }
    }

    @Test
    func `authorized external root cannot bypass a denied native home`() {
        let io = IO()
        CodexCredentialFileAccess.$testIO.withValue(io.call) {
            let scope = CodexCredentialFileAccess.FixtureScope(roots: [URL(fileURLWithPath: "/fictitious-xdg")])
            let before = io.calls.count
            _ = CodexCredentialFileAccess.withFixtureScope(scope) {
                #expect(throws: CodexOAuthCredentialsError.self) {
                    try CodexOAuthCredentialsStore.loadForUsage(
                        env: ["XDG_DATA_HOME": "/fictitious-xdg"], allowExternalSources: true)
                }
            }
            #expect(io.calls.count == before)
        }
    }

    @Test
    func `unregistered OpenCode is not probed after an authorized native miss`() {
        let home = URL(fileURLWithPath: "/fictitious-owned-home")
        let io = IO(files: [
            "/fictitious-unregistered-xdg/opencode/auth.json":
                Data(#"{"openai":{"type":"oauth","access":"must-not-read"}}"#.utf8),
        ])
        _ = CodexCredentialFileAccess.$testIO.withValue(io.call) {
            #expect(throws: CodexOAuthCredentialsError.self) {
                try CodexOAuthCredentialsStore._loadForUsageForTesting(
                    env: ["XDG_DATA_HOME": "/fictitious-unregistered-xdg"],
                    homeDirectory: home,
                    allowExternalSources: true)
            }
        }
        #expect(io.targets == [
            home.appendingPathComponent(".codex/auth.json").path,
            home.appendingPathComponent(".config/codex/auth.json").path,
        ])
    }

    @Test
    func `profile PAT miss cannot escape its scope into ambient HOME`() {
        let home = URL(fileURLWithPath: "/fictitious-profile")
        let auth = home.appendingPathComponent("auth.json")
        let io = IO(files: [auth.path: Data(#"{"tokens":{}}"#.utf8)])
        CodexCredentialFileAccess.$testIO.withValue(io.call) {
            CodexCredentialFileAccess.withFixtureScope(.init(roots: [home])) { () in
                #expect(throws: CodexOAuthCredentialsError.self) {
                    try CodexOAuthCredentialsStore.loadPATResolvingScopedHome(
                        env: ["CODEX_HOME": home.path, "HOME": "/fictitious-ambient"])
                }
            }
        }
        #expect(io.targets == [auth.path])
    }

    @Test(CodexCredentialFixtures())
    func `owned roots reject sibling prefixes traversal and symlink escapes`() throws {
        let root = CodexCredentialFixtures.root
        let owned = root.appendingPathComponent("owned", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let escape = owned.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        let authLink = owned.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(
            at: authLink,
            withDestinationURL: outside.appendingPathComponent("auth.json"))
        CodexCredentialFileAccess.withFixtureScope(.init(roots: [owned])) {
            #expect(CodexCredentialFileAccess.permits(owned.appendingPathComponent("new/auth.json")))
            #expect(!CodexCredentialFileAccess.permits(root.appendingPathComponent("owned-sibling/auth.json")))
            #expect(!CodexCredentialFileAccess.permits(owned.appendingPathComponent("../outside/auth.json")))
            #expect(!CodexCredentialFileAccess.permits(escape.appendingPathComponent("auth.json")))
            #expect(!CodexCredentialFileAccess.permits(authLink))
        }
        CodexCredentialFileAccess.withFixtureScope(.init(files: [authLink], roots: [escape])) {
            #expect(!CodexCredentialFileAccess.permits(authLink))
            #expect(!CodexCredentialFileAccess.permits(escape.appendingPathComponent("auth.json")))
        }
    }

    @Test
    func `Codex metadata defaults are isolated and explicit overrides survive`() throws {
        let accounts = FileManagedCodexAccountStore.defaultURL()
        let workspaces = CodexOpenAIWorkspaceIdentityCache.defaultURL()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.pathComponents
        #expect(accounts.standardizedFileURL.pathComponents.starts(with: temporary))
        #expect(workspaces.standardizedFileURL.pathComponents.starts(with: temporary))
        #expect(accounts != FileManagedCodexAccountStore.defaultURL())
        #expect(workspaces != CodexOpenAIWorkspaceIdentityCache.defaultURL())
        #expect(try FileManagedCodexAccountStore().loadAccounts().accounts.isEmpty)
        #expect(CodexOpenAIWorkspaceIdentityCache().workspaceLabel(for: "synthetic") == nil)
        CodexOpenAIWorkspaceIdentityCache.withFileURLOverrideForTesting(workspaces) {
            #expect(CodexOpenAIWorkspaceIdentityCache.defaultURL() == workspaces)
        }
    }

    @Test
    func `credential owners do not bypass guarded readers or whole write authorization`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for path in [
            "Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift",
            "Sources/CodexBarCore/CodexManagedAccounts.swift",
            "Sources/CodexBar/CodexAccountPromotionService.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(
                !source.contains("Data(contentsOf:"),
                "Route Codex credential reads through the file policy: \(path)")
            #expect(!source.contains("fileExists(atPath:"), "Guard Codex credential probes: \(path)")
        }
        for (path, signature) in [
            ("Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift", "public static func save("),
            (
                "Sources/CodexBar/CodexAccountPromotionService.swift",
                "func swapLiveAuthData(_ data: Data, liveHomeURL: URL) throws {"),
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let start = try #require(source.range(of: signature)?.upperBound)
            let body = source[start...]
            let guardPosition = try #require(body.range(of: "guard CodexCredentialFileAccess.permits("))
            let ioPosition = try #require(body.range(of: "substituteWriteForTesting("))
            let directoryPosition = try #require(body.range(of: "createDirectory("))
            #expect(guardPosition.lowerBound < ioPosition.lowerBound)
            #expect(ioPosition.lowerBound < directoryPosition.lowerBound)
        }
    }
}
