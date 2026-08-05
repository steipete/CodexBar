import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore
@testable import CodexBarWidget

@MainActor
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
}
