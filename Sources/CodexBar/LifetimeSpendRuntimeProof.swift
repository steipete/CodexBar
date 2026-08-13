#if DEBUG
import AppKit
import CodexBarCore
import CryptoKit
import Darwin
import Foundation
import SwiftUI

/// Opt-in packaged-app proof for lifetime spend persistence. This launch mode is
/// compiled out of release builds and resolves before `CodexBarApp` constructs any
/// settings, provider, browser, or Keychain services.
struct LifetimeSpendRuntimeProofConfiguration: Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case record
        case reload

        var now: Date {
            switch self {
            case .record: Date(timeIntervalSince1970: 1_769_731_200) // 2026-01-30T00:00:00Z
            case .reload: Date(timeIntervalSince1970: 1_772_323_200) // 2026-03-01T00:00:00Z
            }
        }

        var expectedCoveredDays: Int {
            switch self {
            case .record: 30
            case .reload: 60
            }
        }
    }

    enum Resolution: Equatable {
        case notRequested
        case accepted(LifetimeSpendRuntimeProofConfiguration)
        case rejected
    }

    private struct Sentinel: Decodable {
        let schemaVersion: Int
        let runID: String
    }

    static let rootEnvironmentKey = "CODEXBAR_LIFETIME_RUNTIME_PROOF_ROOT"
    static let phaseEnvironmentKey = "CODEXBAR_LIFETIME_RUNTIME_PROOF_PHASE"
    static let sentinelFilename = ".codexbar-lifetime-proof.json"

    let root: URL
    let phase: Phase
    let runID: String

    var codexHome: URL {
        self.root.appendingPathComponent("codex-home", isDirectory: true)
    }

    var cacheRoot: URL {
        self.root.appendingPathComponent("cache", isDirectory: true)
    }

    var ledgerURL: URL {
        self.root.appendingPathComponent("spend-history.json", isDirectory: false)
    }

    var outputDirectory: URL {
        self.root.appendingPathComponent("output", isDirectory: true)
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> Resolution
    {
        guard let rawRoot = environment[self.rootEnvironmentKey] else { return .notRequested }
        guard let phaseRaw = environment[self.phaseEnvironmentKey],
              let phase = Phase(rawValue: phaseRaw)
        else { return .rejected }

        let suppliedRoot = URL(fileURLWithPath: rawRoot, isDirectory: true)
        let resolvedRoot = suppliedRoot.standardizedFileURL
        let requiredPrefix = "/private/tmp/codexbar-lifetime-proof."
        guard rawRoot.hasPrefix(requiredPrefix),
              !rawRoot.contains("/../"),
              !rawRoot.contains("/./"),
              !self.isSymbolicLink(rawRoot),
              resolvedRoot.deletingLastPathComponent().path == "/tmp",
              fileManager.fileExists(atPath: resolvedRoot.path),
              let rootValues = try? resolvedRoot.resourceValues(forKeys: [
                  .isDirectoryKey,
                  .isSymbolicLinkKey,
              ]),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true
        else { return .rejected }

        guard let attributes = try? fileManager.attributesOfItem(atPath: resolvedRoot.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              owner.uint32Value == getuid()
        else { return .rejected }

        let sentinelURL = resolvedRoot.appendingPathComponent(self.sentinelFilename, isDirectory: false)
        let rawSentinelPath = suppliedRoot.appendingPathComponent(self.sentinelFilename).path
        guard !self.isSymbolicLink(rawSentinelPath),
              let sentinelValues = try? sentinelURL.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .isSymbolicLinkKey,
              ]),
              sentinelValues.isRegularFile == true,
              sentinelValues.isSymbolicLink != true,
              let data = try? Data(contentsOf: sentinelURL),
              let sentinel = try? JSONDecoder().decode(Sentinel.self, from: data),
              sentinel.schemaVersion == 1,
              sentinel.runID.range(of: #"^[A-F0-9-]{36}$"#, options: .regularExpression) != nil
        else { return .rejected }

        return .accepted(Self(root: resolvedRoot, phase: phase, runID: sentinel.runID))
    }

    static func verifiedLedgerPermissions(
        at url: URL,
        fileManager: FileManager = .default) -> String?
    {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o7777 == 0o600
        else { return nil }
        return "0600"
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return true }
        return metadata.st_mode & S_IFMT == S_IFLNK
    }
}

