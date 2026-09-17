import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct CodexRemoteCostIsolationTests {
    @Test
    func `isolated settings never mirror colors or reload widgets under a non XCTest publication policy`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var mirrors: [[ProviderInstanceID: ProviderColor]] = []
        var reloads = 0
        let recording = ProviderAccentPublication(
            isRunningTests: false,
            mirror: { mirrors.append($0); return true },
            reloadWidgetTimelines: { reloads += 1 })
        let configStore = CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json"))
        try configStore.save(CodexBarConfig(providers: [ProviderConfig(id: .codex, accentColor: "#60BA7E")]))
        let settings = SettingsStore(
            userDefaults: InMemoryUserDefaults(),
            configStore: configStore,
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }),
            performInitialProviderDetection: false,
            isolatedStartup: true,
            accentPublication: recording)
        defer { settings.configPersistTask?.cancel() }
        #expect(mirrors.isEmpty)
        #expect(reloads == 0)
        settings.setAccentColorOverride(ProviderColor(hex: 0xA56CC1), for: .codex)
        settings.setAccentColorOverride(nil, for: .codex)
        settings.updateProviderState(config: CodexBarConfig(providers: []))
        #expect(mirrors.isEmpty)
        #expect(reloads == 0)
        // Positive control proves the recording seam does not inherit XCTest's automatic no-write guard.
        #expect(ProviderAccentPalette.apply(
            config: CodexBarConfig(providers: []),
            allowsSharedDefaults: true,
            publication: recording))
        #expect(mirrors.count == 1)
    }

    @Test
    func `proof only metadata rejects argumentless relaunch without isolated environment`() {
        #expect(CodexRemoteCostNativeProof.launchDisposition(
            arguments: ["CodexBar"],
            proofOnlyBundle: true,
            root: nil,
            configuredHome: nil,
            homeDirectory: "/synthetic/ordinary-home") == .rejectedProof)
        #expect(CodexRemoteCostNativeProof.launchDisposition(
            arguments: ["CodexBar"],
            proofOnlyBundle: true,
            root: "/synthetic/proof",
            configuredHome: "/synthetic/proof/home",
            homeDirectory: "/synthetic/ordinary-home") == .rejectedProof)
        #expect(CodexRemoteCostNativeProof.launchDisposition(
            arguments: ["CodexBar"],
            proofOnlyBundle: true,
            root: "/synthetic/proof",
            configuredHome: "/synthetic/proof/home",
            homeDirectory: "/synthetic/proof/home") == .proof(root: "/synthetic/proof"))
        #expect(CodexRemoteCostNativeProof.launchDisposition(
            arguments: ["CodexBar"],
            proofOnlyBundle: true,
            root: "/synthetic/proof",
            configuredHome: nil,
            homeDirectory: "/synthetic/proof/home") == .rejectedProof)
        #expect(CodexRemoteCostNativeProof.launchDisposition(
            arguments: ["CodexBar", "--codex-remote-cost-proof"],
            proofOnlyBundle: false,
            root: nil,
            configuredHome: nil,
            homeDirectory: "/synthetic/ordinary-home") == .rejectedProof)
        #expect(CodexRemoteCostNativeProof.launchDisposition(
            arguments: ["CodexBar"],
            proofOnlyBundle: false,
            root: nil,
            configuredHome: nil,
            homeDirectory: "/synthetic/ordinary-home") == .normalApplication)
    }

    @Test
    func `proof localization bypasses defaults in later callbacks without task local inheritance`() async {
        let previous = CodexBarLocalizationOverride.setPersistentProofLanguage(nil)
        defer { CodexBarLocalizationOverride.setPersistentProofLanguage(previous) }
        let reads = PreferenceReadCounter()
        #expect(codexBarResolvedAppLanguage(isRunningTests: false, readPreference: reads.read) == "fr")
        #expect(reads.count == 1)
        CodexBarLocalizationOverride.setPersistentProofLanguage("en")
        let laterCallback: @Sendable () -> String = {
            codexBarResolvedAppLanguage(isRunningTests: false, readPreference: reads.read)
        }
        let detached = await Task.detached {
            #expect(CodexBarLocalizationOverride.appLanguage == nil)
            return laterCallback()
        }.value
        let mainQueueCallback = await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume(returning: laterCallback()) }
        }
        #expect(detached == "en")
        #expect(mainQueueCallback == "en")
        #expect(L("Today") == "Today")
        #expect(reads.count == 1)
    }
}

private final class PreferenceReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int {
        self.lock.withLock { self.reads }
    }

    func read() -> String? {
        self.lock.withLock { self.reads += 1 }
        return "fr"
    }
}
