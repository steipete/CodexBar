import Foundation
import Testing
@testable import CodexBarCore

struct CLIProxyAPIUsageCacheTests {
    @Test
    func `cost cache clear advances the durable generation for other processes`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-clear-generation-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: costUsage.appendingPathComponent("claude-v6.json"))
        let initialUpdate = try #require(CostUsageCacheLocations.prepareCLIProxyAPIConfigurationGenerationUpdate(
            stateRoot: root,
            fileManager: fileManager))
        #expect(CostUsageCacheLocations.commitCLIProxyAPIConfigurationGenerationUpdate(
            initialUpdate,
            fileManager: fileManager))
        let initialGeneration = CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
            stateRoot: root,
            fileManager: fileManager)

        let result = CostUsageCacheLocations.clearAllCostUsageCaches(
            in: [costUsage],
            stateRoot: root,
            fileManager: fileManager)

        #expect(result == CostUsageCacheClearResult(cleared: 1, errorDescription: nil))
        #expect(CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
            stateRoot: root,
            fileManager: fileManager) != initialGeneration)
    }

    @Test
    func `integration cleanup removes telemetry pending and derived Claude cache artifacts`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-cleanup-\(UUID().uuidString)", isDirectory: true)
        let legacy = root
            .appendingPathComponent("legacy", isDirectory: true)
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
        let durable = root
            .appendingPathComponent("durable", isDirectory: true)
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        for directory in [legacy, durable] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("usage".utf8).write(to: directory.appendingPathComponent(
                CostUsageCacheLocations.cliProxyAPIUsageFileName))
            try Data("pending".utf8).write(to: directory.appendingPathComponent(
                CostUsageCacheLocations.cliProxyAPIPendingFileName))
        }
        for directory in [legacy, durable] {
            let claudeCache = CostUsageClaudeCacheIO.cacheFileURL(
                provider: .claude,
                cacheRoot: directory.deletingLastPathComponent())
            try Data("derived attribution".utf8).write(to: claudeCache)
        }
        let unrelated = durable.appendingPathComponent("codex-v11.json")
        try Data("keep".utf8).write(to: unrelated)

        let cleared = CostUsageCacheLocations.clearCLIProxyAPIArtifacts(
            in: [legacy, durable],
            stateRoot: root,
            fileManager: fileManager)

        #expect(cleared)
        for directory in [legacy, durable] {
            #expect(!fileManager.fileExists(atPath: directory.appendingPathComponent(
                CostUsageCacheLocations.cliProxyAPIUsageFileName).path))
            #expect(!fileManager.fileExists(atPath: directory.appendingPathComponent(
                CostUsageCacheLocations.cliProxyAPIPendingFileName).path))
            #expect(!fileManager.fileExists(atPath: CostUsageClaudeCacheIO.cacheFileURL(
                provider: .claude,
                cacheRoot: directory.deletingLastPathComponent()).path))
        }
        #expect(fileManager.fileExists(atPath: unrelated.path))
    }

    @Test
    func `integration cleanup waits for the collector interprocess lock`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-cleanup-lock-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: costUsage, withIntermediateDirectories: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let clearStarted = DispatchSemaphore(value: 0)
        let clearFinished = DispatchSemaphore(value: 0)
        let collector = Task.detached {
            try await CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(stateRoot: root) {
                lockAcquired.signal()
                _ = await Self.waitForSignal(releaseLock, timeout: .distantFuture)
            }
        }
        #expect(await Self.waitForSignal(lockAcquired, timeout: .now() + 1))

        let clear = Task.detached {
            clearStarted.signal()
            let result = CostUsageCacheLocations.clearCLIProxyAPIArtifacts(
                in: [costUsage],
                stateRoot: root,
                fileManager: .default)
            clearFinished.signal()
            return result
        }
        #expect(await Self.waitForSignal(clearStarted, timeout: .now() + 1))
        let finishedBeforeRelease = await Self.waitForSignal(
            clearFinished,
            timeout: .now() + .milliseconds(50))
        #expect(!finishedBeforeRelease)

        releaseLock.signal()
        try await collector.value
        #expect(await clear.value)
        #expect(!FileManager.default.fileExists(atPath: usageFile.path))
    }

    @Test
    func `explicit disconnect state survives artifact cleanup and can be cleared on reconnect`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-disconnect-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        #expect(CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
            true,
            stateRoot: root,
            fileManager: fileManager))
        #expect(CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        #expect(CostUsageCacheLocations.clearCLIProxyAPIArtifacts(
            in: [costUsage],
            stateRoot: root,
            fileManager: fileManager))
        #expect(CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))

        #expect(CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
            false,
            stateRoot: root,
            fileManager: fileManager))
        #expect(!CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))
    }

    @Test
    func `explicit disconnect prevents saved connection settings from loading`() {
        var didReadStoredSettings = false
        let loaded = CLIProxyAPIConnectionSettingsStore.load(
            isDisconnected: { true },
            loadStored: {
                didReadStoredSettings = true
                return CLIProxyAPIConnectionSettings(managementKey: "test-management-key")
            })

        #expect(loaded == nil)
        #expect(!didReadStoredSettings)
    }

    @Test
    func `reconnect rolls back saved credentials when disconnect state cannot be cleared`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-disconnect-clear-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let didStore = LockIsolated(false)
        let didRollback = LockIsolated(false)
        let saved = CLIProxyAPIConnectionSettingsStore.saveSerialized(
            CLIProxyAPIConnectionSettings(managementKey: "test-management-key"),
            stateRoot: root,
            fileManager: .default,
            operations: .init(
                isDisconnected: { true },
                loadStored: { .missing },
                store: { _ in
                    didStore.setValue(true)
                    return true
                },
                setDisconnectedState: { disconnected in disconnected },
                restore: { _ in
                    didRollback.setValue(true)
                    return true
                }))

        #expect(!saved)
        #expect(didStore.value)
        #expect(didRollback.value)
    }

    @Test
    func `reconnect publishes telemetry invalidation before storing credentials`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-reconnect-stage-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? fileManager.removeItem(at: root) }

        let artifactWasStagedAtStore = LockIsolated(false)
        let generationWasPublishedAtStore = LockIsolated(false)
        let saved = CLIProxyAPIConnectionSettingsStore.saveSerialized(
            CLIProxyAPIConnectionSettings(managementKey: "test-management-key"),
            artifactDirectories: [costUsage],
            stateRoot: root,
            fileManager: fileManager,
            operations: .init(
                isDisconnected: { true },
                loadStored: { .missing },
                store: { _ in
                    artifactWasStagedAtStore.setValue(!FileManager.default.fileExists(atPath: usageFile.path))
                    generationWasPublishedAtStore.setValue(
                        CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
                            stateRoot: root,
                            fileManager: .default) != nil)
                    return true
                },
                setDisconnectedState: { _ in true },
                restore: { _ in true }))

        #expect(saved)
        #expect(artifactWasStagedAtStore.value)
        #expect(generationWasPublishedAtStore.value)
        #expect(!fileManager.fileExists(atPath: usageFile.path))
    }

    @Test
    func `active configuration replacement plans a telemetry purge`() {
        let existing = CLIProxyAPIConnectionSettings(
            baseURL: "http://127.0.0.1:8317",
            managementKey: "old-management-key")
        let replacement = CLIProxyAPIConnectionSettings(
            baseURL: "http://127.0.0.1:8318",
            managementKey: "new-management-key")
        #expect(CLIProxyAPIConnectionSettingsStore.artifactDisposition(
            existing,
            isDisconnected: false,
            storedSettings: .found(existing)) == .preserve)

        #expect(CLIProxyAPIConnectionSettingsStore.artifactDisposition(
            replacement,
            isDisconnected: false,
            storedSettings: .found(existing)) == .purge)
    }

    @Test
    func `replacement keeps prior telemetry when credential storage fails`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-replacement-store-failure-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? fileManager.removeItem(at: root) }
        let existing = CLIProxyAPIConnectionSettings(managementKey: "old-management-key")
        let replacement = CLIProxyAPIConnectionSettings(managementKey: "new-management-key")
        let disconnected = LockIsolated(false)
        let wasIsolatedAtStore = LockIsolated(false)

        let saved = CLIProxyAPIConnectionSettingsStore.saveSerialized(
            replacement,
            artifactDirectories: [costUsage],
            stateRoot: root,
            fileManager: fileManager,
            operations: .init(
                isDisconnected: { disconnected.value },
                loadStored: { .found(existing) },
                store: { _ in
                    wasIsolatedAtStore.setValue(disconnected.value)
                    return false
                },
                setDisconnectedState: {
                    disconnected.setValue($0)
                    return true
                },
                restore: { _ in true }))

        #expect(!saved)
        #expect(wasIsolatedAtStore.value)
        #expect(!disconnected.value)
        #expect(fileManager.fileExists(atPath: usageFile.path))
    }

    @Test
    func `failed replacement staging restores already moved telemetry`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-replacement-stage-failure-\(UUID().uuidString)", isDirectory: true)
        let firstDirectory = root.appendingPathComponent("first/cost-usage", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second/cost-usage", isDirectory: true)
        let firstURL = firstDirectory.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        let secondURL = secondDirectory.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        for url in [firstURL, secondURL] {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("telemetry".utf8).write(to: url)
        }
        defer { try? fileManager.removeItem(at: root) }

        let update = CostUsageCacheLocations.prepareCLIProxyAPIArtifactsUpdate(
            in: [firstDirectory, secondDirectory],
            fileExists: { fileManager.fileExists(atPath: $0.path) },
            moveItem: { source, destination in
                if source == secondURL {
                    throw CocoaError(.fileWriteUnknown)
                }
                try fileManager.moveItem(at: source, to: destination)
            })

        #expect(update == nil)
        #expect(fileManager.fileExists(atPath: firstURL.path))
        #expect(fileManager.fileExists(atPath: secondURL.path))
    }

    @Test
    func `save and removal advance the durable configuration generation`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-generation-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let settings = CLIProxyAPIConnectionSettings(managementKey: "test-management-key")

        #expect(CLIProxyAPIConnectionSettingsStore.saveSerialized(
            settings,
            stateRoot: root,
            fileManager: fileManager,
            operations: .init(
                isDisconnected: { false },
                loadStored: { .missing },
                store: { _ in true },
                setDisconnectedState: { _ in true },
                restore: { _ in true })))
        let savedGeneration = try #require(CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
            stateRoot: root,
            fileManager: fileManager))

        #expect(CLIProxyAPIConnectionSettingsStore.removeAndPurgeTelemetry(
            in: [],
            stateRoot: root,
            fileManager: fileManager,
            operations: .init(
                isDisconnected: { false },
                loadStored: { .missing },
                clearConfiguration: { true },
                setDisconnectedState: { _ in true },
                restore: { _ in true })) == .removed)
        let removedGeneration = try #require(CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
            stateRoot: root,
            fileManager: fileManager))

        #expect(removedGeneration != savedGeneration)
    }

    @Test
    func `failed credential save keeps its published telemetry invalidation`() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-generation-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        #expect(!CLIProxyAPIConnectionSettingsStore.saveSerialized(
            CLIProxyAPIConnectionSettings(managementKey: "test-management-key"),
            stateRoot: root,
            fileManager: fileManager,
            operations: .init(
                isDisconnected: { false },
                loadStored: { .missing },
                store: { _ in false },
                setDisconnectedState: { _ in true },
                restore: { _ in true })))
        #expect(CostUsageCacheLocations.cliProxyAPIConfigurationGeneration(
            stateRoot: root,
            fileManager: fileManager) != nil)
    }

    @Test
    func `generation publication failure restores replacement credentials state and telemetry`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-generation-commit-failure-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        let generationURL = root.appendingPathComponent(
            "cliproxyapi-configuration-generation-v1",
            isDirectory: false)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        try fileManager.createDirectory(at: generationURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let existing = CLIProxyAPIConnectionSettings(managementKey: "old-management-key")
        let replacement = CLIProxyAPIConnectionSettings(managementKey: "new-management-key")
        let storedSettings = LockIsolated(existing)
        let disconnected = LockIsolated(true)
        let didStore = LockIsolated(false)

        let saved = CLIProxyAPIConnectionSettingsStore.saveSerialized(
            replacement,
            artifactDirectories: [costUsage],
            stateRoot: root,
            fileManager: fileManager,
            operations: .init(
                isDisconnected: { disconnected.value },
                loadStored: { .found(storedSettings.value) },
                store: { settings in
                    didStore.setValue(true)
                    storedSettings.setValue(settings)
                    return true
                },
                setDisconnectedState: { value in
                    disconnected.setValue(value)
                    return true
                },
                restore: { snapshot in
                    guard case let .found(settings) = snapshot else { return false }
                    storedSettings.setValue(settings)
                    return true
                }))

        #expect(!saved)
        #expect(!didStore.value)
        #expect(storedSettings.value == existing)
        #expect(disconnected.value)
        #expect(fileManager.fileExists(atPath: usageFile.path))
    }

    @Test
    func `generation publication failure rolls back configuration removal and telemetry`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-removal-generation-failure-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        let generationURL = root.appendingPathComponent(
            "cliproxyapi-configuration-generation-v1",
            isDirectory: false)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        try fileManager.createDirectory(at: generationURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let existing = CLIProxyAPIConnectionSettings(managementKey: "old-management-key")
        let storedSettings = LockIsolated<CLIProxyAPIConnectionSettings?>(existing)
        let disconnected = LockIsolated(false)
        let didClear = LockIsolated(false)

        let result = CLIProxyAPIConnectionSettingsStore.removeAndPurgeTelemetry(
            in: [costUsage],
            stateRoot: root,
            fileManager: fileManager,
            operations: .init(
                isDisconnected: { disconnected.value },
                loadStored: { .found(existing) },
                clearConfiguration: {
                    didClear.setValue(true)
                    return false
                },
                setDisconnectedState: { value in
                    disconnected.setValue(value)
                    return true
                },
                restore: { snapshot in
                    guard case let .found(settings) = snapshot else { return false }
                    storedSettings.setValue(settings)
                    return true
                }))

        #expect(result == .configurationRemovalFailed)
        #expect(!didClear.value)
        #expect(storedSettings.value == existing)
        #expect(!disconnected.value)
        #expect(fileManager.fileExists(atPath: usageFile.path))
    }

    @Test
    func `configuration removal waits for an in progress save transaction`() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-settings-lock-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? fileManager.removeItem(at: root) }

        let saveEntered = DispatchSemaphore(value: 0)
        let releaseSave = DispatchSemaphore(value: 0)
        let removalEntered = DispatchSemaphore(value: 0)
        let settings = CLIProxyAPIConnectionSettings(managementKey: "test-management-key")
        let saveTask = Task.detached {
            CLIProxyAPIConnectionSettingsStore.saveSerialized(
                settings,
                stateRoot: root,
                fileManager: .default,
                operations: .init(
                    isDisconnected: { false },
                    loadStored: { .missing },
                    store: { _ in
                        saveEntered.signal()
                        releaseSave.wait()
                        return true
                    },
                    setDisconnectedState: { _ in true },
                    restore: { _ in true }))
        }
        #expect(await Self.waitForSignal(saveEntered, timeout: .now() + 1))

        let removalTask = Task.detached {
            CLIProxyAPIConnectionSettingsStore.removeAndPurgeTelemetry(
                in: [costUsage],
                stateRoot: root,
                fileManager: .default,
                operations: .init(
                    isDisconnected: { false },
                    loadStored: { .missing },
                    clearConfiguration: {
                        removalEntered.signal()
                        return true
                    },
                    setDisconnectedState: { _ in true },
                    restore: { _ in true }))
        }
        let removalEnteredBeforeSaveFinished = await Self.waitForSignal(
            removalEntered,
            timeout: .now() + .milliseconds(50))
        #expect(!removalEnteredBeforeSaveFinished)

        releaseSave.signal()
        #expect(await saveTask.value)
        #expect(await removalTask.value == .removed)
        #expect(!FileManager.default.fileExists(atPath: usageFile.path))
    }

    @Test
    func `explicit disconnect prevents collection with persisted settings`() async {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-disconnected-collection-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        #expect(CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
            true,
            stateRoot: root,
            fileManager: fileManager))

        let result = await CLIProxyAPIUsageCollector.collect(
            cacheRoot: root,
            settings: CLIProxyAPIConnectionSettings(managementKey: "secret"))

        #expect(result == .notConfigured)
    }

    @Test
    func `cost cache locations include durable telemetry storage`() throws {
        let fileManager = FileManager.default
        let directories = CostUsageCacheLocations.directories(fileManager: fileManager)
        let cacheRoot = try #require(fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask).first)
        let applicationSupportRoot = try #require(fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first)

        #expect(directories == [cacheRoot, applicationSupportRoot].map { root in
            root
                .appendingPathComponent("CodexBar", isDirectory: true)
                .appendingPathComponent("cost-usage", isDirectory: true)
        })
        #expect(directories.contains(
            CLIProxyAPIUsageCacheIO.cacheFileURL().deletingLastPathComponent()))
        #expect(directories.contains(
            CLIProxyAPIUsagePendingIO.pendingFileURL().deletingLastPathComponent()))
    }

    @Test
    func `default telemetry storage is durable application support`() throws {
        let fileManager = FileManager.default
        let durableURL = CLIProxyAPIUsageCacheIO.cacheFileURL()
        let legacyURL = CLIProxyAPIUsageCacheIO.legacyCacheFileURL()
        let durableRoot = try #require(fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first)
            .appendingPathComponent("CodexBar", isDirectory: true)
        let legacyRoot = try #require(fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask).first)
            .appendingPathComponent("CodexBar", isDirectory: true)

        #expect(durableURL.path.hasPrefix(durableRoot.path + "/"))
        #expect(legacyURL.path.hasPrefix(legacyRoot.path + "/"))
        #expect(durableURL != legacyURL)
    }

    @Test
    func `legacy purgeable telemetry migrates into durable storage`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-migration-\(UUID().uuidString)", isDirectory: true)
        let durableRoot = root.appendingPathComponent("application-support", isDirectory: true)
        let legacyRoot = root.appendingPathComponent("caches", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let record = CLIProxyAPIUsageRecord(
            timestamp: timestamp,
            provider: "codex",
            model: "gpt-5.4",
            alias: "gpt-5.4",
            endpoint: "POST /v1/messages",
            authType: "oauth",
            requestID: "request-1",
            tokens: .init(input: 10, output: 20, total: 30))
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [record],
            cacheRoot: legacyRoot,
            now: timestamp) == 1)
        let legacyURL = CLIProxyAPIUsageCacheIO.cacheFileURL(cacheRoot: legacyRoot)
        #expect(fileManager.fileExists(atPath: legacyURL.path))

        let migrated = CLIProxyAPIUsageCacheIO.load(
            cacheRoot: durableRoot,
            legacyCacheRoot: legacyRoot,
            now: timestamp)

        #expect(migrated.map(\.requestID) == ["request-1"])
        #expect(fileManager.fileExists(
            atPath: CLIProxyAPIUsageCacheIO.cacheFileURL(cacheRoot: durableRoot).path))
        #expect(!fileManager.fileExists(atPath: legacyURL.path))
    }

    @Test
    func `legacy migration waits for the collector interprocess lock`() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-lock-\(UUID().uuidString)", isDirectory: true)
        let durableRoot = root.appendingPathComponent("application-support", isDirectory: true)
        let legacyRoot = root.appendingPathComponent("caches", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let legacyRecord = Self.record(id: "legacy", timestamp: timestamp)
        let collectedRecord = Self.record(
            id: "collected",
            timestamp: timestamp.addingTimeInterval(1))
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [legacyRecord],
            cacheRoot: legacyRoot,
            now: timestamp) == 1)

        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let loadStarted = DispatchSemaphore(value: 0)
        let loadFinished = DispatchSemaphore(value: 0)
        let lockHolder = Task.detached {
            try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(stateRoot: root) {
                lockAcquired.signal()
                releaseLock.wait()
                #expect(CLIProxyAPIUsageCacheIO.merge(
                    [collectedRecord],
                    cacheRoot: durableRoot,
                    legacyCacheRoot: nil,
                    now: timestamp) == 1)
            }
        }
        #expect(await Self.waitForSignal(lockAcquired, timeout: .now() + 1))

        let loadTask = Task.detached {
            loadStarted.signal()
            let records = CLIProxyAPIUsageCacheIO.load(
                cacheRoot: durableRoot,
                legacyCacheRoot: legacyRoot,
                now: timestamp)
            loadFinished.signal()
            return records
        }
        #expect(await Self.waitForSignal(loadStarted, timeout: .now() + 1))
        let loadFinishedBeforeRelease = await Self.waitForSignal(
            loadFinished,
            timeout: .now() + .milliseconds(50))
        #expect(!loadFinishedBeforeRelease)

        releaseLock.signal()
        try await lockHolder.value
        #expect(await Set(loadTask.value.map(\.requestID)) == ["legacy", "collected"])
        let finalRecords = CLIProxyAPIUsageCacheIO.load(
            cacheRoot: durableRoot,
            legacyCacheRoot: legacyRoot,
            now: timestamp)
        #expect(Set(finalRecords.map(\.requestID)) == ["legacy", "collected"])
    }

    @Test
    func `fallback record identity survives cache round trips within one second`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-fractional-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let second = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let records = [
            Self.record(id: "", timestamp: second.addingTimeInterval(0.1)),
            Self.record(id: "", timestamp: second.addingTimeInterval(0.9)),
        ]
        let now = second.addingTimeInterval(1)

        #expect(CLIProxyAPIUsageCacheIO.merge(
            records,
            cacheRoot: root,
            now: now) == 2)
        #expect(CLIProxyAPIUsageCacheIO.merge(
            records,
            cacheRoot: root,
            now: now) == 0)

        let roundTripped = CLIProxyAPIUsageCacheIO.load(
            cacheRoot: root,
            now: now)
        #expect(roundTripped.count == 2)
        #expect(
            roundTripped.map { Int64($0.timestamp.timeIntervalSince1970 * 1000) }
                == records.map { Int64($0.timestamp.timeIntervalSince1970 * 1000) })
    }

    @Test
    func `fallback record identity preserves identical occurrences across batches and replay`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-usage-identical-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00.123Z"))
        let records = [
            Self.record(id: "", timestamp: timestamp).assigningNewLocalOccurrenceID(),
            Self.record(id: "", timestamp: timestamp).assigningNewLocalOccurrenceID(),
        ]
        #expect(records[0].localOccurrenceID != records[1].localOccurrenceID)

        #expect(CLIProxyAPIUsageCacheIO.merge(
            [records[0]],
            cacheRoot: root,
            now: timestamp) == 1)
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [records[0]],
            cacheRoot: root,
            now: timestamp) == 0)
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [records[1]],
            cacheRoot: root,
            now: timestamp) == 1)
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [records[1]],
            cacheRoot: root,
            now: timestamp) == 0)

        let roundTripped = CLIProxyAPIUsageCacheIO.load(
            cacheRoot: root,
            now: timestamp)
        #expect(roundTripped.count == 2)
        #expect(Set(roundTripped.compactMap(\.localOccurrenceID)) == Set(records.compactMap(\.localOccurrenceID)))
    }

    @Test
    func `corrupt durable cache is preserved instead of overwritten`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-corrupt-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let cacheURL = CLIProxyAPIUsageCacheIO.cacheFileURL(cacheRoot: root)
        try fileManager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let corruptData = Data(#"{"version":2,"records":[]}"#.utf8)
        try corruptData.write(to: cacheURL)
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))

        let result = CLIProxyAPIUsageCacheIO.merge(
            [Self.record(id: "new", timestamp: timestamp)],
            cacheRoot: root,
            now: timestamp)

        #expect(result == nil)
        #expect(try Data(contentsOf: cacheURL) == corruptData)
    }

    @Test
    func `fallback record identity survives pending journal round trips within one second`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-pending-fractional-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let second = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let records = [
            Self.record(id: "", timestamp: second.addingTimeInterval(0.1)),
            Self.record(id: "", timestamp: second.addingTimeInterval(0.9)),
        ]

        #expect(CLIProxyAPIUsagePendingIO.save(records, pendingRoot: root))
        let roundTripped = try #require(CLIProxyAPIUsagePendingIO.load(pendingRoot: root))

        #expect(roundTripped.count == 2)
        #expect(
            roundTripped.map { Int64($0.timestamp.timeIntervalSince1970 * 1000) }
                == records.map { Int64($0.timestamp.timeIntervalSince1970 * 1000) })
    }

    @Test
    func `pending journal prunes expired records without collection`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-pending-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let now = try #require(CostUsageDateParser.parse("2026-07-30T12:00:00Z"))
        let records = [
            Self.record(id: "expired", timestamp: now.addingTimeInterval(-367 * 24 * 60 * 60)),
            Self.record(id: "retained", timestamp: now.addingTimeInterval(-365 * 24 * 60 * 60)),
        ]

        #expect(CLIProxyAPIUsagePendingIO.save(records, pendingRoot: root))
        #expect(CLIProxyAPIUsagePendingIO.load(pendingRoot: root, now: now)?.map(\.requestID) == ["retained"])
        #expect(CLIProxyAPIUsagePendingIO.load(pendingRoot: root, now: now)?.map(\.requestID) == ["retained"])
    }

    @Test
    func `collector maintenance prunes pending and durable usage independently of collection`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-pending-maintenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let now = try #require(CostUsageDateParser.parse("2026-07-30T12:00:00Z"))
        let records = [
            Self.record(id: "expired", timestamp: now.addingTimeInterval(-367 * 24 * 60 * 60)),
            Self.record(id: "retained", timestamp: now.addingTimeInterval(-365 * 24 * 60 * 60)),
        ]

        #expect(CLIProxyAPIUsagePendingIO.save(records, pendingRoot: root))
        #expect(CLIProxyAPIUsageCacheIO.merge(
            records,
            cacheRoot: root,
            now: records[1].timestamp) == 2)
        #expect(CLIProxyAPIUsageCollector.pruneExpiredUsage(
            cacheRoot: root,
            pendingRoot: root,
            stateRoot: root,
            now: now,
            fileManager: fileManager))
        #expect(CLIProxyAPIUsagePendingIO.load(pendingRoot: root, now: now)?.map(\.requestID) == ["retained"])
        #expect(CLIProxyAPIUsageCacheIO.load(
            cacheRoot: root,
            now: now.addingTimeInterval(-365 * 24 * 60 * 60)).map(\.requestID) == ["retained"])
    }

    private static func record(id: String, timestamp: Date) -> CLIProxyAPIUsageRecord {
        CLIProxyAPIUsageRecord(
            timestamp: timestamp,
            provider: "codex",
            model: "gpt-5.4",
            alias: "gpt-5.4",
            endpoint: "POST /v1/messages",
            authType: "oauth",
            requestID: id,
            tokens: .init(input: 10, output: 20, total: 30))
    }

    private static func waitForSignal(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime) async -> Bool
    {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
            }
        }
    }
}

