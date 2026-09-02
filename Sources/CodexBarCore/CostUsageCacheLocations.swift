import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct CostUsageCacheClearResult: Equatable, Sendable {
    public let cleared: Int
    public let errorDescription: String?
}

// swiftlint:disable:next type_body_length
public enum CostUsageCacheLocations {
    struct CLIProxyAPIArtifactsUpdate: Sendable {
        struct Move: Sendable {
            let originalURL: URL
            let stagedURL: URL
        }

        let moves: [Move]
        let manifestURL: URL?

        init(moves: [Move], manifestURL: URL? = nil) {
            self.moves = moves
            self.manifestURL = manifestURL
        }
    }

    struct CLIProxyAPIConfigurationGenerationUpdate {
        let stagedURL: URL
        let destinationURL: URL
        let generation: String
    }

    private struct CLIProxyAPIArtifactsTransactionManifest: Codable {
        struct Move: Codable {
            let originalPath: String
            let stagedPath: String
        }

        let expectedGeneration: String
        let moves: [Move]
        let disconnectedStateAfterCommit: Bool?
        let disconnectedStateAfterRollback: Bool?
        let replacementCredentialFingerprint: String?
        let replacementCredentialsStored: Bool?
        let rollbackCredentialFingerprint: String?
        let rollbackCredentialWasMissing: Bool?
        let forceRollback: Bool?
        let rollbackCredentialsRestored: Bool?
        let removalIsolationPublished: Bool?
        let removalCredentialsCleared: Bool?
    }

    static let cliProxyAPIUsageFileName = "cliproxyapi-usage-v1.json"
    static let cliProxyAPIPendingFileName = "cliproxyapi-pending-v1.json"
    private static let cliProxyAPIDisconnectedFileName = "cliproxyapi-disconnected-v1"
    private static let cliProxyAPIConfigurationGenerationFileName = "cliproxyapi-configuration-generation-v1"
    private static let cliProxyAPIArtifactsTransactionFileName = "cliproxyapi-artifacts-transaction-v1.json"

    public static func directories(fileManager: FileManager = .default) -> [URL] {
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let applicationSupportRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
        return [cacheRoot, applicationSupportRoot].map { root in
            root
                .appendingPathComponent("CodexBar", isDirectory: true)
                .appendingPathComponent("cost-usage", isDirectory: true)
        }
    }

    public static func clearAllCostUsageCaches(
        fileManager: FileManager = .default) -> CostUsageCacheClearResult
    {
        self.clearAllCostUsageCaches(
            in: self.directories(fileManager: fileManager),
            stateRoot: nil,
            fileManager: fileManager)
    }

    public static func clearAllCostUsageCaches(
        in directories: [URL],
        stateRoot: URL?,
        fileManager: FileManager = .default) -> CostUsageCacheClearResult
    {
        do {
            return try self.withCLIProxyAPIInterprocessLock(
                stateRoot: stateRoot,
                fileManager: fileManager)
            {
                guard self.advanceCLIProxyAPIConfigurationGeneration(
                    stateRoot: stateRoot,
                    fileManager: fileManager)
                else {
                    return CostUsageCacheClearResult(
                        cleared: 0,
                        errorDescription: CocoaError(.fileWriteUnknown).localizedDescription)
                }
                var cleared = 0
                for directory in directories where fileManager.fileExists(atPath: directory.path) {
                    do {
                        try fileManager.removeItem(at: directory)
                        cleared += 1
                    } catch {
                        return CostUsageCacheClearResult(
                            cleared: cleared,
                            errorDescription: error.localizedDescription)
                    }
                }
                return CostUsageCacheClearResult(cleared: cleared, errorDescription: nil)
            }
        } catch {
            return CostUsageCacheClearResult(cleared: 0, errorDescription: error.localizedDescription)
        }
    }