@MainActor
enum LifetimeSpendRuntimeProofRunner {
    private struct Manifest: Codable {
        let schemaVersion: Int
        let phase: LifetimeSpendRuntimeProofConfiguration.Phase
        let bundleIdentifier: String
        let gitCommit: String
        let executableSHA256: String
        let ledgerBeforeSHA256: String?
        let ledgerAfterSHA256: String
        let ledgerPermissions: String
        let currentWindowDays: Int
        let allTimeCoveredDays: Int
        let allTimeProviderCount: Int
        let allTimeModelNames: [String]
        let emittedPNGs: [String]
    }

    private static let dashboardSize = CGSize(width: 900, height: 1370)
    // Provider-specific by design: the isolated proof uses a fixed dummy Codex account identity.
    private static let accountID = "synthetic"
    private static let accountIdentity = "synthetic|lifetime-proof-v1"

    static func execute(_ configuration: LifetimeSpendRuntimeProofConfiguration) -> Int32 {
        var result: Int32?
        Task { @MainActor in
            result = await self.run(configuration)
        }
        while result == nil {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return result ?? 1
    }

    private static func run(_ configuration: LifetimeSpendRuntimeProofConfiguration) async -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: configuration.outputDirectory,
                withIntermediateDirectories: true)
            let ledgerBefore = Self.sha256(at: configuration.ledgerURL)
            if configuration.phase == .reload, ledgerBefore == nil {
                throw ProofError.missingRecordedLedger
            }

            let controller = self.makeController(configuration)
            controller.update(configuration: self.dashboardConfiguration)
            let deadline = Date(timeIntervalSinceNow: 30)
            while controller.isRefreshing, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard !controller.isRefreshing else { throw ProofError.timedOut }
            guard controller.failedSourceCount == 0 else { throw ProofError.sourceFailed }
            guard controller.model.range == .allTime,
                  controller.model.groups.count == 1,
                  controller.model.groups[0].coveredDayCount == configuration.phase.expectedCoveredDays
            else { throw ProofError.unexpectedCoverage }

            let model = controller.model
            let payload = try Self.require(ShareStatsBuilder.make(model: model))
            try self.validatePrivacy(model: model, payload: payload, root: configuration.root)

            var emittedPNGs: [String] = []
            if configuration.phase == .reload {
                let dashboardData = try Self.require(self.dashboardPNGData(model: model))
                let shareData = try Self.require(ShareStatsRenderer.pngData(for: payload))
                let dashboardName = "all-time-dashboard.png"
                let shareName = "all-time-share-stats.png"
                try dashboardData.write(
                    to: configuration.outputDirectory.appendingPathComponent(dashboardName),
                    options: .atomic)
                try shareData.write(
                    to: configuration.outputDirectory.appendingPathComponent(shareName),
                    options: .atomic)
                emittedPNGs = [dashboardName, shareName]
            }

