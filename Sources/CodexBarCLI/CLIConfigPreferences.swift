import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func preferencesCommandDescriptor() -> CommandDescriptor {
        CommandDescriptor(
            name: "preferences",
            abstract: "Transfer portable UI preferences (macOS)",
            discussion: nil,
            signature: CommandSignature(),
            subcommands: ["export", "import"].map {
                CommandDescriptor(
                    name: $0,
                    abstract: "\($0.capitalized) portable preferences",
                    discussion: nil,
                    signature: CommandSignature.describe(ConfigPreferencesOptions()).flattened())
            })
    }

    static func runConfigPreferences(_ values: ParsedValues, importing: Bool) {
        let output = CLIOutputPreferences.from(values: values)
        do {
            #if os(macOS)
            let domain = values.options["defaultsDomain"]?.last ?? PreferencesDocument.defaultsDomain
            guard let defaults = UserDefaults(suiteName: domain) else {
                throw PreferencesDocument.Error.invalid("Cannot open preferences domain")
            }
            let path = values.options["file"]?.last
            if importing {
                guard let path else { throw PreferencesDocument.Error.invalid("Import requires --file <path>") }
                let document = try PreferencesDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))
                try document.queueImport(in: defaults)
                if domain == PreferencesDocument.defaultsDomain {
                    DistributedNotificationCenter.default().postNotificationName(
                        Notification.Name(PreferencesDocument.importNotification),
                        object: nil,
                        userInfo: nil,
                        deliverImmediately: true)
                }
                if output.format == .json {
                    Self.printJSON(["status": "queued"], pretty: output.pretty)
                } else {
                    print("Preferences queued for the running app, or its next launch.")
                }
            } else {
                defaults.synchronize()
                let data = try PreferencesDocument(defaults: defaults).encoded()
                if let path {
                    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                } else {
                    FileHandle.standardOutput.write(data + Data("\n".utf8))
                }
            }
            #else
            throw PreferencesDocument.Error.invalid("UI preferences import/export requires macOS")
            #endif
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
        }
        Self.exit(code: .success, output: output, kind: .config)
    }
}

struct ConfigPreferencesOptions: CommanderParsable {
    @OptionGroup var common: CLICommonOptions
    @Option(name: .long("file"), help: "Preferences JSON path; export defaults to stdout")
    var file: String?
    @Option(name: .long("defaults-domain"), help: "macOS defaults domain (default: com.steipete.codexbar)")
    var defaultsDomain: String?
}