    static func withCLIProxyAPIInterprocessLock<T>(
        stateRoot: URL?,
        fileManager: FileManager = .default,
        recoverRemovalConfiguration: (() -> Bool)? = nil,
        recoverReplacementConfiguration: ((String) -> Bool?)? = nil,
        operation: () throws -> T) throws -> T
    {
        let descriptor = try self.acquireCLIProxyAPILock(stateRoot: stateRoot, fileManager: fileManager)
        defer { self.releaseCLIProxyAPILock(descriptor) }
        guard self.recoverCLIProxyAPIArtifactsTransaction(
            stateRoot: stateRoot,
            fileManager: fileManager,
            recoverReplacementConfiguration: recoverReplacementConfiguration,
            recoverRemovalConfiguration: recoverRemovalConfiguration ?? {
                CLIProxyAPIConnectionSettingsStore.recoverInterruptedRemovalUnserialized(
                    stateRoot: stateRoot,
                    fileManager: fileManager)
            })
        else {
            throw CocoaError(.fileReadUnknown)
        }
        return try operation()
    }

    static func withCLIProxyAPIInterprocessLock<T>(
        stateRoot: URL?,
        fileManager: FileManager = .default,
        recoverRemovalConfiguration: (() -> Bool)? = nil,
        recoverReplacementConfiguration: ((String) -> Bool?)? = nil,
        operation: () async throws -> T) async throws -> T
    {
        let descriptor = try self.acquireCLIProxyAPILock(stateRoot: stateRoot, fileManager: fileManager)
        defer { self.releaseCLIProxyAPILock(descriptor) }
        guard self.recoverCLIProxyAPIArtifactsTransaction(
            stateRoot: stateRoot,
            fileManager: fileManager,
            recoverReplacementConfiguration: recoverReplacementConfiguration,
            recoverRemovalConfiguration: recoverRemovalConfiguration ?? {
                CLIProxyAPIConnectionSettingsStore.recoverInterruptedRemovalUnserialized(
                    stateRoot: stateRoot,
                    fileManager: fileManager)
            })
        else {
            throw CocoaError(.fileReadUnknown)
        }
        return try await operation()
    }

    @discardableResult
    public static func clearCLIProxyAPIArtifacts(fileManager: FileManager = .default) -> Bool {
        let directories = self.directories(fileManager: fileManager)
        return self.clearCLIProxyAPIArtifacts(
            in: directories,
            stateRoot: directories[1].deletingLastPathComponent(),
            fileManager: fileManager)
    }

    @discardableResult
    static func clearCLIProxyAPIArtifacts(
        in directories: [URL],
        stateRoot: URL?,
        fileManager: FileManager = .default) -> Bool
    {
        do {
            return try self.withCLIProxyAPIInterprocessLock(
                stateRoot: stateRoot,
                fileManager: fileManager)
            {
                guard self.advanceCLIProxyAPIConfigurationGeneration(
                    stateRoot: stateRoot,
                    fileManager: fileManager)
                else { return false }
                return self.clearCLIProxyAPIArtifactsUnserialized(
                    in: directories,
                    fileManager: fileManager)
            }
        } catch {
            return false
        }
    }

