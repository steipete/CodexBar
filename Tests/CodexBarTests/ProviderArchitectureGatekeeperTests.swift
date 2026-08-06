import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore
@testable import CodexBarWidget

// The exact-anchor catalog intentionally makes this test data file long.
// swiftlint:disable file_length

@MainActor
// swiftlint:disable:next type_body_length
struct ProviderArchitectureGatekeeperTests {
    @Test
    func `every provider has descriptor and implementation manifest entries`() {
        let expected = Set(UsageProvider.allCases)
        let descriptors = Set(ProviderDescriptorRegistry.all.map(\.id))
        let implementations = Set(ProviderImplementationRegistry.all.map(\.id))
        let missingDescriptors = expected.subtracting(descriptors).map(\.rawValue).sorted()
        let missingImplementations = expected.subtracting(implementations).map(\.rawValue).sorted()

        #expect(
            missingDescriptors.isEmpty,
            "Missing descriptor manifest entries: \(missingDescriptors.joined(separator: ", "))")
        #expect(
            missingImplementations.isEmpty,
            "Missing implementation manifest entries: \(missingImplementations.joined(separator: ", "))")
    }

    @Test
    func `credential adapters self report capabilities through descriptors`() {
        for descriptor in ProviderDescriptorRegistry.all {
            guard let adapter = descriptor.credentials else { continue }

            #expect(
                ProviderConfigEnvironment.supportsAPIKeyOverride(for: descriptor.id) ==
                    adapter.supportsAPIKeyOverride,
                "API-key capability drifted for \(descriptor.id.rawValue).")
            #expect(
                (TokenAccountSupportCatalog.support(for: descriptor.id) != nil) ==
                    (adapter.tokenAccountSupport != nil),
                "Token-account capability drifted for \(descriptor.id.rawValue).")
        }
    }

    @Test
    func `every provider can produce and read its registered settings section`() {
        let settings = testSettingsStore(suiteName: "ProviderArchitectureGatekeeperTests-settings-sections")
        let context = ProviderSettingsSnapshotContext(settings: settings, tokenOverride: nil)
        var builder = ProviderSettingsSnapshotBuilder()

        for implementation in ProviderImplementationRegistry.all {
            let providerName = implementation.id.rawValue
            let registration = ProviderDescriptorRegistry.descriptor(for: implementation.id).settingsSection
            guard let contribution = implementation.settingsSnapshot(context: context) else {
                Issue.record("Missing settings-section contribution for provider '\(providerName)'.")
                continue
            }
            #expect(
                registration.accepts(contribution),
                "Settings-section registration does not match provider '\(providerName)'.")
            builder.apply(contribution)
        }

        let snapshot = builder.build()
        for descriptor in ProviderDescriptorRegistry.all {
            #expect(
                descriptor.settingsSection.canRead(from: snapshot),
                "Could not read settings section for provider '\(descriptor.id.rawValue)'.")
        }
    }

    @Test
    func `empty settings snapshot factory has no provider sections`() {
        let snapshot = ProviderSettingsSnapshot.make()

        #expect(snapshot.abacus == nil)
        #expect(!snapshot.debugMenuEnabled)
        #expect(!snapshot.debugKeepCLISessionsAlive)
    }

    @Test
    func `every provider descriptor has a loadable SVG resource`() throws {
        let resources = try Self.repoRoot()
            .appending(path: "Sources/CodexBar/Resources", directoryHint: .isDirectory)

        for descriptor in ProviderDescriptorRegistry.all {
            let resourceName = descriptor.branding.iconResourceName
            let url = resources.appending(path: "\(resourceName).svg")
            #expect(
                FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
                "Missing SVG for \(descriptor.id.rawValue): \(resourceName).svg")
            #expect(NSImage(contentsOf: url) != nil, "Could not load \(resourceName).svg as NSImage")
        }
    }

    @Test
    func `widget provider choices match selectable descriptor metadata`() {
        let selectable = Set(ProviderDescriptorRegistry.all.filter(\.metadata.widgetSelectable).map(\.id))
        let choices = Set(ProviderChoice.allCases.map(\.provider))
        let missing = selectable.subtracting(choices).map(\.rawValue).sorted()
        let unexpected = choices.subtracting(selectable).map(\.rawValue).sorted()

        #expect(
            missing.isEmpty,
            "Missing ProviderChoice cases for widget-selectable providers: \(missing.joined(separator: ", "))")
        #expect(
            unexpected.isEmpty,
            "ProviderChoice cases marked non-selectable in descriptor metadata: \(unexpected.joined(separator: ", "))")
    }

    @Test
    func `widget short labels preserve compact provider names`() {
        let overrides: [UsageProvider: String] = [
            .antigravity: "Anti",
            .alibabatokenplan: "Token Plan",
            .vertexai: "Vertex",
            .perplexity: "Pplx",
            .mimo: "MiMo",
            .sakana: "Sakana",
            .abacus: "Abacus",
            .bedrock: "Bedrock",
            .jetbrains: "JetBrains",
            .moonshot: "Moonshot",
        ]
        for descriptor in ProviderDescriptorRegistry.all {
            let expected = overrides[descriptor.id] ?? descriptor.metadata.displayName
            #expect(
                descriptor.metadata.shortDisplayName == expected,
                "Unexpected widget short label for \(descriptor.id.rawValue).")
        }
    }

    @Test
    func `descriptor widget colors preserve the pre-derivation literals`() {
        var widgetFingerprint: UInt64 = 1_469_598_103_934_665_603
        var burnDownFingerprint = widgetFingerprint
        for descriptor in ProviderDescriptorRegistry.all {
            Self.hash(descriptor.id.rawValue.utf8, into: &widgetFingerprint)
            Self.hash(descriptor.branding.widgetColor, into: &widgetFingerprint)
            Self.hash(descriptor.id.rawValue.utf8, into: &burnDownFingerprint)
            Self.hash(descriptor.branding.burnDownWidgetColor, into: &burnDownFingerprint)
        }

        #expect(widgetFingerprint == 8_322_639_844_029_602_741)
        #expect(burnDownFingerprint == 3_478_078_203_311_670_951)
    }

    @Test
    func `descriptor unavailable debug messages preserve the legacy table`() throws {
        let descriptors = ProviderDescriptorRegistry.all.filter { $0.metadata.debugLogUnavailableMessage != nil }
        var fingerprint: UInt64 = 1_469_598_103_934_665_603
        for descriptor in descriptors {
            Self.hash(descriptor.id.rawValue.utf8, into: &fingerprint)
            try Self.hash(#require(descriptor.metadata.debugLogUnavailableMessage?.utf8), into: &fingerprint)
        }

        #expect(descriptors.count == 38)
        #expect(fingerprint == 2_208_147_801_202_684_136)
    }

    @Test
    func `debug pane provider curation preserves legacy membership and order`() {
        let descriptors = ProviderDescriptorRegistry.all
        let ordered: ((ProviderDebugPaneCapabilities) -> Int?) -> [UsageProvider] = { rank in
            descriptors.compactMap { descriptor -> (UsageProvider, Int)? in
                guard let value = rank(descriptor.metadata.debugPane) else { return nil }
                return (descriptor.id, value)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        }

        #expect(ordered { $0.probeLogOrder } == [.codex, .claude, .cursor, .augment, .amp, .ollama])
        #expect(ordered { $0.notificationSimulationOrder } == [.codex, .claude])
        #expect(ordered { $0.errorSimulationOrder } == [
            .codex, .claude, .gemini, .antigravity, .augment, .amp, .t3chat, .zoommate, .ollama,
        ])
    }

    @Test
    func `small provider capabilities preserve legacy registries`() {
        let descriptors = ProviderDescriptorRegistry.all
        #expect(Set(descriptors.filter(\.metadata.balanceOnly).map(\.id)) == [
            .deepseek, .deepinfra, .mistral, .moonshot, .poe,
        ])
        #expect(Set(descriptors.filter(\.metadata.usesDetailBackedWindow).map(\.id)) == [
            .warp, .kilo, .mistral, .deepseek, .deepinfra, .qoder, .crof, .chutes,
        ])
        #if os(macOS)
        #expect(Set(descriptors.filter(\.tokenCost.supportsTokenSnapshot).map(\.id)) == [
            .codex, .claude, .cursor, .vertexai, .bedrock,
        ])
        #else
        #expect(Set(descriptors.filter(\.tokenCost.supportsTokenSnapshot).map(\.id)) == [
            .codex, .claude, .vertexai, .bedrock,
        ])
        #endif
        #expect(Set(descriptors.filter { $0.cli.binaryLocator != nil }.map(\.id)) == [
            .codex, .claude, .gemini,
        ])

        #expect(CodexProviderDescriptor.descriptor.tokenCost.menuHintLines == [.localized("codex_api_estimate_hint")])
        #expect(ClaudeProviderDescriptor.descriptor.tokenCost.menuHintLines == [.estimate])
        #expect(CursorProviderDescriptor.descriptor.tokenCost.menuHintLines == [.estimate])
        #expect(VertexAIProviderDescriptor.descriptor.tokenCost.menuHintLines == [.localized("cost_estimate_hint")])
        #expect(BedrockProviderDescriptor.descriptor.tokenCost.menuHintLines == [
            .literal("AWS Cost Explorer billing can lag."),
        ])
        #expect(OpenAIAPIProviderDescriptor.descriptor.tokenCost.menuHintLines == [
            .literal("Reported by OpenAI Admin API organization usage."),
        ])
        #expect(MistralProviderDescriptor.descriptor.tokenCost.menuHintLines == [
            .literal("Reported by Mistral billing usage."),
        ])
    }

    @Test
    func `cross provider case clusters are derived or specifically justified`() throws {
        let root = try Self.repoRoot()
        let files = try Self.shippedSwiftSources(root: root)
        let providerIDs = Set(UsageProvider.allCases.map(\.rawValue))
        let providerFolderNames = Set(providerIDs.map { $0.lowercased() })
        var failures: [String] = []
        var constructsByPath: [String: [AllowedProviderConstruct]] = [:]

        for construct in Self.allowedProviderConstructs {
            constructsByPath[construct.path, default: []].append(construct)
        }

        for file in files {
            if Self.isProviderImplementationPath(file.path, providerFolderNames: providerFolderNames) {
                continue
            }
            let result = Self.analyze(
                file: file,
                providerIDs: providerIDs,
                allowedConstructs: constructsByPath.removeValue(forKey: file.path) ?? [])
            failures.append(contentsOf: result)
        }

        for constructs in constructsByPath.values.flatMap(\.self) {
            failures.append("\(constructs.path): allowlisted construct file does not exist in a shipped Swift target")
        }

        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    @Test
    func `provider reference scanner catches raw ID policy fallbacks`() {
        let source = #"let command = sender.representedObject as? String ?? "claude""#
        let references = Self.providerReferences(in: source, providerIDs: ["claude", "codex"])

        #expect(references.count == 1)
        #expect(references.first?.providerIDs == ["claude"])
    }

    @Test
    func `provider reference scanner ignores generic URLs and log categories`() {
        let source = #"""
        let url = "https://example.com/claude/status"
        let category = "codex"
        logger.info("claude request completed")
        """#

        #expect(Self.providerReferences(in: source, providerIDs: ["claude", "codex"]).isEmpty)
    }

    @Test
    func `provider implementation path requires a real provider folder`() {
        let folders: Set = ["claude", "codex"]

        #expect(Self.isProviderImplementationPath(
            "Sources/CodexBar/Providers/Claude/ClaudeSettings.swift",
            providerFolderNames: folders))
        #expect(!Self.isProviderImplementationPath(
            "Sources/CodexBar/Providers/Shared/ProviderHelpers.swift",
            providerFolderNames: folders))
        #expect(!Self.isProviderImplementationPath(
            "Sources/CodexBar/NotProviders/ClaudeSettings.swift",
            providerFolderNames: folders))
    }

    @Test
    func `provider clusters cannot chain beyond the fixed window`() {
        let references = [0, 10, 20, 30, 39, 40, 50, 60].map {
            ProviderReference(line: $0, providerIDs: ["codex"])
        }

        #expect(Self.providerReferenceClusters(references).map(\.lineRange) == [0...39, 40...60])
    }

    @Test
    func `one marker cannot justify two provider clusters`() {
        let source = """
        // Provider-specific by design: first fallback.
        let first = .codex













        let second = .claude
        """
        let failures = Self.analyze(
            file: SourceFile(path: "Sources/App/Shared.swift", source: source),
            providerIDs: ["claude", "codex"],
            allowedConstructs: [])

        #expect(failures.count == 1)
        #expect(failures.first?.contains(":16 ") == true)
    }

    @Test
    func `allowlisted constructs are unique and fingerprinted`() {
        let source = """
        let fallback = .codex
        """
        let construct = AllowedProviderConstruct(
            path: "Sources/App/Shared.swift",
            line: 1,
            anchor: "let fallback = .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "The fixture verifies exact construct matching.")

        #expect(Self.analyze(
            file: SourceFile(path: construct.path, source: source),
            providerIDs: ["codex"],
            allowedConstructs: [construct]).isEmpty)
        #expect(Self.analyze(
            file: SourceFile(path: construct.path, source: source + "\nlet other = .codex"),
            providerIDs: ["codex"],
            allowedConstructs: [construct]).isEmpty == false)
    }

    private struct SourceFile {
        let path: String
        let source: String
    }

    private struct ProviderReference: Equatable {
        let line: Int
        let providerIDs: Set<String>
    }

    private struct ProviderReferenceCluster {
        let references: [ProviderReference]

        var lineRange: ClosedRange<Int> {
            self.references[0].line...self.references[self.references.count - 1].line
        }

        var providerIDs: Set<String> {
            self.references.reduce(into: []) { $0.formUnion($1.providerIDs) }
        }

        var referenceCount: Int {
            self.references.reduce(0) { $0 + $1.providerIDs.count }
        }
    }

    private struct AllowedProviderConstruct {
        let path: String
        let line: Int
        let anchor: String
        let expectedProviderIDs: Set<String>
        let expectedReferenceCount: Int
        let reason: String
    }

    private static let providerCaseMarker = "Provider-specific by design:"
    private static let providerCaseMarkerWindow = 40
    private static let providerCaseClusterGap = 12
    private static let providerCaseClusterWindow = 40

    // Each entry names one uniquely anchored construct and pins its complete provider-reference fingerprint.
    // Adding or removing a reference invalidates the entry instead of silently expanding an exemption.
    // Anchor literals must remain byte-for-byte single lines for exact source verification.
    // swiftlint:disable line_length
    private static let allowedProviderConstructs: [AllowedProviderConstruct] = [
        AllowedProviderConstruct(
            path: "Sources/CodexBar/CodexHistoryOwnership.swift",
            line: 13,
            anchor: "private static let providerAccountPrefix = \"codex:v1:provider-account:\"",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact persistence prefix is Codex history's versioned owner-key schema."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/CodexOwnershipContext.swift",
            line: 31,
            anchor: "snapshot?.accountEmail(for: .codex) ??",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/CodexOwnershipContext.swift",
            line: 56,
            anchor: "?? self.snapshots[.codex]?.secondary?.resetsAt",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/CodexOwnershipContext.swift",
            line: 181,
            anchor: "self.sha256Hex(\"\\(UsageProvider.codex.rawValue):email:\\(normalizedEmail)\")",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/CostHistoryChartMenuView.swift",
            line: 950,
            anchor: "let projects = provider == .codex ? snapshot.projects : []",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/HistoricalUsagePace.swift",
            line: 221,
            anchor: "$0.provider == .codex &&",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/HistoricalUsagePace.swift",
            line: 452,
            anchor: "record.provider == .codex && record.windowKind == .secondary && record.windowMinutes > 0",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/IconRenderer.swift",
            line: 668,
            anchor: "let twistGemini = decorations.contains(.gemini)",
            expectedProviderIDs: ["antigravity", "factory", "gemini", "warp"],
            expectedReferenceCount: 4,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/InlineUsageDashboardContent.swift",
            line: 260,
            anchor: "if provider == .cursor, let meteredCostUSD = snapshot.meteredCostUSD {",
            expectedProviderIDs: ["cursor"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuBarLayout.swift",
            line: 253,
            anchor: "ProviderDescriptorRegistry.descriptor(for: provider ?? .codex).presentation.primarySemanticWindow)",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuBarLayoutEditor.swift",
            line: 629,
            anchor: "let provider = self.provider ?? .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuBarLayoutEditor.swift",
            line: 654,
            anchor: "if provider == .codex,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+CodexResetCredits.swift",
            line: 122,
            anchor: "guard input.provider == .codex,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+Costs.swift",
            line: 175,
            anchor: "let sessionLabel = if provider == .bedrock || provider == .mistral {",
            expectedProviderIDs: ["bedrock", "mistral"],
            expectedReferenceCount: 2,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+Costs.swift",
            line: 198,
            anchor: "} else if provider == .mistral,",
            expectedProviderIDs: ["mistral"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+Costs.swift",
            line: 440,
            anchor: "if style == .claude {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+Kiro.swift",
            line: 7,
            anchor: "if let authMethod = input.snapshot?.loginMethod(for: .kiro)?",
            expectedProviderIDs: ["kiro"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            line: 185,
            anchor: "guard provider == .litellm,",
            expectedProviderIDs: ["litellm"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            line: 227,
            anchor: "if input.provider == .kiro {",
            expectedProviderIDs: ["kilo", "kiro"],
            expectedReferenceCount: 2,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            line: 245,
            anchor: "if input.provider == .mimo, input.snapshot != nil {",
            expectedProviderIDs: ["mimo"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            line: 444,
            anchor: "if input.provider == .factory, snapshot.tertiary != nil {",
            expectedProviderIDs: ["alibabatokenplan", "amp", "crof", "cursor", "doubao", "factory", "grok", "sub2api"],
            expectedReferenceCount: 10,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            line: 557,
            anchor: "case .minimax:",
            expectedProviderIDs: ["codex", "minimax", "poe"],
            expectedReferenceCount: 3,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            line: 758,
            anchor: "if input.provider == .codex, !input.showOptionalCreditsAndExtraUsage {",
            expectedProviderIDs: ["claude", "codex", "copilot"],
            expectedReferenceCount: 4,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            line: 783,
            anchor: "let resetText = input.provider == .sub2api && namedWindow.window.resetsAt == nil",
            expectedProviderIDs: ["doubao", "sub2api"],
            expectedReferenceCount: 3,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            line: 854,
            anchor: "if input.provider == .antigravity,",
            expectedProviderIDs: ["antigravity"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            line: 888,
            anchor: "if provider == .claude, window.windowMinutes != 10080 {",
            expectedProviderIDs: ["antigravity", "claude", "codex"],
            expectedReferenceCount: 4,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView+ModelHelpers.swift",
            line: 920,
            anchor: "guard input.provider == .antigravity else { return nil }",
            expectedProviderIDs: ["antigravity"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView.swift",
            line: 191,
            anchor: "if provider == .openrouter, metric.id == \"primary\" {",
            expectedProviderIDs: ["openrouter"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView.swift",
            line: 489,
            anchor: "if self.provider != .codex || self.showsCodexHint,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView.swift",
            line: 635,
            anchor: "guard self.model.provider == .doubao else { return nil }",
            expectedProviderIDs: ["doubao"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView.swift",
            line: 1062,
            anchor: "if provider == .kiro,",
            expectedProviderIDs: ["kilo", "kiro"],
            expectedReferenceCount: 2,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView.swift",
            line: 1085,
            anchor: "if provider == .minimax {",
            expectedProviderIDs: ["codex", "minimax"],
            expectedReferenceCount: 2,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView.swift",
            line: 1120,
            anchor: "guard let loginMethod = snapshot?.loginMethod(for: .kilo) else {",
            expectedProviderIDs: ["kilo"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView.swift",
            line: 1204,
            anchor: "if input.provider == .antigravity {",
            expectedProviderIDs: ["antigravity", "mistral"],
            expectedReferenceCount: 2,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView.swift",
            line: 1224,
            anchor: "if input.provider == .codex, let codexProjection = input.codexProjection {",
            expectedProviderIDs: ["alibaba", "alibabatokenplan", "codex", "perplexity", "sub2api"],
            expectedReferenceCount: 6,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView.swift",
            line: 1275,
            anchor: "if input.provider == .kilo || input.provider == .kimi,",
            expectedProviderIDs: ["kilo", "kimi"],
            expectedReferenceCount: 2,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView.swift",
            line: 1357,
            anchor: "var paceDetail = if input.provider == .kimi {",
            expectedProviderIDs: ["kimi"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView.swift",
            line: 1373,
            anchor: "if input.provider == .warp,",
            expectedProviderIDs: ["chutes", "kilo", "kiro", "litellm", "sub2api", "warp"],
            expectedReferenceCount: 6,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView.swift",
            line: 1406,
            anchor: "if input.provider == .alibaba || input.provider == .alibabatokenplan,",
            expectedProviderIDs: ["alibaba", "alibabatokenplan", "copilot", "crof", "manus", "perplexity", "zenmux"],
            expectedReferenceCount: 8,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuCardView.swift",
            line: 1447,
            anchor: "if input.provider == .synthetic,",
            expectedProviderIDs: ["synthetic"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuDescriptor.swift",
            line: 197,
            anchor: "case .codex: \"⌘\"",
            expectedProviderIDs: ["claude", "codex"],
            expectedReferenceCount: 2,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuDescriptor.swift",
            line: 444,
            anchor: "if provider == .kiro {",
            expectedProviderIDs: ["kiro"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuDescriptor.swift",
            line: 458,
            anchor: "} else if provider == .kilo {",
            expectedProviderIDs: ["kilo", "mimo", "openrouter", "poe"],
            expectedReferenceCount: 4,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuDescriptor.swift",
            line: 647,
            anchor: "let target = provider ?? store.enabledFirstPartyProviders().first ?? .codex",
            expectedProviderIDs: ["claude", "codex"],
            expectedReferenceCount: 3,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuDescriptor.swift",
            line: 675,
            anchor: "if provider == .factory, snapshot.tertiary != nil {",
            expectedProviderIDs: ["alibabatokenplan", "amp", "codex", "crof", "doubao", "factory", "grok", "sub2api"],
            expectedReferenceCount: 11,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuDescriptor.swift",
            line: 750,
            anchor: "let cleaned = if provider == .codex {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/MenuOpenRefreshPlan.swift",
            line: 27,
            anchor: "refreshCodexDashboard: inputs.enabledProviders.contains(.codex))",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PredictivePaceWarnings.swift",
            line: 115,
            anchor: "guard provider == .codex || provider == .claude else { return }",
            expectedProviderIDs: ["claude", "codex"],
            expectedReferenceCount: 2,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PredictivePaceWarnings.swift",
            line: 178,
            anchor: "if provider == .codex {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PredictivePaceWarnings.swift",
            line: 204,
            anchor: "if provider == .codex {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PreferencesCodexAccountsSection.swift",
            line: 278,
            anchor: "Text(L(\"The default Codex account on this Mac.\"))",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PreferencesProvidersPane+Testing.swift",
            line: 115,
            anchor: "store.versions[.codex] = \"1.0.0\"",
            expectedProviderIDs: ["claude", "codex", "cursor", "minimax"],
            expectedReferenceCount: 4,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PreferencesProvidersPane+Testing.swift",
            line: 150,
            anchor: "if let descriptor = pane._test_tokenAccountDescriptor(for: .claude) {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PreferencesProvidersPane.swift",
            line: 274,
            anchor: "guard let state = self.codexAccountsSectionState(for: .codex), state.canAddAccount else {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PreferencesProvidersPane.swift",
            line: 290,
            anchor: "guard let state = self.codexAccountsSectionState(for: .codex), state.canReauthenticate(account) else {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PreferencesProvidersPane.swift",
            line: 303,
            anchor: "guard let state = self.codexAccountsSectionState(for: .codex), state.canReauthenticate(account) else {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PreferencesSpendDashboardPane.swift",
            line: 254,
            anchor: "self.configuration.providerIDs.contains(UsageProvider.codex.rawValue)",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PreferencesSpendDashboardPane.swift",
            line: 282,
            anchor: "L(\"Estimated from local Codex logs for the selected account.\")",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/PreferencesSpendDashboardPane.swift",
            line: 365,
            anchor: ".count { $0.provider == .codex }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 3,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/Providers/Shared/ProviderTokenAccountSelection.swift",
            line: 28,
            anchor: "guard provider == .deepseek else { return settings.showOptionalCreditsAndExtraUsage }",
            expectedProviderIDs: ["deepseek"],
            expectedReferenceCount: 1,
            reason: "This exact shared provider integration dispatches a capability owned by the provider descriptor or adapter."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SessionQuotaNotifications.swift",
            line: 198,
            anchor: "if transition != .restored || observation.provider != .codex {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 3,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SessionQuotaNotifications.swift",
            line: 273,
            anchor: "codexOwnerKey: observation.provider == .codex ? observation.codexOwnerKey : nil,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SessionQuotaNotifications.swift",
            line: 288,
            anchor: "let trustedResetBoundary: Date? = if observation.provider != .codex {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SessionQuotaNotifications.swift",
            line: 304,
            anchor: "codexOwnerKey: observation.provider == .codex ? observation.codexOwnerKey : nil,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SessionQuotaNotifications.swift",
            line: 430,
            anchor: "if provider == .crof, snapshot.secondary == nil {",
            expectedProviderIDs: ["copilot", "crof"],
            expectedReferenceCount: 2,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SessionQuotaNotifications.swift",
            line: 451,
            anchor: "if provider == .codex,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SettingsStore+MenuPreferences.swift",
            line: 259,
            anchor: "(provider == .codex && self.codexLocalSessionCostLedgerEnabled)",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SettingsStore.swift",
            line: 1020,
            anchor: "if !seen.contains(.factory), let zaiIndex = ordered.firstIndex(of: .zai) {",
            expectedProviderIDs: ["factory", "minimax", "zai"],
            expectedReferenceCount: 4,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SpendDashboardController.swift",
            line: 135,
            anchor: "let codexRequests = providers.contains(.codex)",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SpendDashboardController.swift",
            line: 184,
            anchor: "let providerBaselines = initialProviders.filter { $0 != .codex }.map { provider in",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SpendDashboardController.swift",
            line: 203,
            anchor: "let codexRequests = providers.contains(.codex)",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SpendDashboardController.swift",
            line: 224,
            anchor: "for provider in providers where provider != .codex {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SpendDashboardController.swift",
            line: 466,
            anchor: "if providers.contains(.codex) {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SpendDashboardController.swift",
            line: 521,
            anchor: "guard provider != .codex else { return nil }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SpendDashboardController.swift",
            line: 1142,
            anchor: "guard input.provider == .codex,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SpendDashboardModel+ModelBreakdown.swift",
            line: 113,
            anchor: "guard summary.input.provider == .codex else { return false }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/SpendDashboardModel.swift",
            line: 639,
            anchor: "guard provider == .mistral else { return displayCalendar }",
            expectedProviderIDs: ["mistral"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+AccountMenuDisplay.swift",
            line: 122,
            anchor: "guard providers.contains(.codex) else { return }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+AccountMenuDisplay.swift",
            line: 159,
            anchor: "guard provider == .codex else { return display }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Actions.swift",
            line: 371,
            anchor: "if provider == .qoder {",
            expectedProviderIDs: ["claude", "qoder"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Actions.swift",
            line: 441,
            anchor: "?? (self.store.isEnabled(.codex) ? .codex : self.store.enabledFirstPartyProviders().first)",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 3,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Actions.swift",
            line: 462,
            anchor: "?? (self.store.isEnabled(.codex) ? .codex : self.store.enabledFirstPartyProviders().first)",
            expectedProviderIDs: ["claude", "codex"],
            expectedReferenceCount: 3,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Actions.swift",
            line: 535,
            anchor: "?? .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Actions.swift",
            line: 594,
            anchor: "self.lazyStatusItem(for: provider ?? .codex)",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Actions.swift",
            line: 698,
            anchor: "return .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Animation.swift",
            line: 561,
            anchor: "guard isLoading, style == .warp, let phase else {",
            expectedProviderIDs: ["warp"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Animation.swift",
            line: 915,
            anchor: "if provider == .kiro {",
            expectedProviderIDs: ["cursor", "kiro"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+CompactAccountMenu.swift",
            line: 263,
            anchor: "id: ProviderAccountIdentity(source: \"codex-account\", opaqueID: account.id),",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+CostMenuCard.swift",
            line: 129,
            anchor: "+ [provider == .codex ? tokenUsage?.hintLine : nil].compactMap(\\.self)",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared renderer maps provider-owned presentation data into the generic UI model."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+CountdownRefresh.swift",
            line: 122,
            anchor: "if providers.contains(.codex) {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+HostedSubmenus.swift",
            line: 422,
            anchor: "projects: provider == .codex ? tokenSnapshot.projects : [],",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+MemoryPressure.swift",
            line: 37,
            anchor: "scope: UsageProvider.codex.rawValue,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Menu.swift",
            line: 1120,
            anchor: "return .provider((self.resolvedMenuProvider(enabledProviders: enabledProviders) ?? .codex).instanceID)",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+Menu.swift",
            line: 1133,
            anchor: "return self.store.enabledFirstPartyProvidersForDisplay().first ?? .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+MenuBarLayout.swift",
            line: 126,
            anchor: "if provider == .codex,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+MenuSwitcherWarmup.swift",
            line: 70,
            anchor: "let currentProvider = selectedProvider ?? enabledProviders.first ?? .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+MenuTracking.swift",
            line: 373,
            anchor: "if target == .kilo {",
            expectedProviderIDs: ["claude", "kilo"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+MenuTypes.swift",
            line: 14,
            anchor: "self.store.enabledProviders().isEmpty ? .codex : nil",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+MenuViewportRestore.swift",
            line: 611,
            anchor: "return .provider((self.resolvedMenuProvider() ?? .codex).instanceID)",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+OverviewSubmenus.swift",
            line: 10,
            anchor: "if provider == .openai,",
            expectedProviderIDs: ["mistral", "openai"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+ProviderNavigation.swift",
            line: 59,
            anchor: ".provider((self.navigationResolvedProvider(enabledProviders: enabledProviders) ?? .codex).instanceID)",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 4,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+ProviderNavigation.swift",
            line: 96,
            anchor: "return .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController+SwitcherMetrics.swift",
            line: 16,
            anchor: "} else if provider == .mistral {",
            expectedProviderIDs: ["mistral"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/StatusItemController.swift",
            line: 365,
            anchor: "if provider == .codex {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Accessors.swift",
            line: 65,
            anchor: "snapshot.accountEmail(for: .codex) ?? self.accountInfo(for: .codex).email),",
            expectedProviderIDs: ["codex", "deepseek"],
            expectedReferenceCount: 3,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Accessors.swift",
            line: 154,
            anchor: "case .codex:",
            expectedProviderIDs: ["codex", "ollama"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+ClaudeDebug.swift",
            line: 101,
            anchor: "lines.append(\"No planner-selected Claude source.\")",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+CodexCostCatchUp.swift",
            line: 15,
            anchor: "guard provider == .codex else { return }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+CodexCostCatchUp.swift",
            line: 252,
            anchor: "self.lastTokenFetchAt[.codex] = now",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 5,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+CodexCostCatchUp.swift",
            line: 275,
            anchor: "&& self.settings.providerConfigRevision(for: .codex) == context.providerConfigRevision",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 3,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+HighestUsage.swift",
            line: 117,
            anchor: "if provider == .cursor,",
            expectedProviderIDs: ["cursor"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+HistoricalPace.swift",
            line: 127,
            anchor: "let codexSnapshot = self.snapshots[.codex]",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+LimitResetCelebration.swift",
            line: 100,
            anchor: "let requiresLowConfirmation = context.provider == .claude",
            expectedProviderIDs: ["claude", "codex"],
            expectedReferenceCount: 3,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+LimitResetIdentity.swift",
            line: 11,
            anchor: "if provider == .codex {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+OpenAIWeb.swift",
            line: 230,
            anchor: "\"then update OpenAI cookies in Providers → Codex.\",",
            expectedProviderIDs: ["codex", "openai"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+OpenAIWeb.swift",
            line: 353,
            anchor: "guard self.lastSourceLabels[.codex] == \"openai-web\" else { return }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+OpenAIWeb.swift",
            line: 371,
            anchor: "if self.snapshots[.codex] != nil,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+OpenAIWeb.swift",
            line: 389,
            anchor: "\"Switch accounts in your browser and update OpenAI cookies in Providers → Codex.\",",
            expectedProviderIDs: ["codex", "openai"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+OpenAIWeb.swift",
            line: 418,
            anchor: "guard self.isEnabled(.codex),",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+OpenAIWeb.swift",
            line: 1078,
            anchor: "L(\"The selected managed Codex account is unavailable.\"),",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 4,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+OpenAIWeb.swift",
            line: 1512,
            anchor: "\"Sign in to chatgpt.com and update OpenAI cookies in Providers → Codex.\",",
            expectedProviderIDs: ["codex", "openai"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+OpenAIWeb.swift",
            line: 1539,
            anchor: "\"Sign in to chatgpt.com as \\(targetLabel), then update OpenAI cookies in Providers → Codex.\",",
            expectedProviderIDs: ["codex", "openai"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            line: 157,
            anchor: "var providerBuckets = self.planUtilizationHistory[.codex] ?? PlanUtilizationHistoryBuckets()",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            line: 174,
            anchor: "self.planUtilizationHistory[.codex] = providerBuckets",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            line: 224,
            anchor: "let samples = provider == .antigravity",
            expectedProviderIDs: ["antigravity", "claude"],
            expectedReferenceCount: 4,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            line: 305,
            anchor: "if provider == .antigravity,",
            expectedProviderIDs: ["antigravity", "claude", "codex"],
            expectedReferenceCount: 4,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            line: 846,
            anchor: "if provider == .claude {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            line: 861,
            anchor: "guard let identity = snapshot.identity(for: .claude) else { return nil }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            line: 888,
            anchor: "key.hasPrefix(\"\\(UsageProvider.claude.rawValue):\")",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+PlanUtilization.swift",
            line: 1318,
            anchor: "if ![UsageProvider.codex, .claude, .antigravity].contains(provider) {",
            expectedProviderIDs: ["antigravity", "claude", "codex"],
            expectedReferenceCount: 3,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+ProviderStorage.swift",
            line: 253,
            anchor: "guard uniqueProviders.contains(.codex) else { return providerKey }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+QuotaWarnings.swift",
            line: 132,
            anchor: "let extraWindows = provider == .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+QuotaWarnings.swift",
            line: 159,
            anchor: "guard provider == .claude else { return }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 342,
            anchor: "let codexPreparation = provider == .codex ? self.prepareCodexRefreshPublication() : nil",
            expectedProviderIDs: ["claude", "codex", "kilo"],
            expectedReferenceCount: 6,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 398,
            anchor: "let priorClaudeSourceLabel = provider == .claude ? self.lastSourceLabels[.claude] : nil",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 412,
            anchor: "guard provider == .codex else { return outcome }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 431,
            anchor: "if provider == .codex {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 523,
            anchor: "guard input.provider == .claude else {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 687,
            anchor: "if provider == .codex,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 721,
            anchor: "codexOwnerKey: provider == .codex ? context.codexSessionQuotaOwnerKey : nil)",
            expectedProviderIDs: ["claude", "codex", "deepseek"],
            expectedReferenceCount: 4,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 753,
            anchor: "if provider == .gemini {",
            expectedProviderIDs: ["codex", "gemini"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 771,
            anchor: "let isClaudeOAuthSample = provider == .claude",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 805,
            anchor: "if provider == .codex {",
            expectedProviderIDs: ["codex", "deepseek"],
            expectedReferenceCount: 4,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 854,
            anchor: "guard provider == .deepseek else { return snapshot }",
            expectedProviderIDs: ["codex", "deepseek"],
            expectedReferenceCount: 5,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 981,
            anchor: "guard provider == .claude, !hasSelectedTokenAccount else { return false }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 1319,
            anchor: "if provider == .gemini, Self.isGeminiConsumerTierDeprecationError(error) {",
            expectedProviderIDs: ["claude", "gemini"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 1363,
            anchor: "if provider == .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 1379,
            anchor: "if provider == .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 5,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+Refresh.swift",
            line: 1461,
            anchor: "cached.cacheKey == self.tokenAccountSnapshotCacheKey(provider: .claude, account: currentAccount)",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+SessionEquivalents.swift",
            line: 183,
            anchor: "guard ![UsageProvider.codex, .claude, .antigravity].contains(provider) else { return true }",
            expectedProviderIDs: ["antigravity", "claude", "codex"],
            expectedReferenceCount: 3,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+SessionQuotaTransition.swift",
            line: 54,
            anchor: "if provider == .codex,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+SessionQuotaTransition.swift",
            line: 76,
            anchor: "if provider == .codex {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+SpendDashboardCodexCostCatchUp.swift",
            line: 246,
            anchor: "&& self.settings.providerConfigRevision(for: .codex) == context.providerConfigRevision",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 318,
            anchor: "self.snapshots[.codex] = snapshot",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 739,
            anchor: "guard provider == .codex else { return outcome }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 822,
            anchor: "let descriptor = self.providerSpecs[.codex]?.descriptor ?? ProviderDescriptorRegistry",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 927,
            anchor: "let originalManualToken = provider == .stepfun ? self.settings.stepfunToken : nil",
            expectedProviderIDs: ["stepfun"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 969,
            anchor: "guard let self, provider == .stepfun,",
            expectedProviderIDs: ["stepfun"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 1069,
            anchor: "guard let snapshot = self.lastKnownResetSnapshots[.codex],",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 1085,
            anchor: "return self.lastKnownResetSnapshots[.codex]",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 1292,
            anchor: "if let resultEmail = CodexIdentityResolver.normalizeEmail(scoped.accountEmail(for: .codex)),",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 1370,
            anchor: "guard self.isCurrentProviderRefreshGeneration(.codex, generation: generation) else { return }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 9,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 1412,
            anchor: "self.lastFetchAttempts[.codex] = outcome.attempts",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 5,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 1451,
            anchor: "let profileStable = provider == .deepseek",
            expectedProviderIDs: ["deepseek"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 1466,
            anchor: "accountDiscriminatorOverride: provider == .claude ? warningAccountDiscriminator : nil)",
            expectedProviderIDs: ["claude", "deepseek"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 1487,
            anchor: "if provider == .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenAccounts.swift",
            line: 1512,
            anchor: "if provider == .deepseek {",
            expectedProviderIDs: ["deepseek"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenCost.swift",
            line: 218,
            anchor: "guard self.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil else { return }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenCost.swift",
            line: 241,
            anchor: "guard self.providerPublicationRevisionIsCurrent(publicationRevision, for: .codex),",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 9,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenCost.swift",
            line: 278,
            anchor: "return provider == .codex && self.codexCostCatchUpActivity?.phase == .indexing",
            expectedProviderIDs: ["claude", "codex", "vertexai"],
            expectedReferenceCount: 5,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenCost.swift",
            line: 324,
            anchor: "guard provider == .cursor else {",
            expectedProviderIDs: ["cursor"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenCost.swift",
            line: 386,
            anchor: "if provider == .cursor,",
            expectedProviderIDs: ["cursor"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenCost.swift",
            line: 406,
            anchor: "guard provider == .cursor,",
            expectedProviderIDs: ["cursor"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenCost.swift",
            line: 422,
            anchor: "case .openai:",
            expectedProviderIDs: ["mistral", "openai", "opencodego"],
            expectedReferenceCount: 3,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenCost.swift",
            line: 441,
            anchor: "case .mistral, .openai, .opencodego:",
            expectedProviderIDs: ["mistral", "openai", "opencodego"],
            expectedReferenceCount: 3,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+TokenCost.swift",
            line: 483,
            anchor: "self.tokenFailureGates[.codex]?.reset()",
            expectedProviderIDs: ["claude", "codex"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            line: 189,
            anchor: "let claudeQuotaOwnerKey: String? = if provider == .claude {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            line: 210,
            anchor: "(provider == .claude && (storedTokenSnapshot != nil || preservedClaudeUsage != nil))",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            line: 230,
            anchor: "if provider == .codex, let snapshot {",
            expectedProviderIDs: ["claude", "codex", "devin"],
            expectedReferenceCount: 3,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            line: 280,
            anchor: "if let account = self.settings.effectiveSelectedTokenAccount(for: .claude) {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            line: 295,
            anchor: "guard let entry, entry.provider == .claude else { return nil }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            line: 334,
            anchor: "let sessionLabel = if provider == .bedrock || provider == .mistral {",
            expectedProviderIDs: ["bedrock", "codex", "mistral"],
            expectedReferenceCount: 4,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            line: 364,
            anchor: "if provider == .codex {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            line: 383,
            anchor: "if provider == .claude,",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            line: 396,
            anchor: "if provider == .antigravity,",
            expectedProviderIDs: ["alibabatokenplan", "amp", "antigravity", "crof", "cursor", "doubao", "grok"],
            expectedReferenceCount: 8,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            line: 441,
            anchor: "let secondaryTitle = if provider == .amp {",
            expectedProviderIDs: ["alibabatokenplan", "amp"],
            expectedReferenceCount: 2,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            line: 466,
            anchor: "if provider == .kimi {",
            expectedProviderIDs: ["kimi"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore+WidgetSnapshot.swift",
            line: 482,
            anchor: "private nonisolated static let antigravityCompactFallbackWindowIDPrefix = \"antigravity-compact-fallback-\"",
            expectedProviderIDs: ["antigravity"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore.swift",
            line: 585,
            anchor: "self.metadata(for: .codex).browserCookieOrder ?? Browser.defaultImportOrder",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore.swift",
            line: 626,
            anchor: "self.providerSpecs[provider]?.style ?? .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore.swift",
            line: 659,
            anchor: "guard provider != .codex else { return true }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore.swift",
            line: 1008,
            anchor: "let claudeDebugConfiguration: ClaudeDebugLogConfiguration? = if provider == .claude {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore.swift",
            line: 1032,
            anchor: "let deepSeekHasTokenAccount = self.settings.selectedTokenAccount(for: .deepseek) != nil",
            expectedProviderIDs: ["deepseek"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore.swift",
            line: 1088,
            anchor: "case .augment:",
            expectedProviderIDs: ["amp", "augment", "deepseek", "elevenlabs", "notion", "ollama", "openrouter", "warp"],
            expectedReferenceCount: 8,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBar/UsageStore.swift",
            line: 1149,
            anchor: "let claudeSettings = snapshot.claude ?? ProviderSettingsSnapshot.ClaudeProviderSettings(",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact app-runtime bridge coordinates provider-owned state through the shared controller."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCLI/CLICardsCommand.swift",
            line: 170,
            anchor: "includeAllCodexAccounts: tokenSelection.allAccounts && providerList == [.codex],",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact CLI construct preserves the provider-specific command and output contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCLI/CLICostCommand.swift",
            line: 207,
            anchor: "provider == .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact CLI construct preserves the provider-specific command and output contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCLI/CLICostCommand.swift",
            line: 227,
            anchor: "let projects = provider == .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact CLI construct preserves the provider-specific command and output contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCLI/CLICostCommand.swift",
            line: 399,
            anchor: "guard provider == .cursor else { return nil }",
            expectedProviderIDs: ["cursor"],
            expectedReferenceCount: 1,
            reason: "This exact CLI construct preserves the provider-specific command and output contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCLI/CLICostCommand.swift",
            line: 419,
            anchor: "guard provider == .cursor, settings?.cookieSource == .manual else { return nil }",
            expectedProviderIDs: ["cursor"],
            expectedReferenceCount: 1,
            reason: "This exact CLI construct preserves the provider-specific command and output contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCLI/CLIOptions.swift",
            line: 68,
            anchor: "help: \"Exercise the app's Claude Auto route (verification only; requires --provider claude --source auto)\")",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact CLI construct preserves the provider-specific command and output contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCLI/CLIServeCommand.swift",
            line: 1161,
            anchor: "\"\\(configFingerprint):codex-accounts=\\(includeAllCodexAccounts ? \"all\" : \"selected\")\"",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact CLI construct preserves the provider-specific command and output contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCLI/CLIUsageCommand.swift",
            line: 182,
            anchor: "includeAllCodexAccounts: tokenSelection.allAccounts && providerList == [.codex],",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact CLI construct preserves the provider-specific command and output contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/AgentSession.swift",
            line: 258,
            anchor: "return .codex",
            expectedProviderIDs: ["claude", "codex"],
            expectedReferenceCount: 2,
            reason: "This exact host integration maps a provider-owned process, path, or window contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/AgentSession.swift",
            line: 287,
            anchor: "guard self.provider(for: record) == .claude else { return .cli }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact host integration maps a provider-owned process, path, or window contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/CodexLocalDataScope.swift",
            line: 29,
            anchor: "return self.make(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(\".codex\"))",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/CodexLocalProjectUsageModels.swift",
            line: 377,
            anchor: "public static let localChatFallbackTitle = \"Local Codex chat\"",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Config/CodexBarConfig.swift",
            line: 172,
            anchor: "region: provider == .alibabatokenplan ? alibabaTokenPlanRegion.rawValue : nil)",
            expectedProviderIDs: ["alibabatokenplan"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/CostUsageFetcher.swift",
            line: 553,
            anchor: "if provider == .codex {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/CostUsageFetcher.swift",
            line: 579,
            anchor: "provider == .claude || (provider == .codex && options.shouldMergePiUsage)",
            expectedProviderIDs: ["claude", "codex"],
            expectedReferenceCount: 5,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/CostUsageFetcher.swift",
            line: 626,
            anchor: "options.provider == .codex || options.provider == .claude",
            expectedProviderIDs: ["claude", "codex"],
            expectedReferenceCount: 2,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/CostUsageFetcher.swift",
            line: 653,
            anchor: "guard provider == .codex || provider == .claude else { return nil }",
            expectedProviderIDs: ["claude", "codex", "openai"],
            expectedReferenceCount: 5,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/CostUsageFetcher.swift",
            line: 1145,
            anchor: "if provider == .vertexai {",
            expectedProviderIDs: ["claude", "vertexai"],
            expectedReferenceCount: 2,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/CostUsageFetcher.swift",
            line: 1396,
            anchor: "if provider == .cursor {",
            expectedProviderIDs: ["cursor"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/LocalAgentSessionScanner.swift",
            line: 93,
            anchor: "guard AgentPSOutputParser.provider(for: process) == .codex else { return nil }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact host integration maps a provider-owned process, path, or window contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/LocalAgentSessionScanner.swift",
            line: 205,
            anchor: "let claudeProcesses = processes.filter { AgentPSOutputParser.provider(for: $0) == .claude }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact host integration maps a provider-owned process, path, or window contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/LocalAgentSessionScanner.swift",
            line: 221,
            anchor: "let codexProcesses = processes.filter { AgentPSOutputParser.provider(for: $0) == .codex }",
            expectedProviderIDs: ["claude", "codex"],
            expectedReferenceCount: 2,
            reason: "This exact host integration maps a provider-owned process, path, or window contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/LocalAgentSessionScanner.swift",
            line: 247,
            anchor: "case .codex:",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact host integration maps a provider-owned process, path, or window contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Logging/LogCategories.swift",
            line: 3,
            anchor: "let base = instanceID.firstPartyProvider == .opencodego ? \"opencode-go\" : instanceID.rawValue",
            expectedProviderIDs: ["opencode", "opencodego"],
            expectedReferenceCount: 2,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/OpenAIDashboardModels.swift",
            line: 146,
            anchor: "provider: UsageProvider = .codex,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/OpenAIWeb/OpenAIDashboardBrowserCookieImporter.swift",
            line: 107,
            anchor: "ProviderDefaults.metadata[.codex]?.browserCookieOrder ?? Browser.defaultImportOrder",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/OpenAIWeb/OpenAIDashboardBrowserCookieImporter.swift",
            line: 507,
            anchor: "log(\"Selected \\(candidate.label) (matches Codex: \\(signedInEmail))\")",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/PiSessionCostScanner.swift",
            line: 228,
            anchor: "guard provider == .codex || provider == .claude else { return nil }",
            expectedProviderIDs: ["claude", "codex"],
            expectedReferenceCount: 2,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/PiSessionCostScanner.swift",
            line: 259,
            anchor: "modelsDevProviderIDs: [\"anthropic\", \"openai\"]))",
            expectedProviderIDs: ["openai"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/PiSessionCostScanner.swift",
            line: 834,
            anchor: "case .codex:",
            expectedProviderIDs: ["claude", "codex"],
            expectedReferenceCount: 2,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/PiSessionCostScanner.swift",
            line: 883,
            anchor: ".codex",
            expectedProviderIDs: ["claude", "codex"],
            expectedReferenceCount: 2,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/ProviderEndpointOverrideValidator.swift",
            line: 9,
            anchor: "case let .minimax(key):",
            expectedProviderIDs: ["minimax"],
            expectedReferenceCount: 2,
            reason: "This exact shared provider integration dispatches a capability owned by the provider descriptor or adapter."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/ProviderStorageFootprint.swift",
            line: 309,
            anchor: "case .codex:",
            expectedProviderIDs: ["claude", "codex", "copilot", "cursor", "gemini", "opencode", "opencodego"],
            expectedReferenceCount: 7,
            reason: "This exact shared provider integration dispatches a capability owned by the provider descriptor or adapter."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Providers/ProviderCredentialAdapter.swift",
            line: 56,
            anchor: "} else if provider == .stepfun, self.config?.sanitizedRegion != nil {",
            expectedProviderIDs: ["stepfun"],
            expectedReferenceCount: 1,
            reason: "This exact shared provider integration dispatches a capability owned by the provider descriptor or adapter."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Providers/ProviderDiagnosticExport.swift",
            line: 426,
            anchor: "case let .minimax(details):",
            expectedProviderIDs: ["minimax"],
            expectedReferenceCount: 1,
            reason: "This exact shared provider integration dispatches a capability owned by the provider descriptor or adapter."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Providers/ProviderDiagnosticExport.swift",
            line: 560,
            anchor: "guard provider == .minimax else { return nil }",
            expectedProviderIDs: ["minimax"],
            expectedReferenceCount: 2,
            reason: "This exact shared provider integration dispatches a capability owned by the provider descriptor or adapter."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Providers/ProviderFetchPlan.swift",
            line: 194,
            anchor: "if provider == .kiro {",
            expectedProviderIDs: ["kiro"],
            expectedReferenceCount: 1,
            reason: "This exact shared provider integration dispatches a capability owned by the provider descriptor or adapter."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Providers/Shared/AliyunOneConsole/OneConsoleSECTokenResolver.swift",
            line: 191,
            anchor: "components.host = dashboardURL.host ?? \"home.qwencloud.com\"",
            expectedProviderIDs: ["qwencloud"],
            expectedReferenceCount: 1,
            reason: "This exact shared provider integration dispatches a capability owned by the provider descriptor or adapter."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/SessionWindowFocuser.swift",
            line: 70,
            anchor: "case (.claude, .desktopApp): \"com.anthropic.claudefordesktop\"",
            expectedProviderIDs: ["claude", "codex", "openai"],
            expectedReferenceCount: 3,
            reason: "This exact host integration maps a provider-owned process, path, or window contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/UsageSnapshot+SwitcherWeeklyWindow.swift",
            line: 11,
            anchor: "case .factory:",
            expectedProviderIDs: ["cursor", "factory", "perplexity"],
            expectedReferenceCount: 3,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/UsageSnapshot+SwitcherWeeklyWindow.swift",
            line: 44,
            anchor: "case .claude:",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 2,
            reason: "This exact shared construct dispatches a provider-owned capability at the generic integration boundary."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsageCache.swift",
            line: 99,
            anchor: "let expectedProducerKey = producerKey ?? self.currentProducerKey(provider: .codex)",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsageCache.swift",
            line: 162,
            anchor: "if provider == .codex {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsageCache.swift",
            line: 190,
            anchor: "if provider == .codex, data.count > maxCacheBytes {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsageCache.swift",
            line: 215,
            anchor: "if provider == .codex, data.count > maxCacheLoadBytes {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift",
            line: 222,
            anchor: "guard let pricing = self.codex[model] else { continue }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift",
            line: 423,
            anchor: "private static let codexModelsDevProviderID = \"openai\"",
            expectedProviderIDs: ["openai"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift",
            line: 437,
            anchor: "if self.codex[trimmed] != nil {",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 2,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift",
            line: 480,
            anchor: "if self.claude[base] != nil {",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift",
            line: 546,
            anchor: "guard let pricing = self.codex[key] else { return nil }",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift",
            line: 708,
            anchor: "guard let pricing = self.claude[key] else { return nil }",
            expectedProviderIDs: ["claude"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricingKey.swift",
            line: 13,
            anchor: "modelsDevProviderIDs: Set<String> = [\"openai\"]) -> String",
            expectedProviderIDs: ["openai"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner.swift",
            line: 803,
            anchor: "|| path.contains(\"/.codex/worktrees/\")",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarCore/Vendored/CostUsage/ModelsDevPricing.swift",
            line: 75,
            anchor: "[\"anthropic\", \"openai\"].allSatisfy { providerID in",
            expectedProviderIDs: ["openai"],
            expectedReferenceCount: 1,
            reason: "This exact cost scanner dispatch selects a provider-owned transcript, cache, or pricing format."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/CodexBarWidgetProvider.swift",
            line: 82,
            anchor: "self.provider = .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact WidgetKit construct preserves its compile-time provider selection contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/CodexBarWidgetProvider.swift",
            line: 117,
            anchor: "self.provider = .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact WidgetKit construct preserves its compile-time provider selection contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/CodexBarWidgetProvider.swift",
            line: 177,
            anchor: "provider: providers.first ?? .codex,",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact WidgetKit construct preserves its compile-time provider selection contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/CodexBarWidgetProvider.swift",
            line: 199,
            anchor: "let selected = providers.first { $0.instanceID == stored } ?? providers.first ?? .codex",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact WidgetKit construct preserves its compile-time provider selection contract."),
        AllowedProviderConstruct(
            path: "Sources/CodexBarWidget/CodexBarWidgetProvider.swift",
            line: 223,
            anchor: "return supported.isEmpty ? [.codex] : supported",
            expectedProviderIDs: ["codex"],
            expectedReferenceCount: 1,
            reason: "This exact WidgetKit construct preserves its compile-time provider selection contract."),
    ]
    // swiftlint:enable line_length

    private static func shippedSwiftSources(root: URL) throws -> [SourceFile] {
        var files: [SourceFile] = []
        for directoryName in ["Sources", "WidgetExtension"] {
            let directory = root.appending(path: directoryName, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { continue }
            let enumerator = try #require(FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                try files.append(SourceFile(path: path, source: String(contentsOf: url, encoding: .utf8)))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func isProviderImplementationPath(
        _ path: String,
        providerFolderNames: Set<String>) -> Bool
    {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 5,
              components[0] == "Sources",
              components[2] == "Providers"
        else { return false }
        return providerFolderNames.contains(components[3].lowercased())
    }

    private static func analyze(
        file: SourceFile,
        providerIDs: Set<String>,
        allowedConstructs: [AllowedProviderConstruct]) -> [String]
    {
        let lines = file.source.components(separatedBy: .newlines)
        let references = self.providerReferences(in: file.source, providerIDs: providerIDs)
        let clusters = self.providerReferenceClusters(references)
        let markerLines = lines.indices.filter { lines[$0].contains(self.providerCaseMarker) }
        var failures: [String] = []
        var allowedClusterIndices: Set<Int> = []

        for construct in allowedConstructs {
            guard construct.path == file.path else {
                failures.append("\(construct.path): allowlisted construct was assigned to the wrong file")
                continue
            }
            guard !construct.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                failures.append("\(file.path): allowlisted construct '\(construct.anchor)' has no written reason")
                continue
            }
            let anchorLine = construct.line - 1
            guard lines.indices.contains(anchorLine),
                  lines[anchorLine].trimmingCharacters(in: .whitespaces) == construct.anchor
            else {
                failures.append(
                    "\(file.path):\(construct.line) allowlisted construct anchor no longer matches " +
                        "'\(construct.anchor)'")
                continue
            }
            let candidateIndices = clusters.indices.filter { index in
                let range = clusters[index].lineRange
                return range
                    .contains(anchorLine) || (anchorLine < range.lowerBound && range.lowerBound - anchorLine < 12)
            }
            guard candidateIndices.count == 1, let clusterIndex = candidateIndices.first else {
                failures.append(
                    "\(file.path):\(anchorLine + 1) allowlisted construct anchor did not identify exactly one cluster")
                continue
            }
            let cluster = clusters[clusterIndex]
            guard cluster.providerIDs == construct.expectedProviderIDs,
                  cluster.referenceCount == construct.expectedReferenceCount
            else {
                failures.append(
                    "\(file.path):\(cluster.lineRange.lowerBound + 1) allowlisted construct fingerprint changed; " +
                        "expected \(construct.expectedProviderIDs.sorted())/\(construct.expectedReferenceCount), " +
                        "found \(cluster.providerIDs.sorted())/\(cluster.referenceCount)")
                continue
            }
            guard allowedClusterIndices.insert(clusterIndex).inserted else {
                failures.append("\(file.path):\(anchorLine + 1) multiple allowlist entries target the same construct")
                continue
            }
        }

        var usedMarkers: Set<Int> = []
        var previousClusterEnd = -1
        for (index, cluster) in clusters.enumerated() where !allowedClusterIndices.contains(index) {
            let lowerBound = max(previousClusterEnd + 1, cluster.lineRange.lowerBound - self.providerCaseMarkerWindow)
            let marker = markerLines.last { line in
                lowerBound...cluster.lineRange.lowerBound ~= line && !usedMarkers.contains(line)
            }
            if let marker {
                usedMarkers.insert(marker)
            } else {
                failures.append(
                    "\(file.path):\(cluster.lineRange.lowerBound + 1) has an unjustified provider-specific " +
                        "construct (\(cluster.providerIDs.sorted().joined(separator: ", ")); " +
                        "references: \(cluster.referenceCount)); derive it or add " +
                        "'// Provider-specific by design: <specific reason>' immediately before this cluster.")
            }
            previousClusterEnd = cluster.lineRange.upperBound
        }

        return failures
    }

    private static func providerReferenceClusters(
        _ references: [ProviderReference]) -> [ProviderReferenceCluster]
    {
        guard let first = references.first else { return [] }
        var clusters: [ProviderReferenceCluster] = []
        var current = [first]
        var clusterStart = first.line
        var previous = first.line

        for reference in references.dropFirst() {
            if reference.line - previous > self.providerCaseClusterGap ||
                reference.line - clusterStart >= self.providerCaseClusterWindow
            {
                clusters.append(ProviderReferenceCluster(references: current))
                current = [reference]
                clusterStart = reference.line
            } else {
                current.append(reference)
            }
            previous = reference.line
        }
        clusters.append(ProviderReferenceCluster(references: current))
        return clusters
    }

    private static func providerReferences(in source: String, providerIDs: Set<String>) -> [ProviderReference] {
        source.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            let code = self.codeBeforeLineComment(line)
            guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var matches = Set(providerIDs.filter { self.containsDottedProviderCase($0, in: code) })
            for literal in self.quotedStringLiterals(in: code) {
                for providerID in providerIDs where self.isProviderIDLiteral(
                    providerID,
                    literal: literal,
                    line: code)
                {
                    matches.insert(providerID)
                }
            }
            return matches.isEmpty ? nil : ProviderReference(line: index, providerIDs: matches)
        }
    }

    private static func containsDottedProviderCase(_ rawValue: String, in line: String) -> Bool {
        let needle = ".\(rawValue)"
        var searchStart = line.startIndex
        while let range = line.range(of: needle, range: searchStart..<line.endIndex) {
            if range.upperBound == line.endIndex || !Self.isIdentifierCharacter(line[range.upperBound]),
               self.isProviderPolicyPosition(rawValue, range: range, line: line)
            {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isProviderPolicyPosition(
        _ rawValue: String,
        range: Range<String.Index>,
        line: String) -> Bool
    {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let suffix = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("case ") || trimmed.hasPrefix("switch ") ||
            trimmed.hasPrefix("if ") || trimmed.hasPrefix("guard ") ||
            trimmed.hasPrefix("else if ") || trimmed.hasPrefix("return .\(rawValue)")
        {
            return true
        }
        if ["==", "!=", "??", " ? ", ".contains(", ".filter", "rawValue"]
            .contains(where: line.contains)
        {
            return true
        }
        if prefix.isEmpty, suffix.hasPrefix(":") || suffix.hasPrefix(",") || suffix.isEmpty {
            return true
        }
        if prefix.hasSuffix("=") || prefix.hasSuffix("[") || prefix.hasSuffix(",") {
            return true
        }
        return suffix.hasPrefix(":")
    }

    private static func isProviderIDLiteral(_ providerID: String, literal: String, line: String) -> Bool {
        let lowercasedLiteral = literal.lowercased()
        guard self.containsWord(providerID, in: lowercasedLiteral) else { return false }
        let lowercasedLine = line.lowercased()
        if ["http://", "https://", "logger", "log.", "category"].contains(where: lowercasedLine.contains) {
            return false
        }
        let policyKeywords = ["provider", "rawvalue", "representedobject", "fallback", "default", "selected"]
        if lowercasedLiteral == providerID {
            return policyKeywords.contains(where: lowercasedLine.contains)
        }
        return policyKeywords
            .contains(where: lowercasedLine.contains)
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: word, range: searchStart..<text.endIndex) {
            let hasLeftBoundary = range.lowerBound == text.startIndex ||
                !self.isIdentifierCharacter(text[text.index(before: range.lowerBound)])
            let hasRightBoundary = range.upperBound == text.endIndex ||
                !self.isIdentifierCharacter(text[range.upperBound])
            if hasLeftBoundary, hasRightBoundary {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func quotedStringLiterals(in line: String) -> [String] {
        var literals: [String] = []
        var current = ""
        var isInsideString = false
        var isEscaped = false
        for character in line {
            if isInsideString {
                if isEscaped {
                    current.append(character)
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    literals.append(current)
                    current = ""
                    isInsideString = false
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                isInsideString = true
            }
        }
        return literals
    }

    private static func codeBeforeLineComment(_ line: String) -> String {
        var previous: Character?
        var isInsideString = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"", previous != "\\" {
                isInsideString.toggle()
            } else if character == "/", !isInsideString {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "/" {
                    return String(line[..<index])
                }
            }
            previous = character
            index = line.index(after: index)
        }
        return line
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path(percentEncoded: false))
            {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func hash(_ color: ProviderColor, into fingerprint: inout UInt64) {
        for component in [color.red, color.green, color.blue] {
            var bits = component.bitPattern
            for _ in 0..<MemoryLayout<UInt64>.size {
                fingerprint = (fingerprint ^ UInt64(UInt8(truncatingIfNeeded: bits))) &* 1_099_511_628_211
                bits >>= 8
            }
        }
    }

    private static func hash(_ bytes: String.UTF8View, into fingerprint: inout UInt64) {
        for byte in bytes {
            fingerprint = (fingerprint ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
