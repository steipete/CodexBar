import Foundation
import Testing
@testable import CodexBarCore

struct CLIProxyAPIPreCredentialRollbackTests {
    @Test
    func `rollback recovery verifies restored credentials before restoring staged artifacts`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-credential-rollback-recovery-\(UUID().uuidString)", isDirectory: true)
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
            rollbackCredentialFingerprint: "previous-fingerprint",
            rollbackCredentialWasMissing: false,
            prepareState: {
                CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
                    true,
                    stateRoot: root,
                    fileManager: fileManager)
            }))
        #expect(CostUsageCacheLocations.markCLIProxyAPIArtifactsUpdateForRollback(
            artifactsUpdate,
            fileManager: fileManager))

        let recovered = CostUsageCacheLocations.recoverCLIProxyAPIArtifactsTransaction(
            stateRoot: root,
            fileManager: fileManager,
            recoverRollbackConfiguration: { fingerprint, wasMissing in
                #expect(fingerprint == "previous-fingerprint")
                #expect(!wasMissing)
                return true
            })

        #expect(recovered)
        #expect(fileManager.fileExists(atPath: usageFile.path))
        #expect(!CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))
        #expect(artifactsUpdate.manifestURL.map { !fileManager.fileExists(atPath: $0.path) } == true)
        CostUsageCacheLocations.discardCLIProxyAPIConfigurationGenerationUpdate(
            generationUpdate,
            fileManager: fileManager)
    }

    @Test
    func `rollback recovery preserves staged artifacts while credential restoration is unverified`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-credential-rollback-unverified-\(UUID().uuidString)", isDirectory: true)
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
            rollbackCredentialWasMissing: true,
            prepareState: {
                CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
                    true,
                    stateRoot: root,
                    fileManager: fileManager)
            }))
        #expect(CostUsageCacheLocations.markCLIProxyAPIArtifactsUpdateForRollback(
            artifactsUpdate,
            fileManager: fileManager))

        let recovered = CostUsageCacheLocations.recoverCLIProxyAPIArtifactsTransaction(
            stateRoot: root,
            fileManager: fileManager,
            recoverRollbackConfiguration: { fingerprint, wasMissing in
                #expect(fingerprint == nil)
                #expect(wasMissing)
                return false
            })

        #expect(!recovered)
        #expect(!fileManager.fileExists(atPath: usageFile.path))
        #expect(artifactsUpdate.moves.allSatisfy { fileManager.fileExists(atPath: $0.stagedURL.path) })
        #expect(CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))
        #expect(artifactsUpdate.manifestURL.map { fileManager.fileExists(atPath: $0.path) } == true)
        CostUsageCacheLocations.discardCLIProxyAPIConfigurationGenerationUpdate(
            generationUpdate,
            fileManager: fileManager)
    }

    @Test
    func `pre credential rollback restores staged artifacts without isolating the prior configuration`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-pre-credential-rollback-\(UUID().uuidString)", isDirectory: true)
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
            prepareState: {
                CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
                    true,
                    stateRoot: root,
                    fileManager: fileManager)
            }))
        #expect(CostUsageCacheLocations.markCLIProxyAPIArtifactsUpdateForRollback(
            artifactsUpdate,
            rollbackCredentialsRestored: true,
            fileManager: fileManager))

        try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(stateRoot: root, fileManager: fileManager) {}

        #expect(fileManager.fileExists(atPath: usageFile.path))
        #expect(!CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(
            stateRoot: root,
            fileManager: fileManager))
        #expect(artifactsUpdate.manifestURL.map { !fileManager.fileExists(atPath: $0.path) } == true)
        CostUsageCacheLocations.discardCLIProxyAPIConfigurationGenerationUpdate(
            generationUpdate,
            fileManager: fileManager)
    }
}