    static func clearCLIProxyAPIArtifactsUnserialized(
        in directories: [URL],
        fileManager: FileManager) -> Bool
    {
        var succeeded = true
        for url in self.cliProxyAPIArtifactURLs(in: directories) {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    static func prepareCLIProxyAPIArtifactsUpdate(
        in directories: [URL],
        stateRoot: URL?,
        expectedGeneration: String,
        fileManager: FileManager,
        disconnectedStateAfterCommit: Bool? = nil,
        disconnectedStateAfterRollback: Bool? = nil,
        replacementCredentialFingerprint: String? = nil,
        replacementCredentialsStored: Bool? = nil,
        rollbackCredentialFingerprint: String? = nil,
        rollbackCredentialWasMissing: Bool? = nil,
        removalIsolationPublished: Bool? = nil,
        removalCredentialsCleared: Bool? = nil,
        prepareState: () -> Bool = { true }) -> CLIProxyAPIArtifactsUpdate?
    {
        let identifier = UUID().uuidString
        let moves = self.cliProxyAPIArtifactURLs(in: directories)
            .filter { fileManager.fileExists(atPath: $0.path) }
            .map { originalURL in
                CLIProxyAPIArtifactsUpdate.Move(
                    originalURL: originalURL,
                    stagedURL: originalURL
                        .deletingLastPathComponent()
                        .appendingPathComponent(
                            ".\(originalURL.lastPathComponent).\(identifier).replacement-backup",
                            isDirectory: false))
            }
        let manifestURL = self.cliProxyAPIArtifactsTransactionURL(
            stateRoot: stateRoot,
            fileManager: fileManager)
        let manifest = CLIProxyAPIArtifactsTransactionManifest(
            expectedGeneration: expectedGeneration,
            moves: moves.map {
                .init(originalPath: $0.originalURL.path, stagedPath: $0.stagedURL.path)
            },
            disconnectedStateAfterCommit: disconnectedStateAfterCommit,
            disconnectedStateAfterRollback: disconnectedStateAfterRollback,
            replacementCredentialFingerprint: replacementCredentialFingerprint,
            replacementCredentialsStored: replacementCredentialsStored,
            rollbackCredentialFingerprint: rollbackCredentialFingerprint,
            rollbackCredentialWasMissing: rollbackCredentialWasMissing,
            forceRollback: nil,
            rollbackCredentialsRestored: nil,
            removalIsolationPublished: removalIsolationPublished,
            removalCredentialsCleared: removalCredentialsCleared)
        do {
            try fileManager.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: [.atomic])
        } catch {
            return nil
        }

        let update = CLIProxyAPIArtifactsUpdate(moves: moves, manifestURL: manifestURL)
        guard prepareState() else {
            _ = self.removeCLIProxyAPIArtifactsManifest(manifestURL, fileManager: fileManager)
            return nil
        }
        for move in moves {
            do {
                try fileManager.moveItem(at: move.originalURL, to: move.stagedURL)
            } catch {
                _ = self.restoreCLIProxyAPIArtifactsUpdate(update, fileManager: fileManager)
                return nil
            }
        }
        return update
    }

    static func prepareCLIProxyAPIArtifactsUpdate(
        in directories: [URL],
        fileExists: (URL) -> Bool,
        moveItem: (URL, URL) throws -> Void) -> CLIProxyAPIArtifactsUpdate?
    {
        let identifier = UUID().uuidString
        var moves: [CLIProxyAPIArtifactsUpdate.Move] = []
        for originalURL in self.cliProxyAPIArtifactURLs(in: directories) where fileExists(originalURL) {
            let stagedURL = originalURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(originalURL.lastPathComponent).\(identifier).replacement-backup",
                    isDirectory: false)
            do {
                try moveItem(originalURL, stagedURL)
                moves.append(.init(originalURL: originalURL, stagedURL: stagedURL))
            } catch {
                _ = self.restoreCLIProxyAPIArtifactsUpdate(
                    .init(moves: moves),
                    fileExists: fileExists,
                    moveItem: moveItem)
                return nil
            }
        }
        return CLIProxyAPIArtifactsUpdate(moves: moves)
    }

    @discardableResult
    static func restoreCLIProxyAPIArtifactsUpdate(
        _ update: CLIProxyAPIArtifactsUpdate,
        fileManager: FileManager) -> Bool
    {
        let restored = self.restoreCLIProxyAPIArtifactsUpdate(
            update,
            fileExists: { fileManager.fileExists(atPath: $0.path) },
            moveItem: { try fileManager.moveItem(at: $0, to: $1) })
        guard restored else { return false }
        return self.removeCLIProxyAPIArtifactsManifest(update.manifestURL, fileManager: fileManager)
    }

