import CodexBarCore
import Foundation

extension SettingsStore {
    var importedCodexCredentialSources: [ImportedCredentialSource] {
        self.configSnapshot.importedCredentialSources.filter { source in
            source.platform == UsageProvider.codex.rawValue &&
                source.format == CLIProxyCodexAdapter.format
        }
    }

    func addImportedCredentialSource(_ source: ImportedCredentialSource) {
        self.updateConfig(reason: "imported-credential-source-add") { config in
            config.importedCredentialSources.append(source)
        }
    }

    func removeImportedCredentialSource(id: UUID) {
        self.updateConfig(reason: "imported-credential-source-remove") { config in
            config.importedCredentialSources.removeAll { $0.id == id }
        }
    }
}