extension CLIProxyAPIUsageCacheTests {
    @Test
    func `usage retention clamps clock skew and rejects implausible future records`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-future-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let now = try #require(CostUsageDateParser.parse("2026-07-30T12:00:00Z"))
        let records = [
            Self.record(id: "retained", timestamp: now.addingTimeInterval(-365 * 24 * 60 * 60)),
            Self.record(id: "clock-skew", timestamp: now.addingTimeInterval(60)),
            Self.record(id: "implausible-future", timestamp: now.addingTimeInterval(367 * 24 * 60 * 60)),
        ]

        #expect(CLIProxyAPIUsageCacheIO.merge(records, cacheRoot: root, now: now) == 2)
        let cached = CLIProxyAPIUsageCacheIO.load(cacheRoot: root, now: now)
        #expect(cached.map(\.requestID) == ["retained", "clock-skew"])
        #expect(cached.last?.timestamp == now)

        #expect(CLIProxyAPIUsagePendingIO.save(records, pendingRoot: root))
        let pending = try #require(CLIProxyAPIUsagePendingIO.load(pendingRoot: root, now: now))
        #expect(pending.map(\.requestID) == ["retained", "clock-skew"])
        #expect(pending.last?.timestamp == now)
        #expect(CLIProxyAPIUsagePendingIO.load(pendingRoot: root, now: now) == pending)
    }

    @Test
    func `rollback accepts an already missing prior credential`() {
        #expect(CLIProxyAPIConnectionSettingsStore.restoreStoredSettings(
            .missing,
            store: { _ in false },
            clear: { .missing }))
        #expect(!CLIProxyAPIConnectionSettingsStore.restoreStoredSettings(
            .missing,
            store: { _ in false },
            clear: { .failed }))
    }

    @Test
    func `failed save marker rollback retains recovery transaction`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-save-marker-rollback-failure-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? fileManager.removeItem(at: root) }
        let existing = CLIProxyAPIConnectionSettings(managementKey: "old-management-key")
        let replacement = CLIProxyAPIConnectionSettings(managementKey: "new-management-key")
        let storedSettings = LockIsolated(existing)
        let disconnected = LockIsolated(false)

        let saved = CLIProxyAPIConnectionSettingsStore.saveSerialized(
            replacement,
            artifactDirectories: [costUsage],
            stateRoot: root,
            fileManager: fileManager,
            operations: .init(
                isDisconnected: { disconnected.value },
                loadStored: { .found(storedSettings.value) },
                store: { settings in
                    storedSettings.setValue(settings)
                    return true
                },
                setDisconnectedState: { value in
                    guard value else { return false }
                    disconnected.setValue(true)
                    return true
                },
                restore: { snapshot in
                    guard case let .found(settings) = snapshot else { return false }
                    storedSettings.setValue(settings)
                    return true
                }))

        #expect(!saved)
        #expect(storedSettings.value == existing)
        #expect(disconnected.value)
        #expect(!fileManager.fileExists(atPath: usageFile.path))
        #expect(fileManager.fileExists(
            atPath: root.appendingPathComponent("cliproxyapi-artifacts-transaction-v1.json").path))

        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
            stateRoot: root,
            fileManager: fileManager) {}

        #expect(fileManager.fileExists(atPath: usageFile.path))
        #expect(!fileManager.fileExists(
            atPath: root.appendingPathComponent("cliproxyapi-artifacts-transaction-v1.json").path))
    }

    @Test
    func `failed credential rollback keeps replacement telemetry isolated`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-credential-rollback-failure-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? fileManager.removeItem(at: root) }
        let existing = CLIProxyAPIConnectionSettings(managementKey: "old-management-key")
        let replacement = CLIProxyAPIConnectionSettings(managementKey: "new-management-key")
        let storedSettings = LockIsolated(existing)
        let disconnected = LockIsolated(false)
        let didAttemptRestore = LockIsolated(false)

        let saved = CLIProxyAPIConnectionSettingsStore.saveSerialized(
            replacement,
            artifactDirectories: [costUsage],
            stateRoot: root,
            fileManager: fileManager,
            operations: .init(
                isDisconnected: { disconnected.value },
                loadStored: { .found(storedSettings.value) },
                store: { settings in
                    storedSettings.setValue(settings)
                    return true
                },
                setDisconnectedState: { value in
                    guard value else { return false }
                    disconnected.setValue(true)
                    return true
                },
                restore: { _ in
                    didAttemptRestore.setValue(true)
                    return false
                }))

        #expect(!saved)
        #expect(didAttemptRestore.value)
        #expect(storedSettings.value == replacement)
        #expect(disconnected.value)
        #expect(!fileManager.fileExists(atPath: usageFile.path))
        #expect(fileManager.fileExists(
            atPath: root.appendingPathComponent("cliproxyapi-artifacts-transaction-v1.json").path))
        #expect(try fileManager.contentsOfDirectory(at: costUsage, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasSuffix("replacement-backup") })

        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
            stateRoot: root,
            fileManager: fileManager) {}

        #expect(storedSettings.value == replacement)
        #expect(disconnected.value)
        #expect(!fileManager.fileExists(atPath: usageFile.path))
        #expect(!fileManager.fileExists(
            atPath: root.appendingPathComponent("cliproxyapi-artifacts-transaction-v1.json").path))
        #expect(try fileManager.contentsOfDirectory(at: costUsage, includingPropertiesForKeys: nil)
            .allSatisfy { !$0.lastPathComponent.hasSuffix("replacement-backup") })
    }

    @Test
    func `configuration removal accepts a credential removed after its snapshot`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-concurrent-removal-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? fileManager.removeItem(at: root) }
        let existing = CLIProxyAPIConnectionSettings(managementKey: "test-management-key")
        let disconnected = LockIsolated(false)

        let result = CLIProxyAPIConnectionSettingsStore.removeAndPurgeTelemetry(
            in: [costUsage],
            stateRoot: root,
            fileManager: fileManager,
            operations: .init(
                isDisconnected: { disconnected.value },
                loadStored: { .found(existing) },
                clearConfiguration: {
                    CLIProxyAPIConnectionSettingsStore.clearUnserialized(
                        isDisconnected: { disconnected.value },
                        setDisconnectedState: { value in
                            disconnected.setValue(value)
                            return true
                        },
                        clearConfiguration: { .missing })
                },
                setDisconnectedState: { value in
                    disconnected.setValue(value)
                    return true
                },
                restore: { _ in true }))

        #expect(result == .removed)
        #expect(disconnected.value)
        #expect(!fileManager.fileExists(atPath: usageFile.path))
    }

    @Test
    func `failed removal marker rollback retains recovery transaction`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-removal-marker-rollback-failure-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? fileManager.removeItem(at: root) }
        let existing = CLIProxyAPIConnectionSettings(managementKey: "test-management-key")
        let storedSettings = LockIsolated<CLIProxyAPIConnectionSettings?>(existing)
        let disconnected = LockIsolated(false)

        let result = CLIProxyAPIConnectionSettingsStore.removeAndPurgeTelemetry(
            in: [costUsage],
            stateRoot: root,
            fileManager: fileManager,
            operations: .init(
                isDisconnected: { disconnected.value },
                loadStored: { .found(existing) },
                clearConfiguration: {
                    storedSettings.setValue(nil)
                    disconnected.setValue(true)
                    return false
                },
                setDisconnectedState: { value in
                    guard value else { return false }
                    disconnected.setValue(true)
                    return true
                },
                restore: { snapshot in
                    guard case let .found(settings) = snapshot else { return false }
                    storedSettings.setValue(settings)
                    return true
                }))

        #expect(result == .configurationRemovalFailed)
        #expect(storedSettings.value == existing)
        #expect(disconnected.value)
        #expect(!fileManager.fileExists(atPath: usageFile.path))
        #expect(fileManager.fileExists(
            atPath: root.appendingPathComponent("cliproxyapi-artifacts-transaction-v1.json").path))

        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
            stateRoot: root,
            fileManager: fileManager) {}

        #expect(fileManager.fileExists(atPath: usageFile.path))
        #expect(!fileManager.fileExists(
            atPath: root.appendingPathComponent("cliproxyapi-artifacts-transaction-v1.json").path))
    }
}