    @discardableResult
    static func markCLIProxyAPIArtifactsUpdateForRollback(
        _ update: CLIProxyAPIArtifactsUpdate,
        rollbackCredentialsRestored: Bool = false,
        fileManager: FileManager) -> Bool
    {
        guard let manifestURL = update.manifestURL else { return true }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CLIProxyAPIArtifactsTransactionManifest.self, from: data)
        else { return false }
        guard manifest.forceRollback != true else { return true }
        let rollbackManifest = CLIProxyAPIArtifactsTransactionManifest(
            expectedGeneration: manifest.expectedGeneration,
            moves: manifest.moves,
            disconnectedStateAfterCommit: manifest.disconnectedStateAfterCommit,
            disconnectedStateAfterRollback: manifest.disconnectedStateAfterRollback,
            replacementCredentialFingerprint: manifest.replacementCredentialFingerprint,
            replacementCredentialsStored: manifest.replacementCredentialsStored,
            rollbackCredentialFingerprint: manifest.rollbackCredentialFingerprint,
            rollbackCredentialWasMissing: manifest.rollbackCredentialWasMissing,
            forceRollback: true,
            rollbackCredentialsRestored: rollbackCredentialsRestored || manifest.rollbackCredentialsRestored == true,
            removalIsolationPublished: manifest.removalIsolationPublished,
            removalCredentialsCleared: manifest.removalCredentialsCleared)
        do {
            try JSONEncoder().encode(rollbackManifest).write(to: manifestURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func markCLIProxyAPIArtifactsRollbackCredentialsRestored(
        _ update: CLIProxyAPIArtifactsUpdate,
        fileManager: FileManager) -> Bool
    {
        guard let manifestURL = update.manifestURL else { return true }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CLIProxyAPIArtifactsTransactionManifest.self, from: data)
        else { return false }
        guard manifest.forceRollback == true else { return false }
        guard manifest.rollbackCredentialsRestored != true else { return true }
        let restoredManifest = CLIProxyAPIArtifactsTransactionManifest(
            expectedGeneration: manifest.expectedGeneration,
            moves: manifest.moves,
            disconnectedStateAfterCommit: manifest.disconnectedStateAfterCommit,
            disconnectedStateAfterRollback: manifest.disconnectedStateAfterRollback,
            replacementCredentialFingerprint: manifest.replacementCredentialFingerprint,
            replacementCredentialsStored: manifest.replacementCredentialsStored,
            rollbackCredentialFingerprint: manifest.rollbackCredentialFingerprint,
            rollbackCredentialWasMissing: manifest.rollbackCredentialWasMissing,
            forceRollback: true,
            rollbackCredentialsRestored: true,
            removalIsolationPublished: manifest.removalIsolationPublished,
            removalCredentialsCleared: manifest.removalCredentialsCleared)
        do {
            try JSONEncoder().encode(restoredManifest).write(to: manifestURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func markCLIProxyAPIArtifactsReplacementCredentialsStored(
        _ update: CLIProxyAPIArtifactsUpdate,
        fileManager: FileManager) -> Bool
    {
        guard let manifestURL = update.manifestURL else { return true }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CLIProxyAPIArtifactsTransactionManifest.self, from: data)
        else { return false }
        guard manifest.forceRollback != true else { return false }
        guard manifest.replacementCredentialsStored == false else {
            return manifest.replacementCredentialsStored == true
        }
        let storedManifest = CLIProxyAPIArtifactsTransactionManifest(
            expectedGeneration: manifest.expectedGeneration,
            moves: manifest.moves,
            disconnectedStateAfterCommit: manifest.disconnectedStateAfterCommit,
            disconnectedStateAfterRollback: manifest.disconnectedStateAfterRollback,
            replacementCredentialFingerprint: manifest.replacementCredentialFingerprint,
            replacementCredentialsStored: true,
            rollbackCredentialFingerprint: manifest.rollbackCredentialFingerprint,
            rollbackCredentialWasMissing: manifest.rollbackCredentialWasMissing,
            forceRollback: manifest.forceRollback,
            rollbackCredentialsRestored: manifest.rollbackCredentialsRestored,
            removalIsolationPublished: manifest.removalIsolationPublished,
            removalCredentialsCleared: manifest.removalCredentialsCleared)
        do {
            try JSONEncoder().encode(storedManifest).write(to: manifestURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func markCLIProxyAPIArtifactsRemovalCredentialsCleared(
        _ update: CLIProxyAPIArtifactsUpdate,
        fileManager: FileManager) -> Bool
    {
        guard let manifestURL = update.manifestURL else { return true }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CLIProxyAPIArtifactsTransactionManifest.self, from: data)
        else { return false }
        guard manifest.forceRollback != true else { return false }
        guard manifest.removalCredentialsCleared == false else {
            return manifest.removalCredentialsCleared == true
        }
        let clearedManifest = CLIProxyAPIArtifactsTransactionManifest(
            expectedGeneration: manifest.expectedGeneration,
            moves: manifest.moves,
            disconnectedStateAfterCommit: manifest.disconnectedStateAfterCommit,
            disconnectedStateAfterRollback: manifest.disconnectedStateAfterRollback,
            replacementCredentialFingerprint: manifest.replacementCredentialFingerprint,
            replacementCredentialsStored: manifest.replacementCredentialsStored,
            rollbackCredentialFingerprint: manifest.rollbackCredentialFingerprint,
            rollbackCredentialWasMissing: manifest.rollbackCredentialWasMissing,
            forceRollback: manifest.forceRollback,
            rollbackCredentialsRestored: manifest.rollbackCredentialsRestored,
            removalIsolationPublished: manifest.removalIsolationPublished,
            removalCredentialsCleared: true)
        do {
            try JSONEncoder().encode(clearedManifest).write(to: manifestURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func markCLIProxyAPIArtifactsRemovalIsolationPublished(
        _ update: CLIProxyAPIArtifactsUpdate,
        fileManager: FileManager) -> Bool
    {
        guard let manifestURL = update.manifestURL else { return true }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CLIProxyAPIArtifactsTransactionManifest.self, from: data)
        else { return false }
        guard manifest.forceRollback != true else { return false }
        guard manifest.removalIsolationPublished == false else {
            return manifest.removalIsolationPublished == true
        }
        let isolatedManifest = CLIProxyAPIArtifactsTransactionManifest(
            expectedGeneration: manifest.expectedGeneration,
            moves: manifest.moves,
            disconnectedStateAfterCommit: manifest.disconnectedStateAfterCommit,
            disconnectedStateAfterRollback: manifest.disconnectedStateAfterRollback,
            replacementCredentialFingerprint: manifest.replacementCredentialFingerprint,
            replacementCredentialsStored: manifest.replacementCredentialsStored,
            rollbackCredentialFingerprint: manifest.rollbackCredentialFingerprint,
            rollbackCredentialWasMissing: manifest.rollbackCredentialWasMissing,
            forceRollback: manifest.forceRollback,
            rollbackCredentialsRestored: manifest.rollbackCredentialsRestored,
            removalIsolationPublished: true,
            removalCredentialsCleared: manifest.removalCredentialsCleared)
        do {
            try JSONEncoder().encode(isolatedManifest).write(to: manifestURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func restoreCLIProxyAPIArtifactsUpdate(
        _ update: CLIProxyAPIArtifactsUpdate,
        fileExists: (URL) -> Bool,
        moveItem: (URL, URL) throws -> Void) -> Bool
    {
        var succeeded = true
        for move in update.moves.reversed() where fileExists(move.stagedURL) {
            guard !fileExists(move.originalURL) else {
                succeeded = false
                continue
            }
            do {
                try moveItem(move.stagedURL, move.originalURL)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    @discardableResult
    static func discardCLIProxyAPIArtifactsUpdate(
        _ update: CLIProxyAPIArtifactsUpdate,
        fileManager: FileManager) -> Bool
    {
        var succeeded = true
        for move in update.moves {
            guard fileManager.fileExists(atPath: move.stagedURL.path) else { continue }
            do {
                try fileManager.removeItem(at: move.stagedURL)
            } catch {
                succeeded = false
            }
        }
        guard succeeded else { return false }
        return self.removeCLIProxyAPIArtifactsManifest(update.manifestURL, fileManager: fileManager)
    }

    @discardableResult
    private static func recoverCLIProxyAPIRollbackCredentials(
        manifest: CLIProxyAPIArtifactsTransactionManifest,
        update: CLIProxyAPIArtifactsUpdate,
        stateRoot: URL?,
        fileManager: FileManager,
        recoverRollbackConfiguration: ((String?, Bool) -> Bool?)?) -> Bool
    {
        guard manifest.forceRollback == true, manifest.rollbackCredentialsRestored != true else { return true }
        guard self.setCLIProxyAPIExplicitlyDisconnected(
            true,
            stateRoot: stateRoot,
            fileManager: fileManager),
            let rollbackCredentialWasMissing = manifest.rollbackCredentialWasMissing
        else { return false }
        let recoverRollbackConfiguration = recoverRollbackConfiguration ?? {
            CLIProxyAPIConnectionSettingsStore.rollbackCredentialMatches(
                fingerprint: $0,
                wasMissing: $1)
        }
        guard let rollbackCredentialsRestored = recoverRollbackConfiguration(
            manifest.rollbackCredentialFingerprint,
            rollbackCredentialWasMissing),
            rollbackCredentialsRestored
        else { return false }
        return self.markCLIProxyAPIArtifactsRollbackCredentialsRestored(
            update,
            fileManager: fileManager)
    }

    @discardableResult
    static func recoverCLIProxyAPIArtifactsTransaction(
        stateRoot: URL?,
        fileManager: FileManager = .default,
        recoverReplacementConfiguration: ((String) -> Bool?)? = nil,
        recoverRollbackConfiguration: ((String?, Bool) -> Bool?)? = nil,
        recoverRemovalConfiguration: (() -> Bool)? = nil) -> Bool
    {
        let manifestURL = self.cliProxyAPIArtifactsTransactionURL(
            stateRoot: stateRoot,
            fileManager: fileManager)
        guard fileManager.fileExists(atPath: manifestURL.path) else { return true }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CLIProxyAPIArtifactsTransactionManifest.self, from: data)
        else { return false }
        let update = CLIProxyAPIArtifactsUpdate(
            moves: manifest.moves.map {
                .init(
                    originalURL: URL(fileURLWithPath: $0.originalPath),
                    stagedURL: URL(fileURLWithPath: $0.stagedPath))
            },
            manifestURL: manifestURL)
        guard self.recoverCLIProxyAPIRollbackCredentials(
            manifest: manifest,
            update: update,
            stateRoot: stateRoot,
            fileManager: fileManager,
            recoverRollbackConfiguration: recoverRollbackConfiguration)
        else { return false }
        let didCommit = manifest.forceRollback != true &&
            self.cliProxyAPIConfigurationGeneration(stateRoot: stateRoot, fileManager: fileManager) ==
            manifest.expectedGeneration
        if didCommit,
           manifest.replacementCredentialsStored == false,
           let fingerprint = manifest.replacementCredentialFingerprint
        {
            let recoverReplacementConfiguration = recoverReplacementConfiguration ?? {
                CLIProxyAPIConnectionSettingsStore.replacementCredentialMatches(fingerprint: $0)
            }
            guard let replacementCredentialsStored = recoverReplacementConfiguration(fingerprint) else {
                return false
            }
            if replacementCredentialsStored {
                guard self.markCLIProxyAPIArtifactsReplacementCredentialsStored(
                    update,
                    fileManager: fileManager)
                else { return false }
            } else {
                guard self.setCLIProxyAPIExplicitlyDisconnected(
                    manifest.disconnectedStateAfterRollback ?? true,
                    stateRoot: stateRoot,
                    fileManager: fileManager)
                else { return false }
                return self.restoreCLIProxyAPIArtifactsUpdate(update, fileManager: fileManager)
            }
        } else if didCommit, manifest.replacementCredentialsStored == false {
            guard self.setCLIProxyAPIExplicitlyDisconnected(
                manifest.disconnectedStateAfterRollback ?? true,
                stateRoot: stateRoot,
                fileManager: fileManager)
            else { return false }
            return self.restoreCLIProxyAPIArtifactsUpdate(update, fileManager: fileManager)
        }
        if didCommit, manifest.removalIsolationPublished != nil, manifest.removalIsolationPublished != true {
            guard self.setCLIProxyAPIExplicitlyDisconnected(
                manifest.disconnectedStateAfterRollback ?? true,
                stateRoot: stateRoot,
                fileManager: fileManager)
            else { return false }
            return self.restoreCLIProxyAPIArtifactsUpdate(update, fileManager: fileManager)
        }
        if didCommit, manifest.removalIsolationPublished == true, manifest.removalCredentialsCleared != true {
            let recoverRemovalConfiguration = recoverRemovalConfiguration ?? {
                CLIProxyAPIConnectionSettingsStore.recoverInterruptedRemovalUnserialized(
                    stateRoot: stateRoot,
                    fileManager: fileManager)
            }
            guard self.setCLIProxyAPIExplicitlyDisconnected(
                true,
                stateRoot: stateRoot,
                fileManager: fileManager),
                recoverRemovalConfiguration(),
                self.markCLIProxyAPIArtifactsRemovalCredentialsCleared(update, fileManager: fileManager)
            else { return false }
            return self.discardCLIProxyAPIArtifactsUpdate(update, fileManager: fileManager)
        }
        // Recover transactions written before removal-isolation provenance was added conservatively.
        if didCommit, manifest.removalIsolationPublished == nil, manifest.removalCredentialsCleared == false {
            guard self.setCLIProxyAPIExplicitlyDisconnected(
                true,
                stateRoot: stateRoot,
                fileManager: fileManager)
            else { return false }
            return self.restoreCLIProxyAPIArtifactsUpdate(update, fileManager: fileManager)
        }
        let disconnectedState = didCommit
            ? manifest.disconnectedStateAfterCommit
            : manifest.disconnectedStateAfterRollback
        if let disconnectedState,
           !self.setCLIProxyAPIExplicitlyDisconnected(
               disconnectedState,
               stateRoot: stateRoot,
               fileManager: fileManager)
        {
            return false
        }
        if didCommit {
            return self.discardCLIProxyAPIArtifactsUpdate(update, fileManager: fileManager)
        }
        return self.restoreCLIProxyAPIArtifactsUpdate(update, fileManager: fileManager)
    }

    private static func removeCLIProxyAPIArtifactsManifest(
        _ manifestURL: URL?,
        fileManager: FileManager) -> Bool
    {
        guard let manifestURL, fileManager.fileExists(atPath: manifestURL.path) else { return true }
        do {
            try fileManager.removeItem(at: manifestURL)
            return true
        } catch {
            return false
        }
    }

    private static func cliProxyAPIArtifactURLs(in directories: [URL]) -> [URL] {
        var seenPaths: Set<String> = []
        return directories.flatMap { directory in
            [
                directory.appendingPathComponent(self.cliProxyAPIUsageFileName, isDirectory: false),
                directory.appendingPathComponent(self.cliProxyAPIPendingFileName, isDirectory: false),
                // Provider-specific by design: the attributed proxy rows are persisted in the Claude scan cache.
                CostUsageClaudeCacheIO.cacheFileURL(
                    provider: .claude,
                    cacheRoot: directory.deletingLastPathComponent()),
            ]
        }.filter { seenPaths.insert($0.path).inserted }
    }

    public static func isCLIProxyAPIExplicitlyDisconnected(
        stateRoot: URL? = nil,
        fileManager: FileManager = .default) -> Bool
    {
        fileManager.fileExists(atPath: self.cliProxyAPIDisconnectedURL(
            stateRoot: stateRoot,
            fileManager: fileManager).path)
    }

    public static func cliProxyAPIConfigurationGeneration(
        stateRoot: URL? = nil,
        fileManager: FileManager = .default) -> String?
    {
        let url = self.cliProxyAPIConfigurationGenerationURL(
            stateRoot: stateRoot,
            fileManager: fileManager)
        guard let data = try? Data(contentsOf: url),
              let generation = String(data: data, encoding: .utf8),
              !generation.isEmpty
        else { return nil }
        return generation
    }

    static func prepareCLIProxyAPIConfigurationGenerationUpdate(
        stateRoot: URL? = nil,
        fileManager: FileManager = .default) -> CLIProxyAPIConfigurationGenerationUpdate?
    {
        let destinationURL = self.cliProxyAPIConfigurationGenerationURL(
            stateRoot: stateRoot,
            fileManager: fileManager)
        let stagedURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".cliproxyapi-generation-\(UUID().uuidString).tmp", isDirectory: false)
        let generation = UUID().uuidString
        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(generation.utf8).write(to: stagedURL, options: [.atomic])
            return CLIProxyAPIConfigurationGenerationUpdate(
                stagedURL: stagedURL,
                destinationURL: destinationURL,
                generation: generation)
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            return nil
        }
    }

    static func commitCLIProxyAPIConfigurationGenerationUpdate(
        _ update: CLIProxyAPIConfigurationGenerationUpdate,
        fileManager: FileManager = .default) -> Bool
    {
        rename(update.stagedURL.path, update.destinationURL.path) == 0
    }

    static func discardCLIProxyAPIConfigurationGenerationUpdate(
        _ update: CLIProxyAPIConfigurationGenerationUpdate,
        fileManager: FileManager = .default)
    {
        try? fileManager.removeItem(at: update.stagedURL)
    }

    private static func advanceCLIProxyAPIConfigurationGeneration(
        stateRoot: URL?,
        fileManager: FileManager) -> Bool
    {
        guard let update = self.prepareCLIProxyAPIConfigurationGenerationUpdate(
            stateRoot: stateRoot,
            fileManager: fileManager)
        else { return false }
        guard self.commitCLIProxyAPIConfigurationGenerationUpdate(update, fileManager: fileManager) else {
            self.discardCLIProxyAPIConfigurationGenerationUpdate(update, fileManager: fileManager)
            return false
        }
        return true
    }

    @discardableResult
    package static func setCLIProxyAPIExplicitlyDisconnected(
        _ disconnected: Bool,
        stateRoot: URL? = nil,
        fileManager: FileManager = .default) -> Bool
    {
        let url = self.cliProxyAPIDisconnectedURL(
            stateRoot: stateRoot,
            fileManager: fileManager)
        if disconnected {
            guard !fileManager.fileExists(atPath: url.path) else { return true }
            do {
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try Data().write(to: url, options: [.atomic])
                return true
            } catch {
                return false
            }
        }

        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    package static func publishCLIProxyAPIAttributionIsolation(
        expectedGeneration: String?,
        stateRoot: URL? = nil,
        fileManager: FileManager = .default) -> Bool
    {
        do {
            return try self.withCLIProxyAPIInterprocessLock(
                stateRoot: stateRoot,
                fileManager: fileManager)
            {
                guard self.cliProxyAPIConfigurationGeneration(
                    stateRoot: stateRoot,
                    fileManager: fileManager) == expectedGeneration
                else { return false }
                return self.setCLIProxyAPIExplicitlyDisconnected(
                    true,
                    stateRoot: stateRoot,
                    fileManager: fileManager)
            }
        } catch {
            return false
        }
    }

    @discardableResult
    package static func publishCLIProxyAPIAttributionIsolationAsync(
        expectedGeneration: String?,
        stateRoot: URL? = nil) async -> Bool
    {
        await Task.detached(priority: .utility) {
            self.publishCLIProxyAPIAttributionIsolation(
                expectedGeneration: expectedGeneration,
                stateRoot: stateRoot)
        }.value
    }

    private static func cliProxyAPIDisconnectedURL(
        stateRoot: URL?,
        fileManager: FileManager) -> URL
    {
        let root = stateRoot ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        return root.appendingPathComponent(self.cliProxyAPIDisconnectedFileName, isDirectory: false)
    }

    private static func cliProxyAPIConfigurationGenerationURL(
        stateRoot: URL?,
        fileManager: FileManager) -> URL
    {
        let root = stateRoot ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        return root.appendingPathComponent(
            self.cliProxyAPIConfigurationGenerationFileName,
            isDirectory: false)
    }

    private static func cliProxyAPIArtifactsTransactionURL(
        stateRoot: URL?,
        fileManager: FileManager) -> URL
    {
        let root = stateRoot ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        return root.appendingPathComponent(self.cliProxyAPIArtifactsTransactionFileName, isDirectory: false)
    }

    private static func acquireCLIProxyAPILock(
        stateRoot: URL?,
        fileManager: FileManager) throws -> Int32
    {
        let root = stateRoot ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let lockURL = root.appendingPathComponent("cliproxyapi-collection.lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return descriptor
    }
}

extension CostUsageCacheLocations {
    private static func releaseCLIProxyAPILock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