            guard let ledgerAfter = Self.sha256(at: configuration.ledgerURL) else {
                throw ProofError.missingRecordedLedger
            }
            guard let ledgerPermissions = LifetimeSpendRuntimeProofConfiguration.verifiedLedgerPermissions(
                at: configuration.ledgerURL)
            else { throw ProofError.insecureLedgerPermissions }
            let manifest = Manifest(
                schemaVersion: 2,
                phase: configuration.phase,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
                gitCommit: Bundle.main.object(forInfoDictionaryKey: "CodexGitCommit") as? String ?? "unknown",
                executableSHA256: Self.sha256(at: URL(fileURLWithPath: CommandLine.arguments[0])) ?? "unknown",
                ledgerBeforeSHA256: ledgerBefore,
                ledgerAfterSHA256: ledgerAfter,
                ledgerPermissions: ledgerPermissions,
                currentWindowDays: 30,
                allTimeCoveredDays: model.groups[0].coveredDayCount,
                allTimeProviderCount: model.groups[0].providers.count,
                allTimeModelNames: model.groups[0].models.map(\.modelName).sorted(),
                emittedPNGs: emittedPNGs)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try self.validateManifestPrivacy(manifestData, root: configuration.root)
            try manifestData.write(
                to: configuration.outputDirectory
                    .appendingPathComponent("\(configuration.phase.rawValue)-manifest.json"),
                options: .atomic)
            return 0
        } catch {
            fputs("CodexBar lifetime proof failed closed.\n", stderr)
            return 1
        }
    }

    private static var dashboardConfiguration: SpendDashboardConfiguration {
        // Provider-specific by design: the proof exercises the Codex JSONL scanner used by lifetime history.
        SpendDashboardConfiguration(
            costUsageEnabled: true,
            preferredCurrencyCode: "USD",
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: [self.accountIdentity],
            codexAccountDisplayNames: ["codex:\(self.accountID)": "Codex"])
    }

    private static func makeController(
        _ configuration: LifetimeSpendRuntimeProofConfiguration) -> SpendDashboardController
    {
        let account = CodexSpendScanRequest(
            id: self.accountID,
            displayName: "Codex",
            source: .profileHome(path: configuration.codexHome.path),
            homePath: configuration.codexHome.path,
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "lifetime-proof-v1")
        let request = SpendDashboardLoadRequest(
            configuration: self.dashboardConfiguration,
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [account],
            now: configuration.phase.now,
            force: false)
        let suiteName = "com.steipete.codexbar.lifetime-proof.\(configuration.runID)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let controller = SpendDashboardController(
            userDefaults: defaults,
            requestBuilder: { _ in request },
            loader: { request in
                await SpendDashboardSource.load(
                    request,
                    cacheRootResolver: { _ in configuration.cacheRoot },
                    codexSnapshotLoader: { context in
                        // Provider-specific by design: the proof must invoke the real Codex cost-history scanner.
                        try await CostUsageFetcher(cacheRoot: context.cacheRoot).loadTokenSnapshot(
                            provider: .codex,
                            environment: [:],
                            now: context.now,
                            forceRefresh: true,
                            codexHomePath: context.account.homePath,
                            historyDays: context.historyDays,
                            allowPricingRefresh: false,
                            refreshPricingInBackground: false,
                            includePiSessions: false)
                    })
            },
            historyLedger: SpendHistoryLedger(fileURL: configuration.ledgerURL),
            nowProvider: { configuration.phase.now })
        controller.selectRange(.allTime)
        defaults.removePersistentDomain(forName: suiteName)
        return controller
    }

    private static func dashboardPNGData(model: SpendDashboardModel) -> Data? {
        let rootView = ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SpendDashboardHeader(
                    selectedRange: .allTime,
                    isRefreshing: false,
                    isCostTrackingEnabled: true,
                    selectRange: { _ in },
                    refresh: {})
                ForEach(model.groups) { group in
                    SpendCurrencySection(
                        group: group,
                        range: model.range,
                        requestedDays: model.requestedDays)
                }
            }
            .padding(24)
        }
        .frame(width: self.dashboardSize.width, height: self.dashboardSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        let view = NSHostingView(rootView: rootView)
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = CGRect(origin: .zero, size: self.dashboardSize)
        view.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(self.dashboardSize.width * scale),
            pixelsHigh: Int(self.dashboardSize.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else { return nil }
        representation.size = self.dashboardSize
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        view.displayIgnoringOpacity(view.bounds, in: context)
        return representation.representation(using: .png, properties: [:])
    }

    private static func validatePrivacy(
        model: SpendDashboardModel,
        payload: ShareStatsPayload,
        root: URL) throws
    {
        let providerNames = Set(model.groups.flatMap(\.providers).map(\.displayName))
        let modelNames = Set(model.groups.flatMap(\.models).map(\.modelName))
        guard providerNames == ["Codex"], modelNames == ["gpt-5.4"] else {
            throw ProofError.privacyViolation
        }
        let visibleText = ShareStatsFormatting.text(payload)
        // Provider-specific by design: reject the fixed dummy identity if it ever reaches rendered proof output.
        for forbidden in ["@", "/Users/", "/home/", root.path, "synthetic", "proof"]
            where visibleText.localizedCaseInsensitiveContains(forbidden)
        {
            throw ProofError.privacyViolation
        }
    }

    private static func validateManifestPrivacy(_ data: Data, root: URL) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw ProofError.privacyViolation }
        for forbidden in ["@", "/Users/", "/home/", root.path]
            where text.localizedCaseInsensitiveContains(forbidden)
        {
            throw ProofError.privacyViolation
        }
    }

    private static func sha256(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw ProofError.renderFailed }
        return value
    }

    private enum ProofError: Error {
        case insecureLedgerPermissions
        case missingRecordedLedger
        case privacyViolation
        case renderFailed
        case sourceFailed
        case timedOut
        case unexpectedCoverage
    }
}
#endif