struct CLIProxyAPITransactionRecoveryTests {
    @Test
    func `interrupted committed save clears its isolation marker on the next lock`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-save-marker-finalize-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let generationUpdate = try #require(CostUsageCacheLocations
            .prepareCLIProxyAPIConfigurationGenerationUpdate(stateRoot: root, fileManager: fileManager))
        let artifactsUpdate = try #require(CostUsageCacheLocations.prepareCLIProxyAPIArtifactsUpdate(
            in: [],
            stateRoot: root,
            expectedGeneration: generationUpdate.generation,
            fileManager: fileManager,
            disconnectedStateAfterCommit: false,
            disconnectedStateAfterRollback: false,
            prepareState: {
                CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
                    true,
                    stateRoot: root,
                    fileManager: fileManager)
            }))
        #expect(CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))
        #expect(artifactsUpdate.manifestURL.map { fileManager.fileExists(atPath: $0.path) } == true)
        #expect(CostUsageCacheLocations.commitCLIProxyAPIConfigurationGenerationUpdate(
            generationUpdate,
            fileManager: fileManager))

        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(stateRoot: root, fileManager: fileManager) {}

        #expect(!CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))
        #expect(artifactsUpdate.manifestURL.map { !fileManager.fileExists(atPath: $0.path) } == true)
    }

    @Test
    func `interrupted uncommitted save restores its previous isolation marker on the next lock`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-save-marker-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let generationUpdate = try #require(CostUsageCacheLocations
            .prepareCLIProxyAPIConfigurationGenerationUpdate(stateRoot: root, fileManager: fileManager))
        let artifactsUpdate = try #require(CostUsageCacheLocations.prepareCLIProxyAPIArtifactsUpdate(
            in: [],
            stateRoot: root,
            expectedGeneration: generationUpdate.generation,
            fileManager: fileManager,
            disconnectedStateAfterCommit: false,
            disconnectedStateAfterRollback: false,
            prepareState: {
                CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
                    true,
                    stateRoot: root,
                    fileManager: fileManager)
            }))
        #expect(CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))

        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(stateRoot: root, fileManager: fileManager) {}

        #expect(!CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))
        #expect(artifactsUpdate.manifestURL.map { !fileManager.fileExists(atPath: $0.path) } == true)
        CostUsageCacheLocations.discardCLIProxyAPIConfigurationGenerationUpdate(
            generationUpdate,
            fileManager: fileManager)
    }

    @Test
    func `interrupted uncommitted replacement restores staged artifacts on the next lock`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-replacement-recovery-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? fileManager.removeItem(at: root) }

        let generationUpdate = try #require(CostUsageCacheLocations
            .prepareCLIProxyAPIConfigurationGenerationUpdate(stateRoot: root, fileManager: fileManager))
        let artifactsUpdate = try #require(CostUsageCacheLocations.prepareCLIProxyAPIArtifactsUpdate(
            in: [costUsage],
            stateRoot: root,
            expectedGeneration: generationUpdate.generation,
            fileManager: fileManager))
        #expect(!fileManager.fileExists(atPath: usageFile.path))
        #expect(artifactsUpdate.manifestURL.map { fileManager.fileExists(atPath: $0.path) } == true)

        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(stateRoot: root, fileManager: fileManager) {}

        #expect(fileManager.fileExists(atPath: usageFile.path))
        #expect(artifactsUpdate.moves.allSatisfy { !fileManager.fileExists(atPath: $0.stagedURL.path) })
        #expect(artifactsUpdate.manifestURL.map { !fileManager.fileExists(atPath: $0.path) } == true)
        CostUsageCacheLocations.discardCLIProxyAPIConfigurationGenerationUpdate(
            generationUpdate,
            fileManager: fileManager)
    }

    @Test
    func `interrupted committed replacement discards staged artifacts on the next lock`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-replacement-finalize-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? fileManager.removeItem(at: root) }

        let generationUpdate = try #require(CostUsageCacheLocations
            .prepareCLIProxyAPIConfigurationGenerationUpdate(stateRoot: root, fileManager: fileManager))
        let artifactsUpdate = try #require(CostUsageCacheLocations.prepareCLIProxyAPIArtifactsUpdate(
            in: [costUsage],
            stateRoot: root,
            expectedGeneration: generationUpdate.generation,
            fileManager: fileManager))
        #expect(CostUsageCacheLocations.commitCLIProxyAPIConfigurationGenerationUpdate(
            generationUpdate,
            fileManager: fileManager))

        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(stateRoot: root, fileManager: fileManager) {}

        #expect(!fileManager.fileExists(atPath: usageFile.path))
        #expect(artifactsUpdate.moves.allSatisfy { !fileManager.fileExists(atPath: $0.stagedURL.path) })
        #expect(artifactsUpdate.manifestURL.map { !fileManager.fileExists(atPath: $0.path) } == true)
    }

    @Test
    func `interrupted removal before isolation restores telemetry and connection state`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-removal-before-isolation-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? fileManager.removeItem(at: root) }

        let generationUpdate = try #require(CostUsageCacheLocations
            .prepareCLIProxyAPIConfigurationGenerationUpdate(stateRoot: root, fileManager: fileManager))
        let artifactsUpdate = try #require(CostUsageCacheLocations.prepareCLIProxyAPIArtifactsUpdate(
            in: [costUsage],
            stateRoot: root,
            expectedGeneration: generationUpdate.generation,
            fileManager: fileManager,
            disconnectedStateAfterRollback: false,
            removalIsolationPublished: false,
            removalCredentialsCleared: false))
        #expect(CostUsageCacheLocations.commitCLIProxyAPIConfigurationGenerationUpdate(
            generationUpdate,
            fileManager: fileManager))

        let didRecoverConfiguration = LockIsolated(false)
        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
            stateRoot: root,
            fileManager: fileManager)
        {
            didRecoverConfiguration.setValue(true)
            return true
        } operation: {}

        #expect(!CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))
        #expect(!didRecoverConfiguration.value)
        #expect(fileManager.fileExists(atPath: usageFile.path))
        #expect(artifactsUpdate.moves.allSatisfy { !fileManager.fileExists(atPath: $0.stagedURL.path) })
        #expect(artifactsUpdate.manifestURL.map { !fileManager.fileExists(atPath: $0.path) } == true)
    }

    @Test
    func `preexisting isolation does not impersonate removal progress`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-removal-preexisting-isolation-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? fileManager.removeItem(at: root) }
        #expect(CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
            true,
            stateRoot: root,
            fileManager: fileManager))

        let generationUpdate = try #require(CostUsageCacheLocations
            .prepareCLIProxyAPIConfigurationGenerationUpdate(stateRoot: root, fileManager: fileManager))
        let artifactsUpdate = try #require(CostUsageCacheLocations.prepareCLIProxyAPIArtifactsUpdate(
            in: [costUsage],
            stateRoot: root,
            expectedGeneration: generationUpdate.generation,
            fileManager: fileManager,
            disconnectedStateAfterRollback: true,
            removalIsolationPublished: false,
            removalCredentialsCleared: false))
        #expect(CostUsageCacheLocations.commitCLIProxyAPIConfigurationGenerationUpdate(
            generationUpdate,
            fileManager: fileManager))

        let didRecoverConfiguration = LockIsolated(false)
        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
            stateRoot: root,
            fileManager: fileManager)
        {
            didRecoverConfiguration.setValue(true)
            return true
        } operation: {}

        #expect(CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))
        #expect(!didRecoverConfiguration.value)
        #expect(fileManager.fileExists(atPath: usageFile.path))
        #expect(artifactsUpdate.moves.allSatisfy { !fileManager.fileExists(atPath: $0.stagedURL.path) })
        #expect(artifactsUpdate.manifestURL.map { !fileManager.fileExists(atPath: $0.path) } == true)
    }

    @Test
    func `transaction owned isolation completes interrupted credential removal`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-removal-owned-isolation-\(UUID().uuidString)", isDirectory: true)
        let costUsage = root.appendingPathComponent("cost-usage", isDirectory: true)
        let usageFile = costUsage.appendingPathComponent(CostUsageCacheLocations.cliProxyAPIUsageFileName)
        try fileManager.createDirectory(at: costUsage, withIntermediateDirectories: true)
        try Data("telemetry".utf8).write(to: usageFile)
        defer { try? fileManager.removeItem(at: root) }

        let generationUpdate = try #require(CostUsageCacheLocations
            .prepareCLIProxyAPIConfigurationGenerationUpdate(stateRoot: root, fileManager: fileManager))
        let artifactsUpdate = try #require(CostUsageCacheLocations.prepareCLIProxyAPIArtifactsUpdate(
            in: [costUsage],
            stateRoot: root,
            expectedGeneration: generationUpdate.generation,
            fileManager: fileManager,
            disconnectedStateAfterRollback: false,
            removalIsolationPublished: false,
            removalCredentialsCleared: false))
        #expect(CostUsageCacheLocations.commitCLIProxyAPIConfigurationGenerationUpdate(
            generationUpdate,
            fileManager: fileManager))
        #expect(CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
            true,
            stateRoot: root,
            fileManager: fileManager))
        #expect(CostUsageCacheLocations.markCLIProxyAPIArtifactsRemovalIsolationPublished(
            artifactsUpdate,
            fileManager: fileManager))

        let didRecoverConfiguration = LockIsolated(false)
        #expect(throws: CocoaError.self) {
            try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
                stateRoot: root,
                fileManager: fileManager)
            {
                didRecoverConfiguration.setValue(true)
                return false
            } operation: {}
        }
        #expect(didRecoverConfiguration.value)
        #expect(!fileManager.fileExists(atPath: usageFile.path))
        #expect(artifactsUpdate.moves.allSatisfy { fileManager.fileExists(atPath: $0.stagedURL.path) })
        #expect(artifactsUpdate.manifestURL.map { fileManager.fileExists(atPath: $0.path) } == true)

        didRecoverConfiguration.setValue(false)
        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(
            stateRoot: root,
            fileManager: fileManager)
        {
            didRecoverConfiguration.setValue(true)
            return true
        } operation: {}

        #expect(didRecoverConfiguration.value)
        #expect(!fileManager.fileExists(atPath: usageFile.path))
        #expect(artifactsUpdate.moves.allSatisfy { !fileManager.fileExists(atPath: $0.stagedURL.path) })
        #expect(artifactsUpdate.manifestURL.map { !fileManager.fileExists(atPath: $0.path) } == true)
    }
}
